#!/usr/bin/env bash
# switch-model.sh — list Anthropic models, or queue a real model switch into this terminal.
# Backend for the /switch slash command (~/.claude/commands/switch.md).
#
# How the switch works: a custom slash command cannot invoke the built-in /model (the live
# model is in-process state, mutated only by the CLI's own command dispatch), so we type
# "/model <id>" into the session's own input. Claude Code queues input typed mid-turn
# and executes it as a command when the turn ends.
#
# Injection backends (innermost layer wins via process-ancestry detection):
#   claudswap  Write to $CLAUDSWAP_FIFO — universal, works in ANY terminal, over ssh,
#            in VS Code, everywhere ptys exist. The recommended path.
#   tmux     tmux send-keys -t "$TMUX_PANE"           (zero-setup fast path)
#   screen   screen -S "$STY" -p "$WINDOW" -X stuff   (zero-setup fast path)
#   zellij   zellij action write-chars + send-keys     (zero-setup fast path)
#   none     print the /model command for the user to run themselves
#
# Most terminals (Alacritty, GNOME Terminal, Windows Terminal, VS Code, Terminal.app,
# bare ssh) have no self-injection API, and the kernel one (TIOCSTI) is dead since
# Linux 6.2. Rather than maintaining per-terminal backends (kitty, wezterm, konsole,
# iTerm2, Ghostty — each with its own quirks), claudswap solves the problem at the pty
# layer: it owns the master side of the pty, so injection works regardless of terminal.
# Start sessions with `claudswap` (or alias claude=claudswap) and /switch just works.
#
# Model list comes from GET /v1/models using the Claude Code OAuth token in
# ~/.claude/.credentials.json. The token is read into a variable, handed to curl over
# stdin, and never printed, written to disk, or placed in any process's arguments.
set -euo pipefail

CRED="$HOME/.claude/.credentials.json"

fetch_models() {
  local tok
  tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED" 2>/dev/null)
  [ -n "$tok" ] || { echo "ERROR: no OAuth token in $CRED" >&2; return 1; }
  # The token reaches curl on stdin (--config -), never as an argv element: process
  # arguments are world-readable through /proc/<pid>/cmdline for the life of the call.
  # printf is a shell builtin and a pipe is not a file, so the token touches neither
  # argv nor disk. Do NOT switch this to a here-doc or here-string — bash stages both
  # in a temp file. The value must be quoted — curl truncates unquoted config values
  # at the first space, which fails open as a 401 rather than an obvious error.
  printf 'header = "Authorization: Bearer %s"\n' "$tok" \
  | curl -sf --max-time 15 --config - "https://api.anthropic.com/v1/models?limit=100" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
  | jq -r '.data[] | "\(.id)\t\(.display_name)\t\(.created_at[:10])"'
}

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

# grouped_models — number the models, group by family (fable, opus, sonnet, haiku),
# newest first within each family, and derive an alias per model: strip "claude-" and
# any date suffix, dot the version (opus-4-8 -> opus-4.8); the newest model in each
# family gets the bare family name as its alias (opus -> claude-opus-5).
# Output: N \t family \t alias \t id \t name \t date.
# `list` and `switch` both use this, so numbers and aliases always line up.
grouped_models() {
  fetch_models | awk -F'\t' '
    {
      fam = "other"
      if ($1 ~ /fable|mythos/)   fam = "fable"
      else if ($1 ~ /opus/)      fam = "opus"
      else if ($1 ~ /sonnet/)    fam = "sonnet"
      else if ($1 ~ /haiku/)     fam = "haiku"
      lines[fam] = lines[fam] $0 "\n"
    }
    END {
      n = 0
      split("fable opus sonnet haiku other", order, " ")
      for (i = 1; i <= 5; i++) {
        fam = order[i]
        if (lines[fam] == "") continue
        m = split(lines[fam], arr, "\n")
        for (j = 1; j < m; j++) {
          n++
          split(arr[j], f, "\t")
          alias = f[1]
          sub(/^claude-/, "", alias)
          sub(/-20[0-9][0-9][0-9][0-9][0-9][0-9]$/, "", alias)   # drop date suffix
          ver = alias
          sub("^" fam "-?", "", ver)
          gsub(/-/, ".", ver)
          if (j == 1 && fam != "other") alias = fam               # newest in family
          else if (ver != "") alias = fam "-" ver
          print n "\t" fam "\t" alias "\t" f[1] "\t" f[2] "\t" f[3]
          # Emit a [1m] variant for models that support extended context.
          # Eligible: opus (4.6+) and sonnet (5+). The [1m] suffix is a Claude Code
          # convention — append it to the model ID and /model treats it as 1M context.
          if ((fam == "opus" && f[1] !~ /opus-4-5/) || \
              (fam == "sonnet" && f[1] !~ /sonnet-4/)) {
            n++
            print n "\t" fam "\t" alias "[1m]\t" f[1] "[1m]\t" f[2] " [1M]\t" f[3]
          }
        }
      }
    }'
}

