#!/usr/bin/env bash
# cluster-triage.sh <context>
#
# Read-only, token-cheap triage scan of one cluster. Does the heavy `kubectl get`
# calls INSIDE the script and greps for trouble keywords, so the agent only reads a
# short verdict instead of a full `get pods -A` dump.
#
#   Output: [OK] lines = healthy (no action).  [!] lines = drill in here.  [i] = FYI.
#   Exit:   0 = all clear (no drill-down needed).  1 = issues found.
#
# Complies with the operating rules (AGENTS.md): read-only verbs only, --context always required.
set -uo pipefail

CTX="${1:-}"
if [ -z "$CTX" ]; then
  echo "usage: cluster-triage.sh <context>" >&2
  exit 2
fi
K(){ kubectl --context "$CTX" "$@"; }

# Pod STATUS values that mean a real problem (drill in):
BAD='CrashLoopBackOff|ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError|CreateContainerError|RunContainerError|OOMKilled|Evicted|Error|ContainerStatusUnknown|Init:Error|Init:CrashLoopBackOff|DeadlineExceeded'
# Transient/normal-ish states — surfaced as info only, not a hard issue:
WATCH='Pending|ContainerCreating|PodInitializing|Terminating|Init:'

R=""; add(){ R+="$1"$'\n'; }

add "==================== triage: $CTX ===================="

# ---- Reachability -----------------------------------------------------------
# Guard against a false "ALL CLEAR" when the cluster is simply unreachable: a failed
# `kubectl` prints error text to stderr, and blindly line-counting it reported bogus
# "N Ready" nodes. Detect connection/auth failures up front and bail loudly.
nodes="$(K get nodes --no-headers 2>&1)"; nrc=$?
if [ "$nrc" -ne 0 ] || echo "$nodes" | grep -qiE 'Unable to connect|failed to verify certificate|x509:|couldn.t get.*server|connection refused|i/o timeout|no such host|Unauthorized|forbidden'; then
  add "[!] UNREACHABLE / API error for context '$CTX' — NOT healthy, cannot triage:"
  add "$(echo "$nodes" | grep -iE 'Unable to connect|certificate|x509:|server|refused|timeout|host|Unauthorized|forbidden' | head -3 | sed 's/^/    /')"
  add "==================== RESULT: ERROR — context unreachable, fix connectivity first ===================="
  printf '%s' "$R"
  exit 1
fi

# ---- Nodes -----------------------------------------------------------------
if echo "$nodes" | grep -qiE 'NotReady|SchedulingDisabled'; then
  add "[!] nodes NotReady / cordoned:"
  add "$(echo "$nodes" | grep -iE 'NotReady|SchedulingDisabled' | sed 's/^/    /')"
else
  add "[OK] nodes: $(echo "$nodes" | grep -c .) Ready"
fi
# Pressure conditions (DiskPressure is the classic 'node goes dark' cause)
press="$(K get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" Disk="}{range .status.conditions[?(@.type=="DiskPressure")]}{.status}{end}{" Mem="}{range .status.conditions[?(@.type=="MemoryPressure")]}{.status}{end}{" PID="}{range .status.conditions[?(@.type=="PIDPressure")]}{.status}{end}{"\n"}{end}' 2>/dev/null | grep -iE '=(True)')"
[ -n "$press" ] && { add "[!] node pressure = True (check disk/mem first):"; add "$(echo "$press" | sed 's/^/    /')"; }

# ---- Pods ------------------------------------------------------------------
pods="$(K get pods -A --no-headers 2>&1)"
podreport="$(echo "$pods" | awk -v bad="$BAD" -v watch="$WATCH" '
  { ns=$1; name=$2; ready=$3; status=$4; rest=$5; age=$6
    if (status ~ bad)            { b=b sprintf("    %s/%s  status=%s  restarts=%s\n",ns,name,status,rest); nb++; next }
    n=split(ready,a,"/")
    if (n==2 && a[1]+0<a[2]+0 && status=="Running") { nr=nr sprintf("    %s/%s  ready=%s (Running but not ready)\n",ns,name,ready); nnr++; next }
    if (status=="Running" && rest+0>5) { h=h sprintf("    %s/%s  restarts=%s\n",ns,name,rest); nh++; next }
    if (status ~ watch)          { w=w sprintf("    %s/%s  status=%s  age=%s\n",ns,name,status,age); nw++ }
  }
  END{
    if (nb>0)  printf "[!] problem pods (%d) — read logs/describe these:\n%s", nb, b
    if (nnr>0) printf "[!] pods Running but not fully ready (%d):\n%s", nnr, nr
    if (nh>0)  printf "[i] high cumulative restarts >5 (%d) — often historical on long-lived pods; drill only if flapping now:\n%s", nh, h
    if (nw>0)  printf "[i] transient/pending (%d) — usually fine, only worry if persistent:\n%s", nw, w
    if (nb==0 && nnr==0 && nh==0) printf "[OK] pods: none in a bad state\n"
  }')"
add "$podreport"

# ---- PVCs ------------------------------------------------------------------
pvc="$(K get pvc -A --no-headers 2>/dev/null | grep -viE 'Bound' | grep -viE 'No resources')"
[ -n "$pvc" ] && { add "[!] PVCs not Bound:"; add "$(echo "$pvc" | sed 's/^/    /')"; }

# ---- Warning events (reason summary only — cheap) --------------------------
warn="$(K get events -A --field-selector type=Warning -o custom-columns='R:.reason' --no-headers 2>/dev/null | sort | uniq -c | sort -rn | head -8)"
[ -n "$warn" ] && { add "[i] top Warning event reasons:"; add "$(echo "$warn" | sed 's/^/    /')"; }

# ---- Verdict ---------------------------------------------------------------
if echo "$R" | grep -q '\[!\]'; then
  add "==================== RESULT: ISSUES — drill only into the [!] items ===================="
  printf '%s' "$R"
  exit 1
else
  add "==================== RESULT: ALL CLEAR — no drill-down needed ===================="
  printf '%s' "$R"
  exit 0
fi
