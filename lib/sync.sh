#!/usr/bin/env bash
# lib/sync.sh
# Apply AI changes from a drift workspace back to the original source directories.
# Uses git diff --no-index to compare workspace subdirs against their origins,
# then applies the resulting patch with the user's chosen method.
#
# Called by: drift sync <workspace> [--3way | --reject] [--dry-run | --patch] [--force]
# Env:       DRIFT_WORKSPACES_DIR  — where workspaces are stored

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
die()   { echo "Error: $*" >&2; exit 1; }
warn()  { echo "Warning: $*" >&2; }
info()  { echo "$*"; }
sep()   { echo ""; echo "═══════════════════════════════════════════════════"; }

usage() {
  cat >&2 <<EOF

Usage: drift sync <workspace> [--3way | --reject] [--dry-run | --patch] [--force]

  <workspace>   Workspace name or path (must have a corresponding .meta file)

  Apply method (required — choose one):
    --3way      Apply with 'git apply --3way'. Produces standard <<<< conflict
                markers in-file. Requires the original to be a git repository.
                Staged/unstaged changes in the original are stashed automatically
                before applying and restored afterwards.

    --reject    Apply with 'git apply --reject'. Best-effort: hunks that cannot
                apply cleanly are written to <file>.rej alongside the original.
                Works for non-git directories too (uses --no-index).
                Warns before deleting files.

  Output modes (optional, mutually exclusive):
    --dry-run   Preview only. Prints changed file list + diff stat per source.
                Does not modify anything.

    --patch     Print the raw unified diff to stdout and exit. No apply.
                Intended for scripting: pipe to 'git apply -p2', 'patch -p2',
                or other diff tools.

  Options:
    --force     Skip interactive deletion prompts (for CI / non-interactive use).

Examples:
  drift sync my-task --3way
  drift sync my-task --reject
  drift sync my-task --dry-run
  drift sync my-task --patch | head -80

EOF
  exit 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────
WORKSPACE=""
METHOD=""
OUTPUT_MODE="apply"
FORCE=false

[[ $# -lt 1 ]] && usage

WORKSPACE="$1"; shift

for arg in "$@"; do
  case "$arg" in
    --3way)    METHOD="3way" ;;
    --reject)  METHOD="reject" ;;
    --dry-run) OUTPUT_MODE="dry-run" ;;
    --patch)   OUTPUT_MODE="patch" ;;
    --force)   FORCE=true ;;
    *)         die "Unknown argument: $arg. Run 'drift sync' without arguments to see usage." ;;
  esac
done

[[ "$OUTPUT_MODE" == "apply" && -z "$METHOD" ]] \
  && die "No apply method specified. Use --3way (git repo) or --reject (any dir).
  --3way:   produces <<<< conflict markers; requires git in the original
  --reject: best-effort apply; conflicting hunks saved as .rej files"

[[ "$OUTPUT_MODE" == "dry-run" && -n "$METHOD" ]] \
  && warn "--dry-run ignores the apply method (no apply will happen)"

[[ "$OUTPUT_MODE" == "patch" && -n "$METHOD" ]] \
  && warn "--patch ignores the apply method (no apply will happen)"

# ── Resolve workspace path ────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || die "git is not installed or not in PATH."

WORKSPACES_DIR="${DRIFT_WORKSPACES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/drift/workspaces}"

