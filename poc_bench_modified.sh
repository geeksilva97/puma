#!/usr/bin/env bash
# Bench harness for the modified-Puma-with-RactorPool variant.
# Usage: ./poc_bench_modified.sh ractor_pool|baseline N

set -u
variant="${1:?variant: ractor_pool|baseline}"
n="${2:-14}"
port=9292
n_requests=20000
concurrency=50
url="http://127.0.0.1:${port}/"
out_dir="/Users/edy/projects/devrel/ruby-conf-2026/experiment/puma/bench_out"
mkdir -p "$out_dir"

cd /Users/edy/projects/devrel/ruby-conf-2026/experiment/puma

sum_rss() {
  local root=$1
  local total=0
  local pids
  pids=$(pgrep -P "$root" 2>/dev/null || true)
  local rss
  rss=$(ps -o rss= -p "$root" 2>/dev/null | awk '{print $1}')
  [ -n "${rss:-}" ] && total=$((total + rss))
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
    PUMA_RACTOR_POOL=1 PUMA_RACTOR_RACKUP="$(pwd)/poc_baseline_app.ru" \
      RACTORS=$n PORT=$port \
      bundle exec puma -C poc_ractor_pool_config.rb poc_baseline_app.ru \
      > "$out_dir/${variant}.server.log" 2>&1 &
    pid=$!
    ;;
  baseline)
    WORKERS=$n PORT=$port bundle exec puma -C poc_baseline_config.rb poc_baseline_app.ru > "$out_dir/${variant}.server.log" 2>&1 &
    pid=$!
    ;;
  *)
    echo "unknown variant: $variant" >&2; exit 1
    ;;
esac

for i in $(seq 1 50); do
  if curl -s -o /dev/null -m 1 "$url"; then break; fi
  sleep 0.2
done

sleep 1
idle_rss=$(sum_rss "$pid")
echo "[$variant] pid=$pid idle_rss_kib=$idle_rss"

(
  sleep 2
  sum_rss "$pid" > "$out_dir/${variant}.loaded_rss.txt"
) &
sampler_pid=$!

/usr/sbin/ab -n "$n_requests" -c "$concurrency" "$url" > "$out_dir/${variant}.ab.txt" 2>&1
ab_status=$?

wait "$sampler_pid" 2>/dev/null || true
loaded_rss=$(cat "$out_dir/${variant}.loaded_rss.txt" 2>/dev/null || echo 0)
echo "[$variant] loaded_rss_kib=$loaded_rss ab_status=$ab_status"

kill -INT "$pid" 2>/dev/null || true
sleep 2
pkill -P "$pid" 2>/dev/null || true
kill -9 "$pid" 2>/dev/null || true

rps=$(grep "Requests per second" "$out_dir/${variant}.ab.txt" | awk '{print $4}')
mean=$(grep "Time per request" "$out_dir/${variant}.ab.txt" | head -n1 | awk '{print $4}')
p99=$(awk '/Percentage of the requests served/{flag=1; next} flag && $1 == "99%"{print $2}' "$out_dir/${variant}.ab.txt")
failed=$(grep "Failed requests" "$out_dir/${variant}.ab.txt" | awk '{print $3}')

cat <<EOF > "$out_dir/${variant}.summary.txt"
variant=$variant
workers_or_ractors=$n
requests=$n_requests
concurrency=$concurrency
rps=$rps
mean_latency_ms=$mean
p99_latency_ms=$p99
failed_requests=$failed
idle_rss_kib=$idle_rss
loaded_rss_kib=$loaded_rss
EOF

cat "$out_dir/${variant}.summary.txt"
