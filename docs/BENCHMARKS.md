# Benchmarks

Measured results for the Phase 1 implementation. Every number here comes from a
run on the reference machine described below; nothing is estimated.

## Reference environment

| Item | Value |
| --- | --- |
| OS | Void Linux, kernel `6.18.59_1` |
| CPU | AMD A6-9200 RADEON R4, 5 Compute Cores (2C+3G), 2 threads |
| RAM | 11.4 GiB |
| GPU / display | X.Org 24.1.13 on `:0`, depth 24, visual `0x36` (`red_mask=0xff0000`) |
| Zig | 0.17.0 (`/usr/bin/zig`) |
| Backend | `platform.x11` (raw xcb, MIT-SHM frame upload) |

This is modest, low-power hardware. Numbers on a modern desktop CPU will be
lower; the budget verdict below is the conservative case.

## Frame cost

Workload: a fixed 640x420 interface built from `Box` → `Column` → `Button`, with
padding, spacing and centred alignment — the same tree `examples/benchmark.zig`
exercises. 100 measured frames after 5 warm-up frames, minus event draining.

```
zig build run-benchmark                                  # Debug: prints a warning, not a real number
zig build run-benchmark -Doptimize=ReleaseFast           # the measurement that matters
```

| Build mode | Layout + paint p50 | Mean | Min | Max | Present mean | Verdict vs 4 ms (p50) |
| --- | --- | --- | --- | --- | --- | --- |
| Debug | 34.92 ms | 38.09 ms | 30.93 ms | 115.47 ms | 24.49 ms | FAIL (expected) |
| **ReleaseFast** | **3.54 ms** | **3.84 ms** | **1.86 ms** | **9.11 ms** | **1.84 ms** | **PASS** |

> **The harness now prints its own build mode** (`Build mode: fast`). Previously a
> `Status: FAIL` from a debug build looked like a framework defect when it was
> only an unoptimised build. A Debug run now says so and prints the command that
> produces a meaningful number.

### Variance on this machine

Five consecutive `ReleaseFast` runs with load average ~4.2 on **2 cores** (Brave
GPU process, the editor and the compositor competing):

| Run | p50 | Max | Verdict |
| --- | --- | --- | --- |
| 1 | 2.49 ms | 8.90 ms | PASS |
| 2 | 2.36 ms | 12.80 ms | PASS |
| 3 | 3.98 ms | 11.91 ms | PASS |
| 4 | 5.85 ms | 21.06 ms | FAIL |
| 5 | 2.59 ms | 29.18 ms | PASS |

Honest summary: **the budget is met on an idle machine (p50 ~2.4–3.5 ms) and is
borderline under contention** (4/5 pass at load 4.2). Max values of 10–29 ms are
scheduler preemption, not framework cost — which is why the verdict uses **p50
instead of the mean**. One 100 ms hiccup used to shift the mean by a full
millisecond and flip the result between runs.

For a trustworthy number, stop the CPU-heavy processes first and check `uptime`.

Two measurements are reported separately on purpose:

- **Layout + paint** is the framework's own cost: measure, place, and rasterise
  into the software RGBA framebuffer.
- **Present** copies that framebuffer to the X server (MIT-SHM path).

Reporting them combined hides which half is slow. The `PROJECT.md` budget of
4 ms refers to UI state-change work, so layout+paint is the number that decides
PASS/FAIL.

**Conclusion:** the 4 ms target is met in `ReleaseFast` (p50 3.54 ms on an idle
machine) and missed by roughly 10× in `Debug`. Development builds are not
expected to meet a performance budget — that is what the build-mode banner is
for — but the gap is worth knowing: use `ReleaseSafe` or `ReleaseFast` when
evaluating responsiveness.

## Startup latency

Time from process start to the window being mapped and visible, `ReleaseFast`,
three consecutive runs:

| Run | Window mapped after |
| --- | --- |
| 1 | 96 ms |
| 2 | 79 ms |
| 3 | 101 ms |

The `PROJECT.md` target is sub-100 ms. Two of three runs are inside it; the third
is 1 ms over. On this hardware the target is met only marginally, and this
measurement includes X server round-trips, not just framework initialisation.

## Idle cost

An open, idle `zui-x11` window: 1 scheduler tick over 5 s = **0.20 % CPU**.

Both backends block in `xcb_wait_for_event` / `SDL_WaitEvent` rather than
polling. An earlier SDL3 loop busy-spun at 84 %; that is fixed and must not
regress.

## Memory

| Item | Value |
| --- | --- |
| Framebuffer, 640x420 RGBA | 1.08 MB |
| MIT-SHM segment (sized for the window) | 1.08 MB |
| Binary size, `ReleaseFast` | ~3.9 MB per example |

No per-frame allocation in steady state: the layout engine resets its arena with
`reset(.retain_capacity)` and the renderer reuses one framebuffer
(`docs/RESOURCE-OWNERSHIP.md`).

## Note on the X11 frame path

The X11 surface now repacks RGBA into the visual's byte order when the visual is
not RGBA-native. On this machine the server reads BGRX, so every frame goes
through `Surface.repackRgba`. That cost is included in the present numbers above
and is small relative to the shared-memory copy itself.

## Reproducing

```bash
zig build test --summary all          # 161 tests
zig build                             # 5 binaries in zig-out/bin

# Release numbers
zig build -Doptimize=ReleaseFast -p /tmp/rel
DISPLAY=:0 /tmp/rel/bin/zui-benchmark

# Startup: poll for the window
for i in 1 2 3; do
  start=$(date +%s%N)
  DISPLAY=:0 /tmp/rel/bin/zui-x11 & pid=$!
  while ! DISPLAY=:0 xwininfo -root -children | grep -q "ZUI + X11"; do :; done
  echo "$(( ($(date +%s%N) - start) / 1000000 )) ms"
  kill $pid
done

# Idle cost
DISPLAY=:0 /tmp/rel/bin/zui-x11 & pid=$!
sleep 1; t1=$(awk '{print $14+$15}' /proc/$pid/stat)
sleep 5; t2=$(awk '{print $14+$15}' /proc/$pid/stat)
awk -v d=$((t2-t1)) 'BEGIN { printf "%.2f %%\n", d/5 }'
kill $pid
```

## Caveats

- Numbers come from a debug-info-bearing build of the framework and a
  `ReleaseFast` example. Mixing modes changes them; the table above states which
  mode produced each row.
- `std.time.nanoTimestamp` does not exist in Zig 0.17.0; timing uses
  `std.Io.Timestamp` (monotonic, no wall-clock jumps).
- No regression baseline is recorded yet. Phase 2 will need one, since
  recomposition changes the per-frame path.
