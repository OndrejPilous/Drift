#!/usr/bin/env bash
# lib/prepare.sh
# Copy source directories into a clean, history-free drift workspace,
# and initialise a fresh git repository.
#
# Called by: drift prepare <name> <folder> [folder2 ...]
# Env:       DRIFT_WORKSPACES_DIR  — where workspaces are stored

set -euo pipefail

# ── Bash version guard (associative arrays require bash 4+) ───────────────────
(( BASH_VERSINFO[0] >= 4 )) \
  || { echo "Error: bash 4.0+ required (found ${BASH_VERSION})." >&2; exit 1; }

WORKSPACES_DIR="${DRIFT_WORKSPACES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/drift/workspaces}"

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "$*"; }

usage() {
  cat <<EOF
Usage: drift prepare <name> <folder> [folder2 ...]

  name    Workspace name — letters, digits, hyphens, underscores only.
          Created as $WORKSPACES_DIR/<name>/
  folder  One or more source directories to copy into the workspace.
EOF
  exit 1
}

# Resolve an absolute, canonical path (directories only for the cd fallback).
abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$p"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f -- "$p"
  else
    [[ -d "$p" ]] || die "Cannot resolve path: $p"
    ( cd -- "$p" && pwd -P )
  fi || die "Cannot resolve path: $p"
}

# ── Dependency checks ─────────────────────────────────────────────────────────
command -v git  >/dev/null 2>&1 || die "git is not installed or not in PATH."

