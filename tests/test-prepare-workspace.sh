#!/usr/bin/env bash
# tests/test-prepare-workspace.sh
# Test suite for drift prepare (lib/prepare.sh via bin/drift)

set -euo pipefail

DRIFT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DRIFT_ROOT/bin/drift"

# ── Tiny test framework ───────────────────────────────────────────────────────
PASS=0; FAIL=0
_pass() { echo "  ✓ $1"; (( PASS++ )) || true; }
_fail() { echo "  ✗ $1"; (( FAIL++ )) || true; }

assert_exit_ok()  { [[ "$1" -eq 0  ]] && _pass "$2" || _fail "$2 (exit $1)"; }
assert_exit_err() { [[ "$1" -ne 0  ]] && _pass "$2" || _fail "$2 (expected non-zero)"; }
assert_not_exists() { [[ ! -e "$1" ]] && _pass "$2" || _fail "$2 (should not exist: $1)"; }
assert_dir()      { [[ -d "$1"     ]] && _pass "$2" || _fail "$2 (not a dir: $1)"; }
assert_file()     { [[ -f "$1"     ]] && _pass "$2" || _fail "$2 (not a file: $1)"; }
assert_stderr_contains() {
  local msg="$1" pattern="$2" label="$3"
  [[ "$msg" == *"$pattern"* ]] && _pass "$label" || _fail "$label (stderr: $msg)"
}

# ── Setup / teardown ──────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
STDERR_FILE="$TMP/stderr"
WORKSPACES_DIR="$TMP/workspaces"
mkdir -p "$WORKSPACES_DIR"

# Export so lib/prepare.sh picks it up via env
export DRIFT_WORKSPACES_DIR="$WORKSPACES_DIR"

# Per-run prefix so names never collide
P="tp$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

cleanup() {
  set +e
  rm -rf -- "$TMP"
}
trap cleanup EXIT

# Helper: run the script, capturing stdout/stderr and exit code.
# Sets: RUN_EXIT, RUN_STDOUT, RUN_STDERR
run_script() {
  RUN_STDOUT="$(bash "$SCRIPT" prepare "$@" 2>"$STDERR_FILE")" && RUN_EXIT=0 || RUN_EXIT=$?
  RUN_STDERR="$(cat "$STDERR_FILE")"
}

# ── Source directory fixtures ─────────────────────────────────────────────────
SRC_A="$TMP/project-a"
SRC_B="$TMP/project-b"
SRC_WITHGIT="$TMP/project-git"
SRC_WORKTREE="$TMP/project-worktree"

mkdir -p "$SRC_A/subdir"
echo "hello"  > "$SRC_A/hello.txt"
echo "nested" > "$SRC_A/subdir/nested.txt"

mkdir -p "$SRC_B"
echo "world" > "$SRC_B/world.txt"

mkdir -p "$SRC_WITHGIT/.git/objects"
echo "gitfile" > "$SRC_WITHGIT/.git/HEAD"
echo "src"     > "$SRC_WITHGIT/main.c"

mkdir -p "$SRC_WORKTREE"
echo "gitdir: /some/other/repo/.git/worktrees/wt" > "$SRC_WORKTREE/.git"
echo "src" > "$SRC_WORKTREE/main.c"

# ── Tests ─────────────────────────────────────────────────────────────────────

echo ""
echo "=== Happy path: single source ==="
WS="${P}-single"
run_script "$WS" "$SRC_A"
assert_exit_ok  "$RUN_EXIT"                           "exits 0"
assert_dir      "$WORKSPACES_DIR/$WS"                 "workspace dir created"
assert_dir      "$WORKSPACES_DIR/$WS/project-a"       "source dir copied as subdirectory"
assert_file     "$WORKSPACES_DIR/$WS/project-a/hello.txt"          "file in source copied"
assert_file     "$WORKSPACES_DIR/$WS/project-a/subdir/nested.txt"  "nested file copied"
assert_dir      "$WORKSPACES_DIR/$WS/.git"            "git repo initialised"
assert_file     "$WORKSPACES_DIR/${WS}.meta"          "meta file written"
INITIAL_COMMIT="$(git -C "$WORKSPACES_DIR/$WS" log --oneline 2>/dev/null | wc -l | tr -d ' ')"
[[ "$INITIAL_COMMIT" -ge 1 ]] \
  && _pass "initial commit created" \
  || _fail "initial commit created (no commits found)"

echo ""
echo "=== Happy path: multiple sources ==="
WS="${P}-multi"
run_script "$WS" "$SRC_A" "$SRC_B"
assert_exit_ok  "$RUN_EXIT"                          "exits 0"
assert_dir      "$WORKSPACES_DIR/$WS/project-a"      "first source copied"
assert_dir      "$WORKSPACES_DIR/$WS/project-b"      "second source copied"
assert_file     "$WORKSPACES_DIR/${WS}.meta"         "meta file written for multi-source"
META_API="$(grep 'source\.1\.path=' "$WORKSPACES_DIR/${WS}.meta" | cut -d= -f2-)"
[[ "$META_API" == "$SRC_A" ]] \
  && _pass "meta records project-a path" \
  || _fail "meta records project-a path (got: $META_API)"
