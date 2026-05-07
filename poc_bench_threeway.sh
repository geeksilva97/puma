#!/usr/bin/env bash
# Bench harness: ractor_pool | cluster | cluster_nate | single_threaded
#
# Usage: ./poc_bench_threeway.sh <variant> [run_idx]
#   variant: ractor_pool | cluster | cluster_nate | single_threaded
#   run_idx: optional integer, used to suffix output files (default 1)
#
#   cluster       — 14 workers x 5 threads (parity with RactorPool's unit count)
#   cluster_nate  — 8 workers x 5 threads (Speedshop "3-8 procs, 5 threads" rec)
#
# All variants serve poc_realistic_app.ru on 127.0.0.1:9292.

set -u
variant="${1:?variant: ractor_pool|cluster|cluster_nate|single_threaded}"
run_idx="${2:-1}"
port=9292
n_warmup=2000
n_requests=30000
concurrency=50
url="http://127.0.0.1:${port}/"
out_dir="/Users/edy/projects/devrel/ruby-conf-2026/experiment/puma/bench_out"
mkdir -p "$out_dir"
tag="${variant}.run${run_idx}"

cd /Users/edy/projects/devrel/ruby-conf-2026/experiment/puma

# Kill anything still listening on the port from a prior aborted run.
lsof -ti tcp:${port} 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 0.5

# Recursively sum RSS (KiB) of pid + descendants.
sum_rss() {
  local root=$1
  local total=0
  local rss
  rss=$(ps -o rss= -p "$root" 2>/dev/null | awk '{print $1}')
  [ -n "${rss:-}" ] && total=$((total + rss))
  local pids
  pids=$(pgrep -P "$root" 2>/dev/null || true)
  for p in $pids; do
    rss=$(ps -o rss= -p "$p" 2>/dev/null | awk '{print $1}')
    [ -n "${rss:-}" ] && total=$((total + rss))
    for gp in $(pgrep -P "$p" 2>/dev/null || true); do
      rss=$(ps -o rss= -p "$gp" 2>/dev/null | awk '{print $1}')
      [ -n "${rss:-}" ] && total=$((total + rss))
    done
  done
  echo "$total"
}

case "$variant" in
  ractor_pool)
    PUMA_RACTOR_POOL=1 PUMA_RACTOR_RACKUP="$(pwd)/poc_realistic_app.ru" \
      RACTORS=14 PORT=$port \
      bundle exec puma -C poc_ractor_pool_config.rb poc_realistic_app.ru \
      > "$out_dir/${tag}.server.log" 2>&1 &
    pid=$!
    ;;
  cluster)
    bundle exec puma -w 14 -t 5:5 -b "tcp://127.0.0.1:${port}" --quiet \
      poc_realistic_app.ru \
      > "$out_dir/${tag}.server.log" 2>&1 &
    pid=$!
    ;;
  cluster_nate)
    bundle exec puma -w 8 -t 5:5 -b "tcp://127.0.0.1:${port}" --quiet \
      poc_realistic_app.ru \
      > "$out_dir/${tag}.server.log" 2>&1 &
    pid=$!
    ;;
  single_threaded)
    bundle exec puma -t 14:14 -b "tcp://127.0.0.1:${port}" --quiet \
      poc_realistic_app.ru \
      > "$out_dir/${tag}.server.log" 2>&1 &
    pid=$!
    ;;
  *)
    echo "unknown variant: $variant" >&2; exit 1
    ;;
esac

# Wait until the server actually accepts connections.
for i in $(seq 1 100); do
  if curl -s -o /dev/null -m 1 "$url"; then booted=1; break; fi
  sleep 0.2
done
if [ -z "${booted:-}" ]; then
  echo "[$variant] ERROR: server never came up. log:" >&2
  tail -40 "$out_dir/${tag}.server.log" >&2
  kill -9 "$pid" 2>/dev/null || true
  exit 2
fi

sleep 1
idle_rss=$(sum_rss "$pid")
echo "[$tag] pid=$pid idle_rss_kib=$idle_rss"

# Verify the response actually matches the app's schema. Cheap insurance
# against a broken server (truncated body, wrong content-type, cached
# response) producing impressive-looking but meaningless RPS numbers.
if ! ruby poc_verify.rb "$url" > "$out_dir/${tag}.verify.txt" 2>&1; then
  echo "[$tag] ERROR: response verification failed:" >&2
  cat "$out_dir/${tag}.verify.txt" >&2
  kill -INT "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true
  lsof -ti tcp:${port} 2>/dev/null | xargs kill -9 2>/dev/null || true
  exit 4
fi
echo "[$tag] verify: $(cat "$out_dir/${tag}.verify.txt")"

# Mid-load sampler: record RSS halfway through the main run.
(
  sleep 4
  sum_rss "$pid" > "$out_dir/${tag}.midload_rss.txt"
) &
sampler_pid=$!

# Warmup (discarded).
/usr/sbin/ab -n "$n_warmup" -c "$concurrency" "$url" > "$out_dir/${tag}.warmup.txt" 2>&1 || true

# Main run.
/usr/sbin/ab -e "$out_dir/${tag}.percentiles.csv" -n "$n_requests" -c "$concurrency" "$url" \
  > "$out_dir/${tag}.ab.txt" 2>&1
ab_status=$?

wait "$sampler_pid" 2>/dev/null || true
midload_rss=$(cat "$out_dir/${tag}.midload_rss.txt" 2>/dev/null || echo 0)

postload_rss=$(sum_rss "$pid")
echo "[$tag] midload_rss_kib=$midload_rss postload_rss_kib=$postload_rss ab_status=$ab_status"

# Tear down cleanly.
kill -INT "$pid" 2>/dev/null || true
sleep 2
pkill -P "$pid" 2>/dev/null || true
kill -9 "$pid" 2>/dev/null || true
lsof -ti tcp:${port} 2>/dev/null | xargs kill -9 2>/dev/null || true

# Extract metrics.
rps=$(grep "Requests per second" "$out_dir/${tag}.ab.txt" | awk '{print $4}')
mean=$(grep "Time per request" "$out_dir/${tag}.ab.txt" | head -n1 | awk '{print $4}')
p50=$(awk '/Percentage of the requests served/{flag=1; next} flag && $1 == "50%"{print $2}' "$out_dir/${tag}.ab.txt")
p99=$(awk '/Percentage of the requests served/{flag=1; next} flag && $1 == "99%"{print $2}' "$out_dir/${tag}.ab.txt")
# p99.9 isn't printed by ab; derive from CSV (column 2 is ms, column 1 is percentile 0..100).
p999=$(awk -F, 'NR>1 && $1+0 >= 99.9 {print $2; exit}' "$out_dir/${tag}.percentiles.csv" 2>/dev/null)
failed=$(grep "Failed requests" "$out_dir/${tag}.ab.txt" | awk '{print $3}')

cat <<EOF > "$out_dir/${tag}.summary.txt"
variant=$variant
run_idx=$run_idx
requests=$n_requests
concurrency=$concurrency
rps=$rps
mean_latency_ms=$mean
p50_latency_ms=$p50
p99_latency_ms=$p99
p999_latency_ms=$p999
failed_requests=$failed
idle_rss_kib=$idle_rss
midload_rss_kib=$midload_rss
postload_rss_kib=$postload_rss
EOF

cat "$out_dir/${tag}.summary.txt"
