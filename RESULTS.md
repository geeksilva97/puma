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

---

## Original toy-workload run (echo `"hello"`)

The numbers in the rest of this file used a 38-byte fixed-body echo
app with `ab -n 20000 -c 50`. Kept for context, but see the
three-way realistic comparison above for the actual story.

This is a **real fork** of Puma's source — not a PoC TCP server "inspired by"
Puma. The HTTP listener loop, the binder, the C HTTP parser, and the Server
boot path are all upstream Puma. Only the per-connection concurrency unit
changes.

## What I actually changed in Puma

Three touch-points; everything else (binder, HTTP parser, accept loop, CLI,
Configuration DSL) is unchanged.

| File                          | Change       | Lines |
|-------------------------------|--------------|------:|
| `lib/puma/ractor_pool.rb`     | **new file** |   269 |
| `lib/puma/server.rb`          | modified     | +30 / -6 |

The `server.rb` diff in shape:

- `require_relative 'ractor_pool'` next to the `thread_pool` require.
- In `Server#run`: branch on `options[:use_ractor_pool]` /
  `ENV['PUMA_RACTOR_POOL']`. The default branch is the unmodified ThreadPool.
- In the accept loop: when the pool is a `RactorPool`, skip `new_client` and
  hand the raw socket to the pool directly. Wrapping into `Puma::Client`
  before the Ractor boundary would just throw the Client away.

`RactorPool` mirrors `ThreadPool`'s interface — `<<`, `shutdown`, `stats`,
`backlog`, `pool_capacity`, `auto_trim!`, `auto_reap!`,
`with_force_shutdown`, `wait_while_out_of_band_running`, `with_mutex` — most
as no-ops because the rest of `Server` calls them unconditionally during
boot/shutdown. Mirroring the surface keeps the patch localised.

## The C extension question

**`puma_http11` is Ractor-safe.** Evidence: `ext/puma_http11/puma_http11.c`
calls `rb_ext_ractor_safe(true)` in `Init_puma_http11` (gated by
`HAVE_RB_EXT_RACTOR_SAFE`). Each Ractor instantiates its own
`Puma::HttpParser` and uses it without contention. We exercise the parser
inside the Ractor; the bench drives it for 20,000 requests across 14 Ractors
with zero failures.

The C ext does have file-static `VALUE` globals (`global_request_method`,
etc., wired up by `DEF_GLOBAL`), but they are written exactly once during
`Init_puma_http11` (called on the main Ractor before any worker spawn) and
then only read. That's the standard Ractor-safe-ext pattern.

The C ext compiles on Ruby 4.0.2 unchanged.

## The Client / Rack-app sharing problem

Three concrete `Ractor::Error` / `Ractor::IsolationError` cases hit during
this work, all real, all reproducible:

### 1. `Puma::Client` cannot cross a Ractor boundary

```
Ractor::Error: can not copy Puma::IOBuffer object
```

`Puma::Client` carries a `Puma::IOBuffer` (a `String`-backed buffer) plus a
parsed `env` hash plus the IO. The IOBuffer is a plain Ruby object that
includes ivars Ractor's copy/move logic refuses. **Workaround:** the accept
loop hands the raw `TCPSocket` (which IS Ractor-sendable, with `move: true`)
directly to the Ractor and skips the `Client` wrap entirely. The Ractor
runs its own minimal HTTP/1.1 request handler using `Puma::HttpParser`.

### 2. The Rack app cannot cross a Ractor boundary

```
TypeError: allocator undefined for Proc
Ractor::IsolationError: Proc's self is not shareable
```

`Ractor.send(some_proc)` raises `TypeError`, and `Ractor.make_shareable` on a
top-level lambda raises `Ractor::IsolationError` because `self` (the toplevel
`main` object) is not shareable. **Workaround:** each Ractor loads the Rack
app *inside itself* from the rackup path. The path string is shareable.

### 3. `Rack::Builder.parse_file` cannot run inside a Ractor

```
Ractor::IsolationError: can not access non-shareable objects in constant
Rack::BUILDER_TOPLEVEL_BINDING by non-main ractor
```

This was the surprise. Even loading a `.ru` file is impossible inside a
non-main Ractor — Rack 3.2.6 freezes a `TOPLEVEL_BINDING` into a constant
that is not shareable. **Workaround:** the main thread reads the rackup
file's text (a frozen `String`, shareable), passes the source to each Ractor,
and each Ractor `instance_eval`s the source against a tiny stub object that
records `run`/`use`/`map`/`warmup` calls. We only honour `run`, which is
enough for the experiment.

This is the cleanest illustration of the broader Ractor-and-Rack
incompatibility: even the entry point of a Rack app can't be loaded under a
Ractor without hand-rolling a parser. Real Rails / ActiveRecord / Sidekiq
would multiply this problem by every gem with class-level mutable state.

### What the Ractor actually executes

- `Ractor.receive` — get the raw TCPSocket
- read until `Puma::HttpParser#finished?` (with a 5s timeout, an 80 KiB
  header cap, and `IO::WaitReadable` retry — basically Puma's read path
  minus the Reactor)
