#!/usr/bin/env bash
# guard.sh  —  a PreToolUse-style guard for shell/Bash tool calls that run kubectl.
#
# WHAT IT ENFORCES (deterministically, before any command runs):
#   RO-CONTEXT   Never change the active context. `kubectl config use-context` is denied, and every
#                cluster-talking kubectl call MUST carry an explicit --context <name>. (Operating
#                rule in AGENTS.md: one shared workspace talks to many clusters; a hidden "current
#                context" is how you fat-finger the wrong cluster.)
#   READ-ONLY    Only read-only kubectl verbs are allowed. Anything mutating (apply, create, delete,
#                edit, patch, replace, scale, rollout, drain, exec, cp, run, port-forward, ...) is
#                BLOCKED unless the operator has approved it by creating the single-use token
#                <root>/state/APPROVE_NEXT (see AGENTS.md "APPROVE_NEXT").
#
#   node-shell exception (read-only host access):
#                `kubectl node-shell <node> -- <cmd>` (and the plugin form `kubectl-node_shell`) is
#                ALLOWED WITHOUT a token *iff* it is non-interactive (has `-- <cmd>`), carries an
#                explicit --context, and the host command is strictly READ-ONLY (allowlisted primary
#                binary + denylist of any mutating/redirect/substitution/privilege/network/interpreter
#                command). Interactive node-shell is blocked (it can't be bounded to read-only).
#
#   HARD GUARD (protected CNI / cluster-infra — NOT overridable by APPROVE_NEXT):
#                Mutating the CNI / API-aggregation layer is blocked outright, EVEN WITH a token.
#                Covers the CNI/system namespaces, any APIService, and any Calico/Tigera/flannel
#                resource. Deleting these breaks pod networking cluster-wide. If a change here is ever
#                truly required, a human runs it manually, outside the agent.
#
# INPUT — works with any agent harness, not just one product:
#   * If a JSON object arrives on stdin (the common "hook" shape), the command is read from
#     `.tool_input.command`. This matches Claude Code / most tool-call hook payloads.
#   * Otherwise the raw stdin text is treated as the command; if stdin is empty, "$*" is used.
#   So you can wire it as a PreToolUse hook, OR call it directly: `guard.sh 'kubectl --context X get po'`.
#
# CONTRACT:  exit 0 = allow the command.  exit 2 = block it (stderr is shown to the agent).
# Non-kubectl commands are always allowed here (they are still recorded by logger.sh).
set -uo pipefail
set -f   # disable globbing while we tokenize the command

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Repo root = two levels up from tools/hooks/. logs/, audit/, state/ live at the root.
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Per-user identity: attribute blocks/approvals to the operator + avoid merge conflicts on a shared
# repo. Identity = git user.name, else OS user.
log_user() {
  local u; u="$(git config user.name 2>/dev/null)"
  [ -z "$u" ] && u="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"; [ -z "$u" ] && u="unknown"
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]._-'
}
# Redact inline secret ARGS before writing to the SHARED audit trail (no output is ever written there).
redact_cmd() {
  printf '%s' "$1" | sed -E \
    -e 's/(--token[=[:space:]])[^[:space:]]+/\1<REDACTED>/g' \
    -e 's/(--password[=[:space:]])[^[:space:]]+/\1<REDACTED>/g' \
    -e 's/(--client-secret[=[:space:]])[^[:space:]]+/\1<REDACTED>/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._-]+/\1<REDACTED>/g' \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=)[^[:space:]]+/\1<REDACTED>/g'
}
USER_SLUG="$(log_user)"
LOG="$ROOT/logs/commands-$USER_SLUG.log"            # FULL — local only (gitignored)
AUDIT="$ROOT/audit/commands-$USER_SLUG.audit.log"   # policy verdicts — SHARED (no output)
APPROVE_FLAG="$ROOT/state/APPROVE_NEXT"
mkdir -p "$ROOT/logs" "$ROOT/audit" "$ROOT/state" 2>/dev/null

now() { date '+%Y-%m-%d %H:%M:%S%z'; }
# Append a one-line policy verdict to the shared audit trail.
audit() { printf '%s | user=%s | VERDICT=%s | cmd=%s\n' "$(now)" "$USER_SLUG" "$1" "$(redact_cmd "$cmd")" >> "$AUDIT" 2>/dev/null; }

# ---- read the command from whatever the harness handed us -----------------------------------
payload="$(cat 2>/dev/null)"
cmd=""
if [ -n "$payload" ]; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [ -z "$cmd" ] && cmd="$payload"   # not a hook JSON → treat stdin as the raw command
fi
[ -z "$cmd" ] && cmd="$*"

