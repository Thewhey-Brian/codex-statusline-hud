# codex-statusline-hud

A comprehensive usage **HUD for the OpenAI Codex CLI** — rate-limit and credit
tracking for both **individual** (Plus / Pro / Edu) and **company**
(Team / Enterprise / Business) ChatGPT plans, rendered as colored bars.

```
Codex | Plus
  5h █████░░░░░░░ 42% (resets 2h 5m)
  7d ████████░░░░ 71% (resets 2d 10h)
```

```
Codex | Business (company)
  Credits 328.50 left
  5h █░░░░░░░░░░░ 12% (resets 1h 0m)
```

## Why standalone (and not a native status line)?

Unlike Claude Code, **Codex has no command-backed/custom-script status line**.
Its `/statusline` feature (merged Feb 2026) only lets you pick from a *fixed set
of built-in items*; an external-command status item is still an open, unreleased
feature request ([codex#20244](https://github.com/openai/codex/issues/20244),
[codex#14043](https://github.com/openai/codex/issues/14043)). This holds for the
latest Codex too. So this HUD is a standalone tool you run alongside Codex —
on demand, in a watch pane, or wired into your shell prompt / tmux bar.

If/when Codex ships custom status items, the same renderer can be dropped in.

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
