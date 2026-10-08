#!/usr/bin/env bash
# Benchmark the Lean and Go kv.KV servers with ghz, the same way: a fresh SQLite file, 10,000 keys preloaded with
# 64-byte values, then reads (Get of a random existing key) and writes (Put of a random key) at several
# concurrencies. Each run gets a 2-second warm-up that is thrown away, then 10 seconds measured; every scenario runs
# REPS times (default 3) on every server, interleaved, and the table shows the median and the range.
#
#   bench/run.sh            writes bench/results.json and prints a table
#
# Servers: run/kv-lean-server-sqlite-O0 (SQLite as leansqlite builds it, with no -O flag),
#          run/kv-lean-server-sqlite-O2 (the same, SQLite at -O2), go-baseline/kv-go-server (SQLite at -O2 via cgo).
set -euo pipefail
cd "$(dirname "$0")/.."
PROTO=proto/kv.proto
DUR=${DUR:-10s}
WARM=${WARM:-2s}
VALUE=$(python3 -c 'import base64; print(base64.b64encode(bytes(range(64))).decode())')
OUT=bench/results.json
echo '[' > "$OUT.tmp"
first=1

servers=(
  "lean (SQLite as shipped, -O0)|run/kv-lean-server-sqlite-O0 --addr 127.0.0.1:50061 --db run/bench-lean-O0.sqlite|127.0.0.1:50061|run/bench-lean-O0.sqlite"
  "lean (SQLite -O2)|run/kv-lean-server-sqlite-O2 --addr 127.0.0.1:50062 --db run/bench-lean-O2.sqlite|127.0.0.1:50062|run/bench-lean-O2.sqlite"
  "go (grpc-go, SQLite -O2)|go-baseline/kv-go-server -addr 127.0.0.1:50063 -db run/bench-go.sqlite|127.0.0.1:50063|run/bench-go.sqlite"
)

# name|call|data|concurrency|connections
scenarios=(
  "Get c=1|kv.KV.Get|{\"key\":\"key-{{randomInt 0 10000}}\"}|1|1"
  "Get c=64, 1 conn|kv.KV.Get|{\"key\":\"key-{{randomInt 0 10000}}\"}|64|1"
  "Get c=64, 8 conns|kv.KV.Get|{\"key\":\"key-{{randomInt 0 10000}}\"}|64|8"
  "Put c=1|kv.KV.Put|{\"key\":\"key-{{randomInt 0 10000}}\",\"value\":\"$VALUE\"}|1|1"
  "Put c=64, 8 conns|kv.KV.Put|{\"key\":\"key-{{randomInt 0 10000}}\",\"value\":\"$VALUE\"}|64|8"
)

REPS=${REPS:-3}
pids=()
for s in "${servers[@]}"; do
  IFS='|' read -r name cmd addr db <<< "$s"
  rm -f "$db" "$db-wal" "$db-shm"
  $cmd > /dev/null 2>&1 &
  pids+=($!)
done
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
sleep 1.5
for s in "${servers[@]}"; do
  IFS='|' read -r name cmd addr db <<< "$s"
  ghz --insecure --proto "$PROTO" --call kv.KV.Put -d "{\"key\":\"key-{{.RequestNumber}}\",\"value\":\"$VALUE\"}" \
    -n 10000 -c 16 "$addr" > /dev/null
done

# Interleaved: every scenario is measured REPS times on every server, and each round starts with a different server,
# so load from anything else on the machine falls on all of them alike.
for rep in $(seq 1 "$REPS"); do
  for sc in "${scenarios[@]}"; do
    IFS='|' read -r sname call data conc conns <<< "$sc"
    n=${#servers[@]}
    for k in $(seq 0 $((n - 1))); do
      s=${servers[$(( (k + rep) % n ))]}
      IFS='|' read -r name cmd addr db <<< "$s"
      ghz --insecure --proto "$PROTO" --call "$call" -d "$data" -z "$WARM" -c "$conc" --connections "$conns" "$addr" > /dev/null
      json=$(ghz --insecure --proto "$PROTO" --call "$call" -d "$data" -z "$DUR" -c "$conc" --connections "$conns" --format json "$addr")
      line=$(python3 - "$name" "$sname" "$rep" <<PY
import json, sys
d = json.loads('''$json''')
lat = {p["percentage"]: p["latency"] / 1e6 for p in d.get("latencyDistribution") or []}
errs = sum(v for k, v in (d.get("statusCodeDistribution") or {}).items() if k != "OK")
print(json.dumps({"server": sys.argv[1], "scenario": sys.argv[2], "rep": int(sys.argv[3]), "rps": round(d["rps"]),
                  "count": d["count"], "avgMs": round(d["average"] / 1e6, 3), "p50Ms": round(lat.get(50, 0), 3),
                  "p99Ms": round(lat.get(99, 0), 3), "errors": errs}))
PY
)
      echo "   $line"
      if [ $first -eq 1 ]; then first=0; else echo ',' >> "$OUT.tmp"; fi
      echo "$line" >> "$OUT.tmp"
    done
  done
done
echo ']' >> "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
python3 - "$OUT" <<'PY'
import json, sys, statistics
rows = json.load(open(sys.argv[1]))
scen = list(dict.fromkeys(r["scenario"] for r in rows))
servers = list(dict.fromkeys(r["server"] for r in rows))
print()
print("Median of the runs (range in brackets), requests per second; p99 latency is the median run's.")
print()
print("| Scenario | " + " | ".join(servers) + " |")
print("|---|" + "---:|" * len(servers))
for sc in scen:
    cells = []
    for sv in servers:
        rs = sorted((x for x in rows if x["scenario"] == sc and x["server"] == sv), key=lambda x: x["rps"])
        med = rs[len(rs) // 2]
        cells.append(f'{med["rps"]:,} [{rs[0]["rps"]:,}–{rs[-1]["rps"]:,}], p99 {med["p99Ms"]} ms')
    print(f"| {sc} | " + " | ".join(cells) + " |")
PY
