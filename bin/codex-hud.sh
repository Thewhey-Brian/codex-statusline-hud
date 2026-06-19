#!/usr/bin/env bash
# codex-hud — a comprehensive usage HUD for the OpenAI Codex CLI.
#
# Codex (as of CLI 0.138) has no command-backed TUI status line, so this is a
# standalone HUD. It reads the Codex OAuth token from ~/.codex/auth.json and
# queries the (private) ChatGPT usage endpoint, then renders rate-limit /
# credit info for both individual and company (team/enterprise/business)
# ChatGPT plans.
#
# Modes:
#   codex-hud            full panel (one render)
#   codex-hud --watch N  refresh the full panel every N seconds (default 30)
#   codex-hud --line     compact one-liner (for shell prompt / scripts)
#   codex-hud --tmux     compact one-liner with tmux #[...] color escapes
#   codex-hud --json     raw usage JSON (debugging)
#   codex-hud --no-color disable ANSI colors (also honors NO_COLOR)
#
# Exit codes: 0 ok, 2 no token, 3 token expired, 4 fetch failed.

set -u

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTH_FILE="$CODEX_HOME/auth.json"
USAGE_URL="https://chatgpt.com/backend-api/wham/usage"
CACHE_FILE="${TMPDIR:-/tmp}/.codex_hud_usage"
CACHE_TTL="${CODEX_HUD_TTL:-60}"     # seconds; the live TUI polls ~60s too
CURL_TIMEOUT=8
NOW=$(date +%s)

MODE="panel"
USE_COLOR=1
WATCH_INTERVAL=30
[ -n "${NO_COLOR:-}" ] && USE_COLOR=0
[ -t 1 ] || USE_COLOR=0   # not a tty -> no color unless forced

while [ $# -gt 0 ]; do
  case "$1" in
    --watch) MODE="watch"; [ -n "${2:-}" ] && printf '%s' "$2" | grep -q '^[0-9]\+$' && { WATCH_INTERVAL="$2"; shift; } ;;
    --line) MODE="line" ;;
    --tmux) MODE="tmux"; USE_COLOR=0 ;;
    --json) MODE="json" ;;
    --no-color) USE_COLOR=0 ;;
    --color) USE_COLOR=1 ;;
    -h|--help) MODE="help" ;;
    *) ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# Colors
# --------------------------------------------------------------------------
if [ "$USE_COLOR" = "1" ]; then
  RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; GRAY=$'\033[90m'
else
  RST=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; GRAY=""
fi

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq; then
  echo "codex-hud: 'jq' is required (brew install jq)" >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Rendering helpers
# --------------------------------------------------------------------------
BAR_W=12
# pick bar color by utilization %
bar_color() {
  local p="${1:-0}"
  if   [ "$p" -ge 90 ] 2>/dev/null; then printf '%s' "$RED"
  elif [ "$p" -ge 70 ] 2>/dev/null; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}
# make_bar PERCENT WIDTH  -> filled/empty block bar
make_bar() {
  local p="${1:-0}" w="${2:-$BAR_W}" filled i out=""
  [ "$p" -lt 0 ] 2>/dev/null && p=0; [ "$p" -gt 100 ] 2>/dev/null && p=100
  filled=$(( p * w / 100 ))
  i=0; while [ "$i" -lt "$w" ]; do
    if [ "$i" -lt "$filled" ]; then out="${out}█"; else out="${out}░"; fi
    i=$((i+1))
  done
  printf '%s' "$out"
}
# humanize seconds -> "2h 5m" / "3d 4h" / "12m"
fmt_dur() {
  local s="${1:-0}"
  [ "$s" -le 0 ] 2>/dev/null && { printf 'now'; return; }
  local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}
# nicely-cased plan label
plan_label() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    free*)        printf 'Free' ;;
    plus*)        printf 'Plus' ;;
    pro*)         printf 'Pro' ;;
    team*)        printf 'Team' ;;
    edu*)         printf 'Edu' ;;
    enterprise*)  printf 'Enterprise' ;;
    business*)    printf 'Business' ;;
    ""|unknown)   printf '' ;;
    *)            printf '%s' "$1" | awk '{print toupper(substr($0,1,1)) substr($0,2)}' ;;
  esac
}
# is this a company / credit-billed plan?
is_company_plan() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    team*|enterprise*|business*) return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Token + plan discovery
# --------------------------------------------------------------------------
ACCESS_TOKEN=""; ACCOUNT_ID=""; JWT_PLAN=""; TOKEN_STATE="ok"

