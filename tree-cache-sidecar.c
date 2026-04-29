/*
 * tree-cache-sidecar.c - Flat HEAD tree sidecar for fast diff --cached
 *
 * Instead of traversing 220K tree objects (decompressing each from packfiles),
 * we store a flat array of OIDs in index order. This allows O(n) linear
 * comparison against the index with zero tree decompression.
 *
 * File format (.git/head-tree.fast):
 *   [20-byte HEAD commit OID] [20-byte entry OID × cache_nr]
 *
 * Staleness: if HEAD changes, the file is stale and we fall back to
 * normal traverse_trees.
 */
#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "environment.h"
#include "hash.h"
#include "hex.h"
#include "object.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "tree.h"
#include "tree-walk.h"
#include "setup.h"
#include "trace2.h"
#include "path.h"

#include <sys/mman.h>

static char *head_tree_sidecar_path(void)
{
	return repo_git_path(the_repository, "head-tree.fast");
}

/*
 * Try to use the flat tree sidecar for a fast diff --cached.
 * Returns: number of staged changes found (0 = clean), or -1 if
 * sidecar is stale/missing and caller should fall back to normal path.
 *
 * When successful, calls the diff callback for each entry that differs.
 */
int try_fast_diff_cached(struct index_state *istate,
			 const struct object_id *head_oid,
			 void (*cb)(const char *path, int namelen,
				    const struct object_id *tree_oid,
				    const struct object_id *index_oid,
				    unsigned int mode, void *data),
			 void *cb_data)
{
	char *path = head_tree_sidecar_path();
	int fd, ret = -1;
	struct stat st;
	char *fmap;
	size_t fmap_size;
	int hashsz = the_hash_algo->rawsz;
	size_t expected_size;
	unsigned int i, nr, changes = 0;
	const unsigned char *tree_oids;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		goto done;

	if (fstat(fd, &st)) {
		close(fd);
		goto done;
	}

	nr = istate->cache_nr;
	expected_size = (size_t)hashsz + (size_t)nr * hashsz;
	fmap_size = xsize_t(st.st_size);

	if (fmap_size != expected_size) {
		close(fd);
		goto done;
	}

	fmap = xmmap_gently(NULL, fmap_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (fmap == MAP_FAILED)
		goto done;

	/* Check HEAD OID matches */
	if (memcmp(fmap, head_oid->hash, hashsz) != 0) {
		munmap(fmap, fmap_size);
		goto done;
	}

	/* Linear scan: compare each entry's OID */
	tree_oids = (const unsigned char *)(fmap + hashsz);

	trace2_region_enter("diff", "fast_diff_cached", istate->repo);

	for (i = 0; i < nr; i++) {
		struct cache_entry *ce = istate->cache[i];
		const unsigned char *tree_oid_raw = tree_oids + (size_t)i * hashsz;

		/* Skip intent-to-add entries (not in tree) */
		if (ce->ce_flags & CE_INTENT_TO_ADD)
			continue;

		if (memcmp(ce->oid.hash, tree_oid_raw, hashsz) != 0) {
			if (cb) {
				struct object_id toid;
				oidread(&toid, tree_oid_raw, the_repository->hash_algo);
				cb(ce->name, ce_namelen(ce), &toid, &ce->oid,
				   ce->ce_mode, cb_data);
			}
			changes++;
		}
	}

	trace2_region_leave("diff", "fast_diff_cached", istate->repo);

	munmap(fmap, fmap_size);
	ret = changes;
done:
	free(path);
	return ret;
}

/*
 * Generate the flat tree sidecar by walking the HEAD tree recursively
 * and storing OIDs in index order.
 */
struct tree_flatten_ctx {
	unsigned char *oid_buf;
	struct index_state *istate;
	unsigned int pos;
};

static int flatten_tree_recursive(const struct object_id *tree_oid,
				  struct strbuf *base,
				  struct tree_flatten_ctx *ctx)
{
	struct tree *tree;
	struct tree_desc desc;
	struct name_entry entry;
	int hashsz = the_hash_algo->rawsz;
	size_t baselen = base->len;

	tree = repo_parse_tree_indirect(the_repository, tree_oid);
	if (!tree)
		return -1;

	init_tree_desc(&desc, &tree->object.oid, tree->buffer, tree->size);

	while (tree_entry(&desc, &entry)) {
		strbuf_setlen(base, baselen);
		strbuf_add(base, entry.path, entry.pathlen);

		if (S_ISDIR(entry.mode)) {
			strbuf_addch(base, '/');
			if (flatten_tree_recursive(&entry.oid, base, ctx) < 0)
				return -1;
		} else {
			/* Find this entry in the index */
			int pos = index_name_pos(ctx->istate, base->buf, base->len);
			if (pos >= 0 && (unsigned int)pos < ctx->istate->cache_nr) {
				memcpy(ctx->oid_buf + (size_t)pos * hashsz,
				       entry.oid.hash, hashsz);
			}
		}
	}

	return 0;
}

void write_head_tree_sidecar(struct index_state *istate,
			     const struct object_id *head_oid,
			     const struct object_id *tree_oid)
{
	char *path = head_tree_sidecar_path();
	char *tmp_path;
	int fd, hashsz = the_hash_algo->rawsz;

	/* Skip write if sidecar already exists and matches current HEAD */
	{
		int check_fd = open(path, O_RDONLY);
		if (check_fd >= 0) {
			unsigned char stored_oid[GIT_MAX_RAWSZ];
			if (read(check_fd, stored_oid, hashsz) == hashsz &&
			    !memcmp(stored_oid, head_oid->hash, hashsz)) {
				close(check_fd);
				free(path);
				return;
			}
			close(check_fd);
		}
	}

	tmp_path = xstrfmt("%s.tmp", path);
	unsigned int nr = istate->cache_nr;
	size_t oid_buf_size = (size_t)nr * hashsz;
	unsigned char *oid_buf;
	struct strbuf base = STRBUF_INIT;
	struct tree_flatten_ctx ctx;

	fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd < 0)
		goto done;

	/* Allocate buffer for all OIDs, fill with zeros (null OID = not in tree) */
	oid_buf = xcalloc(nr, hashsz);

	ctx.oid_buf = oid_buf;
	ctx.istate = istate;
	ctx.pos = 0;

	/* Ensure name_hash is initialized for index_name_pos */
	/* (Should already be from status path) */

	if (flatten_tree_recursive(tree_oid, &base, &ctx) < 0) {
		free(oid_buf);
		close(fd);
		unlink(tmp_path);
		goto done;
	}

	if (write(fd, head_oid->hash, hashsz) != hashsz ||
	    write(fd, oid_buf, oid_buf_size) != (ssize_t)oid_buf_size) {
		free(oid_buf);
		close(fd);
		unlink(tmp_path);
		goto done;
	}

	free(oid_buf);
	close(fd);

	if (rename(tmp_path, path))
		unlink(tmp_path);

done:
	strbuf_release(&base);
	free(tmp_path);
	free(path);
}
