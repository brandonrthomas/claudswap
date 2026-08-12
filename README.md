# claudswap

Switch Claude Code to any model — including the old ones `/model` doesn't show you.

Claude Code's built-in `/model` picker only lists the models Anthropic currently promotes. But the API supports every model your account has access to, and `/model <exact-id>` still works if you know the ID. **claudswap** bridges the gap: a `/swap` command that lists everything, resolves fuzzy aliases, and actually switches the running session.

**Why reach for an older model?** They aren't just cheaper or faster — they behave differently. If you tuned a prompt against a specific version, you're comparing behavior across versions, or you need to reproduce something a particular model did, "whatever is newest" is the wrong tool. The API keeps serving them; only the picker moved on.

## The problem

Claude Code's live model is in-process state. No file, socket, or API can change it from outside — only the CLI's own `/model` command, dispatched through stdin. Most terminals have no way to programmatically type into their own input. The kernel mechanism that used to allow this (`TIOCSTI`) is dead since Linux 6.2.

## The solution

**claudswap** is a transparent pty wrapper. It runs `claude` under a pseudo-terminal and exposes a FIFO. Anything inside the session can inject input by writing to the FIFO. The terminal is out of the equation — it works in VS Code, GNOME Terminal, Windows Terminal, Terminal.app, Alacritty, bare SSH, everywhere ptys exist.

For tmux, screen, and zellij users, `/swap` works without the wrapper — their APIs can target their own pane. claudswap is the universal path for everything else.

## Install

```bash
pip install claudswap
claudswap install
```

`pip install` gives you the `claudswap` wrapper. `claudswap install` writes the `/swap` slash command and its backend into `~/.claude/` — run it once. (pip can't do that step itself; post-install hooks are unreliable and effectively deprecated.)

<details>
<summary>From source, without pip</summary>

```bash
git clone https://github.com/brandonrthomas/claudswap.git
cd claudswap
bash install.sh
```
</details>

Either route puts:
- `claudswap` in `~/.local/bin/`
- `switch-model.sh` in `~/.claude/scripts/`
- `/swap` slash command in `~/.claude/commands/`

## Usage

### Start a session with claudswap

```bash
claudswap                  # same as: claude
claudswap -c               # same as: claude -c (resume)
claudswap --model opus     # same as: claude --model opus
claudswap --200k           # launch with 200K context instead of 1M
claudswap --run bash       # wrap any command, not just claude
```

Or make it the default:

```bash
# add to .bashrc / .zshrc
alias claude=claudswap
```

### /swap — list models

Type `/swap` with no argument inside a Claude Code session. Example output — the real list is fetched live from the API, so yours will differ:

```
Context: 1M

 #  alias       name                  released
── Fable ─────────────────────────────────────
 1  fable       Claude Fable 5        2026-06-07
── Opus ──────────────────────────────────────
 2  opus        Claude Opus 5         2026-07-24
 3  opus-4.8    Claude Opus 4.8       2026-05-28
 4  opus-4.7    Claude Opus 4.7       2026-04-14
 5  opus-4.6    Claude Opus 4.6       2026-02-04  ← current
 6  opus-4.5    Claude Opus 4.5       2025-11-24
── Sonnet ────────────────────────────────────
 ...
── Haiku ─────────────────────────────────────
 ...
```

Numbers and aliases auto-update when Anthropic adds new models. When launched with `claudswap --200k`, the context mode shows "200K" instead of "1M".

### /swap — switch models

```
/swap 2           → switches to model #2
/swap opus        → switches to newest Opus
/swap haiku       → switches to newest Haiku
/swap opus 4.7    → switches to Opus 4.7
```

The switch fires the moment Claude's current turn ends.

## How it works

1. **claudswap** allocates a pty, runs `claude` on it, and mirrors I/O in raw mode (window resizes, signals, exit status — all transparent). It also opens a per-session FIFO at `$CLAUDSWAP_FIFO`.

2. **/swap** fetches the full model list from `GET /v1/models` using the Claude Code OAuth token, resolves the user's input (number, alias, substring), and writes `/model <resolved-id>\r` to the FIFO.

3. Claude Code sees `/model ...` as typed input, queued during the current turn. When the turn ends, it executes — switching the live model.

### Injection backends

| Backend | When it's used | Needs claudswap? |
|---------|---------------|----------------|
| claudswap | `$CLAUDSWAP_PID` in process ancestry | Yes |
| tmux | `tmux` in process ancestry | No |
| screen | `screen` in process ancestry | No |
| zellij | `zellij` in process ancestry | No |
| *(manual)* | Everything else | Prints `/model` command for you |

Backend detection walks the process tree (not env vars — those get inherited across terminal boundaries and cause mis-targeting). The nearest multiplexer or wrapper wins.

## Credentials

`/swap` reads your Claude Code OAuth token from `~/.claude/.credentials.json` in order to call `GET /v1/models`. It is sent only to `api.anthropic.com` over HTTPS — the same endpoint Claude Code itself uses, and the only host this project contacts.

The token is never printed, logged, or written to disk, and it is **never placed in a command line**. Passing a credential as a process argument would expose it through `/proc/<pid>/cmdline`, which any process running as you — and root — can read for the duration of the call. Instead it is piped to `curl` on stdin via `--config -`. The `claudswap` wrapper never touches the token at all; it only moves bytes between your terminal and the pty.

## Requirements

- Python 3.9+ (the pty wrapper is standard library only — no runtime dependencies)
- `jq` and `curl` (for the API call)
- Claude Code with an active OAuth session (`~/.claude/.credentials.json`)

## Authors

- **Brandon Thomas** — author
- **Claude** — co-author (written with [Claude Code](https://claude.com/claude-code))

## License

Apache-2.0 © 2026 Brandon Thomas