decode_jwt_plan() {
  # echo chatgpt_plan_type claim from a JWT id_token, if present
  local jwt="$1" payload
  payload=$(printf '%s' "$jwt" | cut -d. -f2 | tr '_-' '/+')
  case $(( ${#payload} % 4 )) in 2) payload="${payload}==";; 3) payload="${payload}=";; esac
  printf '%s' "$payload" | base64 -d 2>/dev/null \
    | jq -r '.["https://api.openai.com/auth"].chatgpt_plan_type // empty' 2>/dev/null
}

load_token() {
  [ -f "$AUTH_FILE" ] || { TOKEN_STATE="notoken"; return 1; }
  ACCESS_TOKEN=$(jq -r '.tokens.access_token // empty' "$AUTH_FILE" 2>/dev/null)
  ACCOUNT_ID=$(jq -r '.tokens.account_id // empty' "$AUTH_FILE" 2>/dev/null)
  local idt; idt=$(jq -r '.tokens.id_token // empty' "$AUTH_FILE" 2>/dev/null)
  [ -n "$idt" ] && JWT_PLAN=$(decode_jwt_plan "$idt")
  [ -z "$ACCESS_TOKEN" ] && { TOKEN_STATE="notoken"; return 1; }
  # check access-token expiry from its own JWT exp claim, if decodable
  local exp; exp=$(decode_jwt_exp "$ACCESS_TOKEN")
  if [ -n "$exp" ] && [ "$NOW" -ge "$exp" ] 2>/dev/null; then TOKEN_STATE="expired"; return 1; fi
  return 0
}

decode_jwt_exp() {
  local jwt="$1" payload
  printf '%s' "$jwt" | grep -q '\.' || return 0   # opaque token, can't check
  payload=$(printf '%s' "$jwt" | cut -d. -f2 | tr '_-' '/+')
  case $(( ${#payload} % 4 )) in 2) payload="${payload}==";; 3) payload="${payload}=";; esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null
}

file_age() {
  [ -f "$1" ] || { echo 999999; return; }
  local m; m=$(stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0)
  echo $(( NOW - m ))
}

# --------------------------------------------------------------------------
# Fetch usage (cached)
# --------------------------------------------------------------------------
USAGE_JSON=""; FETCH_STATE="ok"

fetch_usage() {
  if [ "$(file_age "$CACHE_FILE")" -lt "$CACHE_TTL" ]; then
    USAGE_JSON=$(cat "$CACHE_FILE" 2>/dev/null)
    [ -n "$USAGE_JSON" ] && return 0
  fi
  load_token || { FETCH_STATE="$TOKEN_STATE"; return 1; }
  local resp http body
  resp=$(curl -s --max-time "$CURL_TIMEOUT" -w '\n%{http_code}' "$USAGE_URL" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "ChatGPT-Account-Id: $ACCOUNT_ID" \
    -H "Accept: application/json" \
    -H "User-Agent: codex-hud" 2>/dev/null)
  http=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  case "$http" in
    200)
      if printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        USAGE_JSON="$body"; printf '%s' "$body" > "$CACHE_FILE"; return 0
      fi
      FETCH_STATE="badjson"; ;;
    401) FETCH_STATE="expired" ;;
    403) FETCH_STATE="forbidden" ;;
    429) FETCH_STATE="ratelimited" ;;
    *)   FETCH_STATE="http${http:-err}" ;;
  esac
  # fall back to stale cache if we have it
  [ -f "$CACHE_FILE" ] && { USAGE_JSON=$(cat "$CACHE_FILE"); return 0; }
  return 1
}

# Pull a rate-limit window's fields with defensive fallbacks across schema
# variants. $1 = "primary" | "secondary". Echoes "PCT<TAB>RESET_SECONDS<TAB>WINDOW_LABEL".
window_fields() {
  local key="$1"
  printf '%s' "$USAGE_JSON" | jq -r --arg k "$key" '
    (.rate_limits[$k] // .[$k]) as $w
    | if ($w == null or $w == {}) then empty else
    ($w.used_percent // $w.used_pct // 0) as $pct
    | ($w.resets_in_seconds
        // (if ($w.reset_at // null) != null then ($w.reset_at - now) else null end)
        // ($w.seconds_until_reset // 0)) as $reset
    | ($w.window_minutes
        // (if ($w.limit_window_seconds // null) != null then ($w.limit_window_seconds/60) else null end)
        // null) as $win
    | "\($pct|floor)\t\($reset|floor)\t\($win // "")"
    end
  ' 2>/dev/null
}

# window label from minutes -> "5h" / "7d" / "Nm"
win_label() {
  local m="${1:-}"
  [ -z "$m" ] && { printf ''; return; }
  m=$(printf '%s' "$m" | cut -d. -f1)
  if   [ "$m" -ge 1440 ] 2>/dev/null; then printf '%dd' "$((m/1440))"
  elif [ "$m" -ge 60 ]  2>/dev/null; then printf '%dh' "$((m/60))"
  else printf '%dm' "$m"; fi
}

# --------------------------------------------------------------------------
# Render
# --------------------------------------------------------------------------
get_plan() {
  local p; p=$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.plan_type // .plan_type // .plan // empty' 2>/dev/null)
  [ -z "$p" ] || [ "$p" = "unknown" ] && p="$JWT_PLAN"
  printf '%s' "$p"
}

# build "5h ████░░ 42% (resets 2h 5m)" for a window; empty if no data
render_window() {
  local key="$1" deflabel="$2" line pct reset winmin lbl clr bar
  line=$(window_fields "$key"); [ -z "$line" ] && return 1
  pct=$(printf '%s' "$line" | cut -f1); reset=$(printf '%s' "$line" | cut -f2)
  winmin=$(printf '%s' "$line" | cut -f3)
  [ -z "$pct" ] && return 1
  lbl=$(win_label "$winmin"); [ -z "$lbl" ] && lbl="$deflabel"
  clr=$(bar_color "$pct"); bar=$(make_bar "$pct" "$BAR_W")
  if [ "$reset" -gt 0 ] 2>/dev/null; then
    printf '%s%s%s %s%s%s %s%d%%%s %s(resets %s)%s' \
      "$DIM" "$lbl" "$RST" "$clr" "$bar" "$RST" "$BOLD" "$pct" "$RST" \
      "$DIM" "$(fmt_dur "$reset")" "$RST"
  else
    printf '%s%s%s %s%s%s %s%d%%%s' "$DIM" "$lbl" "$RST" "$clr" "$bar" "$RST" "$BOLD" "$pct" "$RST"
  fi
}

# credits block for company / credit accounts
render_credits() {
  local has unlimited bal
  has=$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.credits.has_credits // .credits.has_credits // false' 2>/dev/null)
  [ "$has" != "true" ] && return 1
  unlimited=$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.credits.unlimited // .credits.unlimited // false' 2>/dev/null)
  bal=$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.credits.balance // .credits.balance // empty' 2>/dev/null)
  if [ "$unlimited" = "true" ]; then
    printf '%sCredits%s %s%s∞ unlimited%s' "$DIM" "$RST" "$BOLD" "$GREEN" "$RST"
  elif [ -n "$bal" ] && [ "$bal" != "null" ]; then
    printf '%sCredits%s %s%s left%s' "$DIM" "$RST" "$BOLD" "$(printf '%s' "$bal" | awk '{printf "%.2f", $0}')" "$RST"
  else
    printf '%sCredits%s %senabled%s' "$DIM" "$RST" "$DIM" "$RST"
  fi
}

state_message() {
  case "$1" in
    notoken)     printf 'not signed in (run: codex login)' ;;
    expired)     printf 'token expired — run codex once to refresh' ;;
    forbidden)   printf 'usage unavailable for this plan/account' ;;
    ratelimited) printf 'rate limited — try again shortly' ;;
    badjson)     printf 'unexpected response from usage endpoint' ;;
    http*)       printf 'usage fetch failed (%s)' "$1" ;;
    *)           printf 'usage unavailable' ;;
  esac
}