- build a Rack env from the C parser's keys plus `rack.input`,
  `rack.errors`, `rack.url_scheme`, `SCRIPT_NAME`
- call `app.call(env)`
- write a synchronous HTTP/1.1 response, computing `Content-Length` if
  the app didn't supply one

No keep-alive, no chunked encoding, no hijack, no early hints, no SSL.

## Numbers

`workers_or_ractors = 14` (matches `Etc.nprocessors`). RSS in MiB summed
across the entire process tree. Two runs each, second-run numbers shown
(both runs were within ~5% of each other for the modified Puma).

| variant                          |    RPS | mean (ms) | p99 (ms) | idle RSS | RSS under load |
|----------------------------------|-------:|----------:|---------:|---------:|---------------:|
| **modified Puma + RactorPool**   | 38,055 |     1.31  |       3  |   35 MiB |        46 MiB  |
| baseline Puma (cluster, 14×fork) | 29,041 |     1.72  |       4  |  244 MiB |       404 MiB  |
| previous toy Ractor server (PoC) | 33,136 |     1.51  |       3  |   16 MiB |        39 MiB  |

Failed requests: 0 in all variants. `ab` time-taken: 0.526s (modified Puma)
vs 0.689s (baseline) vs 0.604s (toy).

The "real Puma machinery overhead" of swapping ThreadPool for RactorPool —
including running the actual `Puma::HttpParser` C ext, building a Rack env,
calling a real Rack app, running through Puma's CLI/Configuration boot path,
exercising Puma's accept loop — is a positive ~5K RPS over the toy and
~10K RPS over baseline cluster Puma, with about 9× less RSS than baseline.

That's a finding, but with caveats — see below.

## Honest assessment

**Could this be upstreamed?** No. Not as it stands.

The patch shape is small (~30 lines of `server.rb`, one new file), but the
compromises inside `RactorPool` strip out features that real Puma users
depend on:

- **No Reactor, so no read-buffering against slow clients.** Puma's
  `Reactor` exists specifically to prevent slow-client DoS by buffering
  request headers off the worker pool. The RactorPool reads inline on the
  Ractor, with a 5-second hard timeout, blocking that Ractor for the full
  duration. A handful of slow clients can deadlock the pool.

- **No keep-alive.** `process_client`'s keep-alive loop hands the client
  back to either the Reactor or the pool. We don't do either; we close the
  socket after one request. This is a real RPS hit on benchmarks that USE
  keep-alive (we deliberately ran without `-k` for that reason).

- **No hijack, no early hints, no chunked, no SSL, no IPv6 quirks.** Each
  of these involves code in `Puma::Response#prepare_response` that we
  bypass. Reproducing it inside a Ractor is mechanical but tedious; the
  bigger problem is that any abstraction we share (constants, helper
  modules) must be Ractor-shareable end-to-end. Puma's `Const` module
  is mostly frozen strings and IS shareable; the `Response` mixin
  references Server ivars and is not.

- **The Rack-app problem is the wall.** A toy `->(env) { [200,{},["hi"]] }`
  loads inside a Ractor via `instance_eval`. A real Rails app does not. Rails'
  application bootstraps thousands of constants, many holding mutable
  registries (ActiveRecord connection pool, ActiveSupport notifications,
  I18n backends, gem-level singletons). Every one of those is a
  `Ractor::IsolationError` waiting to fire. Puma forks precisely because
  the Ruby ecosystem assumes mutable global state per process; Ractors
  outlaw that assumption. Rails-on-Ractor isn't a Puma project.

- **What Puma would need from upstream Ruby.** At minimum: a way to mark
  whole module trees as shareable for "I promise I'm only reading." A
  story for shareable Procs that captures their lexical environment safely.
  Probably structured cloning for IO + buffer state (so `Puma::Client`
  can move). These are all open Ractor-design questions, not Puma-side
  fixes.

**What the talk gets out of this.** The numbers are real and the diff is
small enough to put on a slide. But the headline is the *errors*, not the
RPS:

```
Ractor::Error: can not copy Puma::IOBuffer object
Ractor::IsolationError: Proc's self is not shareable
Ractor::IsolationError: can not access non-shareable objects in
                        constant Rack::BUILDER_TOPLEVEL_BINDING
                        by non-main ractor
```

Three errors, one per layer (Puma's own internals, the Rack app, the Rack
gem itself). Each one was hit on the first attempt. Each one has a
workaround that strictly reduces feature coverage. The pattern is the
finding: as you push Ractors deeper into a real Ruby webserver stack,
every layer demands a new compromise, and the compromises don't compose.

## Repro

```sh
# modified Puma + RactorPool
PUMA_RACTOR_POOL=1 RACTORS=14 \
  bundle exec puma -C poc_ractor_pool_config.rb poc_baseline_app.ru

# bench harness
./poc_bench_modified.sh ractor_pool 14
./poc_bench_modified.sh baseline 14
```

Files of interest:
- `lib/puma/ractor_pool.rb` — the new pool
- `lib/puma/server.rb` — minimal swap-in (~30 lines diff)
- `poc_ractor_pool_config.rb` — Puma config that flips the flag
- `poc_bench_modified.sh` — benchmark driver
- `bench_out/*.summary.txt` — raw numbers
