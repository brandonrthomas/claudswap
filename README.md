# claudle

Switch Claude Code to any model — including the old ones `/model` doesn't show you.

Claude Code's built-in `/model` picker only lists the models Anthropic currently promotes. But the API supports every model your account has access to, and `/model <exact-id>` still works if you know the ID. **claudle** bridges the gap: a `/switch` command that lists everything, resolves fuzzy aliases, and actually switches the running session.

**Why reach for an older model?** They aren't just cheaper or faster — they behave differently. If you tuned a prompt against a specific version, you're comparing behavior across versions, or you need to reproduce something a particular model did, "whatever is newest" is the wrong tool. The API keeps serving them; only the picker moved on.

## The problem

Claude Code's live model is in-process state. No file, socket, or API can change it from outside — only the CLI's own `/model` command, dispatched through stdin. Most terminals have no way to programmatically type into their own input. The kernel mechanism that used to allow this (`TIOCSTI`) is dead since Linux 6.2.

## The solution

**claudle** is a transparent pty wrapper. It runs `claude` under a pseudo-terminal and exposes a FIFO. Anything inside the session can inject input by writing to the FIFO. The terminal is out of the equation — it works in VS Code, GNOME Terminal, Windows Terminal, Terminal.app, Alacritty, bare SSH, everywhere ptys exist.

For tmux, screen, and zellij users, `/switch` works without the wrapper — their APIs can target their own pane. claudle is the universal path for everything else.

## Install

```bash
git clone https://github.com/brandonrthomas/claudle.git
cd claudle
bash install.sh
```

This puts:
- `claudle` in `~/.local/bin/`
- `switch-model.sh` in `~/.claude/scripts/`
- `/switch` slash command in `~/.claude/commands/`

## Usage

### Start a session with claudle

```bash
claudle                  # same as: claude
claudle -c               # same as: claude -c (resume)
claudle --model opus     # same as: claude --model opus
claudle --run bash       # wrap any command, not just claude
```

Or make it the default:

```bash
# add to .bashrc / .zshrc
alias claude=claudle
```

### /switch — list models

Type `/switch` with no argument inside a Claude Code session. Example output — the real list is fetched live from the API, so yours will differ:

```
 #  alias       name                  released
── Fable ─────────────────────────────────────
 1  fable       Claude Fable 5        2025-12-12
── Opus ──────────────────────────────────────
 2  opus        Claude Opus 5         2026-05-22
 3  opus-4.8    Claude Opus 4.8       2026-03-24
 4  opus-4.7    Claude Opus 4.7       2026-02-24
 5  opus-4.6    Claude Opus 4.6       2025-10-14  ← current
 ...
── Sonnet ────────────────────────────────────
 ...
── Haiku ─────────────────────────────────────
 ...
```

Numbers and aliases auto-update when Anthropic adds new models.

### /switch — switch models

```
/switch 2           → switches to model #2
/switch opus        → switches to newest Opus
/switch haiku       → switches to newest Haiku
/switch opus 4.7    → switches to Opus 4.7
```

The switch fires the moment Claude's current turn ends.

## How it works

1. **claudle** allocates a pty, runs `claude` on it, and mirrors I/O in raw mode (window resizes, signals, exit status — all transparent). It also opens a per-session FIFO at `$CLAUDLE_FIFO`.

2. **/switch** fetches the full model list from `GET /v1/models` using the Claude Code OAuth token, resolves the user's input (number, alias, substring), and writes `/model <resolved-id>\r` to the FIFO.

3. Claude Code sees `/model ...` as typed input, queued during the current turn. When the turn ends, it executes — switching the live model.

### Injection backends

| Backend | When it's used | Needs claudle? |
|---------|---------------|----------------|
| claudle | `$CLAUDLE_PID` in process ancestry | Yes |
| tmux | `tmux` in process ancestry | No |
| screen | `screen` in process ancestry | No |
| zellij | `zellij` in process ancestry | No |
| *(manual)* | Everything else | Prints `/model` command for you |

Backend detection walks the process tree (not env vars — those get inherited across terminal boundaries and cause mis-targeting). The nearest multiplexer or wrapper wins.

## Credentials

`/switch` reads your Claude Code OAuth token from `~/.claude/.credentials.json` in order to call `GET /v1/models`. It is sent only to `api.anthropic.com` over HTTPS — the same endpoint Claude Code itself uses, and the only host this project contacts.

The token is never printed, logged, or written to disk, and it is **never placed in a command line**. Passing a credential as a process argument would expose it through `/proc/<pid>/cmdline`, which any process running as you — and root — can read for the duration of the call. Instead it is piped to `curl` on stdin via `--config -`. The `claudle` wrapper never touches the token at all; it only moves bytes between your terminal and the pty.

## Requirements

- Python 3 (for the pty wrapper — standard library only, no pip)
- `jq` and `curl` (for the API call)
- Claude Code with an active OAuth session (`~/.claude/.credentials.json`)

## Authors

- **Brandon Thomas** — author
- **Claude** — co-author (written with [Claude Code](https://claude.com/claude-code))

## License

Apache-2.0 © 2026 Brandon Thomas