render_panel() {
  local plan plabel header p5 p7 credits company=0
  plan=$(get_plan); plabel=$(plan_label "$plan")
  is_company_plan "$plan" && company=1
  # credits present + balance -> treat as credit account regardless of plan string
  if [ "$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.credits.has_credits // .credits.has_credits // false' 2>/dev/null)" = "true" ] \
     && [ "$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.credits.balance // .credits.balance // "null"' 2>/dev/null)" != "null" ]; then
    company=1
  fi

  header="${BOLD}${CYAN}Codex${RST}"
  [ -n "$plabel" ] && header="${header} ${DIM}|${RST} ${BOLD}${plabel}${RST}"
  [ "$company" = "1" ] && header="${header} ${DIM}(company)${RST}"
  printf '%b\n' "$header"

  p5=$(render_window primary "5h")
  p7=$(render_window secondary "7d")
  credits=$(render_credits)

  if [ "$company" = "1" ]; then
    # company/credit account: lead with credits, then any rate windows
    [ -n "$credits" ] && printf '  %b\n' "$credits"
    [ -n "$p5" ] && printf '  %b\n' "$p5"
    [ -n "$p7" ] && printf '  %b\n' "$p7"
    [ -z "$credits$p5$p7" ] && printf '  %b\n' "${DIM}no usage data yet${RST}"
  else
    # individual account: rate-limit windows
    [ -n "$p5" ] && printf '  %b\n' "$p5"
    [ -n "$p7" ] && printf '  %b\n' "$p7"
    [ -n "$credits" ] && printf '  %b\n' "$credits"
    [ -z "$p5$p7$credits" ] && printf '  %b\n' "${DIM}no usage data yet — run a Codex turn${RST}"
  fi
}