# inject <payload> — type payload + Enter into our own terminal. Payload is a resolved
# model command, charset-checked by the caller; still, each backend quotes defensively.
# detect_layer — which multiplexer/terminal are we ACTUALLY inside? Determined by
# process ancestry (nearest ancestor wins), not by env vars: a screen session or ssh
# session started from inside tmux inherits $TMUX_PANE, and trusting that would inject
# into the outer tmux pane instead of the terminal we're really in. Verified: from
# Claude's Bash tool -> tmux; from a screen session started there -> screen.
# A tty comparison can't substitute for this — Claude Code runs tools with no
# controlling terminal at all (`tty` says "not a tty", `ps -o tty=` says "?").
#
# The claudswap pty wrapper is checked by PID ($CLAUDSWAP_PID) at every step, so a
# wrapped session wins over any outer terminal — and a *stale* $CLAUDSWAP_FIFO inherited
# across a terminal boundary loses, because the walk hits that terminal first.

# Portable process-tree helpers: /proc where it exists (Linux), ps elsewhere (macOS).
_ppid() {
  if [ -r "/proc/$1/status" ]; then awk '/^PPid:/{print $2}' "/proc/$1/status"
  else ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; fi
}
_comm() {
  if [ -r "/proc/$1/comm" ]; then cat "/proc/$1/comm"
  else basename "$(ps -o comm= -p "$1" 2>/dev/null | sed 's/^-//')" 2>/dev/null; fi
}

detect_layer() {
  local pid=$$ depth=0 comm
  while [ "${pid:-0}" -gt 1 ] && [ "$depth" -lt 40 ]; do
    if [ -n "${CLAUDSWAP_PID:-}" ] && [ "$pid" = "$CLAUDSWAP_PID" ]; then
      echo claudswap; return
    fi
    comm=$(_comm "$pid")
    [ -n "$comm" ] || break
    case "$comm" in
      claudswap)       echo claudswap; return ;;
      screen|SCREEN) echo screen;  return ;;
      tmux*)         echo tmux;    return ;;
      zellij)        echo zellij;  return ;;
      sshd*)         echo ssh;     return ;;
      # Any recognized terminal emulator stops the walk — prevents firing into an
      # outer multiplexer when the user is actually typing in this terminal.
      wezterm*|kitty|konsole|xterm|alacritty|gnome-terminal*|terminator|urxvt|\
      rxvt*|st|foot|tilix|mate-terminal*|xfce4-terminal|lxterminal|qterminal|\
      deepin-terminal|iTerm2|iterm2|ghostty|WindowsTerminal|code)
                     echo none;    return ;;
    esac
    pid=$(_ppid "$pid")
    depth=$((depth + 1))
  done
  echo ""
}

