# Ingress TLS cert expired on a restored cluster (cert-manager renewals stuck)

Symptom: browser `NET::ERR_CERT_DATE_INVALID` while the app, DNS and Issuer look fine. Common after
a config-only restore (e.g. Velero) where ACME order/challenge objects didn't restore cleanly. All
steps below are read-only. Replace `<CTX>`, `<HOST>`.

```bash
# 1) What the site really serves
echo | openssl s_client -connect <HOST>:443 -servername <HOST> 2>/dev/null | openssl x509 -noout -subject -issuer -dates

# 2) Cluster-wide: expiry, revision and Ready. Past renewal + null revision = stuck, even if Ready=True today.
kubectl --context <CTX> get certificate -A -o json | jq -r '.items[]|[.metadata.namespace,.metadata.name,(.status.revision//"null"|tostring),(.status.notAfter//"-"),(.status.renewalTime//"-"),(.status.conditions[]?|select(.type=="Ready")|.status)]|@tsv' | sort -t$'\t' -k4

# 3) The reason
kubectl --context <CTX> -n cert-manager logs deploy/cert-manager --since=2h | grep -E '^E' | cut -c1-220 | tail -20

# 4) Were the ACME objects restored?
kubectl --context <CTX> get certificaterequest,order -A -o json | jq -r '.items|group_by(.metadata.labels["velero.io/restore-name"]//"NOT-restored")|map("\(.[0].metadata.labels["velero.io/restore-name"]//"NOT-restored"): \(length)")[]'
```

Known error signatures after a restore:
- `certificaterequests "<cert>-1" already exists` / `found Order resource not owned by this CertificateRequest`:
  revision was lost, new CR name collides.
- `404 No order for ID ...`: Order points at a dead Let's Encrypt order.

Gotchas:
- `Ready=True` hides the problem until expiry. Check `renewalTime` in the past.
- `curl` can get 403 from ingresses whose server-snippet blocks that user agent. Test with `-A 'Mozilla/5.0'`.
- Restored Orders/Challenges don't cascade-delete with their CRs. Delete them explicitly, and check for unlabelled Challenges.
- Fix is destructive and needs owner approval. Stage a cert-reissue command file for the owner.
