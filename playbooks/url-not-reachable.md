# Playbook: "the cluster's URL isn't working" (ingress reachability)

Symptom: an app URL served by a cluster ingress "doesn't work" while the cluster looks fine.
Goal: decide FAST whether the fault is in the cluster/ingress or outside it (DNS / edge / client),
without dumping raw kubectl. Work outside-in. Replace `<CTX>`, `<HOST>`, `<NS>`.

> Golden rule: a **timeout/can't-connect** means packets never reached nginx (look at DNS/edge/route);
> a **403/404/502/503** means they did (look at ingress rules/backends). Split on that first.

## 0. Triage the cluster (cheap)
```bash
bash tools/scans/cluster-triage.sh <CTX>          # ALL CLEAR => cluster is likely innocent
kubectl --context <CTX> get pods -A | grep -iE 'ingress|nginx|traefik'   # controller Running?
```

## 1. Enumerate the real URLs from the ingress (don't guess them)
```bash
kubectl --context <CTX> get ingress -A -o wide       # HOSTS + CLASS + ADDRESS
```

## 2. Test each host from OUTSIDE the cluster (this is the key step)
```bash
# DNS: internal resolver vs public, must agree and point at a reachable IP
nslookup <HOST>            # what you get
nslookup <HOST> 8.8.8.8    # what the public internet gets  (differ => split-horizon DNS)
nslookup -type=AAAA <HOST> 8.8.8.8   # a bad/blackholed IPv6 record makes v6 browsers hang

# Reachability + response from your vantage
curl -sS -m 10 -D - "https://<HOST>/" | head -20     # code + headers + body start
```
Read the response:
- `200` / real app body -> URL works from here; problem is client-side or a specific path.
- `X-Powered-By: <app>` with a 404 -> backend is UP, that path just isn't a route (often fine).
- `Server: nginx` + body "default backend" 404 -> no ingress rule matched (real routing bug -> step 4).
- `502/503` -> backend down/unready -> step 3.
- **timeout** -> DNS wrong, or edge/route drop. Confirm which:
```bash
curl -s https://api.ipify.org           # your public egress IP (are you really "outside"?)
tracert -d <IP>   ||  traceroute -n <IP> # where does the path die? (private hops => you're internal)
```

## 3. If 502/503 — backend health
```bash
kubectl --context <CTX> -n <NS> get svc,endpoints        # endpoints EMPTY => no ready pods
kubectl --context <CTX> -n <NS> get pods                 # backing pods Ready?
```

## 4. If default-backend 404 / cert / restriction — inspect the ingress
```bash
kubectl --context <CTX> -n <NS> describe ingress <NAME>  # host/path rules, tls secret
# TLS actually served at the edge:
echo | openssl s_client -connect <IP>:443 -servername <HOST> 2>/dev/null | openssl x509 -noout -subject -issuer -dates
# Source restriction? (returns 403, NOT timeout)
kubectl --context <CTX> -n <NS> get ingress <NAME> -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep -iE 'whitelist|source-range|geo|auth|limit'
```

## 5. If it works from outside but not for the owner (timeout)
The fault is between the owner's client and the edge IP. Hand them a client-side probe FILE (stage
it rather than pasting loose commands in chat): DNS-they-see, TCP to :443, verbose curl, traceroute,
retry on another network.

## Gotchas
- Your DNS resolver being `10.x`/`192.168.x` does NOT mean you're on the cluster LAN — check the
  actual **route** (`tracert`) and your **egress IP** (`api.ipify.org`) before claiming "internal".
- Certs that verify (`curl` ssl_verify=0) rule out the "expired cert" theory immediately.
- Record findings per cluster under **Check-first hints** in your knowledge library.
