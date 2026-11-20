# Control-plane certificate expiry (= `kubeadm certs check-expiration`, read-only)

`kubeadm` and `openssl` may not be on your node-shell allowlist, so don't run
`kubeadm certs check-expiration` on the node. Instead read the **public** certs (never `.key`
files, never `client-key-data`) with allowlisted `grep`/`sed` and decode them locally. This gives
the same rows kubeadm prints. Replace `<CTX>`, `<CP_NODE>`, `<NODE>`, `<API_HOST>`.

```bash
# 1) every control-plane node: pki certs + kubeconfig client certs + kubelet client cert -> decode locally
kubectl node-shell --context <CTX> <CP_NODE> -- sh -c 'grep -H . /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/etcd/*.crt; grep -H client-certificate-data /etc/kubernetes/*.conf; sed -n "/BEGIN CERT/,/END CERT/p" /var/lib/kubelet/pki/kubelet-client-current.pem | sed "s#^#/var/lib/kubelet/pki/kubelet-client-current.pem:#"' 2>&1 \
  | grep -E '^/(etc|var)/' | bash tools/scans/cert-expiry-decode.sh
# -> name | notAfter | days left | issuer.  Leaf certs = 1y, CAs (ca/etcd-ca/front-proxy-ca) = 10y.

# 2) what the API server actually presents (from your machine, no cluster write)
echo | openssl s_client -connect <API_HOST>:6443 -servername <API_HOST> 2>/dev/null | openssl x509 -noout -enddate -subject

# 3) workers: kubelet client cert (auto-rotates when rotateCertificates=true)
kubectl node-shell --context <CTX> <NODE> -- sed -n "/BEGIN CERT/,/END CERT/p" /var/lib/kubelet/pki/kubelet-client-current.pem 2>/dev/null \
  | sed -n '/BEGIN CERT/,/END CERT/p' | openssl x509 -noout -enddate
```

Gotchas
- HA clusters: run step 1 on **every** CP node. Each node has its own apiserver/etcd certs.
- Leaf certs are renewed by `kubeadm upgrade` or `kubeadm certs renew all` + static-pod restart. That is a **write**
  and needs owner approval; it's run by the owner via a command file.
- Don't redirect node-shell output to a file (`>` anywhere after ` -- ` is denied by a read-only guard). Pipe it instead.
- Writing a file whose *text* contains a node-shell command via a Bash heredoc can trip the guard. Use the file-write tool.
