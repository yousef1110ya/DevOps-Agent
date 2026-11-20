#!/usr/bin/env bash
# cluster-identities.sh [context]
#
# Harvest every kubectl context's STABLE IDENTITY (its API server URL + user) from the
# LOCAL kubeconfig, so you can tell which local context names point at the SAME cluster.
#
# WHY: in a shared workspace the same cluster often carries DIFFERENT context names on
# different machines. The cluster's real identity is its API server URL (+ shared admin
# user), NOT the local context name. Keep your knowledge keyed to the cluster (by URL),
# and record each device's context name as an alias.
#
#   - Reads `kubectl config view` only. NO cluster contact, NO --context needed, works even for
#     clusters that are currently unreachable (it's just parsing your kubeconfig).
#   - Output is NON-SECRET: server URLs + user names. It deliberately does NOT use `--raw`, so
#     certs/tokens stay REDACTED and never hit any shared log.
#   - Contexts that share the SAME server URL are the SAME cluster = aliases of each other. The
#     script flags those groups for you.
#
# Usage:
#   bash tools/scans/cluster-identities.sh            # all contexts, as a markdown table
#   bash tools/scans/cluster-identities.sh <context>  # just one context's identity
set -uo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "cluster-identities: kubectl not found on PATH" >&2; exit 2; }
command -v jq      >/dev/null 2>&1 || { echo "cluster-identities: jq not found on PATH" >&2; exit 2; }

ONE="${1:-}"

# Local kubeconfig only. `config view` is a read-only, no-cluster verb (allowed by the guard,
# needs no --context). No `--raw` => secrets stay redacted.
JSON="$(kubectl config view -o json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] || ! printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
  echo "cluster-identities: could not read kubeconfig via 'kubectl config view':" >&2
  printf '%s\n' "$JSON" | head -3 >&2
  exit 1
fi

# Rows: context <TAB> server <TAB> user, sorted by server then context so aliases sit together.
rows="$(printf '%s' "$JSON" | jq -r '
  ((.clusters // []) | map({ (.name): (.cluster.server // "?") }) | add // {}) as $srv
  | (.contexts // [])
  | map({ ctx: .name,
          server: ($srv[.context.cluster] // "?"),
          user: (.context.user // "?") })
  | sort_by(.server, .ctx)
  | .[] | [.ctx, .server, .user] | @tsv')"

if [ -z "$rows" ]; then
  echo "cluster-identities: no contexts found in this kubeconfig." >&2
  exit 1
fi

# Single-context lookup -------------------------------------------------------
if [ -n "$ONE" ]; then
  hit="$(printf '%s\n' "$rows" | awk -F'\t' -v c="$ONE" '$1==c')"
  if [ -z "$hit" ]; then
    echo "cluster-identities: context '$ONE' not found. Known contexts:" >&2
    printf '%s\n' "$rows" | cut -f1 | sed 's/^/  - /' >&2
    exit 1
  fi
  ctx="$(printf '%s' "$hit" | cut -f1)"
  srv="$(printf '%s' "$hit" | cut -f2)"
  usr="$(printf '%s' "$hit" | cut -f3)"
  echo "Context : $ctx"
  echo "Server  : $srv   <- stable identity (match key for your cluster registry)"
  echo "User    : $usr"
  # Any other local context on the same server = an alias of the same cluster.
  aliases="$(printf '%s\n' "$rows" | awk -F'\t' -v s="$srv" -v c="$ctx" '$2==s && $1!=c {print $1}')"
  if [ -n "$aliases" ]; then
    echo "Aliases : same server on this device also named ->"
    printf '%s\n' "$aliases" | sed 's/^/            /'
  fi
  exit 0
fi

# Full table ------------------------------------------------------------------
echo "# Context identities on THIS device  ($(printf '%s\n' "$rows" | wc -l | tr -d ' ') contexts)"
echo
echo "The API server URL is the cluster's identity. Contexts sharing a URL are the SAME cluster"
echo "(aliases) — see the groups below. Record identity <-> aliases in your own cluster registry."
echo
echo "| Context | API server URL (identity) | User |"
echo "|---------|---------------------------|------|"
printf '%s\n' "$rows" | awk -F'\t' '{ printf "| %s | `%s` | %s |\n", $1, $2, $3 }'

# Shared-server groups = same cluster under >1 name on THIS device.
groups="$(printf '%s' "$JSON" | jq -r '
  ((.clusters // []) | map({ (.name): (.cluster.server // "?") }) | add // {}) as $srv
  | (.contexts // [])
  | map({ ctx: .name, server: ($srv[.context.cluster] // "?") })
  | group_by(.server)
  | map(select(length > 1))
  | .[] | (.[0].server) + "\t" + ([.[].ctx] | join(", "))')"

echo
if [ -n "$groups" ]; then
  echo "## Same cluster under multiple context names on THIS device (record as aliases):"
  printf '%s\n' "$groups" | awk -F'\t' '{ printf "- `%s`\n    aliases: %s\n", $1, $2 }'
else
  echo "## No two local contexts share a server URL — each context is a distinct cluster here."
  echo "   (Cross-DEVICE aliases still come from matching this list against a teammate's.)"
fi
