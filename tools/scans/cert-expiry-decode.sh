#!/usr/bin/env bash
# cert-expiry-decode.sh
#
# Decode Kubernetes control-plane / kubelet certs and print their expiry, newest-expiring last.
# Feed it "grep -H" output gathered on a control-plane node (via node-shell or SSH). Read-only.
#
# stdin: "grep -H" output from the node. Lines are either
#   <file>:<pem line>                           (.crt files)
#   <file>:    client-certificate-data: <b64>   (kubeconfigs)
# Prints: name | notAfter | days left | issuer CN
#
# Example (gather on the node, decode locally):
#   kubectl-node_shell --context <CTX> <cp-node> -- \
#     grep -RH -e 'BEGIN CERTIFICATE' -e client-certificate-data /etc/kubernetes /var/lib/kubelet/pki \
#     | bash tools/scans/cert-expiry-decode.sh
set -euo pipefail
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
while IFS= read -r line; do
  f="${line%%:*}"; rest="${line#*:}"
  key=$(printf '%s' "$f" | sed 's#^/etc/kubernetes/##; s#^/var/lib/kubelet/pki/#kubelet/#; s#/#_#g')
  if [[ "$rest" == *client-certificate-data:* ]]; then
    printf '%s' "${rest##*client-certificate-data: }" | base64 -d > "$d/$key.pem"
  else
    printf '%s\n' "$rest" >> "$d/$key.pem"
  fi
done
now=$(date +%s)
for p in "$d"/*.pem; do
  n=$(basename "$p" .pem)
  end=$(openssl x509 -in "$p" -noout -enddate | cut -d= -f2)
  iss=$(openssl x509 -in "$p" -noout -issuer | sed 's/.*CN *= *//')
  days=$(( ( $(date -d "$end" +%s) - now ) / 86400 ))
  printf '%-40s %-26s %6s  %s\n' "$n" "$end" "${days}d" "$iss"
done | sort -k6
