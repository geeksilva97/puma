# Modified Puma — RactorPool replaces ThreadPool

Source-level modification of Puma 8.0.1. Ruby 4.0.2 +PRISM, macOS arm64
(M-series, 14 logical cores). Single-host bench, loopback HTTP, no TLS.
Bench tool: Apache `ab` from `/usr/sbin/ab`, no keep-alive (`-k` is
omitted in every run because the RactorPool variant has no keep-alive
support — see caveats).

## Realistic workload — three-way comparison

The first round of numbers (further down this file) compared the
RactorPool variant against cluster Puma using a trivial echo-`"hello"`
app. That comparison was confounded twice over: the workload was
kernel-bound (so the GVL barely mattered for threads), and the only
non-Ractor variant tested was cluster, which uses fork-based
parallelism. The numbers below fix both problems.

### Workload

`poc_realistic_app.ru` — what a typical Rails JSON action looks like,
without needing Rails. Per request:

- Build a "user with 40 orders" hash (~100 keys total, nested arrays,
  mix of strings/ints).
- `JSON.generate` the hash (~7 KiB body).
- `Digest::SHA256` the JSON, then re-hash 6 times (request-id +
  signing-style work).
- `downcase`/`gsub` a paragraph of lorem ipsum 120 times (the
  per-request CPU dial).

Single-threaded cost: **~0.7 ms of pure-Ruby CPU per request** on this
hardware. That's deliberately high enough that the GVL is the
contended resource, not the network or the kernel.

The app uses only stdlib (`json`, `digest`, `securerandom`) and closes
over a single frozen constant — fully Ractor-safe with no source
modifications needed.

### Three configurations

All three serve `poc_realistic_app.ru` on `127.0.0.1:9292` with no SSL.

| label | command | shape |
|-------|---------|-------|
| **A. RactorPool** | `bundle exec puma -C poc_ractor_pool_config.rb poc_realistic_app.ru` | 1 process, 14 Ractors |
| **B. Cluster** | `bundle exec puma -w 14 -t 5:5 poc_realistic_app.ru` | 14 forked workers × 5 threads |
| **C. Single threaded** | `bundle exec puma -t 14:14 poc_realistic_app.ru` | 1 process, 14 threads |

A vs C is the apples-to-apples question (same process model, only
the concurrency primitive differs). A vs B is the
RactorPool-vs-production-default question.

### Methodology

For each variant:

1. Boot, wait for first 200, sleep 1s.
2. Snapshot **idle RSS** (sum across master + all workers/children).
3. Warmup: `ab -n 2000 -c 50` (discard).
4. Main: `ab -n 30000 -c 50 -e percentiles.csv`.
5. Sample **mid-load RSS** 4s into the main run (background sampler).
6. Snapshot **post-load RSS** after the main run completes.
7. Tear down. Repeat 3×. Median of three reported below.

### Results (median of 3 runs)

| variant | RPS | p50 (ms) | p99 (ms) | p99.9 (ms) | idle RSS | mid-load RSS | KiB / RPS |
|---------|----:|---------:|---------:|-----------:|---------:|-------------:|----------:|
| **A. RactorPool**       | **6,561** |  7 | 17 |  52 |  39 MiB |  48 MiB |  7.5 |
| **B. Cluster (14×5)**   | **7,514** |  6 | 10 |  38 | 266 MiB | 688 MiB | 93.7 |
| **C. Single threaded**  | **1,267** | 39 | 43 |  53 |  35 MiB |  54 MiB | 43.6 |

Failed requests: 0 across all 9 runs. Per-run numbers are in
`bench_out/{ractor_pool,cluster,single_threaded}.run{1,2,3}.summary.txt`.

### Q1 — Is Ractor parallelism actually faster than thread parallelism on a CPU-bound workload?

**Yes, by 5.2×.** Same process model (single Puma process, 14
concurrent units), same Rack app, same machine. The only thing that
changes between A and C is whether the 14 concurrent units are MRI
threads or Ractors:

```
A (RactorPool, 14 Ractors)        6,561 RPS
C (single-mode, 14 OS threads)    1,267 RPS
                                  ─────────
                                  ~5.2× faster
```

