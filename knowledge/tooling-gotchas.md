# Tooling gotchas

Generalized, reusable lessons on guard bypasses, kubeconfig merges, kubectl apply, and mc storage ops.

### A guard that greps literal `kubectl` is bypassed by `bash script.sh` and `kubectl create --raw`
**Symptom:** A policy guard (PreToolUse hook) that inspects the command string for `kubectl` verbs lets destructive operations through, and the single-use approval token isn't consumed.
**Cause:** The guard greps the **literal tool command string**. Running kubectl inside a script makes the tool command just `bash script.sh` — no `kubectl` token, so the destructive-verb check **and** any hard-guard are both skipped for in-script commands, and the approval token is never consumed (it lingers as a live approval). Separately, `kubectl create --raw <path> -f file` reaches the apiserver but isn't caught as a destructive verb (the guard keys on the first bare word).
**Fix:** **Always `rm -f` the approval token after running an approved command file.** Treat script execution as carrying the operator's manual approval, not the guard's. For read-only scanners run via `bash`, keep them read-only *by construction* (never add a mutating verb). To close the gaps, the guard must also inspect referenced script files and treat `--raw` as mutating.
**Note:** To POST a test alert to Alertmanager, don't use `kubectl create --raw …/api/v2/alerts` → HTTP 415 `UnsupportedMediaType` (kubectl's content-type can't be overridden); use `kubectl exec <am-pod> -c alertmanager -- amtool alert add … --alertmanager.url=http://localhost:9093`.

### `kubectl apply` via heredoc stdin is blocked even with a valid token — write the manifest to a file
**Symptom:** `kubectl apply -f - <<'YAML' … YAML` is blocked by the guard even when a valid approval token exists on disk; the token is NOT consumed (a tell).
**Cause:** The guard tokenizes the whole command string to find verbs; a large inline heredoc body (YAML + embedded shell with `||`, `aws s3 cp`, etc.) confuses the segment splitter so the `apply` token check doesn't resolve, and it denies.
**Fix:** Never feed `apply`/`create -f -` a heredoc. Write the manifest to a file and run `kubectl --context <context> -n <namespace> apply -f <file>` — a short command the guard parses cleanly, so a fresh token is honored.
**Note:** Keep secrets out of that file (use `secretKeyRef`) since command files are shared.

### Merging kubeconfigs on Windows needs `;`, not `:` — a `:` separator can wipe your config
**Symptom:** `KUBECONFIG="a:b" kubectl config view --flatten` produces **empty (0-byte)** output; piping that over the real config wipes every context.
**Cause:** On Windows kubectl the `KUBECONFIG` path separator is **`;`**, not POSIX `:`. Paths contain drive-letter colons (`C:\…`), so a `:` separator makes kubectl read one bogus giant path → `error loading config file` → empty flatten. The failure is silent (flatten "succeeds" with empty output; an env-prefixed failure can dodge `set -e`).
**Fix:** Before any merge — (1) `cp "$KCFG" backup.yaml` first; (2) use `;` on Windows / `:` on Linux-mac; (3) put your own config **first** in `KUBECONFIG` to preserve its active context; (4) `test -s merged.yaml && grep -q <name> merged.yaml` **before** copying over the real config.
**Note:** `kubectl config view --flatten` is read-only; to change the active context, edit `current-context:` in the file directly rather than `use-context`.

### `mc` storage wipes: trailing slash required, and never trust the tool's own "after = 0" line
**Symptom:** `mc rm --recursive --force <alias>/<bucket>` errors `Requested path not found` and deletes nothing; or a wipe script prints "after = 0 B / 0 objects" but the bucket is actually untouched.
**Cause:** A bucket-**root** recursive remove needs a **trailing slash** (`<alias>/<bucket>/`) — `mc ls`/`mc find` work without it so the dry-run looks fine. And a `mc du || mc ls --summarize` fallback can mask a `du` failure and print a bogus `0`.
**Fix:** Always use `…/` on bucket-root `mc rm`. **Verify a reclaim with an independent object-count delta** (before vs. after) from a *separate* read, never the deleting tool's self-report.
**Note:** The minimal MinIO server image has `mc`/`sh` but **no `grep`/`awk`** — emit raw `mc` output from the pod and parse in the outer shell. Also, `mc rm` frees disk **asynchronously** — deleted objects move to `.minio.sys/tmp/.trash` and a background janitor purges blocks over ~minutes, so immediate `df` looks flat or momentarily worse. Don't conclude the reclaim failed from an immediate `df`; watch `.trash` drain (`du -xh -d0 <pvc-path>/data/.minio.sys/tmp/.trash`) then re-check `df`. (Incomplete multipart orphans live in `.minio.sys/multipart`, cleared with `mc rm --incomplete --recursive --force <alias>/<bucket>/`.)
