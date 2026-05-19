#!/usr/bin/env bash
# tests/test-status-delete.sh
# Test suite for drift status and drift delete

set -euo pipefail

DRIFT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIFT_CMD="$DRIFT_ROOT/bin/drift"

# ── Tiny test framework ───────────────────────────────────────────────────────
PASS=0; FAIL=0
_pass() { echo "  ✓ $1"; (( PASS++ )) || true; }
_fail() { echo "  ✗ $1"; (( FAIL++ )) || true; }

assert_exit_ok()  { [[ "$1" -eq 0  ]] && _pass "$2" || _fail "$2 (exit $1)"; }
assert_exit_err() { [[ "$1" -ne 0  ]] && _pass "$2" || _fail "$2 (expected non-zero, got $1)"; }
assert_exists()   { [[ -e  "$1"    ]] && _pass "$2" || _fail "$2 (should exist: $1)"; }
assert_not_exists() { [[ ! -e "$1" ]] && _pass "$2" || _fail "$2 (should not exist: $1)"; }
assert_contains() { [[ "$1" == *"$2"* ]] && _pass "$3" || _fail "$3 (not found: '$2')"; }
assert_stderr_contains() { [[ "$1" == *"$2"* ]] && _pass "$3" || _fail "$3 (stderr: $1)"; }

# ── Setup ─────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
WORKSPACES_DIR="$TMP/workspaces"
mkdir -p "$WORKSPACES_DIR"
export DRIFT_WORKSPACES_DIR="$WORKSPACES_DIR"

STDERR_FILE="$TMP/stderr"
P="sd$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

cleanup() { set +e; rm -rf -- "$TMP"; }
trap cleanup EXIT

run() {
  RUN_STDOUT="$(bash "$DRIFT_CMD" "$@" 2>"$STDERR_FILE" </dev/null)" && RUN_EXIT=0 || RUN_EXIT=$?
  RUN_STDERR="$(cat "$STDERR_FILE")"
}

make_git_repo() {
  local dir="$1"; shift
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  for f in "$@"; do
    mkdir -p "$(dirname "$dir/$f")"
    echo "content of $f" > "$dir/$f"
  done
  git -C "$dir" add -A
  git -C "$dir" commit --quiet -m "Initial"
}

make_workspace() {
  local ws_name="$1" src="$2"
  bash "$DRIFT_CMD" prepare "$ws_name" "$src" >/dev/null 2>&1
  echo "$WORKSPACES_DIR/$ws_name"
}

# ═══════════════════════════════════════════════════════
# drift status
# ═══════════════════════════════════════════════════════

echo ""
echo "=== status: basic output ==="
ORIG="$TMP/status-orig"
make_git_repo "$ORIG" "main.ts" "lib/util.ts"
WS_NAME="${P}-status1"
WS="$(make_workspace "$WS_NAME" "$ORIG")"

run status "$WS_NAME"
assert_exit_ok "$RUN_EXIT" "exits 0"
assert_contains "$RUN_STDOUT" "$WS_NAME"        "output includes workspace name"
assert_contains "$RUN_STDOUT" "$WS"              "output includes workspace path"
assert_contains "$RUN_STDOUT" "$ORIG"            "output includes source path"
assert_contains "$RUN_STDOUT" "$(basename "$ORIG")" "output includes source name"

echo ""
echo "=== status: shows git info ==="
run status "$WS_NAME"
assert_contains "$RUN_STDOUT" "Commits:"        "output includes commit count"
assert_contains "$RUN_STDOUT" "Working tree:"   "output includes working tree state"
assert_contains "$RUN_STDOUT" "clean"           "working tree is clean after prepare"

echo ""
echo "=== status: working tree shows dirty state ==="
echo "dirty" >> "$WS/$(basename "$ORIG")/main.ts"
run status "$WS_NAME"
assert_contains "$RUN_STDOUT" "unstaged"        "dirty working tree reported"

echo ""
echo "=== status: full path also works ==="
run status "$WS"
assert_exit_ok "$RUN_EXIT" "exits 0 with full path"
assert_contains "$RUN_STDOUT" "$WS_NAME"        "name shown for full-path arg"

echo ""
echo "=== status: warns when original is gone ==="
ORIG2="$TMP/status-gone"
make_git_repo "$ORIG2" "app.py"
WS_NAME2="${P}-status2"
make_workspace "$WS_NAME2" "$ORIG2" >/dev/null
rm -rf "$ORIG2"

run status "$WS_NAME2"
assert_exit_ok "$RUN_EXIT" "exits 0 even when original is missing"
assert_contains "$RUN_STDOUT" "original not found" "warns about missing original"

echo ""
echo "=== status: multi-source workspace ==="
ORIG_A="$TMP/status-api"
ORIG_B="$TMP/status-web"
make_git_repo "$ORIG_A" "api.ts"
make_git_repo "$ORIG_B" "app.tsx"
WS_NAME3="${P}-status3"
bash "$DRIFT_CMD" prepare "$WS_NAME3" "$ORIG_A" "$ORIG_B" >/dev/null 2>&1

