# scans/ — token-cheap, read-only cluster scan scripts

Read-only scripts that do the heavy `kubectl` fetch + keyword filtering **in the shell** and
return a short verdict, so an agent reads a handful of lines instead of full dumps. Scan before you
read (triage-first) — a clean scan tells you where **not** to spend time.

| Script | Usage | Exit 0 / 1 |
|--------|-------|------------|
| `cluster-triage.sh` | `bash tools/scans/cluster-triage.sh <CTX>` | 0 = all clear · 1 = `[!]` issues to drill |
| `pod-logs-scan.sh`  | `bash tools/scans/pod-logs-scan.sh <CTX> <ns> <pod> [container] [tail]` | 0 = no error keywords · 1 = matches |
| `cluster-identities.sh` | `bash tools/scans/cluster-identities.sh [CTX]` | 0 = printed identities · 1/2 = no kubeconfig/context |
| `disk-usage-all-nodes.sh` | `bash tools/scans/disk-usage-all-nodes.sh <CTX> [--du]` (`DATA_MOUNT=` to override) | 0 = printed · 1 = can't list nodes |
| `cert-expiry-decode.sh` | pipe control-plane cert grep output into it (see header) | prints expiry table |

**How they fit together**
1. `cluster-triage.sh <CTX>` first. Exit 0 → stop, the cluster is clear. Exit 1 → drill only into `[!]`.
2. For a flagged pod, `pod-logs-scan.sh <CTX> <ns> <pod>` greps its logs for error keywords before
   you open the full log.
3. `disk-usage-all-nodes.sh <CTX>` for a fast `df` sweep; add `--du` for a slow per-PVC `du`
   attribution (needs `kubectl-node_shell`). Disk answers must name the top consumers — see
   `knowledge/storage-and-disk.md`.
4. `cluster-identities.sh` maps your local context names to cluster identities (API server URL) so
   the same cluster under different names on different machines is recognised as one.

**Conventions (keep them true if you edit these):**
- Read-only kubectl verbs only (`get`, `logs`, `config view`), and `--context` always required for
  any *cluster-talking* call (`config view` is local-only, so it's exempt).
- Output is a compact `[OK]` / `[!]` / `[i]` report — never a raw dump.
- Tune the keyword variables (`BAD`, `WATCH`, `ERR`) as you learn new failure modes.
- A clean scan is *evidence of* health, not proof every workload is correct — it saves tokens, it
  does not replace judgement.
