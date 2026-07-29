# Fork changes: measurements, rationale, and how to enable

This fork of [puma/puma](https://github.com/puma/puma) carries bug fixes and opt-in
performance settings, each developed on its own branch and merged into `heroku-perf` through a
pull request that records what was measured and why. **Every pull request in this repository is
against this fork's own `heroku-perf` branch — none are open against upstream puma.**

Every number below was measured on real hardware with a same-commit control arm and interleaved
repetitions. Where a change did not pay off, that is recorded too.

## The changes

| # | Change | Default | Headline measurement |
|---|---|---|---|
| 1 | Benchmark-suite fixes | n/a | The primary `wrk` benchmark had been broken and silently exiting 0 since Nov 2024 |
| 2 | `Errno::EBADF` shutdown fix | always on | Removes an exception logged on **every** cluster SIGTERM (7/7 logs before, 0 after) |
| 3 | YJIT boot reporting + `yjit` setting | reporting on, setting off | **+24.8%** rps single mode, **+10.8%** cluster |
| 4 | `warmup_before_fork` (`Process.warmup`) | off | **−51.6%** per-worker unshared memory on a real Rails app, at +0.73 s boot |
| 5 | Per-request allocation reductions | always on | **44.0 → 39.0** allocations per keep-alive request |
| 6 | `reuse_port_per_worker` (Linux) | off | Characterized: no measurable win on macOS; kept for contended Linux deployments |

## Reference machine and method

Apple M5 Max, 18 cores (no SMT), 128 GB unified memory, macOS 26.5.2. MRI 3.3.11 for the
synthetic harness; MRI 3.3.10 for the real-application runs. Load generators: `wrk` 4.2.0 and
`hey`.

Method, applied to every measurement:

- **Same-commit control arms.** An "off" arm on the identical binary, not just a comparison
  against a previous release.
- **Interleaved repetitions** (on, off, on, off, …) with a fresh boot per repetition, so drift
  in machine state cannot land entirely on one arm.
- **Medians of 3–5 reps**, with per-rep ranges reported; ranges that overlap are called noise.
- **Locked baselines** captured before any change, so every later claim is measured against a
  recorded number rather than a remembered one.

### Locked baseline (stock puma at the fork point)

| Config | Result |
|---|---|
| single mode `-t0:5`, TCP, hello | 30,182 rps · p50 0.518 ms · p99 0.860 ms |
| single + YJIT | 37,667 rps · p50 0.402 · p99 0.734 |
| cluster `-w8`, TCP, hello | 94,426 rps · p50 0.160 · p99 0.362 |
| cluster `-w8` + YJIT | 104,593 rps · p50 0.142 · p99 0.330 |
| single mode, SSL, hello | 30,543 rps |
| single mode, 100 KB body | 23,147 rps |
| cluster `-w8`, per-worker RSS boot → warm | 12.1 → 21.2 MB |
| cluster `-w8`, per-worker dirtied pages | 0.672 → 5.188 MB |
| allocations per request (keep-alive / not) | 44.019 / 61.556 |
| worker request distribution (max/min) | 1.017 (CV 0.61%) |

## Enabling the optional settings

```ruby
# config/puma.rb
workers Integer(ENV.fetch("WEB_CONCURRENCY", 2))   # cluster mode is required for warmup
threads 4, 6

warmup_before_fork true    # memory: fewer copy-on-write pages dirtied per worker
yjit true                  # speed: enable YJIT in the master, inherited by workers
# reuse_port_per_worker true  # Linux only; measure before adopting
```

`warmup_before_fork` and `yjit` accept only literal `true`/`false`.

### Before enabling `warmup_before_fork`, validate your gem bundle

Heap compaction can expose latent bugs in C extensions that are not compaction-safe. This is
the reason upstream declined the feature (puma/puma#3304) and removed its predecessor
`nakayoshi_fork`, and it is why the setting is off by default. Ruby ships a deterministic way to
check your own bundle rather than waiting to find out in production:

```ruby
# bin/rails runner (or equivalent) — boot the app first, then:
Rails.application.eager_load!
GC.verify_compaction_references(expand_heap: true, toward: :empty)
# ... exercise your native gems here, holding handles across the compaction ...
GC.verify_compaction_references(expand_heap: true, toward: :empty)
```

This forces *every* movable object to a new page — harsher than `Process.warmup` itself. A real
Rails application with mysql2, grpc, nokogiri, ffi, and bcrypt passed this on a 1.1M-object
heap during development of this fork. Note that puma can only rescue `StandardError` around
`Process.warmup`; a native segfault would still stop boot, which is what this pre-flight check
is for.

## What did not work, and other honest notes

- **Four of seven proposed allocation reductions were rejected after measurement**, including
  one that looked like a clear win in isolation but regressed both allocation count and memory
  retention against the real class. See PR #5.
- **`reuse_port_per_worker` shows no measurable benefit on macOS**, and macOS `SO_REUSEPORT`
  turned out not to distribute connections at all (last-bind-wins, measured 200/0/0/0). The
  option gates itself to Linux. See PR #6.
- **The accept-loop sleep heuristic is not a bottleneck** at steady state: removing it entirely
  measured +0.54%, inside the noise band.
- **`warmup_before_fork` costs ~0.73 s of boot** on a realistically eager-loaded heap. That is
  once per deploy, not per worker respawn — but it is a real cost, and a benchmark run without
  eager loading will not show it (see below).
- **Benchmarking pre-fork memory without eager loading is misleading.** With Rails'
  `config.eager_load = false`, `preload_app!` loads the framework but not the application
  classes, so the same A/B reported −0.5% boot cost instead of +22.7%, and understated the
  memory benefit as well. Always eager-load when measuring anything about forking.
- **Not tested on Linux.** The page-release path differs (`malloc_trim` under glibc), and the
  reuse-port distribution behavior is Linux-specific by definition. Numbers here are Darwin.

## Upstream

Nothing here is proposed to upstream puma. `warmup_before_fork` corresponds to
puma/puma#3304, which upstream closed as not-planned; that thread asked for benchmarks that
were never produced, and this fork's measurements are that data should it ever be revisited.
The benchmark-suite fixes and the `Errno::EBADF` shutdown fix are plain bugs and would be
upstreamable as-is.
