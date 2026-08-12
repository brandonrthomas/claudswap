---
description: List all available Claude models (incl. old ones /model hides) or actually switch the session to one
argument-hint: "[number from /swap list, or model/alias — e.g. 3, 'opus 4.1', haiku]"
allowed-tools: Bash(CLAUDSWAP_SCRIPT_PATH *), Bash(bash CLAUDSWAP_SCRIPT_PATH *)
---

User argument: "$ARGUMENTS"

**If no argument was given** — list mode:
1. Run: `bash CLAUDSWAP_SCRIPT_PATH list` (output: number, family, alias, ID, name, release date).
2. Present the models grouped by family — one small table or section per family (Fable, Opus, Sonnet, Haiku), keeping the script's numbers and aliases exactly as given. Columns: #, alias, name, release date (show the full ID only if asked — the alias resolves it). Mark the current model with `← current` appended inside the release-date cell (not as an extra column — that breaks table rendering). If the env var `$CLAUDSWAP_CONTEXT` is set, show the context mode before the table (e.g. "Context: 1M" or "Context: 200K — launched with `--200k`"). Close with: "Switch with `/swap <number>` or `/swap <alias>` — or just reply with a number."
3. If the user replies with a bare number (or alias) in the next message, run switch mode with it — the script resolves numbers against the same list.

**If an argument was given** — switch mode:
1. Run: `bash CLAUDSWAP_SCRIPT_PATH switch '<argument>'` (single-quote the argument).
2. On success ("queued via <backend>"), the script has typed `/model <resolved-id>` into this terminal; it executes the moment your turn ends. Tell the user, in one or two lines, which model the switch is queued for. Note: the built-in `/model` also saves the choice as the default for new sessions — that's its normal behavior.
3. If the script prints `NO_INJECTION_BACKEND`, this terminal can't inject input. Give the user the resolved command to run themselves: `/model <resolved-id>`. Mention they can use `claudswap` to make `/switch` work in any terminal.
4. If the script reports ambiguity or "no model matches", relay its output and ask which one they meant. Do not retry with a guessed ID.

Keep the response terse either way. Do not do anything beyond what's described here.