# Injection backends. Each echoes its name on success, returns 1 on failure.
_try_claudswap() {
  [ -n "${CLAUDSWAP_FIFO:-}" ] && [ -p "$CLAUDSWAP_FIFO" ] || return 1
  printf '%s\r' "$1" > "$CLAUDSWAP_FIFO" 2>/dev/null \
    && { echo claudswap; return 0; }
  return 1
}
_try_tmux() {
  [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1 || return 1
  tmux send-keys -t "$TMUX_PANE" -l "$1" >/dev/null \
    && tmux send-keys -t "$TMUX_PANE" Enter >/dev/null \
    && { echo tmux; return 0; }
  return 1
}
_try_screen() {
  [ -n "${STY:-}" ] && [ -n "${WINDOW:-}" ] && command -v screen >/dev/null 2>&1 || return 1
  local esc
  esc=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\$/\\$/g' -e 's/\^/\\^/g')
  screen -S "$STY" -p "$WINDOW" -X stuff "$esc^M" >/dev/null \
    && { echo screen; return 0; }
  return 1
}
_try_zellij() {
  [ -n "${ZELLIJ:-}" ] && command -v zellij >/dev/null 2>&1 || return 1
  zellij action write-chars "$1" >/dev/null \
    && zellij action send-keys "Enter" >/dev/null \
    && { echo zellij; return 0; }
  return 1
}

inject() {
  local payload="$1" layer
  layer=$(detect_layer)
  case "$layer" in
    claudswap) _try_claudswap "$payload" && return 0 ;;
    tmux)    _try_tmux "$payload" && return 0 ;;
    screen)  _try_screen "$payload" && return 0 ;;
    zellij)  _try_zellij "$payload" && return 0 ;;
    ssh|none) ;;  # no injection possible
  esac
  return 1
}

cmd="${1:-list}"
case "$cmd" in
  list)
    grouped_models
    ;;
  switch)
    query="${2:?usage: switch-model.sh switch <model-number-or-alias>}"
    models=$(fetch_models)

    # bare number → index into the numbered list (same ordering as `list`)
    case "$query" in
      *[!0-9\ ]*|'') ;;  # not a pure number — fall through to name resolution
      *)
        nq=$(printf '%s' "$query" | tr -d ' ')
        id=$(grouped_models | awk -F'\t' -v n="$nq" '$1==n{print $4; exit}')
        if [ -z "$id" ]; then
          echo "ERROR: no model #$nq. Run list mode to see the numbers." >&2
          exit 2
        fi
        ;;
    esac

    q=$(norm "$query")
    [ -n "$q" ] || { echo "ERROR: empty query" >&2; exit 2; }

    # exact alias match (incl. bare family name -> newest in family), before fuzzy rules
    if [ -z "${id:-}" ]; then
      id=$(grouped_models | awk -F'\t' -v q="$q" '
        { a = $3; gsub(/[^a-z0-9]/, "", a); if (a == q) { print $4; exit } }')
    fi

    # 1. exact ID match (skip if already resolved by number)
    if [ -z "${id:-}" ]; then
      id=$(awk -F'\t' -v q="$query" '$1==q{print $1; exit}' <<<"$models")
    fi

    # 2. exact match after normalization, against ID or display name
    if [ -z "$id" ]; then
      id=$(while IFS=$'\t' read -r mid name _; do
        if [ "$(norm "$mid")" = "$q" ] || [ "$(norm "$name")" = "$q" ]; then
          echo "$mid"; break
        fi
      done <<<"$models")
    fi

    # 3. substring match against normalized ID+name; list is newest-first, pick first
    if [ -z "$id" ]; then
      matches=$(while IFS=$'\t' read -r mid name _; do
        case "$(norm "$mid")|$(norm "$name")" in *"$q"*) echo "$mid" ;; esac
      done <<<"$models")
      n=$(grep -c . <<<"$matches" || true)
      if [ "$n" -eq 0 ]; then
        echo "ERROR: no model matches '$query'. Available:" >&2
        echo "$models" >&2
        exit 2
      fi
      id=$(head -1 <<<"$matches")
      if [ "$n" -gt 1 ]; then
        echo "note: '$query' matched $n models; picked newest: $id (others: $(tail -n +2 <<<"$matches" | tr '\n' ' '))"
      fi
    fi

    # sanity: only inject a well-formed model ID
    case "$id" in
      *[!A-Za-z0-9._:\[\]-]*|'') echo "ERROR: unsafe resolved id '$id'" >&2; exit 3 ;;
    esac

    if backend=$(inject "/model $id"); then
      echo "queued via $backend: /model $id (executes as soon as the current turn ends)"
    else
      echo "NO_INJECTION_BACKEND: this terminal has no self-injection support."
      echo "Run this yourself:  /model $id"
      echo ""
      echo "To make /switch work in any terminal, start sessions with claudswap:"
      echo "  claudswap            # wraps claude with injection support"
      echo "  claudswap -c         # resume a session"
      echo "  alias claude=claudswap   # make it permanent"
      exit 4
    fi
    ;;
  *)
    echo "usage: switch-model.sh [list | switch <model-or-alias>]" >&2
    exit 1
    ;;
esac
