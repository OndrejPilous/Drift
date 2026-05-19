#!/usr/bin/env bash
# install.sh — Install drift to ~/.local/bin/drift
#
# What this does:
#   1. Validates requirements (bash 4+, git)
#   2. Creates ~/.local/bin/, ~/.local/share/drift/workspaces/, ~/.config/drift/
#   3. Symlinks <repo>/bin/drift → ~/.local/bin/drift
#   4. Writes ~/.config/drift/config with DRIFT_SOURCE_DIR
#   5. Reminds you to add ~/.local/bin to PATH if it's not there

set -euo pipefail

# ── Bash version guard ────────────────────────────────────────────────────────
(( BASH_VERSINFO[0] >= 4 )) \
  || { echo "Error: bash 4.0+ required (found ${BASH_VERSION})." >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "$*"; }
ok()   { echo "  ✓ $*"; }
skip() { echo "  · $*"; }

# ── Locate the source directory (where this script lives) ─────────────────────
DRIFT_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DRIFT_BIN="$DRIFT_SOURCE_DIR/bin/drift"

[[ -f "$DRIFT_BIN" ]] \
  || die "bin/drift not found in $DRIFT_SOURCE_DIR — is the repo intact?"

# ── Requirements check ────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || die "git is not installed or not in PATH."

# ── Destination paths (respect XDG env vars) ─────────────────────────────────
BIN_DIR="${HOME}/.local/bin"
WORKSPACES_DIR="${DRIFT_WORKSPACES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/drift/workspaces}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/drift"
CONFIG_FILE="$CONFIG_DIR/config"
LINK_TARGET="$BIN_DIR/drift"

info ""
info "Installing drift"
info "  Source:     $DRIFT_SOURCE_DIR"
info "  Binary:     $LINK_TARGET → $DRIFT_BIN"
info "  Workspaces: $WORKSPACES_DIR"
info "  Config:     $CONFIG_FILE"
info ""

# ── Create directories ────────────────────────────────────────────────────────
if [[ ! -d "$BIN_DIR" ]]; then
  mkdir -p -- "$BIN_DIR"
  ok "Created $BIN_DIR"
else
  skip "$BIN_DIR already exists"
fi

if [[ ! -d "$WORKSPACES_DIR" ]]; then
  mkdir -p -- "$WORKSPACES_DIR"
  ok "Created $WORKSPACES_DIR"
else
  skip "$WORKSPACES_DIR already exists"
fi

if [[ ! -d "$CONFIG_DIR" ]]; then
  mkdir -p -- "$CONFIG_DIR"
  ok "Created $CONFIG_DIR"
else
  skip "$CONFIG_DIR already exists"
fi

# ── Symlink bin/drift ─────────────────────────────────────────────────────────
chmod +x -- "$DRIFT_BIN"

if [[ -L "$LINK_TARGET" ]]; then
  current="$(readlink -- "$LINK_TARGET" 2>/dev/null || true)"
  if [[ "$current" == "$DRIFT_BIN" ]]; then
    skip "$LINK_TARGET already points to $DRIFT_BIN"
  else
    ln -sf -- "$DRIFT_BIN" "$LINK_TARGET"
    ok "Updated symlink: $LINK_TARGET → $DRIFT_BIN  (was: $current)"
  fi
elif [[ -e "$LINK_TARGET" ]]; then
  die "$LINK_TARGET exists and is not a symlink. Remove it manually and re-run."
else
  ln -s -- "$DRIFT_BIN" "$LINK_TARGET"
  ok "Created symlink: $LINK_TARGET → $DRIFT_BIN"
fi

# ── Write config ──────────────────────────────────────────────────────────────
cat > "$CONFIG_FILE" <<EOF
# drift configuration — managed by install.sh
# Edit manually or re-run install.sh to update.
DRIFT_SOURCE_DIR=$DRIFT_SOURCE_DIR
EOF
ok "Wrote $CONFIG_FILE"

# ── PATH check ────────────────────────────────────────────────────────────────
echo ""
if [[ ":${PATH}:" == *":${BIN_DIR}:"* ]]; then
  ok "$BIN_DIR is already on your PATH"
else
  info "  ⚠  $BIN_DIR is not on your PATH."
  info ""
  info "  Add one of the following to your shell's rc file:"
  info ""

  SHELL_NAME="$(basename -- "${SHELL:-bash}")"
  case "$SHELL_NAME" in
    zsh)
      info '    echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc'
      info '    source ~/.zshrc'
      ;;
    fish)
      info '    fish_add_path ~/.local/bin'
      ;;
    *)
      info '    echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'
      info '    source ~/.bashrc'
      ;;
  esac
fi

echo ""
info "✓ Installation complete. Run: drift help"
echo ""
