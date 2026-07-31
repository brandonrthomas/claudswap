#!/usr/bin/env bash
# Install claudle + /switch for Claude Code.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${CLAUDLE_BIN_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$HOME/.claude/scripts"
CMD_DIR="$HOME/.claude/commands"

echo "Installing claudle..."

# 1. claudle binary  (install(1) unlinks the target first — safe over symlinks)
mkdir -p "$BIN_DIR"
install -m 0755 "$REPO/claudle" "$BIN_DIR/claudle"
echo "  claudle -> $BIN_DIR/claudle"

# 2. switch-model.sh backend
mkdir -p "$SCRIPT_DIR"
install -m 0755 "$REPO/switch-model.sh" "$SCRIPT_DIR/switch-model.sh"
echo "  switch-model.sh -> $SCRIPT_DIR/switch-model.sh"

# 3. /switch slash command (rewrite placeholder path)
mkdir -p "$CMD_DIR"
sed "s|CLAUDLE_SCRIPT_PATH|$SCRIPT_DIR/switch-model.sh|g" "$REPO/switch.md" \
  > "$CMD_DIR/switch.md"
echo "  switch.md -> $CMD_DIR/switch.md"

echo ""
echo "Done. You now have:"
echo "  /switch          — list + switch models from inside Claude Code"
echo "  claudle          — pty wrapper that makes /switch work in any terminal"
echo ""

# Check PATH
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "NOTE: $BIN_DIR is not in your PATH. Add it:"
     echo "  export PATH=\"$BIN_DIR:\$PATH\""
     echo "" ;;
esac

echo "Quick start:"
echo "  claudle                    # start claude with injection support"
echo "  claudle -c                 # resume a session"
echo "  alias claude=claudle       # make it the default (add to .bashrc/.zshrc)"