This is the headline. Ractors really do release Ruby code from the
GVL, and on a workload that spends most of its time in Ruby
(`JSON.generate`, gsub, SHA256), 14 Ractors put 14 cores to work where
14 threads put roughly 1 core to work serially-rotated. p50 latency
under load drops from 39 ms (threads queuing on the GVL) to 7 ms
(Ractors running in parallel).

The same comparison on the IO-bound echo app (single-run sanity
check, `bench_out/echo_*.run1.summary.txt`):

| variant | echo RPS | realistic RPS |
|---------|---------:|--------------:|
| A. RactorPool      | 37,730 |  6,561 |
| C. Single threaded | 22,618 |  1,267 |
| ratio (A / C)      |  1.7×  |  5.2×  |

When the work is IO-bound, threads are *fine* — the GVL gets released
during the kernel write and threads parallelize at the OS level. The
gap collapses from 5.2× to 1.7×. **The Ractor win is the GVL win**;
on workloads where the GVL is not the bottleneck, there is no Ractor
win to be had.

### Q2 — RactorPool vs production default (cluster)

```
A (RactorPool, 1 proc × 14 Ractors)        6,561 RPS,  48 MiB peak
B (Cluster,    14 procs × 5 threads)       7,514 RPS, 688 MiB peak
                                           ────────────────────────
A reaches 87% of B's RPS at 1/14th the RSS.
```

Per-RPS memory cost is the cleanest number to put on a slide:
**7.5 KiB/RPS for RactorPool vs 93.7 KiB/RPS for cluster** —
RactorPool serves at ~1/12 the memory-per-throughput of the
production default. On a 512 MiB container with the realistic app:

- Cluster (14×5): 688 MiB — **does not fit**.
- Cluster trimmed to 7×5 to fit: ~half the RPS.
- RactorPool: 48 MiB — fits 10× over.

That's the case for Ractors as a deployment shape: comparable
throughput to a forking webserver at memory budgets that current
forking deployments cannot reach.

p99 favours cluster (10 ms vs 17 ms), and p99.9 favours cluster
(38 ms vs 52 ms). RactorPool's tail is wider, almost certainly
because of the lack of a Reactor — every Ractor stalls on its own
read instead of having a shared event loop drain headers.

### Honest caveats

The RactorPool variant is feature-stripped relative to what a real
Puma user runs. Its RPS would drop, and probably its RSS would
rise, if these were implemented:

- **No Reactor / no slow-client buffering.** Adds latency and CPU
  proportional to header complexity for real internet traffic. On
  loopback with `ab` this is invisible. Cost estimate: 5–15% of RPS.
- **No keep-alive.** Every connection is a fresh TCP handshake +
  TLS handshake (if TLS were on). On benches with `-k` this is a
  2–3× hit; we removed `-k` from every variant for parity, so the
  number above is not penalising RactorPool here. But "no keep-alive"
  is not a deploy-shippable property.
- **No SSL, no hijack, no early hints, no chunked encoding.** Each
  is a few dozen lines of Puma's response writer that the Ractor
  bypasses. Reproducing them inside a Ractor is mechanical; the
  shareable-constants problem is the real cost (see RESULTS section
  on Rack/Rails incompat below).
- **No `Rack::Builder`.** The Ractor hand-rolls a `run`/`use`/`map`
  parser. Anything more complex than `run <app>` in a `.ru` file
  silently does the wrong thing. This is a PoC-only shortcut.
- **The Rack-app constraint is the real wall.** The realistic app
  works because it only touches stdlib. A real Rails boot inside a
  Ractor is currently not viable — see "The Rack-app problem"
  section below.

The takeaway for the talk: **the RPS gap (A vs C) is real; the RSS
gap (A vs B) is real; the production-readiness gap is also real**.
You don't get the first two without paying for the third.

### Repro

```sh
# Three runs each, ~1 minute per run.
for v in ractor_pool cluster single_threaded; do
  for i in 1 2 3; do
    ./poc_bench_threeway.sh $v $i
  done
done
# Optional: echo-workload run (single iteration)
for v in ractor_pool cluster single_threaded; do
  ./poc_bench_threeway_echo.sh $v 1
done
```

Files:
- `poc_realistic_app.ru` — the JSON+SHA+gsub workload.
- `poc_bench_threeway.sh` — driver for the realistic three-way bench.
- `poc_bench_threeway_echo.sh` — IO-bound counterpart.
- `bench_out/*.summary.txt` — raw per-run numbers.
