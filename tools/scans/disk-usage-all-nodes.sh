#!/usr/bin/env bash
# disk-usage-all-nodes.sh <context> [--du]
#
# Disk usage across ALL nodes of one cluster, focused on the data drive where pod PVCs live
# (on hostpath/local-path provisioners that's a single shared mount, often /media/data or
# /var/lib). Read-only.
#
#   default        : fast `df` sweep of the data mount and / on every node  (seconds/node)
#   --du           : ALSO run a per-node `du` breakdown of the hostpath BasePath, with each
#                    pvc-<uuid> dir resolved to its <namespace>/<pvc>  (SLOW — walks the
#                    whole data drive on every node; minutes per node)
#
# Needs: kubectl (with --context), and kubectl-node_shell on PATH (install only when needed;
# see onboarding.md). node-shell spawns a short-lived read-only helper pod per node; the guard
# allows it because the host command is read-only.
#
# Config via env:
#   DATA_MOUNT   the shared data filesystem to report (default: /media/data) — adjust to yours.
#
# Complies with the operating rules: read-only only, --context always passed.
set -uo pipefail

CTX="${1:-}"
MODE="${2:-}"
DATA_MOUNT="${DATA_MOUNT:-/media/data}"
if [ -z "$CTX" ]; then
  echo "usage: disk-usage-all-nodes.sh <context> [--du]    (DATA_MOUNT=/your/mount to override)" >&2
  exit 2
fi
K(){ kubectl --context "$CTX" "$@"; }
NS(){ kubectl-node_shell --context "$CTX" "$@"; }

# Discover the OpenEBS hostpath BasePath (fallback to a common default under the data mount).
BASE="$(K get sc -o jsonpath='{range .items[*]}{.metadata.annotations.cas\.openebs\.io/config}{"\n"}{end}' 2>/dev/null \
        | sed -n 's/.*BasePath[^"]*"\([^"]*\)".*/\1/p' | head -1)"
[ -z "$BASE" ] && BASE="$DATA_MOUNT/openebs/openebs"

nodes="$(K get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)"
if [ -z "$nodes" ] || echo "$nodes" | grep -qiE 'error|Unable to connect|x509'; then
  echo "[!] cannot list nodes for context '$CTX':"; echo "$nodes" | head -3; exit 1
fi

echo "==================== disk usage: $CTX ===================="
echo "data mount: $DATA_MOUNT   hostpath BasePath: $BASE"
echo ""
echo "---- df sweep ($DATA_MOUNT and /) per node ----"
printf '%-22s %-14s %-6s %-6s %-8s\n' NODE MOUNT USE% AVAIL SIZE
for n in $nodes; do
  out="$(NS "$n" -- df -h "$DATA_MOUNT" / 2>/dev/null | awk 'NR>1{print $6" "$5" "$4" "$2}')"
  # de-dup identical mount lines, keep the data mount and /
  echo "$out" | awk -v node="$n" -v dm="$DATA_MOUNT" '
    $1==dm  && !md++ {printf "%-22s %-14s %-6s %-6s %-8s\n", node, dm, $2, $3, $4}
    $1=="/" && !r++  {printf "%-22s %-14s %-6s %-6s %-8s\n", node, "/", $2, $3, $4}'
done

if [ "$MODE" = "--du" ]; then
  echo ""
  echo "---- per-node du of $BASE (SLOW; pvc-<uuid> resolved to namespace/pvc) ----"
  # Build the PV -> namespace/pvc map once.
  map="$(K get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"/"}{.spec.claimRef.name}{"\t"}{.spec.capacity.storage}{"\n"}{end}' 2>/dev/null)"
  for n in $nodes; do
    raw="$(NS "$n" -- du -xh -d1 "$BASE" 2>/dev/null | grep -E '^[0-9.]+[KMGT]?[[:space:]]' | sort -h | tail -12)"
    [ -z "$raw" ] && continue
    echo ""
    echo "### $n"
    echo "$raw" | while IFS= read -r line; do
      sz="${line%%$'\t'*}"; path="${line##*/}"
      hit="$(echo "$map" | awk -F'\t' -v p="$path" '$1==p{print $2" ("$3")"}')"
      if [ -n "$hit" ]; then printf '  %-7s %s\n' "$sz" "$hit"; else printf '  %-7s %s\n' "$sz" "$path"; fi
    done
  done
  echo ""
  echo "NOTE: hostpath/local-path provisioners enforce NO quota — a PVC's declared size is cosmetic;"
  echo "a volume grows until the node's data drive fills. Usual heavy hitters: DB replica-set members"
  echo "and object-store pool volumes. See playbooks/disk-usage-all-nodes.md and knowledge/storage-and-disk.md."
fi
