#!/usr/bin/env bash
# tests/test-sync-back.sh
# End-to-end test suite for drift sync (lib/sync.sh via bin/drift)

set -euo pipefail

DRIFT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIFT_CMD="$DRIFT_ROOT/bin/drift"

# ── Tiny test framework ───────────────────────────────────────────────────────
PASS=0; FAIL=0
_pass() { echo "  ✓ $1"; (( PASS++ )) || true; }
_fail() { echo "  ✗ $1"; (( FAIL++ )) || true; }

assert_exit_ok()       { [[ "$1" -eq 0  ]] && _pass "$2" || _fail "$2 (exit $1)"; }
assert_exit_err()      { [[ "$1" -ne 0  ]] && _pass "$2" || _fail "$2 (expected non-zero, got $1)"; }
assert_file()          { [[ -f "$1"     ]] && _pass "$2" || _fail "$2 (not a file: $1)"; }
assert_not_file()      { [[ ! -f "$1"   ]] && _pass "$2" || _fail "$2 (should not exist: $1)"; }
assert_file_contains() {
  [[ -f "$1" ]] && grep -qF "$2" "$1" \
    && _pass "$3" || _fail "$3 (not found in $1: '$2')"; }
assert_file_not_contains() {
  if [[ ! -f "$1" ]]; then _pass "$3"; return; fi
  grep -qF "$2" "$1" && _fail "$3 (found in $1: '$2')" || _pass "$3"; }
assert_branch_exists() {
  git -C "$1" rev-parse --verify "$2" >/dev/null 2>&1 \
    && _pass "$3" || _fail "$3 (branch not found: $2)"; }
