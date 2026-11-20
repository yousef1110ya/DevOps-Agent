# Load balancers & edge

Generalized, reusable lessons for edge nginx load balancers that fail without firing cluster alerts.

### Edge nginx fails intermittently with no alerts — connection exhaustion on an unmonitored LB
**Symptom:** "The LB / the app fails sometimes but not always, and NO alerts fired." The cluster behind it looks healthy.
**Cause:** nginx connection exhaustion on the edge LB VM, which the cluster's Prometheus never scrapes (the LB box isn't monitored → no alert). Two distinct knobs, **check both**:
- **`worker_rlimit_nofile`** — if workers run with `nofile 1024`, FDs exhaust → `accept4() failed (24: Too many open files)`.
- **`worker_connections`** — even with a high nofile, the stock default `worker_connections 768` is far too low. Total slots = `worker_processes × worker_connections`; each L4/stream (MQTT/Kafka/TCP) session uses 2, so a busy edge blows past it in waves → `"768 worker_connections are not enough"` → can't open new connections for *any* service, so :443/:6443 blip too.
**Fix:** Set `worker_rlimit_nofile 65535` and **full `systemctl restart`** (a *reload* does NOT re-exec the master, so the nofile change won't take). Raise `worker_connections` to 16384 (safe under nofile 65535, ~2 FD/conn), `nginx -t`, then `systemctl reload`.
**Note:** A port-80 scanner/bot flood holding connections aggravates it by eating the shared pool. Identify: `grep 'worker_connections are not enough' error.log | grep ':80' | grep -oE 'client: [0-9.]+' | sort|uniq -c|sort -rn`; drop the worst IPs on :80 (firewall/`limit_conn`). **Root fix for the "no alerts" part: monitor the LB tier** (blackbox/node-exporter) — these only surface via user complaints because the edge is a blind spot.
