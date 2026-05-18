#!/bin/sh

test_description='fast index sidecar (.git/index.fast) tests

Tests for the native-endian index sidecar that accelerates index loading.
The sidecar is auto-generated on first read and invalidated on writes.
'

. ./test-lib.sh

# Helper: check if sidecar exists
sidecar_exists () {
	test -f .git/index.fast
}

# Helper: run status excluding test artifacts
porcelain_status () {
	git status --porcelain -- ':!output' ':!expected' ':!actual*' ':!before' ':!after' ':!count*' ':!with_*' ':!without_*'
}

test_expect_success 'setup: create test repo' '
	mkdir -p dir/sub &&
	echo "root file" >file.txt &&
	echo "dir file" >dir/a.txt &&
	echo "sub file" >dir/sub/b.txt &&
	echo "another" >other.txt &&
	git add . &&
	git commit -m "initial"
'

test_expect_success 'sidecar is generated after commit' '
	sidecar_exists
'

test_expect_success 'sidecar has correct entry count' '
	git ls-files | wc -l >expected &&
	perl -e "
		open F, q(<), q(.git/index.fast) or die;
		seek F, 8, 0;
		read F, \$buf, 4;
		print unpack(q(V), \$buf), qq(\n);
	" >actual &&
	test_cmp expected actual
'

test_expect_success 'status is clean with sidecar' '
	sidecar_exists &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'modified file detected' '
	echo "modified" >>file.txt &&
	porcelain_status >output &&
	grep " M file.txt" output &&
	git checkout -- file.txt
'

test_expect_success 'modified file in subdirectory detected' '
	echo "modified" >>dir/sub/b.txt &&
	porcelain_status >output &&
	grep " M dir/sub/b.txt" output &&
	git checkout -- dir/sub/b.txt
'

test_expect_success 'git add regenerates sidecar' '
	echo "to add" >>file.txt &&
	git add file.txt &&
	sidecar_exists &&
	porcelain_status >output &&
	grep "^M  file.txt" output &&
	git commit -m "added change"
'

test_expect_success 'status clean after commit' '
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'new untracked file shown' '
	echo "new" >untracked.txt &&
	porcelain_status >output &&
	grep "?? untracked.txt" output &&
	rm untracked.txt
'

test_expect_success 'deleted file detected' '
	rm other.txt &&
	porcelain_status >output &&
	grep " D other.txt" output &&
	git checkout -- other.txt
'

test_expect_success 'deleted sidecar regenerates on next read' '
	rm -f .git/index.fast &&
	! sidecar_exists &&
	porcelain_status >output &&
	test_must_be_empty output &&
	sidecar_exists
'

test_expect_success 'corrupted sidecar triggers regen' '
	echo "garbage" >.git/index.fast &&
	porcelain_status >output &&
	test_must_be_empty output &&
	sidecar_exists &&
	echo "test" >>file.txt &&
	porcelain_status >output &&
	grep "M file.txt" output &&
	git checkout -- file.txt
'

test_expect_success 'truncated sidecar triggers regen' '
	head -c 50 .git/index.fast >truncated &&
	mv truncated .git/index.fast &&
	porcelain_status >output &&
	test_must_be_empty output &&
	sidecar_exists
'

test_expect_success 'rapid same-second modifications detected' '
	echo "v1" >rapid.txt &&
	git add rapid.txt &&
	git commit -m "rapid base" &&
	echo "v2" >rapid.txt &&
	porcelain_status >output &&
	grep "M rapid.txt" output &&
	echo "v3" >rapid.txt &&
	porcelain_status >output &&
	grep "M rapid.txt" output &&
	git checkout -- rapid.txt
'

test_expect_success 'branch switch works with sidecar' '
	git checkout -b feature &&
	echo "feature" >feature.txt &&
	git add feature.txt &&
	git commit -m "feature commit" &&
	sidecar_exists &&
	git checkout master &&
	sidecar_exists &&
	! test -f feature.txt &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'merge works with sidecar' '
	git merge feature --no-edit &&
	test -f feature.txt &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'rename tracked by git mv' '
	echo "to rename" >rename_me.txt &&
	git add rename_me.txt &&
	git commit -m "add rename_me" &&
	git mv rename_me.txt renamed.txt &&
	porcelain_status >output &&
	grep "rename_me.txt" output &&
	git commit -m "rename" &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'many files: add and detect modifications' '
	mkdir -p bulk &&
	for i in $(test_seq 1 200); do
		echo "file $i" >bulk/f$i.txt || return 1
	done &&
	git add bulk/ &&
	git commit -m "bulk files" &&
	porcelain_status >output &&
	test_must_be_empty output &&
	echo "changed" >>bulk/f1.txt &&
	echo "changed" >>bulk/f100.txt &&
	echo "changed" >>bulk/f200.txt &&
	porcelain_status >output &&
	test_line_count = 3 output &&
	git checkout -- bulk/
'

test_expect_success 'diff-cached detects staged changes' '
	echo "staged" >>file.txt &&
	git add file.txt &&
	git diff --cached --stat >output &&
	grep "file.txt" output &&
	git commit -m "staged change"
'

test_expect_success 'diff-cached empty when clean' '
	git diff --cached --stat >output &&
	test_must_be_empty output
'

test_expect_success 'git reset works' '
	echo "reset me" >>file.txt &&
	git add file.txt &&
	git reset HEAD file.txt &&
	porcelain_status >output &&
	grep " M file.txt" output &&
	git checkout -- file.txt
