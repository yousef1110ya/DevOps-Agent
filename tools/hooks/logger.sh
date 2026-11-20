#!/usr/bin/env bash
# logger.sh  —  a PostToolUse-style recorder for shell/Bash tool calls.
#
# TWO TIERS, both PER-USER:
#
#   1) FULL log      <root>/logs/commands-<user>.log        — command + FULL output.
#      -> LOCAL ONLY (gitignored). Full output can contain secrets (get secret -o yaml, env dumps),
#         so it never leaves the machine. Use it for deep debugging locally.
#
#   2) AUDIT trail   <root>/audit/commands-<user>.audit.log — the shareable accountability record:
#      timestamp | user | session | cluster context | the command (secret-bearing ARGS redacted).
#      NO command output is ever written here, so no dumped secrets can leak. THIS is what syncs to a
#      team repo — the "who ran what, when, on which cluster" proof.
#
# Per-user files also mean a shared repo never merge-conflicts on the log (each person only ever
# writes their own file).
#
# INPUT: same flexible contract as guard.sh — a hook JSON on stdin (`.tool_input.command` +
# optional `.tool_response`, `.session_id`), OR raw stdin / "$*" as the command. When invoked
# directly (no JSON), there is no captured output to log, so only the audit line + a command record
# are written.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Per-user identity: prefer git user.name, else the OS user; slugified. Matches guard.sh exactly.
log_user() {
  local u; u="$(git config user.name 2>/dev/null)"
  [ -z "$u" ] && u="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"; [ -z "$u" ] && u="unknown"
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]._-'
}
# Redact obvious inline secrets from a command line before it goes to the SHARED audit trail.
redact_cmd() {
  printf '%s' "$1" | sed -E \
    -e 's/(--token[=[:space:]])[^[:space:]]+/\1<REDACTED>/g' \
    -e 's/(--password[=[:space:]])[^[:space:]]+/\1<REDACTED>/g' \
    -e 's/(--client-secret[=[:space:]])[^[:space:]]+/\1<REDACTED>/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._-]+/\1<REDACTED>/g' \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=)[^[:space:]]+/\1<REDACTED>/g'
}
USER_SLUG="$(log_user)"
LOG="$ROOT/logs/commands-$USER_SLUG.log"            # FULL output — LOCAL ONLY (gitignored)
AUDIT="$ROOT/audit/commands-$USER_SLUG.audit.log"   # accountability — SHARED (no output)
mkdir -p "$ROOT/logs" "$ROOT/audit" 2>/dev/null

payload="$(cat 2>/dev/null)"
is_json=0
if [ -n "$payload" ] && printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then is_json=1; fi

if [ "$is_json" -eq 1 ]; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  sid="$(printf '%s' "$payload" | jq -r '.session_id // "?"' 2>/dev/null)"
else
  cmd="${payload:-$*}"
  sid="?"
fi
[ -z "$cmd" ] && exit 0

ts="$(date '+%Y-%m-%d %H:%M:%S%z')"

# Best-effort detection of which --context(s) the command touched (for auditing).
ctx="$(printf '%s' "$cmd" | grep -oE -- '--context[= ][^ ]+' | sed -E 's/--context[= ]//' | paste -sd, - 2>/dev/null)"
[ -z "$ctx" ] && ctx="(none/non-kubectl)"

# (2) SHARED audit trail — metadata only, NO output.
printf '%s | user=%s | session=%s | ctx=%s | cmd=%s\n' \
  "$ts" "$USER_SLUG" "$sid" "$ctx" "$(redact_cmd "$cmd")" >> "$AUDIT"

# (1) LOCAL full log — command + full output (only present when a hook JSON carried tool_response).
resp=""
if [ "$is_json" -eq 1 ]; then
  resp="$(printf '%s' "$payload" | jq -r '
    .tool_response // empty
    | if type=="string" then .
      elif type=="object" then (to_entries | map("\(.key):\n\(.value|tostring)") | join("\n"))
      else tostring end' 2>/dev/null)"
fi

{
  echo "==================================================================="
  echo "[$ts] session=$sid context=$ctx"
  echo "\$ $cmd"
  echo "--- output ------------------------------------------------------"
  printf '%s\n' "$resp"
} >> "$LOG"

exit 0
