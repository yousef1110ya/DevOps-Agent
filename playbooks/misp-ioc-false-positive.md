# Playbook: triage a Wazuh "MISP IOC match (to_ids)" alert (rule 100702, level 14)

**Symptom:** a high-severity Wazuh alert like
`rule.description: MISP IOC match (to_ids): <hash> [hash] event <N> - <event info>`,
`rule.id:100702`, `rule.level:14`, `rule.groups: threat_intel, misp, misp_alert, ids_flagged`,
`data.integration:misp`, usually with `data.misp.orig_location:syscheck` (so the trigger is File
Integrity Monitoring on a node).

These fire at level 14 and can mail/page. Most hash-based ones that originate from **FIM/syscheck**
are **false positives** — confirm before raising an incident. Work top-down; stop as soon as a step
proves benign.

> All commands are **read-only**. Substitute your own SIEM host SSH, the Wazuh manager container
> name, and the MISP DB container name for the `<...>` placeholders. On a Dockerized SIEM, run the
> inner commands with `sudo docker exec <container> …`.

## 0. Is the IOC value a well-known EMPTY-FILE hash? (the #1 FP — check first)
An empty/zero-byte file hashes to a fixed value. Wazuh FIM reports exactly this for **symlinks** and
for files that are empty/mid-create/mid-delete, so a MISP event that stored a malware hash as the
empty hash matches *everything*.
```
# the empty-file hashes:
printf '' | md5sum     # d41d8cd98f00b204e9800998ecf8427e
printf '' | sha1sum    # da39a3ee5e6b4b0d3255bfef95601890afd80709
printf '' | sha256sum  # e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```
If `data.misp.value` equals one of these → **false positive, you are done** (record it, then jump to
"Remediate"). This is a common poisoned-event case (a malware-sample attribute stored with the empty hash).

## 1. What FILE(S) actually triggered it? (pull from the Wazuh archive, don't guess)
`orig_rule_id` (e.g. 550/553/554) is a syscheck FIM rule; the path is in the original event.
```
ssh <siem-ssh> \
 'sudo docker exec <wazuh-manager-container> sh -c \
  "zcat /var/ossec/logs/alerts/<YYYY>/<Mon>/ossec-alerts-<DD>.json.gz | grep <hash> \
   | grep -o \"\\\"path\\\":\\\"[^\\\"]*\\\"\" | sort | uniq -c | sort -rn | head -40"'
```
- **All paths are OS symlinks / system files** (`/usr/bin/xz*`, `/etc/ssl/certs/*.pem` & `*.0`,
  `/etc/localtime`, systemd `*.wants/*.mount`, git-* wrappers, `sudoedit`) → **FIM-symlink artifact,
  benign.** (On Ubuntu these `.0`/`.pem` cert names and the `xz*` wrappers are all symlinks.)
- **A real, attacker-plausible path** (a user dir, `/tmp`, a webroot, an app volume) with a
  **non-empty** hash that matches a real sample → escalate to incident response (contain the host).

## 2. What does MISP actually say about this IOC? (read-only DB)
```
ssh <siem-ssh> 'sudo docker exec <misp-db-container> sh -c \
 "mysql -u root -p\$MYSQL_ROOT_PASSWORD \$MYSQL_DATABASE -e \
  \"SELECT id,type,category,value1,value2,to_ids,deleted FROM attributes \
    WHERE uuid=\\\"<attr-uuid>\\\";\""'
```
- `type = malware-sample` or `filename|md5` → value is **composite** `filename|hash`; the match is on
  the hash part (`value2`). If `value2` is the empty hash → junk IOC.
- Count how poisoned the event is:
  `SELECT type,count(*),sum(to_ids) FROM attributes WHERE event_id=<N> AND deleted=0 GROUP BY type;`

## 3. Does MISP already KNOW the IOC is junk? (warninglists)
```
SELECT w.id,w.name,w.enabled FROM warninglist_entries e
 JOIN warninglists w ON w.id=e.warninglist_id WHERE e.value='<hash>';
```
If it returns an **enabled** warninglist (e.g. "known hashes for empty files", common-FP lists) the
hash is a recognised false positive. **Gotcha:** even with `enforceWarninglist:True` in the
integration, MISP does **not** reliably strip the hash sub-part of composite
`malware-sample`/`filename|hash` attributes — so the alert fires anyway. Don't rely on enforcement alone.

## Remediate (choose; both are MUTATING → need owner approval)
- **Local Wazuh rule override (fleet-wide, reversible):** add a `local_rules.xml` rule that drops
  rule 100702 to level 0 when `data.misp.value` is a known empty/benign hash (or when the FIM path is
  a symlink dir). Cheapest; also protects against future poisoned events. Needs manager
  `restart`/ruleset reload.
- **Fix at the MISP source:** set `to_ids=0` on (or soft-delete) the empty-hash `malware-sample`
  attributes in the offending event so they stop being queryable IOCs. Surgical; only helps for that
  event. Done via MISP UI/API by the owner.
- **Reduce FIM noise:** scope syscheck / disable md5 on pure-symlink dirs. Bigger change; usually the
  rule override is enough.

Record the verdict + which files in your knowledge library (**Check-first hints**).
