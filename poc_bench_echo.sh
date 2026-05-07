#!/usr/bin/env bash
# Same as poc_bench_realistic.sh but serves an echo "hello" Rack app.
# Used to characterise the IO-bound end of the spectrum.
#
# NOTE: this script currently references poc_baseline_app.ru, which was
# removed in the round-1 cleanup. Either restore that file or point this
# at a small inline echo app before running.

set -u
variant="${1:?variant: ractor_pool|cluster|single_threaded}"
run_idx="${2:-1}"
port=9292
n_warmup=2000
n_requests=30000
concurrency=50
url="http://127.0.0.1:${port}/"
out_dir="/Users/edy/projects/devrel/ruby-conf-2026/experiment/puma/bench_out"
mkdir -p "$out_dir"
tag="echo_${variant}.run${run_idx}"

cd /Users/edy/projects/devrel/ruby-conf-2026/experiment/puma

lsof -ti tcp:${port} 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 0.5

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
    PUMA_RACTOR_POOL=1 PUMA_RACTOR_RACKUP="$(pwd)/poc_baseline_app.ru" \
      RACTORS=14 PORT=$port \
      bundle exec puma -C poc_ractor_pool_config.rb poc_baseline_app.ru \
      > "$out_dir/${tag}.server.log" 2>&1 &
    pid=$!
    ;;
  cluster)
    bundle exec puma -w 14 -t 5:5 -b "tcp://127.0.0.1:${port}" --quiet \
      poc_baseline_app.ru \
      > "$out_dir/${tag}.server.log" 2>&1 &
    pid=$!
    ;;
  single_threaded)
    bundle exec puma -t 14:14 -b "tcp://127.0.0.1:${port}" --quiet \
      poc_baseline_app.ru \
      > "$out_dir/${tag}.server.log" 2>&1 &
    pid=$!
    ;;
  *)
    echo "unknown variant: $variant" >&2; exit 1
    ;;
esac

for i in $(seq 1 100); do
  if curl -s -o /dev/null -m 1 "$url"; then booted=1; break; fi
  sleep 0.2
done
if [ -z "${booted:-}" ]; then
  echo "[$variant] ERROR: server never came up." >&2
  tail -40 "$out_dir/${tag}.server.log" >&2
  kill -9 "$pid" 2>/dev/null || true
  exit 2
fi

sleep 1
idle_rss=$(sum_rss "$pid")

(
  sleep 2
  sum_rss "$pid" > "$out_dir/${tag}.midload_rss.txt"
) &
sampler_pid=$!

/usr/sbin/ab -n "$n_warmup" -c "$concurrency" "$url" > "$out_dir/${tag}.warmup.txt" 2>&1 || true
/usr/sbin/ab -e "$out_dir/${tag}.percentiles.csv" -n "$n_requests" -c "$concurrency" "$url" \
  > "$out_dir/${tag}.ab.txt" 2>&1
ab_status=$?

wait "$sampler_pid" 2>/dev/null || true
midload_rss=$(cat "$out_dir/${tag}.midload_rss.txt" 2>/dev/null || echo 0)

kill -INT "$pid" 2>/dev/null || true
sleep 2
pkill -P "$pid" 2>/dev/null || true
kill -9 "$pid" 2>/dev/null || true
lsof -ti tcp:${port} 2>/dev/null | xargs kill -9 2>/dev/null || true

rps=$(grep "Requests per second" "$out_dir/${tag}.ab.txt" | awk '{print $4}')
mean=$(grep "Time per request" "$out_dir/${tag}.ab.txt" | head -n1 | awk '{print $4}')
p50=$(awk '/Percentage of the requests served/{flag=1; next} flag && $1 == "50%"{print $2}' "$out_dir/${tag}.ab.txt")
p99=$(awk '/Percentage of the requests served/{flag=1; next} flag && $1 == "99%"{print $2}' "$out_dir/${tag}.ab.txt")
failed=$(grep "Failed requests" "$out_dir/${tag}.ab.txt" | awk '{print $3}')

cat <<EOF > "$out_dir/${tag}.summary.txt"
variant=$variant
workload=echo
run_idx=$run_idx
rps=$rps
mean_latency_ms=$mean
p50_latency_ms=$p50
p99_latency_ms=$p99
failed_requests=$failed
idle_rss_kib=$idle_rss
midload_rss_kib=$midload_rss
EOF

cat "$out_dir/${tag}.summary.txt"