if [[ "$WORKSPACE" != */* && ! -d "$WORKSPACE" ]]; then
  WORKSPACE="$WORKSPACES_DIR/$WORKSPACE"
fi

if command -v realpath >/dev/null 2>&1; then
  WORKSPACE="$(realpath -- "$WORKSPACE")"
else
  WORKSPACE="$(cd -- "$WORKSPACE" && pwd -P)"
fi

[[ -d "$WORKSPACE" ]] || die "Workspace not found: $WORKSPACE"

META="${WORKSPACE}.meta"
[[ -f "$META" ]] || die "Meta file not found: ${META}
  Was this workspace created with 'drift prepare'?"

# ── Parse .meta ───────────────────────────────────────────────────────────────
parse_meta_value() {
  grep -m1 "^$1=" "$META" | cut -d= -f2-
}

WORKSPACE_NAME="$(parse_meta_value "workspace.name")"
[[ -n "$WORKSPACE_NAME" ]] || die ".meta is missing workspace.name"

SOURCE_COUNT="$(grep -c '^source\.[0-9]*\.name=' "$META" || true)"
[[ "$SOURCE_COUNT" -gt 0 ]] || die ".meta contains no source.* entries."

# ── Build a temp dir for patches ─────────────────────────────────────────────
TMPDIR_PATCHES="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_PATCHES"' EXIT

# ── Process each source ───────────────────────────────────────────────────────
OVERALL_EXIT=0

for (( i=1; i<=SOURCE_COUNT; i++ )); do
  NAME="$(parse_meta_value "source.$i.name")"
  ORIG_PATH="$(parse_meta_value "source.$i.path")"
  SUBDIR="$(parse_meta_value "source.$i.subdir")"

  [[ -n "$ORIG_PATH" ]] || { warn "source.$i.path missing in .meta — skipping"; continue; }
  [[ -n "$SUBDIR" ]]    || { warn "source.$i.subdir missing in .meta — skipping"; continue; }
  [[ -n "$NAME" ]]      || NAME="$SUBDIR"

  WORKSPACE_SUBDIR="$WORKSPACE/$SUBDIR"

  [[ -d "$ORIG_PATH" ]] \
    || die "Original source directory not found: $ORIG_PATH (source: $NAME)"
  [[ -d "$WORKSPACE_SUBDIR" ]] \
    || die "Workspace subdirectory not found: $WORKSPACE_SUBDIR (source: $NAME)"

  sep
  info "Source: $NAME"
  info "  Workspace:  $WORKSPACE_SUBDIR"
  info "  Original:   $ORIG_PATH"
  info ""

  PATCH_RAW="$TMPDIR_PATCHES/${NAME}.raw.patch"
  ORIG_CLEAN="$TMPDIR_PATCHES/${NAME}.orig-clean"
  WS_LINK="$TMPDIR_PATCHES/${NAME}.ws"
  STASH_REF=""

  if [[ "$OUTPUT_MODE" == "apply" && "$METHOD" == "3way" ]]; then
    [[ -d "$ORIG_PATH/.git" ]] \
      || die "Original '$ORIG_PATH' is not a git repository.
  Use --reject for non-git directories."

    STASH_MSG="drift: your work-in-progress before syncing workspace '$WORKSPACE_NAME' ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
    set +e
    STASH_RESULT="$(git -C "$ORIG_PATH" stash push -u -m "$STASH_MSG" 2>&1)"
    STASH_EXIT=$?
    set -e

    if [[ $STASH_EXIT -ne 0 ]]; then
      warn "git stash failed: $STASH_RESULT"
      warn "Proceeding without stash — ensure the working tree is clean."
    elif echo "$STASH_RESULT" | grep -q "^No local changes"; then
      true
    else
      STASH_REF="stash@{0}"
      info "  ↓ Your WIP has been saved to the stash: '$STASH_MSG'"
      info "    Recover it later with: git stash pop"
    fi
  fi

  mkdir -p "$ORIG_CLEAN"
  cp -r -- "$ORIG_PATH/." "$ORIG_CLEAN/"
  while IFS= read -r -d '' gitpath; do
    rm -rf -- "$gitpath"
  done < <(
    find "$ORIG_CLEAN" -name ".git" -type d -prune -print0
    find "$ORIG_CLEAN" -name ".git" ! -type d -print0
  )
  ln -s -- "$WORKSPACE_SUBDIR" "$WS_LINK"

  set +e
  (cd "$TMPDIR_PATCHES" && git diff \
      --no-index \
      --full-index \
      --binary \
      -M \
      -- "${NAME}.orig-clean/" "${NAME}.ws/" \
      > "$PATCH_RAW" 2>/dev/null)
  DIFF_EXIT=$?
  set -e

  [[ $DIFF_EXIT -gt 1 ]] && die "git diff --no-index failed for source '$NAME'."

  if [[ $DIFF_EXIT -eq 0 ]] || [[ ! -s "$PATCH_RAW" ]]; then
    info "  ✓ No changes — workspace and original are identical."
    continue
  fi

  if [[ "$OUTPUT_MODE" == "patch" ]]; then
    cat "$PATCH_RAW"
    continue
  fi

  if [[ "$OUTPUT_MODE" == "dry-run" ]]; then
    info "  Diff stat:"
    git apply --stat -p2 "$PATCH_RAW" 2>/dev/null | sed 's/^/    /'
    info ""
    info "  Changed files (A=added M=modified D=deleted R=renamed):"
    git apply --numstat -p2 "$PATCH_RAW" 2>/dev/null \
      | awk '{printf "    %s\n", $3}' \
      || true
    continue
  fi

  if [[ "$METHOD" == "3way" ]]; then

    BRANCH="drift/$WORKSPACE_NAME"
    CURRENT_BRANCH="$(git -C "$ORIG_PATH" symbolic-ref --short HEAD 2>/dev/null || echo "HEAD")"
    if git -C "$ORIG_PATH" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
      warn "Branch '$BRANCH' already exists in $ORIG_PATH — reusing it."
      git -C "$ORIG_PATH" checkout "$BRANCH" --quiet
    else
      git -C "$ORIG_PATH" checkout -b "$BRANCH" --quiet
      info "  ✓ Safety branch created: $BRANCH"
      info "    To discard this sync: git checkout $CURRENT_BRANCH && git branch -D $BRANCH"
    fi

    info ""
    info "  Applying with --3way..."
    set +e
    git -C "$ORIG_PATH" apply --3way --whitespace=nowarn -p2 "$PATCH_RAW" 2>&1 \
      | sed 's/^/    /'
    set -e

    info ""
    UNMERGED="$(git -C "$ORIG_PATH" ls-files --unmerged 2>/dev/null | awk '{print $4}' | sort -u)"
    info "  Result:"
    git -C "$ORIG_PATH" diff --stat HEAD 2>/dev/null | sed 's/^/    /' || true
    if [[ -n "$UNMERGED" ]]; then
      info ""
      info "  ⚠  Conflicts (resolve these files):"
      echo "$UNMERGED" | sed 's/^/    /'
      info ""
      info "  Next steps:"
      info "    cd $ORIG_PATH"
      info "    git mergetool              # resolve conflicts"
      info "    git add -A && git commit -m 'Apply workspace changes from $WORKSPACE_NAME'"
      info "    git branch -D $BRANCH     # clean up safety branch when done"
      [[ -n "${STASH_REF:-}" ]] && \
        info "    git stash pop              # restore your saved WIP"
      OVERALL_EXIT=1
    else
      info ""
      info "  ✓ Applied cleanly — no conflicts."
      info ""
      info "  Next steps:"
      info "    cd $ORIG_PATH"
      info "    git diff HEAD              # review changes"
      info "    git add -A && git commit -m 'Apply workspace changes from $WORKSPACE_NAME'"
      info "    git branch -D $BRANCH     # clean up safety branch when done"
      [[ -n "${STASH_REF:-}" ]] && \
        info "    git stash pop              # restore your saved WIP"
    fi

  elif [[ "$METHOD" == "reject" ]]; then

    if grep -q '^deleted file' "$PATCH_RAW" 2>/dev/null; then
      DEL_FILES="$(awk '/^deleted file mode/{found=1; next} found && /^--- a\//{print substr($2,3); found=0}' "$PATCH_RAW" \
        | sed "s|^${NAME}.orig-clean/||" || true)"
      if [[ -n "$DEL_FILES" ]]; then
        echo ""
        warn "The following files will be deleted from $ORIG_PATH:"
        echo "$DEL_FILES" | sed 's/^/    /'
        echo ""
        if [[ "$FORCE" != true ]]; then
          if [[ -t 0 ]]; then
            read -r -p "  Proceed with deletions? [y/N] " CONFIRM
            [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]] || die "Aborted. No changes made."
          else
            die "Non-interactive mode and --force not set. Use --force to allow deletions."
          fi
        fi
      fi
    fi

    info "  Applying with --reject..."
    set +e
    (cd "$ORIG_PATH" && git apply --reject --no-index --whitespace=nowarn -p2 "$PATCH_RAW") 2>&1 \
      | sed 's/^/    /'
    set -e

    REJ_FILES="$(find "$ORIG_PATH" -name "*.rej" 2>/dev/null | sort)"
    info ""
    if [[ -n "$REJ_FILES" ]]; then
      info "  ⚠  Rejected hunks (apply manually):"
      echo "$REJ_FILES" | sed 's/^/    /'
      info ""
      info "  For each .rej file: apply its hunks manually into the target file, then:"
      info "    rm <file>.rej"
      OVERALL_EXIT=1
    else
      info "  ✓ Applied cleanly — no rejected hunks."
    fi
    info ""
    info "  Next steps:"
    info "    cd $ORIG_PATH"
    info "    # Review and commit your changes"
  fi

done

sep
echo ""
if [[ "$OUTPUT_MODE" == "dry-run" ]]; then
  info "  (dry-run — no changes made)"
elif [[ "$OUTPUT_MODE" == "patch" ]]; then
  true
elif [[ $OVERALL_EXIT -eq 0 ]]; then
  info "  All sources synced successfully."
else
  info "  Sync complete with conflicts. See above for next steps."
fi
echo ""

exit $OVERALL_EXIT
