# codex-statusline-hud

Usage HUD for the **OpenAI Codex CLI** — model, context, and rate-limit/credit
info in your status line, for both **individual** (Plus / Pro / Edu) and
**company** (Team / Enterprise / Business) ChatGPT plans.

There are two ways to use it. **Start with the native footer** — it's built into
Codex and needs no extra process. Use the standalone `codex-hud` only for the
extras the native footer can't show (bars, credit balance, usage outside Codex).

---

## 1. Native footer (recommended) — Codex 0.141+

Codex's own status line supports built-in items including **usage limits**.
Configure it in `~/.codex/config.toml` (or run `/statusline` in the TUI):

```toml
# The footer is a SINGLE line — items render left-to-right and the tail
# truncates when wider than the terminal, so put the most important first.
# `dir` is omitted on purpose (the shell prompt already shows it).
tui.status_line = [
  "model-with-reasoning",
  "git-branch",
  "context-remaining",
  "five-hour-limit",
  "weekly-limit",
  "approval-mode",
]
tui.status_line_use_colors = true
```

Renders in the Codex footer, e.g.:

```
gpt-5.5 medium · main · ctx 78% · 5h 98% · 7d 76% · on-request
```

Available item ids: `model-with-reasoning`, `reasoning`, `dir`, `git-branch`,
`branch-changes`, `pull-request-number`, `context-remaining`, `context-used`,
`context-window-size`, `used-tokens`, `total-input-tokens`,
`total-output-tokens`, `five-hour-limit`, `weekly-limit`, `approval-mode`,
`codex-version`, `fast-mode`, `task-progress`.
Validate edits with `codex doctor`.

**Limitations of the native footer:** single line only (no rows — the tail
truncates when too wide), percentages only (no bars), no credit balance /
spend-cap / overage detail, and it only shows inside Codex. For any of those,
use the standalone `codex-hud` below.

---

## 2. Standalone `codex-hud` (optional) — for bars & extras

A separate command for what the native footer can't do: **bars**, **credit
balance / spend caps / overage**, edu/company detail, and showing usage
**outside** Codex (shell, tmux, watch pane).

```
Codex | Plus
  5h █████░░░░░░░ 42% (resets 2h 5m)
  7d ████████░░░░ 71% (resets 2d 10h)
```

```
Codex | Business (company)
  Credits 328.50 left / 500.00 cap
  5h █░░░░░░░░░░░ 12% (resets 1h 0m)
```

> Why not run this *inside* Codex's footer? Codex has **no command-backed/
> custom-script status item** in any released version (open request:
> [codex#20244](https://github.com/openai/codex/issues/20244),
> [codex#14043](https://github.com/openai/codex/issues/14043)). So it runs
> alongside Codex, not in it. If Codex ever ships custom items, this renderer
> drops straight in.

## How it works

Reads the Codex OAuth token from `~/.codex/auth.json` and queries the (private)
ChatGPT usage endpoint `GET https://chatgpt.com/backend-api/wham/usage`
(`Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`).
The response is cached for 60s (the same cadence the Codex TUI itself polls).

> ⚠️ This endpoint is private and may change. If it breaks, check the official
> usage page at <https://chatgpt.com/codex/settings/usage>.

The token is **read only** — Codex refreshes it itself when it runs. If the
token is expired, the HUD says so instead of touching your credentials.

## Install

```bash
git clone https://github.com/<you>/codex-statusline-hud
cd codex-statusline-hud
./install.sh         # symlinks `codex-hud` into ~/.local/bin
```

Requires `bash`, `curl`, and `jq` (`brew install jq`).

## Usage

```bash
codex-hud              # full panel, once
codex-hud --watch 30   # refresh the panel every 30s in its own pane
codex-hud --line       # compact one-liner (shell prompt / scripts)
codex-hud --tmux       # compact one-liner with tmux color escapes
codex-hud --json       # raw usage JSON (debugging)
codex-hud --no-color   # disable ANSI (also honors $NO_COLOR)
```

### Shell prompt (zsh)

```zsh
# ~/.zshrc — show the compact HUD line above each prompt
precmd() { codex-hud --line 2>/dev/null }
```

### tmux status bar

```tmux
# ~/.tmux.conf
set -g status-right '#(codex-hud --tmux)'
set -g status-interval 60
```

## Account types

| Account kind | Plans | What's shown |
|---|---|---|
| Consumer | Free / Plus / Pro | 5h + weekly rate-limit bars with reset times |
| Edu | Education / Student / Academic | Rate-limit bars **plus** credit/overage detail (approx local & cloud messages, overage warnings) |
| Company | Team / Enterprise / Business | Credit balance (or ∞ unlimited) and spend cap first, then rate-limit bars |

Account kind is **auto-detected** from the usage response (`plan_type`,
`credits`, `spend_control`) with a fallback to the `id_token` plan claim. A
credit balance on an otherwise-consumer plan is treated as a credit/org account.

The HUD parses the live `wham/usage` schema (`rate_limit.primary_window` /
`secondary_window`, top-level `plan_type`, `credits`, `spend_control`) and also
falls back to Codex's internal-event schema, so it keeps working across versions.

## Config (env)

| Var | Default | Meaning |
|---|---|---|
| `CODEX_HOME` | `~/.codex` | Codex config dir (where `auth.json` lives) |
| `CODEX_HUD_TTL` | `60` | usage cache TTL in seconds |
| `NO_COLOR` | — | disable colors when set |

## License

MIT
