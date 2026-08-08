#!/usr/bin/env bash
# Install claudswap + /switch for Claude Code.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${CLAUDSWAP_BIN_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$HOME/.claude/scripts"
CMD_DIR="$HOME/.claude/commands"

echo "Installing claudswap..."

# 1. claudswap binary  (install(1) unlinks the target first — safe over symlinks)
mkdir -p "$BIN_DIR"
install -m 0755 "$REPO/src/claudswap/cli.py" "$BIN_DIR/claudswap"
echo "  claudswap -> $BIN_DIR/claudswap"

# 2. switch-model.sh backend
mkdir -p "$SCRIPT_DIR"
install -m 0755 "$REPO/src/claudswap/data/switch-model.sh" "$SCRIPT_DIR/switch-model.sh"
echo "  switch-model.sh -> $SCRIPT_DIR/switch-model.sh"

# 3. /switch slash command (rewrite placeholder path)
mkdir -p "$CMD_DIR"
sed "s|CLAUDSWAP_SCRIPT_PATH|$SCRIPT_DIR/switch-model.sh|g" "$REPO/src/claudswap/data/switch.md" \
  > "$CMD_DIR/switch.md"
echo "  switch.md -> $CMD_DIR/switch.md"

echo ""
echo "Done. You now have:"
echo "  /switch          — list + switch models from inside Claude Code"
echo "  claudswap        — pty wrapper that makes /switch work in any terminal"
echo ""

# Check PATH
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "NOTE: $BIN_DIR is not in your PATH. Add it:"
     echo "  export PATH=\"$BIN_DIR:\$PATH\""
     echo "" ;;
esac

echo "Quick start:"
echo "  claudswap                    # start claude with injection support"
echo "  claudswap -c                 # resume a session"
echo "  alias claude=claudswap       # make it the default (add to .bashrc/.zshrc)"