# Nothing to inspect, or not a kubectl command -> allow.
[ -z "$cmd" ] && exit 0
case "$cmd" in
  *kubectl*) ;;
  *) exit 0 ;;
esac

deny() {
  {
    echo "$(now) | BLOCKED | reason=$1"
    echo "    cmd: $cmd"
  } >> "$LOG" 2>/dev/null
  audit "BLOCKED"
  echo "BLOCKED by guard: $1" >&2
  echo "Command was: $cmd" >&2
  echo "If this is intended, the OPERATOR must approve it (see AGENTS.md: READ-ONLY / APPROVE_NEXT)." >&2
  exit 2
}

# --- HARD GUARD: protected CNI / cluster-infra (NOT overridable by APPROVE_NEXT) --------------
# Mutating these is almost never intended and is catastrophic (an agent once deleted the CNI
# namespaces/APIServices "to free CPU" and broke pod networking cluster-wide — CNI ADD/DEL failed,
# pods stuck Terminating). So it is blocked outright, even with the operator's single-use token.
deny_protected() {
  {
    echo "$(now) | BLOCKED-PROTECTED | reason=$1"
    echo "    cmd: $cmd"
  } >> "$LOG" 2>/dev/null
  audit "BLOCKED-PROTECTED"
  echo "BLOCKED by guard (PROTECTED CNI/cluster-infra): $1" >&2
  echo "Command was: $cmd" >&2
  echo "This is a HARD guard — NOT overridable by APPROVE_NEXT. Deleting/mutating the CNI or cluster" >&2
  echo "aggregation layer breaks the whole cluster. If truly required, a human runs it manually." >&2
  exit 2
}

# Protected kube/CNI namespaces — never let the agent mutate these or objects inside them.
PROTECTED_NS='kube-system|kube-public|kube-node-lease|calico-system|calico-apiserver|tigera-operator|kube-flannel'

# Called for MUTATING (non-allowlisted) kubectl segments only. Denies hard if the target is CNI /
# cluster-infra, regardless of the approval token.
check_protected() {
  local seg="$1"
  # (a) a protected namespace named as the object of `namespace/ns ...` (handles a list of names)
  if printf '%s' "$seg" | grep -Eiq "(^|[[:space:]])(namespaces?|ns)[[:space:]]+([^[:space:]|;&]+[[:space:]]+)*(${PROTECTED_NS})([[:space:]]|,|$)"; then
    deny_protected "targets a protected CNI/system namespace (${PROTECTED_NS//|/, }) — deleting/mutating it breaks the cluster."
  fi
  # (b) an operation scoped INTO a protected namespace via -n/--namespace
  if printf '%s' "$seg" | grep -Eiq "(-n|--namespace)[[:space:]=]+(${PROTECTED_NS})([[:space:]]|$)"; then
    deny_protected "operation is scoped to a protected CNI/system namespace (${PROTECTED_NS//|/, })."
  fi
  # (c) APIService objects — cluster-critical API aggregation (deleting one breaks API discovery)
  if printf '%s' "$seg" | grep -Eiq '(^|[[:space:]])apiservices?(\.apiregistration\.k8s\.io)?([[:space:]/]|$)'; then
    deny_protected "APIService is a cluster-critical aggregation point (e.g. metrics.k8s.io / projectcalico.org); deleting one breaks API discovery and crashes operators."
  fi
  # (d) Calico / Tigera CNI resources (by kind or API group) and named CNI workloads
  if printf '%s' "$seg" | grep -Eiq '(^|[[:space:]])(installations?|tigerastatuses?|ippools?|felixconfigurations?|bgpconfigurations?)([[:space:].]|$)' \
     || printf '%s' "$seg" | grep -Eiq 'projectcalico\.org|tigera\.io' \
     || printf '%s' "$seg" | grep -Eiq '(calico-node|calico-kube-controllers|calico-apiserver|calico-typha|tigera-operator|kube-flannel)'; then
    deny_protected "Calico/Tigera/flannel CNI resource — mutating it breaks pod networking."
  fi
}

# --- RO-CONTEXT 1: never switch the active context ----------------------------
if printf '%s' "$cmd" | grep -Eq 'kubectl[[:space:]]+([^|;&]*[[:space:]])?config[[:space:]]+use-context'; then
  deny "'kubectl config use-context' changes the active context. Pass --context <name> on each call instead."
fi

# --- node-shell exception (must be evaluated before the generic verb loop) ----
# Detect a node-shell invocation only at a *command position* (start / after a shell separator), so a
# plugin file path or URL that merely contains the string does NOT match. Two invocation forms:
#   (1) plugin binary, contiguous:  kubectl-node_shell [flags] <node> -- <cmd>   (PLUGIN_RE below)
#   (2) kubectl subcommand:         kubectl [flags] node-shell <node> -- <cmd>   (caught in the loop)
PLUGIN_RE='(^|[;|&(])[[:space:]]*((sudo|env)[[:space:]]+)?kubectl-node[-_]shell([[:space:]]|$)'

