# Playbook: scanning a cluster cheaply (triage-first)

Goal: find out if a cluster is healthy **without** dumping big `kubectl get`/`logs` output into
the model. The scan scripts do the bulk fetch + keyword filtering **in the shell** and return a
short verdict. You only read logs when a keyword actually shows up.

## The workflow (in order)

1. **Symptom index first.** If you're chasing a specific symptom, check the
   [README index](README.md) / your symptom→playbook map — the known cause for that cluster is the
   *first* thing to verify (but not the only thing; keep the other causes in play).

2. **Triage scan.** One command, compact output:
   ```bash
   bash tools/scans/cluster-triage.sh <CTX>
   ```
   - `[OK]` lines → healthy, move on.
   - `[!]` lines → the only things worth drilling into.
   - `[i]` lines → FYI (transient/pending pods, historical restarts) — usually ignore.
   - Exit `0` = all clear (stop here, spend no more tokens). Exit `1` = drill the `[!]` items.

   It checks: nodes Ready/cordoned, **DiskPressure/MemoryPressure/PIDPressure**, pod states
   (CrashLoopBackOff, ImagePullBackOff, OOMKilled, Evicted, Error, not-ready-while-Running…),
   PVCs not Bound, and a top-reasons summary of Warning events.

3. **Log scan (only for flagged pods).** Instead of reading a whole log, grep it for error
   keywords and read only the hits:
   ```bash
   bash tools/scans/pod-logs-scan.sh <CTX> <namespace> <pod> [container] [tail]
   ```
   - `[OK]` = no error keywords → don't open the full log.
   - `[!]` = shows the matching lines (the likely root-cause hints).

4. **Record + stop.** Put real findings (with the scan output as proof) into your knowledge
   library (`knowledge/`); if you learned a recurring "symptom → cause" for this cluster, add it
   there. Then stop — don't keep reading healthy resources.

## Why this saves tokens
A cluster with hundreds of pods returns hundreds of lines from `get pods -A`; the triage script
collapses that to a handful of `[!]` lines. A noisy log becomes a few matched lines. The model
reads verdicts, not dumps.

## Keyword sets (tune these as you learn)
- **Pod states → drill:** in `cluster-triage.sh` var `BAD`.
- **Transient/ignore:** var `WATCH`.
- **Log error keywords:** in `pod-logs-scan.sh` var `ERR`.
Add patterns when you hit a failure mode the scan missed; remove ones that only ever false-positive.

## Gotchas / limits (be honest)
- Triage is heuristic — `[i]`/`[!]` are hints, not verdicts. A clean scan is *evidence of*
  health, not proof every workload is correct.
- Cumulative restart counts are historical on long-lived pods (a 630-day pod with 25 restarts
  is usually fine) — that's why they're `[i]`, not `[!]`.
- Old failed **Job/CronJob** pods linger in `Error`/`ImagePullBackOff`; the scan surfaces them
  (they can be real backup failures) — confirm before dismissing.
- The scripts call kubectl inside themselves, so a guard hook can't inspect each inner call.
  They are written to be read-only and to require `--context`; keep them that way if you edit them.