# ── Arguments ─────────────────────────────────────────────────────────────────
[[ $# -lt 2 ]] && usage

NAME="$1"; shift
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] \
  || die "Invalid name '$NAME'. Use only letters, digits, hyphens, or underscores."

# ── Core directory checks ─────────────────────────────────────────────────────
mkdir -p -- "$WORKSPACES_DIR" || die "Could not create workspaces directory: $WORKSPACES_DIR"

NORM_WORKSPACES="$(abs_path "$WORKSPACES_DIR")"
DEST="$NORM_WORKSPACES/$NAME"

[[ -e "$DEST" ]] \
  && die "'$DEST' already exists. Choose a different name or remove it first."

# ── Resolve and validate all source directories up-front ─────────────────────
declare -a SOURCES=()
declare -A SEEN_BASENAMES=()

for ARG in "$@"; do
  [[ -d "$ARG" ]] || die "Not a directory (or does not exist): $ARG"
  ABS="$(abs_path "$ARG")"

  [[ "$ABS" != "/" ]] \
    || die "Root directory '/' cannot be used as a source."

  [[ "${NORM_WORKSPACES#"$ABS"}" != "$NORM_WORKSPACES" ]] \
    && die "Source '$ABS' is an ancestor of (or equal to) the workspaces dir '$NORM_WORKSPACES'."

  BN="$(basename -- "$ABS")"
  [[ -n "$BN" && "$BN" != "." && "$BN" != ".." && "$BN" != "/" ]] \
    || die "Cannot determine a safe basename for: $ABS"

  if [[ ${SEEN_BASENAMES["$BN"]+set} == set ]]; then
    die "Duplicate basename '$BN': '${SEEN_BASENAMES[$BN]}' and '$ABS'."
  fi
  SEEN_BASENAMES["$BN"]="$ABS"
  SOURCES+=("$ABS")
done

# ── Create destination (mkdir without -p to fail atomically if it exists) ─────
mkdir -- "$DEST" || die "Could not create directory: $DEST"
info "Created workspace: $DEST"

# ── Helper: inherit upper-level gitignore rules for workspace self-containment ─
# Collects patterns from .gitignore files in parent directories (between the git
# root and the source directory) and writes them to the workspace root .gitignore
# under a clearly-marked drift section. Placing them at the workspace root (not
# inside the source subdir) ensures they are never diffed or synced back to the
# original repo, while still being visible to any tool running inside the workspace.
#
# Path adjustments written to <DEST>/.gitignore:
#   - Non-anchored patterns (e.g. node_modules/) → written as-is (git applies them
#     at every directory level, so they work from the workspace root too).
#   - Anchored patterns pointing inside SRC (e.g. /apps/v3/frontend/app/coverage/)
#     → translated to /<basename>/app/coverage/ so they are anchored correctly
#     relative to the workspace root.
_inherit_gitignores() {
  local SRC="$1" BN="$2" WORKSPACE_GITIGNORE="$3"
  local GIT_ROOT_SRC
  GIT_ROOT_SRC="$(git -C "$SRC" rev-parse --show-toplevel 2>/dev/null)" || return 0

  # Nothing to inherit when SRC is the git root itself
  [[ "$SRC" == "$GIT_ROOT_SRC" ]] && return 0

  # Relative path from git root to parent of SRC
  local SRC_PARENT GIT_PARENT_REL
  SRC_PARENT="$(dirname "$SRC")"
  GIT_PARENT_REL="${SRC_PARENT#"$GIT_ROOT_SRC"}"
  GIT_PARENT_REL="${GIT_PARENT_REL#/}"  # strip leading slash

  # Build list: git root down to parent(SRC) inclusive
  local DIRS_TO_CHECK=("$GIT_ROOT_SRC")
  if [[ -n "$GIT_PARENT_REL" ]]; then
    local CURRENT="$GIT_ROOT_SRC" PART _PATH_PARTS
    IFS='/' read -ra _PATH_PARTS <<< "$GIT_PARENT_REL"
    for PART in "${_PATH_PARTS[@]}"; do
      CURRENT="$CURRENT/$PART"
      DIRS_TO_CHECK+=("$CURRENT")
    done
  fi

  # Collect patterns, rewriting paths to be relative to the workspace root.
  local INHERITED_LINES=() DIR GITIGNORE_FILE LINE
  for DIR in "${DIRS_TO_CHECK[@]}"; do
    GITIGNORE_FILE="$DIR/.gitignore"
    [[ -f "$GITIGNORE_FILE" ]] || continue
    while IFS= read -r LINE; do
      [[ -z "$LINE" || "$LINE" == \#* ]] && continue
      if [[ "$LINE" == /* ]]; then
        # Anchored patterns: translate only those pointing strictly inside SRC.
        # Skip patterns with glob characters — they can't be path-resolved safely.
        [[ "$LINE" == *\** || "$LINE" == *\?* || "$LINE" == *\[* ]] && continue
        local PATTERN_BARE FULL_PATH REMAINING
        PATTERN_BARE="${LINE%/}"; PATTERN_BARE="${PATTERN_BARE#/}"
        FULL_PATH="$DIR/$PATTERN_BARE"
        if [[ "$FULL_PATH" == "$SRC/"* ]]; then
          REMAINING="${FULL_PATH#"$SRC/"}"
          # Prefix with /<basename>/ so the pattern is anchored at the workspace root
          [[ "$LINE" == */ ]] \
            && INHERITED_LINES+=("/$BN/$REMAINING/") \
            || INHERITED_LINES+=("/$BN/$REMAINING")
        fi
        continue
      fi
      # Non-anchored patterns apply at every level — no rewrite needed
      INHERITED_LINES+=("$LINE")
    done < "$GITIGNORE_FILE"
  done

  [[ ${#INHERITED_LINES[@]} -eq 0 ]] && return 0

  {
    printf '\n'
    printf '# ── drift: inherited gitignore rules for /%s (from parent dirs in source repo)\n' "$BN"
    printf '# ── Do not edit — managed by drift prepare\n'
    printf '%s\n' "${INHERITED_LINES[@]}"
  } >> "$WORKSPACE_GITIGNORE"
  info "  Inherited ${#INHERITED_LINES[@]} gitignore pattern(s) from parent directories → workspace .gitignore"
}

# ── Copy source directories ───────────────────────────────────────────────────
WORKSPACE_GITIGNORE="$DEST/.gitignore"
for SRC in "${SOURCES[@]}"; do
  BN="$(basename -- "$SRC")"
  info "  Copying /$BN  ←  $SRC"
  cp -a -- "$SRC" "$DEST/$BN" || die "Failed to copy '$SRC'."
  _inherit_gitignores "$SRC" "$BN" "$WORKSPACE_GITIGNORE"
done

# ── Strip all .git directories AND .git files (worktrees) ────────────────────
info "Removing .git directories and files..."

NORM_DEST="$(abs_path "$DEST")"

find "$DEST" -name ".git" -print0 >/dev/null 2>&1 \
  || die "find encountered errors while scanning $DEST for .git entries."

GIT_COUNT=0
while IFS= read -r -d '' GIT_ENTRY; do
  NORM_GIT="$(abs_path "$GIT_ENTRY" 2>&1)" \
    || NORM_GIT="$GIT_ENTRY"

  [[ "${NORM_GIT#"$NORM_DEST/"}" != "$NORM_GIT" ]] \
    || die "Refusing to remove '$GIT_ENTRY': resolved path is outside workspace."

  info "  Removed: ${NORM_GIT#"$NORM_DEST/"}"
  rm -rf -- "$NORM_GIT" || die "Failed to remove $NORM_GIT"
  GIT_COUNT=$(( GIT_COUNT + 1 ))
done < <(
  find "$DEST" -name ".git" -type d -prune -print0
  find "$DEST" -name ".git" ! -type d -print0
)
[[ $GIT_COUNT -eq 0 ]] && info "  (none found)"

# ── Init a clean git repository ───────────────────────────────────────────────
info "Initialising fresh git repository..."
git -C "$DEST" init --quiet || die "git init failed."

# ── Write <name>.meta (sibling to workspace dir) ──────────────────────────────
META_FILE="${DEST}.meta"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# Generated by drift prepare — do not edit manually"
  echo "workspace.name=$NAME"
  echo "workspace.created=$CREATED_AT"
  IDX=0
  for SRC in "${SOURCES[@]}"; do
    IDX=$(( IDX + 1 ))
    BN="$(basename -- "$SRC")"
    echo "source.$IDX.name=$BN"
    echo "source.$IDX.path=$SRC"
    echo "source.$IDX.subdir=$BN"
  done
} > "$META_FILE" || die "Failed to write ${META_FILE}."

# ── Initial commit ────────────────────────────────────────────────────────────
info "Creating initial commit..."
git -C "$DEST" add -A          || die "git add failed."
git -C "$DEST" commit --quiet -m "drift: initial workspace snapshot" \
  || die "git commit failed."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "✓ Workspace ready: $DEST"
for SRC in "${SOURCES[@]}"; do
  info "  + $(basename -- "$SRC")"
done
info "  Git remotes: none"
info "  Initial commit: created automatically"
echo ""
info "  cd \"$DEST\" && start working"