check_nodeshell() {
  # Must carry an explicit --context.
  case " $cmd " in
    *" --context "*|*" --context="*) : ;;
    *) deny "node-shell must include an explicit --context <name>." ;;
  esac
  # Must be non-interactive: a host command after ' -- '.
  case "$cmd" in
    *" -- "*) : ;;
    *) deny "node-shell is only allowed non-interactively — pass a read-only command after ' -- ' (interactive shells are blocked)." ;;
  esac
  host="${cmd#* -- }"   # everything after the first ' -- ' == the command run on the host

  # (a) no output redirection to a file (only >/dev/null, 2>/dev/null, 2>&1 are OK)
  scrub="$(printf '%s' "$host" | sed -E 's/2>&1//g; s/[12]?>[[:space:]]*\/dev\/null//g')"
  if printf '%s' "$scrub" | grep -Eq '>>|>'; then
    deny "node-shell host command: output redirection to a file is not read-only."
  fi
  # (b) no command / process substitution or backticks
  if printf '%s' "$host" | grep -Eq '\$\(|`|<\(|>\('; then
    deny "node-shell host command: command/process substitution is not allowed."
  fi
  # (c) denylist — any mutating / privilege / network / interpreter command anywhere
  DENY='rm|rmdir|unlink|mv|cp|dd|tee|truncate|shred|wipefs|mkfs[.a-z0-9]*|mke2fs|fsck[.a-z0-9]*|parted|fdisk|gdisk|sgdisk|sfdisk|mkswap|swapon|swapoff|mount|umount|remount|chmod|chown|chgrp|chattr|setfacl|ln|touch|install|dpkg|apt|apt-get|aptitude|yum|dnf|rpm|apk|snap|pip|pip3|gem|npm|yarn|cargo|make|gcc|cc|kill|pkill|killall|fuser|reboot|shutdown|halt|poweroff|telinit|systemctl|service|rc-service|initctl|chroot|pivot_root|sysctl|modprobe|insmod|rmmod|iptables|ip6tables|nft|crontab|curl|wget|nc|ncat|netcat|socat|ssh|scp|sftp|rsync|ftp|tftp|python|python2|python3|perl|ruby|php|node|lua|tclsh|expect|sudo|su|doas|unshare|setsid|eval|source|xargs|vi|vim|nano|emacs|patch|git|tar|cpio|zip|gzip|bzip2|xz|zstd|setenforce'
  if printf '%s' "$host" | grep -Eiwq "($DENY)"; then
    bad="$(printf '%s' "$host" | grep -Eiwo "($DENY)" | head -1)"
    deny "node-shell host command contains a non-read-only command ('$bad'). Only read-only host commands are permitted."
  fi
  # (d) primary binary must be on the read-only allowlist (unwrap an optional sh/bash -c)
  primary="$(printf '%s' "$host" \
    | sed -E 's/^[[:space:]]+//' \
    | sed -E 's/^(sh|bash|ash|dash)[[:space:]]+-c[[:space:]]+//' \
    | sed -E 's/^[^[:alnum:]_./-]+//' \
    | awk '{print $1}')"
  primary="${primary##*/}"
  RO='du|df|ls|dir|vdir|cat|zcat|head|tail|wc|stat|find|file|readlink|realpath|ps|top|free|vmstat|iostat|mpstat|sar|uptime|uname|arch|hostname|lsblk|blkid|findmnt|mountpoint|lsof|lscpu|lsmod|lspci|lsusb|id|whoami|groups|date|echo|printf|true|grep|egrep|fgrep|zgrep|awk|gawk|mawk|sed|sort|uniq|cut|tr|nl|tac|rev|comm|cksum|md5sum|sha1sum|sha256sum|basename|dirname|nproc|getconf|getent|ip|ss|netstat|ping|dig|nslookup|host|dmesg|journalctl|numfmt|column|fold|expand|paste|join|pwd|tree'
  if ! printf '%s' "$primary" | grep -Eq "^($RO)$"; then
    deny "node-shell host command: '${primary:-<none>}' is not on the read-only allowlist (du/df/ls/cat/find/stat/ps/free/grep/awk/sed/sort/head/tail/lsblk/findmnt/journalctl/dmesg/…). Edit guard.sh RO= to extend."
  fi
  # (e) per-tool write-flag guards for tools that CAN write
  if printf '%s' "$host" | grep -Eqw 'find' && printf '%s' "$host" | grep -Eq '(-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprintf|-fls)'; then
    deny "node-shell: 'find' with a write/exec action (-delete/-exec/…) is not read-only."
  fi
  if printf '%s' "$host" | grep -Eqw 'sed' && printf '%s' "$host" | grep -Eq '(^|[[:space:]])(-i|--in-place)'; then
    deny "node-shell: 'sed -i' modifies files."
  fi
  if printf '%s' "$host" | grep -Eqw 'sort' && printf '%s' "$host" | grep -Eq '[[:space:]]-o([[:space:]]|=)'; then
    deny "node-shell: 'sort -o' writes to a file."
  fi
  if printf '%s' "$host" | grep -Eq '(awk|gawk|mawk)' && printf '%s' "$host" | grep -Eq '(system\(|print[f]?[[:space:]]*>)'; then
    deny "node-shell: awk system()/redirection is not read-only."
  fi
  if printf '%s' "$host" | grep -Eqw 'ip' && printf '%s' "$host" | grep -Eq '(^|[[:space:]])(add|del|delete|flush|set|change|replace)([[:space:]]|$)'; then
    deny "node-shell: 'ip' write subcommand is not read-only."
  fi
  # passed all checks -> allow, and record it.
  {
    echo "$(now) | NODE-SHELL ALLOWED (read-only host cmd)"
    echo "    cmd: $cmd"
  } >> "$LOG" 2>/dev/null
  audit "NODE-SHELL-ALLOWED"
  exit 0
}

