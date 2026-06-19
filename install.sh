#!/usr/bin/env bash
# Install codex-hud by symlinking it into a bin dir on your PATH.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/bin/codex-hud.sh"
BIN_DIR="${CODEX_HUD_BIN_DIR:-$HOME/.local/bin}"
TARGET="$BIN_DIR/codex-hud"

command -v jq >/dev/null 2>&1 || echo "warning: 'jq' not found — install it (brew install jq)" >&2

mkdir -p "$BIN_DIR"
ln -sf "$SRC" "$TARGET"
chmod +x "$SRC"

echo "Installed: $TARGET -> $SRC"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
echo "Try: codex-hud   (or: codex-hud --watch)"