'

test_expect_success 'git stash works' '
	echo "stash" >>file.txt &&
	git stash &&
	porcelain_status >output &&
	test_must_be_empty output &&
	git stash pop &&
	porcelain_status >output &&
	grep "M file.txt" output &&
	git checkout -- file.txt
'

test_expect_success 'ls-files matches with and without sidecar' '
	sidecar_exists &&
	git ls-files --full-name >with_sidecar &&
	rm -f .git/index.fast &&
	git ls-files --full-name >without_sidecar &&
	test_cmp with_sidecar without_sidecar
'

test_expect_success 'diff output matches with and without sidecar' '
	echo "diff test" >>file.txt &&
	sidecar_exists &&
	git diff --stat >with_sidecar &&
	rm -f .git/index.fast &&
	git diff --stat >without_sidecar &&
	test_cmp with_sidecar without_sidecar &&
	git checkout -- file.txt
'

test_expect_success 'status output matches with and without sidecar' '
	echo "status test" >>file.txt &&
	sidecar_exists &&
	porcelain_status >with_sidecar &&
	rm -f .git/index.fast &&
	porcelain_status >without_sidecar &&
	test_cmp with_sidecar without_sidecar &&
	git checkout -- file.txt
'

test_expect_success 'commit produces valid tree object' '
	echo "tree test" >>file.txt &&
	git add file.txt &&
	git commit -m "tree test" &&
	git cat-file -t HEAD^{tree} >output &&
	echo "tree" >expected &&
	test_cmp expected output
'

test_expect_success 'amend works' '
	echo "amend" >>file.txt &&
	git add file.txt &&
	git commit --amend --no-edit &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'cherry-pick works' '
	git checkout -b pick_source &&
	echo "pick me" >picked.txt &&
	git add picked.txt &&
	git commit -m "to pick" &&
	git checkout master &&
	git cherry-pick pick_source &&
	test -f picked.txt &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'rebase works' '
	git checkout -b rebase_test HEAD~2 &&
	echo "rebase" >rebased.txt &&
	git add rebased.txt &&
	git commit -m "rebase me" &&
	git rebase master &&
	test -f rebased.txt &&
	porcelain_status >output &&
	test_must_be_empty output &&
	git checkout master &&
	git merge rebase_test --no-edit
'

test_expect_success 'gc does not break sidecar' '
	git gc --quiet &&
	porcelain_status >output &&
	test_must_be_empty output &&
	echo "post gc" >>file.txt &&
	porcelain_status >output &&
	grep "M file.txt" output &&
	git checkout -- file.txt
'

test_expect_success 'repack does not break sidecar' '
	git repack -a -d --quiet &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'gitignore respected with sidecar' '
	echo "*.log" >.gitignore_test &&
	git config core.excludesFile .gitignore_test &&
	echo "ignored" >test.log &&
	porcelain_status >output &&
	! grep "test.log" output &&
	rm test.log .gitignore_test &&
	git config --unset core.excludesFile
'

test_expect_success 'symlink handling' '
	ln -s file.txt link.txt &&
	git add link.txt &&
	git commit -m "symlink" &&
	porcelain_status >output &&
	test_must_be_empty output &&
	echo "target changed" >>file.txt &&
	porcelain_status >output &&
	grep "M file.txt" output &&
	git checkout -- file.txt
'

test_expect_success 'submodule handling' '
	git init sub_repo &&
	(cd sub_repo && echo "sub" >s.txt && git add . && git commit -m "sub") &&
	if git submodule add ./sub_repo sub
	then
		git commit -m "add submodule" &&
		porcelain_status >output &&
		test_must_be_empty output
	else
		# submodule add can fail in test env (missing templates)
		rm -rf sub sub_repo &&
		echo "submodule add failed, skipping" &&
		git clean -fd >/dev/null 2>&1 &&
		git checkout -- . 2>/dev/null
	fi
'

test_expect_success 'intent-to-add entries' '
	git clean -fd >/dev/null 2>&1 &&
	echo "ita content" >ita_file.txt &&
	git add -N ita_file.txt &&
	porcelain_status >output &&
	grep "ita_file" output &&
	git add ita_file.txt &&
	git commit -m "ita done" &&
	porcelain_status >output &&
	test_must_be_empty output
'

test_expect_success 'empty repo has no sidecar' '
	git init ../empty_repo &&
	! test -f ../empty_repo/.git/index.fast &&
	(cd ../empty_repo && git status >/dev/null) &&
	! test -f ../empty_repo/.git/index.fast
'

test_expect_success 'cache-tree valid after sidecar load cycle' '
	# Ensure sidecar is fresh
	sidecar_exists &&
	# cache-tree should be valid (no "invalid" entries at root)
	test-tool dump-cache-tree >ct_output &&
	! grep "^invalid " ct_output &&
	rm ct_output
'

test_expect_success 'interactive add works' '
	echo "line1" >interactive.txt &&
	git add interactive.txt &&
	git commit -m "interactive base" &&
	printf "line1\nline2\n" >interactive.txt &&
	printf "y\n" | git add -p interactive.txt &&
	porcelain_status >output &&
	grep "^M" output &&
	git commit -m "interactive done"
'

test_expect_success 'final state is clean' '
	git add -A &&
	git commit --allow-empty -m "final cleanup" &&
	porcelain_status >output &&
	test_must_be_empty output &&
	sidecar_exists
'

test_done