META_FRONT="$(grep 'source\.2\.path=' "$WORKSPACES_DIR/${WS}.meta" | cut -d= -f2-)"
[[ "$META_FRONT" == "$SRC_B" ]] \
  && _pass "meta records project-b path" \
  || _fail "meta records project-b path (got: $META_FRONT)"

echo ""
echo "=== Git repo initialised with no remotes ==="
WS="${P}-gitcheck"
run_script "$WS" "$SRC_A"
REMOTES="$(git -C "$WORKSPACES_DIR/$WS" remote 2>/dev/null)"
[[ -z "$REMOTES" ]] && _pass "no git remotes" || _fail "no git remotes (found: $REMOTES)"

echo ""
echo "=== .git directory in source is stripped ==="
WS="${P}-gitstrip"
run_script "$WS" "$SRC_WITHGIT"
assert_not_exists "$WORKSPACES_DIR/$WS/project-git/.git" ".git dir removed from source copy"
assert_file       "$WORKSPACES_DIR/$WS/project-git/main.c" "other files preserved"

echo ""
echo "=== .git worktree file in source is stripped ==="
WS="${P}-worktree"
run_script "$WS" "$SRC_WORKTREE"
assert_not_exists "$WORKSPACES_DIR/$WS/project-worktree/.git" ".git worktree file removed"
assert_file       "$WORKSPACES_DIR/$WS/project-worktree/main.c"    "other files preserved"

echo ""
echo "=== Error: too few arguments ==="
run_script
assert_exit_err "$RUN_EXIT" "exits non-zero with no args"

run_script only-name
assert_exit_err "$RUN_EXIT" "exits non-zero with name only"

echo ""
echo "=== Error: invalid workspace name ==="
run_script "bad name!" "$SRC_A"
assert_exit_err "$RUN_EXIT"                          "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "Invalid name"  "stderr mentions invalid name"
assert_not_exists "$WORKSPACES_DIR/bad name!" "workspace not created for invalid name"

run_script "has/slash" "$SRC_A"
assert_exit_err "$RUN_EXIT"                          "slash in name rejected"
assert_stderr_contains "$RUN_STDERR" "Invalid name"  "slash in name gives correct error"
assert_not_exists "$WORKSPACES_DIR/has/slash"        "workspace not created for slash name"

echo ""
echo "=== Error: workspace already exists ==="
WS="${P}-exists"
run_script "$WS" "$SRC_A"
run_script "$WS" "$SRC_A"
assert_exit_err "$RUN_EXIT"                             "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "already exists"  "stderr mentions already exists"

echo ""
echo "=== Error: source does not exist ==="
WS="${P}-nosrc"
run_script "$WS" "$TMP/does-not-exist"
assert_exit_err "$RUN_EXIT"                              "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "Not a directory"  "stderr mentions not a directory"
assert_not_exists "$WORKSPACES_DIR/$WS"                 "workspace not created"

echo ""
echo "=== Error: source is a file, not a directory ==="
TMPFILE="$TMP/not-a-dir.txt"
echo "file" > "$TMPFILE"
WS="${P}-fileasrc"
run_script "$WS" "$TMPFILE"
assert_exit_err "$RUN_EXIT"                              "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "Not a directory"  "stderr mentions not a directory"
assert_not_exists "$WORKSPACES_DIR/$WS"                 "workspace not created"

echo ""
echo "=== Error: duplicate source basenames ==="
DUP_A="$TMP/dup/alpha/same-name"
DUP_B="$TMP/dup/beta/same-name"
mkdir -p "$DUP_A" "$DUP_B"
WS="${P}-dupbase"
run_script "$WS" "$DUP_A" "$DUP_B"
assert_exit_err "$RUN_EXIT"                              "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "Duplicate basename" "stderr mentions duplicate basename"
assert_not_exists "$WORKSPACES_DIR/$WS"                 "workspace not created"

echo ""
echo "=== Error: source is root ==="
WS="${P}-root"
run_script "$WS" /
assert_exit_err "$RUN_EXIT"                              "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "Root directory"   "stderr mentions root directory"
assert_not_exists "$WORKSPACES_DIR/$WS"                 "workspace not created"

echo ""
echo "=== Error: source is ancestor of workspaces dir ==="
WS="${P}-ancestor"
# $TMP is the parent of WORKSPACES_DIR ($TMP/workspaces), so it is an ancestor
run_script "$WS" "$TMP"
assert_exit_err "$RUN_EXIT"                              "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "ancestor"          "stderr mentions ancestor"
assert_not_exists "$WORKSPACES_DIR/$WS"                 "workspace not created"

echo ""
echo "=== Error: source is workspaces dir itself ==="
WS="${P}-wself"
run_script "$WS" "$WORKSPACES_DIR"
assert_exit_err "$RUN_EXIT"                              "exits non-zero"
assert_stderr_contains "$RUN_STDERR" "ancestor"          "stderr mentions ancestor (equal case)"
assert_not_exists "$WORKSPACES_DIR/$WS"                 "workspace not created"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
[[ $FAIL -eq 0 ]]