assert_no_rej_files()  {
  local count; count="$(find "$1" -name '*.rej' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]] && _pass "$2" || _fail "$2 ($count .rej files found)"; }
assert_rej_file_exists() {
  local count; count="$(find "$1" -name '*.rej' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -gt 0 ]] && _pass "$2" || _fail "$2 (no .rej files found)"; }
assert_unmerged_paths() {
  local count; count="$(git -C "$1" ls-files --unmerged 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -gt 0 ]] && _pass "$2" || _fail "$2 (no unmerged paths in $1)"; }
assert_stderr_contains() {
  [[ "$1" == *"$2"* ]] && _pass "$3" || _fail "$3 (stderr: $1)"; }

# ── Setup / teardown ──────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
STDERR_FILE="$TMP/stderr"
WORKSPACES_DIR="$TMP/workspaces"
mkdir -p "$WORKSPACES_DIR"

export DRIFT_WORKSPACES_DIR="$WORKSPACES_DIR"

P="sb$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

cleanup() {
  set +e
  rm -rf -- "$TMP"
}
trap cleanup EXIT

run_prepare() {
  bash "$DRIFT_CMD" prepare "$@" 2>"$STDERR_FILE" || true
}

run_sync() {
  local ws="$1"; shift
  RUN_STDOUT="$(bash "$DRIFT_CMD" sync "$ws" "$@" 2>"$STDERR_FILE" </dev/null)" && RUN_EXIT=0 || RUN_EXIT=$?
  RUN_STDERR="$(cat "$STDERR_FILE")"
}

# Helper: create a git repo with a single commit
make_git_repo() {
  local dir="$1"; shift
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  for f in "$@"; do
    mkdir -p "$(dirname "$dir/$f")"
    echo "original content of $f" > "$dir/$f"
  done
  git -C "$dir" add -A
  git -C "$dir" commit --quiet -m "Initial"
}

# Helper: create a plain (non-git) directory
make_plain_dir() {
  local dir="$1"; shift
  mkdir -p "$dir"
  for f in "$@"; do
    mkdir -p "$(dirname "$dir/$f")"
    echo "original content of $f" > "$dir/$f"
  done
}

# Helper: create a drift workspace from a source directory
make_workspace() {
  local ws_name="$1" src_dir="$2"
  bash "$DRIFT_CMD" prepare "$ws_name" "$src_dir" >/dev/null 2>&1
  echo "$WORKSPACES_DIR/$ws_name"
}

# ── Test cases ────────────────────────────────────────────────────────────────

# ── Test 1: Clean sync to a git original, --3way ─────────────────────────────
echo ""
echo "=== Test 1: Clean sync, git original, --3way ==="
ORIG="$TMP/t1-orig"
make_git_repo "$ORIG" "src/foo.ts" "lib/bar.ts"
WS="$(make_workspace "${P}-t1" "$ORIG")"
echo "modified by AI" > "$WS/$(basename "$ORIG")/src/foo.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0"
assert_file_contains "$ORIG/src/foo.ts" "modified by AI" "change applied to original"
assert_branch_exists "$ORIG" "drift/${P}-t1" "safety branch created"
assert_no_rej_files "$ORIG" "no .rej files"

# ── Test 2: Clean sync, non-git original, --reject ───────────────────────────
echo ""
echo "=== Test 2: Clean sync, non-git original, --reject ==="
ORIG="$TMP/t2-orig"
make_plain_dir "$ORIG" "src/main.py" "README.md"
WS="$(make_workspace "${P}-t2" "$ORIG")"
echo "AI added this" >> "$WS/$(basename "$ORIG")/README.md"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS" --reject --force
assert_exit_ok "$RUN_EXIT" "exits 0"
assert_file_contains "$ORIG/README.md" "AI added this" "change applied to original"
assert_no_rej_files "$ORIG" "no .rej files"

# ── Test 3: Diverged git repo — workspace version wins cleanly ───────────────
echo ""
echo "=== Test 3: Diverged git repo, workspace version wins ==="
ORIG="$TMP/t3-orig"
make_git_repo "$ORIG" "src/handler.ts"
WS="$(make_workspace "${P}-t3" "$ORIG")"
echo "AI version line" >> "$WS/$(basename "$ORIG")/src/handler.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"
echo "original version line" >> "$ORIG/src/handler.ts"
git -C "$ORIG" add -A
git -C "$ORIG" commit --quiet -m "Original also changed"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 (workspace version wins cleanly)"
assert_file_contains "$ORIG/src/handler.ts" "AI version line" "AI change applied"

# ── Test 4: Diverged non-git dir — workspace version wins cleanly ────────────
echo ""
echo "=== Test 4: Diverged non-git dir, workspace version wins ==="
ORIG="$TMP/t4-orig"
make_plain_dir "$ORIG" "src/config.py"
WS="$(make_workspace "${P}-t4" "$ORIG")"
echo "ai_setting = True" > "$WS/$(basename "$ORIG")/src/config.py"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"
echo "completely different content" > "$ORIG/src/config.py"

run_sync "$WS" --reject --force
assert_exit_ok "$RUN_EXIT" "exits 0 (workspace version wins cleanly)"
assert_file_contains "$ORIG/src/config.py" "ai_setting = True" "AI change applied"
assert_no_rej_files "$ORIG" "no .rej files"

# ── Test 5: File addition by AI ──────────────────────────────────────────────
echo ""
echo "=== Test 5: File addition ==="
ORIG="$TMP/t5-orig"
make_git_repo "$ORIG" "main.go"
WS="$(make_workspace "${P}-t5" "$ORIG")"
echo "package utils" > "$WS/$(basename "$ORIG")/utils.go"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI adds utils.go"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0"
assert_file "$ORIG/utils.go" "new file added to original"

# ── Test 6: File deletion with warning (interactive prompt) ──────────────────
echo ""
echo "=== Test 6: File deletion warning (--force) ==="
ORIG="$TMP/t6-orig"
make_git_repo "$ORIG" "main.ts" "delete-me.ts"
WS="$(make_workspace "${P}-t6" "$ORIG")"
rm "$WS/$(basename "$ORIG")/delete-me.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI deletes delete-me.ts"

run_sync "$WS" --reject --force
assert_exit_ok "$RUN_EXIT" "exits 0 with --force"
assert_not_file "$ORIG/delete-me.ts" "file deleted from original"

# ── Test 7: File deletion aborted without --force (non-interactive stdin) ─────
echo ""
echo "=== Test 7: Deletion aborted without --force ==="
ORIG="$TMP/t7-orig"
make_git_repo "$ORIG" "main.ts" "to-delete.ts"
WS="$(make_workspace "${P}-t7" "$ORIG")"
rm "$WS/$(basename "$ORIG")/to-delete.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI deletes to-delete.ts"

run_sync "$WS" --reject
assert_exit_err "$RUN_EXIT" "exits non-zero without --force on deletion"
assert_file "$ORIG/to-delete.ts" "file NOT deleted (aborted)"

# ── Test 8: Binary file ──────────────────────────────────────────────────────
echo ""
echo "=== Test 8: Binary file ==="
ORIG="$TMP/t8-orig"
make_git_repo "$ORIG" "assets/icon.png"
printf '\x89PNG\r\n\x1a\n' > "$ORIG/assets/icon.png"
git -C "$ORIG" add -A
git -C "$ORIG" commit --quiet -m "add binary"
WS="$(make_workspace "${P}-t8" "$ORIG")"
printf '\x89PNG\r\n\x1a\nMODIFIED' > "$WS/$(basename "$ORIG")/assets/icon.png"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI updates binary"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 for binary file"
assert_file_contains "$ORIG/assets/icon.png" "MODIFIED" "binary file updated"

# ── Test 9: Multi-source workspace ───────────────────────────────────────────
echo ""
echo "=== Test 9: Multi-source workspace ==="
ORIG_A="$TMP/t9-api"
ORIG_B="$TMP/t9-frontend"
make_git_repo "$ORIG_A" "api.ts"
make_git_repo "$ORIG_B" "app.tsx"
WS_NAME="${P}-t9"
bash "$DRIFT_CMD" prepare "$WS_NAME" "$ORIG_A" "$ORIG_B" >/dev/null 2>&1
WS="$WORKSPACES_DIR/$WS_NAME"
echo "AI changed api" >> "$WS/t9-api/api.ts"
echo "AI changed frontend" >> "$WS/t9-frontend/app.tsx"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 for multi-source"
assert_file_contains "$ORIG_A/api.ts" "AI changed api" "api source synced"
assert_file_contains "$ORIG_B/app.tsx" "AI changed frontend" "frontend source synced"

# ── Test 10: Missing meta file ────────────────────────────────────────────────
echo ""
echo "=== Test 10: Missing .meta ==="
EMPTY_WS="$TMP/t10-empty-ws"
mkdir -p "$EMPTY_WS"

run_sync "$EMPTY_WS" --3way
assert_exit_err "$RUN_EXIT" "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "Meta file not found" "error mentions missing meta"

# ── Test 11: Dirty original — WIP is stashed, not popped ─────────────────────
echo ""
echo "=== Test 11: Dirty original, --3way — WIP stashed, not auto-restored ==="
ORIG="$TMP/t11-orig"
make_git_repo "$ORIG" "app.ts" "wip.ts"
WS="$(make_workspace "${P}-t11" "$ORIG")"
echo "AI changed app.ts" >> "$WS/$(basename "$ORIG")/app.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"
echo "staged WIP" >> "$ORIG/wip.ts"
git -C "$ORIG" add wip.ts
echo "unstaged WIP" >> "$ORIG/wip.ts"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 even with dirty original"
assert_file_not_contains "$ORIG/wip.ts" "staged WIP" "WIP stashed — not in working tree"
STASH_CONTENT="$(git -C "$ORIG" stash show -p 2>/dev/null || true)"
[[ "$STASH_CONTENT" == *"staged WIP"* ]] \
  && _pass "WIP saved in stash" || _fail "WIP saved in stash"
assert_file_contains "$ORIG/app.ts" "AI changed app.ts" "AI change applied to original"

# ── Test 12: No apply method flag ─────────────────────────────────────────────
echo ""
echo "=== Test 12: No apply method flag ==="
ORIG="$TMP/t12-orig"
make_git_repo "$ORIG" "file.ts"
WS="$(make_workspace "${P}-t12" "$ORIG")"

run_sync "$WS"
assert_exit_err "$RUN_EXIT" "exits non-zero without method flag"
assert_stderr_contains "$RUN_STDERR" "--3way" "error mentions --3way"

# ── Test 13: --3way on non-git original ───────────────────────────────────────
echo ""
echo "=== Test 13: --3way on non-git original ==="
ORIG="$TMP/t13-orig"
make_plain_dir "$ORIG" "file.py"
WS="$(make_workspace "${P}-t13" "$ORIG")"
echo "AI change" >> "$WS/$(basename "$ORIG")/file.py"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS" --3way
assert_exit_err "$RUN_EXIT" "exits non-zero for --3way on non-git dir"
assert_stderr_contains "$RUN_STDERR" "reject" "error suggests --reject"

# ── Test 14: --dry-run does not modify anything ───────────────────────────────
echo ""
echo "=== Test 14: --dry-run ==="
ORIG="$TMP/t14-orig"
make_git_repo "$ORIG" "main.ts"
WS="$(make_workspace "${P}-t14" "$ORIG")"
echo "AI change" >> "$WS/$(basename "$ORIG")/main.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"
ORIG_CONTENT="$(cat "$ORIG/main.ts")"

run_sync "$WS" --dry-run
assert_exit_ok "$RUN_EXIT" "exits 0"
AFTER_CONTENT="$(cat "$ORIG/main.ts")"
[[ "$ORIG_CONTENT" == "$AFTER_CONTENT" ]] \
  && _pass "original not modified by --dry-run" \
  || _fail "original not modified by --dry-run (file changed)"
[[ "$RUN_STDOUT" == *"main.ts"* ]] \
  && _pass "dry-run output lists main.ts" \
  || _fail "dry-run output lists main.ts (stdout: $RUN_STDOUT)"

# ── Test 15: --patch outputs raw diff to stdout ───────────────────────────────
echo ""
echo "=== Test 15: --patch outputs raw diff ==="
ORIG="$TMP/t15-orig"
make_git_repo "$ORIG" "widget.ts"
WS="$(make_workspace "${P}-t15" "$ORIG")"
echo "patched by AI" >> "$WS/$(basename "$ORIG")/widget.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"
ORIG_CONTENT="$(cat "$ORIG/widget.ts")"

run_sync "$WS" --patch
assert_exit_ok "$RUN_EXIT" "exits 0"
AFTER_CONTENT="$(cat "$ORIG/widget.ts")"
[[ "$ORIG_CONTENT" == "$AFTER_CONTENT" ]] \
  && _pass "original not modified by --patch" \
  || _fail "original not modified by --patch (file changed)"
[[ "$RUN_STDOUT" == *"diff --git"* ]] \
  && _pass "--patch stdout contains diff header" \
  || _fail "--patch stdout contains diff header"
[[ "$RUN_STDOUT" == *"patched by AI"* ]] \
  && _pass "--patch stdout contains AI change" \
  || _fail "--patch stdout contains AI change"

# ── Test 15b: --patch output is actually applicable end-to-end ────────────────
echo ""
echo "=== Test 15b: --patch output applicable via git apply -p2 ==="
echo "$RUN_STDOUT" | (cd "$ORIG" && git apply --no-index --whitespace=nowarn -p2) 2>/dev/null
APPLIED_CONTENT="$(cat "$ORIG/widget.ts")"
[[ "$APPLIED_CONTENT" == *"patched by AI"* ]] \
  && _pass "--patch | git apply -p2 lands changes correctly" \
  || _fail "--patch | git apply -p2 lands changes correctly"

# ── Test 16: meta file is NOT in the patch ───────────────────────────────────
echo ""
echo "=== Test 16: meta file excluded from patch ==="
ORIG="$TMP/t16-orig"
make_git_repo "$ORIG" "index.ts"
WS="$(make_workspace "${P}-t16" "$ORIG")"
echo "AI change" >> "$WS/$(basename "$ORIG")/index.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS" --patch
[[ "$RUN_STDOUT" != *".meta"* ]] \
  && _pass "meta file absent from patch output" \
  || _fail "meta file absent from patch output (found in stdout)"

echo "$RUN_STDOUT" | (cd "$ORIG" && git apply --no-index --whitespace=nowarn -p2) 2>/dev/null || true
assert_not_file "$ORIG/${P}-t16.meta" "meta file not copied to original"

# ── Test 17: Safety branch is named correctly ─────────────────────────────────
echo ""
echo "=== Test 17: Safety branch name ==="
ORIG="$TMP/t17-orig"
make_git_repo "$ORIG" "service.ts"
WS_NAME="${P}-t17"
bash "$DRIFT_CMD" prepare "$WS_NAME" "$ORIG" >/dev/null 2>&1
WS="$WORKSPACES_DIR/$WS_NAME"
echo "AI change" >> "$WS/$(basename "$ORIG")/service.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0"
assert_branch_exists "$ORIG" "drift/$WS_NAME" "safety branch drift/<name> created"

# ── Test 18: Workspace referenced by name only (not full path) ───────────────
echo ""
echo "=== Test 18: Workspace name-only resolution ==="
ORIG="$TMP/t18-orig"
make_git_repo "$ORIG" "main.ts"
WS_NAME="${P}-t18"
WS="$(make_workspace "$WS_NAME" "$ORIG")"
echo "AI change" >> "$WS/$(basename "$ORIG")/main.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS_NAME" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 when workspace given by name"
assert_file_contains "$ORIG/main.ts" "AI change" "change applied when using name-only"
assert_branch_exists "$ORIG" "drift/$WS_NAME" "safety branch created with name-only arg"

# ── Test 19: Non-existent workspace name → clear error ───────────────────────
echo ""
echo "=== Test 19: Non-existent workspace name → error ==="
run_sync "no-such-workspace-xyz" --3way
assert_exit_err "$RUN_EXIT" "exits non-zero for unknown workspace name"
assert_stderr_contains "$RUN_STDERR" "Workspace not found" "error mentions Workspace not found"

# ── Test 20: --3way on a source that is a subdirectory of a git repo ─────────
echo ""
echo "=== Test 20: --3way on git subdir source ==="
REPO="$TMP/t20-repo"
ORIG="$REPO/packages/api"
make_git_repo "$REPO" "packages/api/src/service.ts" "packages/api/lib/util.ts"
WS="$(make_workspace "${P}-t20" "$ORIG")"
echo "AI refactored" >> "$WS/api/src/service.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI changes"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 for subdir source"
assert_file_contains "$ORIG/src/service.ts" "AI refactored" "change applied to subdir source"
assert_branch_exists "$REPO" "drift/${P}-t20" "safety branch created in repo root"
assert_no_rej_files "$ORIG" "no .rej files"

# ── Test 21: --3way when patch only touches gitignored files ─────────────────
echo ""
echo "=== Test 21: --3way with only gitignored files in patch ==="
ORIG="$TMP/t21-orig"
make_git_repo "$ORIG" "src/app.ts"
# Mark dist/ as gitignored in the original repo
echo "dist/" >> "$ORIG/.gitignore"
git -C "$ORIG" add .gitignore
git -C "$ORIG" commit --quiet -m "Add .gitignore"
# Put an existing (untracked, gitignored) dist file in the original
mkdir -p "$ORIG/dist"
echo "old build" > "$ORIG/dist/bundle.js"

WS="$(make_workspace "${P}-t21" "$ORIG")"
WS_SUBDIR="$WS/$(basename "$ORIG")"
# Modify the dist file in the workspace — this is the only difference.
# sync.sh diffs the filesystem with --no-index, so git tracking is irrelevant.
echo "new build" > "$WS_SUBDIR/dist/bundle.js"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 when only gitignored files differ"
[[ "$RUN_STDOUT" == *"No tracked changes to sync"* ]] \
  && _pass "output warns: no tracked changes" \
  || _fail "output warns: no tracked changes (got: $RUN_STDOUT)"
[[ "$RUN_STDOUT" == *"gitignored"* || "$RUN_STDOUT" == *"git index"* ]] \
  && _pass "output mentions gitignored / index" \
  || _fail "output mentions gitignored / index"

# ── Test 22: --3way mixed tracked + gitignored changes ───────────────────────
echo ""
echo "=== Test 22: --3way tracked change lands, gitignored skipped ==="
ORIG="$TMP/t22-orig"
make_git_repo "$ORIG" "src/app.ts"
echo 'version: "1.0"' > "$ORIG/package.json"
echo "dist/" >> "$ORIG/.gitignore"
git -C "$ORIG" add .
git -C "$ORIG" commit --quiet -m "Add package.json and .gitignore"
# Create gitignored dist file in original
mkdir -p "$ORIG/dist"
echo "old build" > "$ORIG/dist/bundle.js"

WS="$(make_workspace "${P}-t22" "$ORIG")"
WS_SUBDIR="$WS/$(basename "$ORIG")"
# Modify both a tracked file and a gitignored file
echo 'version: "2.0"' > "$WS_SUBDIR/package.json"
echo "new build" > "$WS_SUBDIR/dist/bundle.js"

run_sync "$WS" --3way
assert_exit_ok "$RUN_EXIT" "exits 0 with mixed tracked+gitignored changes"
# Tracked change must land
[[ "$(git -C "$ORIG" diff HEAD -- package.json)" == *'version: "2.0"'* ]] \
  && _pass "tracked package.json change landed" \
  || _fail "tracked package.json change did NOT land"
# Gitignored file must NOT be tracked
git -C "$ORIG" ls-files --error-unmatch dist/bundle.js 2>/dev/null \
  && _fail "dist/bundle.js must not be tracked" \
  || _pass "dist/bundle.js not tracked (correct)"
# Gitignored file content on disk must be unchanged (worktree must not have overwritten it)
assert_file_contains "$ORIG/dist/bundle.js" "old build" "gitignored file content unchanged on disk"
assert_no_rej_files "$ORIG" "no .rej files"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
[[ $FAIL -eq 0 ]]