# Route the plugin (contiguous) form before the generic verb loop.
if printf '%s' "$cmd" | grep -Eq "$PLUGIN_RE"; then
  check_nodeshell
fi

# Read-only verbs that are always allowed:
ALLOW='get|describe|logs|top|explain|version|api-resources|api-versions|cluster-info|events|auth|config|kustomize|diff'
# Of those, verbs that do NOT talk to a cluster (so --context is not required):
NOCTX='version|explain|api-resources|api-versions|config|kustomize'

approved_consumed=0

# Inspect every kubectl segment that sits at a command position (start / after a shell separator,
# optionally behind sudo/env). This deliberately ignores the string 'kubectl' when it only appears
# inside a path, URL, or as another command's argument.
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  # tokenize the text that follows 'kubectl'
  set -- $seg
  verb=""
  while [ $# -gt 0 ]; do
    tok="$1"; shift
    case "$tok" in
      --context=*|--kubeconfig=*|--namespace=*|-n=*) : ;;                 # flag=value, no verb
      --context|--kubeconfig|--namespace|-n|--as|--as-group|--cluster|--user|--token|--server)
        shift || true ;;                                                  # flag consumes its value
      -*) : ;;                                                            # any other global flag
      *) verb="$tok"; break ;;                                            # first bare word = verb
    esac
  done
  [ -z "$verb" ] && continue

  # node-shell as a kubectl subcommand (form 2) -> validate as read-only host access.
  case "$verb" in
    node-shell|node_shell) check_nodeshell ;;
  esac

  # Does this segment carry an explicit --context ?
  has_ctx=0
  case " $seg " in *" --context "*|*" --context="*) has_ctx=1 ;; esac

  if printf '%s' "$verb" | grep -Eq "^($ALLOW)$"; then
    # read-only verb: require --context unless it is a no-cluster verb
    if printf '%s' "$verb" | grep -Eqv "^($NOCTX)$"; then
      [ "$has_ctx" -eq 0 ] && deny "kubectl '$verb' must include an explicit --context <name> flag."
    fi
  else
    # HARD GUARD first: CNI / cluster-infra is never mutable by the agent, even with a token.
    check_protected "$seg"
    # destructive / non-allowlisted verb: require operator approval token
    if [ -f "$APPROVE_FLAG" ]; then
      approved_consumed=1
    else
      deny "'$verb' is not on the read-only allowlist and needs the operator's approval (APPROVE_NEXT)."
    fi
  fi
done < <(printf '%s\n' "$cmd" \
           | grep -oE '(^|[;|&(])[[:space:]]*((sudo|env)[[:space:]]+)?kubectl[[:space:]]+[^|;&]*' \
           | sed -E 's/^([[:space:];|&(]*)((sudo|env)[[:space:]]+)?kubectl[[:space:]]+//')

# Consume the single-use approval token and record it.
if [ "$approved_consumed" -eq 1 ]; then
  rm -f "$APPROVE_FLAG"
  {
    echo "$(now) | APPROVED-DESTRUCTIVE (single-use operator token consumed)"
    echo "    cmd: $cmd"
  } >> "$LOG" 2>/dev/null
  audit "APPROVED-DESTRUCTIVE"
fi

exit 0