render_line() {
  # compact: "Codex Plus · 5h 42% · 7d 71%"  (or credits for company)
  local plan plabel parts="" l5 l7 pct reset
  plan=$(get_plan); plabel=$(plan_label "$plan")
  local head="Codex"; [ -n "$plabel" ] && head="Codex ${plabel}"
  parts="${BOLD}${CYAN}${head}${RST}"

  local has bal
  has=$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.credits.has_credits // .credits.has_credits // false' 2>/dev/null)
  bal=$(printf '%s' "$USAGE_JSON" | jq -r '.rate_limits.credits.balance // .credits.balance // empty' 2>/dev/null)
  if { is_company_plan "$plan" || { [ "$has" = "true" ] && [ -n "$bal" ] && [ "$bal" != "null" ]; }; }; then
    if [ -n "$bal" ] && [ "$bal" != "null" ]; then
      parts="${parts} ${DIM}·${RST} ${BOLD}$(printf '%s' "$bal" | awk '{printf "%.2f",$0}') cr${RST}"
    fi
  fi
  l5=$(window_fields primary); l7=$(window_fields secondary)
  if [ -n "$l5" ]; then
    pct=$(printf '%s' "$l5" | cut -f1)
    parts="${parts} ${DIM}·${RST} 5h $(bar_color "$pct")${BOLD}${pct}%${RST}"
  fi
  if [ -n "$l7" ]; then
    pct=$(printf '%s' "$l7" | cut -f1)
    parts="${parts} ${DIM}·${RST} 7d $(bar_color "$pct")${BOLD}${pct}%${RST}"
  fi
  printf '%b\n' "$parts"
}

render_tmux() {
  # like --line but with tmux color escapes and no ANSI
  local plan plabel pct l5 l7 out
  plan=$(get_plan); plabel=$(plan_label "$plan")
  out="#[fg=cyan,bold]Codex${plabel:+ $plabel}#[default]"
  l5=$(window_fields primary); l7=$(window_fields secondary)
  if [ -n "$l5" ]; then pct=$(printf '%s' "$l5" | cut -f1); out="$out #[fg=$(tmux_color "$pct")]5h ${pct}%#[default]"; fi
  if [ -n "$l7" ]; then pct=$(printf '%s' "$l7" | cut -f1); out="$out #[fg=$(tmux_color "$pct")]7d ${pct}%#[default]"; fi
  printf '%s\n' "$out"
}
tmux_color() {
  local p="${1:-0}"
  if   [ "$p" -ge 90 ] 2>/dev/null; then printf 'red'
  elif [ "$p" -ge 70 ] 2>/dev/null; then printf 'yellow'
  else printf 'green'; fi
}

print_help() {
  cat <<EOF
codex-hud — usage HUD for the OpenAI Codex CLI

USAGE:
  codex-hud [--watch [N]] [--line] [--tmux] [--json] [--no-color]

MODES:
  (default)     full panel, rendered once
  --watch [N]   refresh the full panel every N seconds (default 30)
  --line        compact one-liner (shell prompt / scripts)
  --tmux        compact one-liner with tmux color escapes
  --json        raw usage JSON (debugging)

OPTIONS:
  --no-color    disable ANSI colors (also honors \$NO_COLOR)
  -h, --help    this help

ENV:
  CODEX_HOME      Codex config dir (default ~/.codex)
  CODEX_HUD_TTL   usage cache TTL in seconds (default 60)
EOF
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
run_once() {
  if ! fetch_usage; then
    local msg; msg=$(state_message "$FETCH_STATE")
    case "$MODE" in
      line) printf '%b\n' "${BOLD}${CYAN}Codex${RST} ${DIM}${msg}${RST}" ;;
      tmux) printf '#[fg=cyan,bold]Codex#[default] #[fg=red]%s#[default]\n' "$msg" ;;
      json) printf '{"error":"%s"}\n' "$FETCH_STATE" ;;
      *)    printf '%b\n' "${BOLD}${CYAN}Codex${RST}\n  ${RED}${msg}${RST}" ;;
    esac
    case "$FETCH_STATE" in notoken) return 2;; expired) return 3;; *) return 4;; esac
  fi
  case "$MODE" in
    json) printf '%s\n' "$USAGE_JSON" | jq . 2>/dev/null || printf '%s\n' "$USAGE_JSON" ;;
    line) render_line ;;
    tmux) render_tmux ;;
    *)    render_panel ;;
  esac
  return 0
}

case "$MODE" in
  help) print_help; exit 0 ;;
  watch)
    # clear-and-redraw loop
    while :; do
      printf '\033[H\033[2J' 2>/dev/null
      printf '%s%s%s\n\n' "$DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$RST"
      MODE="panel" run_once
      NOW=$(date +%s)
      sleep "$WATCH_INTERVAL"
    done
    ;;
  *) run_once; exit $? ;;
esac
