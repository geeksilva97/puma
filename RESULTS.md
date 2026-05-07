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

### Four configurations

All four serve `poc_realistic_app.ru` on `127.0.0.1:9292` with no SSL.

| label | command | shape |
|-------|---------|-------|
| **A. RactorPool** | `bundle exec puma -C poc_ractor_pool_config.rb poc_realistic_app.ru` | 1 process, 14 Ractors |
| **B. Cluster (parity)** | `bundle exec puma -w 14 -t 5:5 poc_realistic_app.ru` | 14 forked workers × 5 threads |
| **C. Single threaded** | `bundle exec puma -t 14:14 poc_realistic_app.ru` | 1 process, 14 threads |
| **D. Cluster (Speedshop)** | `bundle exec puma -w 8 -t 5:5 poc_realistic_app.ru` | 8 forked workers × 5 threads |

Three questions, three comparisons:

- **A vs C** — same process model, only the concurrency primitive
  differs. Isolates "Ractors vs threads" as such.
- **A vs B** — RactorPool's unit count matched against an equivalently
  parallel cluster (14 vs 14). Useful for "what's the ceiling
  cluster gives me at the same parallelism budget?" but **not how
  anyone actually deploys Puma**.
- **A vs D** — the production-shaped comparison. Speedshop's
  recommendation is 5 threads/worker and 3–8 workers per host
  (Berkopec, [*Configuring Puma, Unicorn, and Passenger for Maximum
  Efficiency*](https://www.speedshop.co/blog/appserver/)). 8 workers
  × 5 threads is the upper bound of that recommendation.

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
| **A. RactorPool**         | **6,561** |  7 | 17 |  52 |  39 MiB |  48 MiB |  7.5 |
| **B. Cluster (14×5)**     | **7,514** |  6 | 10 |  38 | 260 MiB | 672 MiB | 91.6 |
| **C. Single threaded**    | **1,267** | 39 | 43 |  53 |  35 MiB |  54 MiB | 43.6 |
| **D. Cluster (8×5, Speedshop)** | **5,310** |  9 | 13 |  46 | 163 MiB | 392 MiB | 75.6 |

Failed requests: 0 across all 12 runs. Per-run numbers are in
`bench_out/{ractor_pool,cluster,cluster_nate,single_threaded}.run{1,2,3}.summary.txt`.

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

The same A-vs-C comparison on an explicitly I/O-bound workload
(`poc_io_bound_app.ru`, 20 ms `sleep` per request — see Q3 for the
full table):

| variant | I/O-bound RPS | realistic RPS |
|---------|--------------:|--------------:|
| A. RactorPool      |   642 |  6,561 |
| C. Single threaded |   581 |  1,267 |
| ratio (A / C)      | 1.10× |  5.2×  |

`sleep` releases the GVL, so threads-in-one-process parallelize at
the OS scheduler level just like Ractors do. The gap collapses from
5.2× to 1.10×. **The Ractor win is the GVL win**; on workloads
where the GVL is not the bottleneck, there is no Ractor win to be
had.

### Q2 — RactorPool vs a Speedshop-tuned cluster

This is the comparison that matters for deployments. Berkopec's
recommendation for Puma is **5 threads per worker** (Amdahl's-law
argument: web apps only parallelize I/O, ~10–25% of execution time)
and **3–8 workers per host**, sized by RAM headroom rather than core
count. We benchmark variant D at the upper bound: 8 workers × 5
threads.

```
A (RactorPool, 1 proc × 14 Ractors)    6,561 RPS,  48 MiB peak
D (Cluster,    8 procs × 5 threads)    5,310 RPS, 392 MiB peak
                                       ────────────────────────
A delivers 1.24× D's RPS at ~1/8 the RSS.
```

Per-RPS memory cost on a slide:
**7.5 KiB/RPS for RactorPool vs 75.6 KiB/RPS for the Speedshop
cluster** — RactorPool serves at ~1/10 the memory-per-throughput of
the production-shaped baseline. On a 512 MiB container with the
realistic app:

- Cluster (8×5, Speedshop): 392 MiB — fits, but ~76% of the budget.
- Cluster (14×5, max parallelism): 672 MiB — **does not fit**.
- RactorPool: 48 MiB — fits 10× over.

A vs B (the parallelism-parity cluster): cluster reaches 7,514 RPS
at 14 workers, which is ~15% above RactorPool's 6,561 — but at
**672 MiB, well past Speedshop's RAM budget for typical app
servers**. That comparison is useful as a ceiling, not as a
deployable shape.

p99 favours both clusters over RactorPool (10–13 ms vs 17 ms), and
p99.9 favours them too (38–46 ms vs 52 ms). RactorPool's tail is
wider, almost certainly because of the missing Reactor — every
Ractor stalls on its own read instead of having a shared event
loop drain headers.

### Q3 — What about I/O-bound workloads?

Different workload, different story. `poc_io_bound_app.ru` does
`sleep(20ms)` per request — a model for "Postgres query" or
"internal HTTP API call." `sleep` releases the GVL, so OS threads
parallelize at the scheduler level. This is the workload class
the GVL doesn't bottleneck.

| variant | RPS | p50 (ms) | p99 (ms) | mid-load RSS |
|---------|----:|---------:|---------:|-------------:|
| **A. RactorPool**               |   642 | 85 | 108 |  41 MiB |
| **B. Cluster (14×5)**           | 1,911 | 25 |  45 | 452 MiB |
| **C. Single threaded (14×)**    |   581 | 86 | 100 |  41 MiB |
| **D. Cluster (8×5, Speedshop)** | 1,679 | 28 |  49 | 276 MiB |

Median of 3 runs each, 30k requests at 50 concurrency, 20 ms `sleep`.
Per-run details in `bench_out/io_*.run{1,2,3}.summary.txt`.

**The GVL falsifier (A vs C):** 642 vs 581 RPS = **1.10×.** On the
realistic CPU-bound bench, the same comparison is **5.2×.** The
collapse is the evidence: when the GVL is released during the I/O
wait, ractor_pool and threads-in-one-process are equivalent. **The
Ractor win is specifically the GVL win**, not a generic
"Ractors are faster" effect.

**The cluster surprise (A vs D):** D delivers **2.6× RactorPool's
RPS** on this workload (1,679 vs 642). The reason is concurrency-
per-worker: cluster has 8 procs × **5 threads each** = 40 concurrent
execution units; RactorPool has 14 (one socket per Ractor,
sequential within each Ractor). On I/O-bound work where 5 threads
in a worker can all sleep concurrently, threads-per-worker is a
force multiplier RactorPool doesn't get — and can't, without
nesting an OS thread pool inside each Ractor (which would re-open
all the Ractor-isolation problems we worked around to begin with).

The honest framing for the talk:

- **CPU-bound (the realistic bench):** Ractors win on RPS (1.24× D)
  and dominate on RSS (1/8 D). The GVL is the bottleneck; removing
  it pays.
- **I/O-bound (this bench):** cluster wins on RPS (2.6× A) at the
  cost of RSS (~7× A). The GVL is not the bottleneck;
  threads-per-worker is the lever.

A real Rails app sits between these: rendering and serialization
are CPU-bound, the database round-trip is I/O-bound. Neither
single-axis optimization wins outright. **What changes the
calculation is the workload mix, not the primitive.**

#### Note on pairing — the cluster surprise inverts at matched concurrency

The A vs D / A vs B comparisons above hold the *primitive* axis fair
(same workload, same machine, default flags) but pin RactorPool's
unit count to `nprocessors` (14) while letting cluster carry
`workers × threads` units (40 or 70). On I/O-bound work — where
units mostly sleep — that's effectively comparing a 14-lane road to
a 40- or 70-lane road and concluding the wider road moves more cars.

If we re-run RactorPool with the unit count *paired to cluster's*:

| pairing | concurrent units | RPS | p50 | mid-load RSS |
|---------|----------------:|----:|----:|-------------:|
| RactorPool, 70 Ractors  | 70 | **1,931** | 25 ms |  **49 MiB** |
| B. Cluster (14×5)       | 70 | 1,911     | 25 ms |    452 MiB  |
| RactorPool, 40 Ractors  | 40 | **1,767** | 26 ms |  **44 MiB** |
| D. Cluster (8×5)        | 40 | 1,679     | 28 ms |    276 MiB  |

Median of 3 runs each, same 20 ms `sleep`. Per-run details in
`bench_out/io_ractor_pool.run{40,70}_{1,2,3}.summary.txt`.

At matched concurrency, **RactorPool ties B on RPS (101%) and beats
D by 5%**, while still costing **6–9× less RSS** in both pairings.
The "cluster wins on I/O-bound" finding is real *only* under the
core-count pinning; once you size RactorPool for the workload's
concurrency budget the way Speedshop sizes cluster threads, the
RPS gap closes and the RSS gap stays.

Per-Ractor overhead is tiny on this app: going 14 → 70 Ractors adds
~12 MiB total (≈170 KiB/Ractor), nowhere near the per-fork cost of
adding cluster workers. So the natural deployment knob shifts from
"how many forks?" (RAM-bounded) to "how many Ractors?" (much cheaper
per unit, plausibly N_ractors > N_cores for I/O-heavy apps — the
same logic as Speedshop's 5-threads-per-worker rule, applied one
layer down).

This doesn't invalidate Q3's GVL-falsifier finding (A vs C at the
same 14 units = 1.10×, equivalence holds). It does sharpen the
deployment story: **RactorPool beats cluster on RPS-per-RSS on
both workload classes, when sized for the workload.**

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
  Ractor is currently not viable: instantiating `Rails::Application`
  in a non-main Ractor immediately raises
  `Ractor::IsolationError` on `Rails::Railtie::ABSTRACT_RAILTIES`
  ([rails/rails#51543](https://github.com/rails/rails/issues/51543),
  closed). Same problem class as the `Rack::BUILDER_TOPLEVEL_BINDING`
  wall this experiment had to work around — Rails just hits it one
  framework layer up, and on a constant the experiment author
  doesn't control.

The takeaway for the talk: **the RPS gap (A vs C) is real; the RSS
gap (A vs B) is real; the production-readiness gap is also real**.
You don't get the first two without paying for the third.

### Repro

```sh
# Realistic (CPU-bound) bench: 3 runs per variant, ~1 minute each.
for v in ractor_pool cluster cluster_nate single_threaded; do
  for i in 1 2 3; do
    ./poc_bench_realistic.sh $v $i
  done
done

# I/O-bound bench: 3 runs per variant (tunable via IO_WAIT_MS env).
for v in ractor_pool cluster cluster_nate single_threaded; do
  for i in 1 2 3; do
    ./poc_bench_io_bound.sh $v $i
  done
done

# I/O-bound matched-concurrency: 3 runs each at 40 and 70 Ractors.
for n in 40 70; do
  for i in 1 2 3; do
    RACTORS=$n ./poc_bench_io_bound.sh ractor_pool "${n}_${i}"
  done
done
```

Files:
- `poc_realistic_app.ru` — CPU-bound workload (JSON+SHA+gsub).
- `poc_io_bound_app.ru` — I/O-bound workload (sleep-based downstream model).
- `poc_bench_realistic.sh` — driver for the realistic four-way bench.
- `poc_bench_io_bound.sh` — driver for the I/O-bound four-way bench.
- `poc_verify.rb` — response-shape verifier called by the realistic bench.
- `bench_out/*.summary.txt` — raw per-run numbers (gitignored).