run status "$WS_NAME3"
assert_exit_ok "$RUN_EXIT" "exits 0 for multi-source"
assert_contains "$RUN_STDOUT" "Sources (2)"    "shows source count"
assert_contains "$RUN_STDOUT" "$ORIG_A"         "shows first source path"
assert_contains "$RUN_STDOUT" "$ORIG_B"         "shows second source path"

echo ""
echo "=== status: no args → error ==="
run status
assert_exit_err "$RUN_EXIT" "exits non-zero with no args"

echo ""
echo "=== status: unknown workspace → error ==="
run status "no-such-ws-xyz"
assert_exit_err "$RUN_EXIT" "exits non-zero for unknown workspace"
assert_stderr_contains "$RUN_STDERR" "not found" "error mentions not found"

# ═══════════════════════════════════════════════════════
# drift delete
# ═══════════════════════════════════════════════════════

echo ""
echo "=== delete: removes workspace dir and meta (--force) ==="
ORIG="$TMP/del-orig"
make_git_repo "$ORIG" "main.go"
WS_NAME="${P}-del1"
WS="$(make_workspace "$WS_NAME" "$ORIG")"

assert_exists "$WS"                       "workspace exists before delete"
assert_exists "${WS}.meta"                "meta exists before delete"

run delete "$WS_NAME" --force
assert_exit_ok    "$RUN_EXIT"             "exits 0"
assert_not_exists "$WS"                   "workspace dir removed"
assert_not_exists "${WS}.meta"            "meta file removed"
assert_contains   "$RUN_STDOUT" "Deleted" "prints confirmation"

echo ""
echo "=== delete: full path also works (--force) ==="
ORIG="$TMP/del-orig2"
make_git_repo "$ORIG" "index.ts"
WS_NAME="${P}-del2"
WS="$(make_workspace "$WS_NAME" "$ORIG")"

run delete "$WS" --force
assert_exit_ok    "$RUN_EXIT"   "exits 0 with full path"
assert_not_exists "$WS"         "workspace dir removed via full path"
assert_not_exists "${WS}.meta"  "meta removed via full path"

echo ""
echo "=== delete: non-interactive stdin without --force → error ==="
ORIG="$TMP/del-orig3"
make_git_repo "$ORIG" "file.ts"
WS_NAME="${P}-del3"
WS="$(make_workspace "$WS_NAME" "$ORIG")"

run delete "$WS_NAME"
assert_exit_err "$RUN_EXIT"             "exits non-zero without --force"
assert_exists   "$WS"                   "workspace NOT deleted"
assert_stderr_contains "$RUN_STDERR" "--force" "error mentions --force"

echo ""
echo "=== delete: unknown workspace → error ==="
run delete "no-such-ws-xyz" --force
assert_exit_err "$RUN_EXIT" "exits non-zero for unknown workspace"
assert_stderr_contains "$RUN_STDERR" "not found" "error mentions not found"

echo ""
echo "=== delete: no args → error ==="
run delete
assert_exit_err "$RUN_EXIT" "exits non-zero with no args"

echo ""
echo "=== delete: out-of-bounds path with crafted .meta is rejected ==="
# Create a real directory and a crafted .meta alongside it — simulates attacker scenario
OUTSIDE_DIR="$TMP/outside-project"
mkdir -p "$OUTSIDE_DIR"
echo "workspace.name=trap" > "${OUTSIDE_DIR}.meta"

run delete "$OUTSIDE_DIR" --force
assert_exit_err "$RUN_EXIT" "exits non-zero for out-of-bounds path"
assert_stderr_contains "$RUN_STDERR" "Refusing" "error mentions Refusing"
assert_exists "$OUTSIDE_DIR" "out-of-bounds directory NOT deleted"

echo ""
echo "=== delete: warns about unsynced commits ==="
ORIG="$TMP/del-unsync-orig"
make_git_repo "$ORIG" "main.ts"
WS_NAME="${P}-del-unsync"
WS="$(make_workspace "$WS_NAME" "$ORIG")"
# Make a commit beyond the initial snapshot
echo "AI work" >> "$WS/$(basename "$ORIG")/main.ts"
git -C "$WS" add -A
git -C "$WS" commit --quiet -m "AI commit"

run delete "$WS_NAME" --force
assert_exit_ok "$RUN_EXIT" "exits 0 with --force despite unsynced commits"
assert_contains "$RUN_STDOUT" "after initial snapshot" "warns about unsynced commits"
assert_not_exists "$WS" "workspace still deleted after warning"

echo ""
echo "=== list: surfaces orphaned .meta files ==="
# Create a meta without a matching workspace dir
echo "workspace.name=ghost" > "$WORKSPACES_DIR/ghost.meta"

run list
assert_exit_ok "$RUN_EXIT" "exits 0"
assert_contains "$RUN_STDOUT" "orphaned" "list shows orphaned meta"
assert_contains "$RUN_STDOUT" "ghost"    "list names the orphaned workspace"

# Cleanup orphan
rm -f "$WORKSPACES_DIR/ghost.meta"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────"
[[ $FAIL -eq 0 ]]
