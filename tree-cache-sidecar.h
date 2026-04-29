#ifndef TREE_CACHE_SIDECAR_H
#define TREE_CACHE_SIDECAR_H

struct index_state;
struct object_id;

/*
 * Try fast diff --cached using the flat tree sidecar.
 * Returns number of staged changes (0 = clean), or -1 if sidecar
 * is stale/missing (caller should fall back to normal traverse_trees).
 */
int try_fast_diff_cached(struct index_state *istate,
			 const struct object_id *head_oid,
			 void (*cb)(const char *path, int namelen,
				    const struct object_id *tree_oid,
				    const struct object_id *index_oid,
				    unsigned int mode, void *data),
			 void *cb_data);

/*
 * Generate the flat tree sidecar from HEAD's tree.
 * Called after status/commit to keep the sidecar fresh.
 */
void write_head_tree_sidecar(struct index_state *istate,
			     const struct object_id *head_oid,
			     const struct object_id *tree_oid);

#endif /* TREE_CACHE_SIDECAR_H */
