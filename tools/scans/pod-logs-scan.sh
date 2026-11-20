#!/usr/bin/env bash
# pod-logs-scan.sh <context> <namespace> <pod> [container] [tail]
#
# Pull recent logs for ONE pod and grep for error keywords. Prints only matching
# lines (+count) instead of dumping the whole log — so you spend tokens only when
# there is actually something wrong.
#
#   Exit: 0 = no error keywords found (skip it).  1 = matches found (investigate).
#
# Read-only (`kubectl logs`), --context required. Use after cluster-triage.sh flags a pod.
set -uo pipefail

CTX="${1:-}"; NS="${2:-}"; POD="${3:-}"; CON="${4:-}"; TAIL="${5:-500}"
if [ -z "$CTX" ] || [ -z "$NS" ] || [ -z "$POD" ]; then
  echo "usage: pod-logs-scan.sh <context> <namespace> <pod> [container] [tail]" >&2
  exit 2
fi

# Keyword set that indicates a real problem in logs:
ERR='error|err |fatal|panic|exception|traceback|timed out|timeout|refused|unreachable|OOM|out of memory|cannot|could not|unable to|failed|failure|denied|unauthorized|forbidden|crash|backoff|no such|not found|dial tcp|connection reset|broken pipe|deadlock|evicted|throttl'

args=(--context "$CTX" -n "$NS" logs "$POD" --tail="$TAIL")
[ -n "$CON" ] && args+=(-c "$CON")

out="$(kubectl "${args[@]}" 2>&1)"
matches="$(printf '%s\n' "$out" | grep -inE "$ERR" || true)"

if [ -z "$matches" ]; then
  echo "[OK] $NS/$POD: no error keywords in last $TAIL lines — no need to read the full log."
  exit 0
fi

n="$(printf '%s\n' "$matches" | grep -c .)"
echo "[!] $NS/$POD: $n line(s) match error keywords (last $TAIL). Most recent:"
printf '%s\n' "$matches" | tail -40 | sed 's/^/    /'
exit 1
