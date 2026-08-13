# Milestone 08.2 — Characterising the deployed pipeline under sustained load

**Goal.** Find out what the Jetson actually does when the deployed application
runs continuously, instead of for the 9.61 s it has run for every time before.

**Status: complete.** `./scripts/measure_edge.sh --soak` exited 0 after a 30 s
idle baseline and a 604 s unpaced run; `./scripts/analyze_edge.py --soak`
turned the telemetry into the figures below. Nothing was built, pulled or
pruned, and the deployment artifact under measurement is the Milestone 7 image
exactly as it was certified.

Headline results:

| | |
|---|---|
| Sustained throughput | **178.14 fps** mean over the steady window (n=540, sd 1.36) |
| Independent cross-check | **178.03 fps** from a frame count DeepStream did not produce — **0.06%** apart |
| Real-time headroom | **5.94×** the 29.97 fps source rate; 540 of 540 steady samples above it |
| Throughput drift | **+0.010 fps/min** fitted over the steady window — flat |
| Peak junction temperature | **64.97 °C**, plateauing ~5 °C below the first passive trip |
| Thermal frequency capping | **None.** All three Class A cooling devices stayed at state 0 for the whole run |
| Process RSS | **+84.91 MB** over the steady window, decelerating and **unresolved** |
| Exit | **0**, on SIGINT, in ~4 s, no container or process left behind |

Two things this milestone does **not** claim, both stated at length below:

> RSS showed sustained but strongly decelerating, stepwise growth during the
> bounded 10-minute test. The cause was not isolated, and the run was not long
> enough to determine whether the process eventually converges.

> The planned dedicated Phase A cold single-pass instrumentation was not
> executed. The ~126.09 fps value that exists is contextual evidence derived
> retrospectively from the Milestone 7 KITTI metadata file mtime span, and is
> **not** a Milestone 8.2 Phase A measurement.

---

## 1. Goal

[`milestone-08-inspection.md`](milestone-08-inspection.md) §4 found one gap that
dominated all the others:

> **every run this project has ever made processed 288 frames and stopped.**

The literal capstone requirement — run on a Jetson with `deepstream-app` — was
already satisfied by Milestones 6 and 7. What had never been established was how
the deployed artifact behaves when it is not allowed to stop: what throughput it
sustains, how hot it gets, whether the kernel throttles it, whether its memory
footprint grows, and whether it shuts down cleanly afterwards.

Milestone 8.2 measures the existing artifact. It does not improve it. A run that
throttled, degraded or leaked would have been a **result** to record, not a
reason to retune the pipeline — and where the evidence is inconclusive, §13 and
§17 say so rather than rounding to a clean answer.

## 2. The artifact under measurement

Nothing in the deployment path was changed. This is the point of the milestone:
a characterisation of a modified pipeline would characterise nothing useful.

| | |
|---|---|
| Image | `video-surveillance-deepstream:m7-triton` — reused, never rebuilt |
| Engine | Milestone 4 FP16 TrafficCamNet, sha256 `35677da6a31aa3724b1d7d93f6b8925a64a7a64b6790a55c18413562725270a6` |
| Serving | `nvinferserver` → in-process Triton 2.68.0 → TensorRT |
| Tracker | NvSORT, vendor YAML referenced in place |
| Analytics | The Milestone 5 restricted-zone ROI, unchanged |
| Sink | `type=1` fakesink, `sync=0` |
| Power mode | `MAXN_SUPER` — read and asserted, never changed |
| Network | `--network none` |

The engine hash and the power mode are **preflight assertions**, not
observations: `measure_edge.sh` refuses to run if either differs
(`measure_edge.sh:151-157`). If the hash had moved, the thing measured would not
have been the thing certified, and the run would have been worthless.

## 3. What Milestone 8.2 set out to prove

| Question | Answered by |
|---|---|
| What end-to-end throughput does the assembled pipeline sustain? | §6 |
| Is that figure trustworthy, given `deepstream-app` reports it about itself? | §7 |
| What does looping the source cost? | §8 |
| Where do the thermals settle, and how close to a trip point? | §9 |
| Does the kernel throttle the CPU or GPU? | §10 |
| What CPU, GPU and power does sustained load draw? | §11 |
| Does anything degrade over ten minutes? | §12 |
| Does the process's memory footprint grow? | §13 — **not fully answered** |
| Does it shut down cleanly and leave nothing behind? | §14, §15 |

## 4. Test design

Three decisions shaped the experiment, all taken before it ran
([`milestone-08-inspection.md`](milestone-08-inspection.md) §8) and all with a
cost worth stating.

**Unpaced (`sync=0`), not real-time paced.** A paced run would prove the board
can keep up with 29.97 fps and nothing more. An unpaced run yields the actual
throughput ceiling *and* is the harshest thermal and power condition available,
in a single run. The cost is that the result must be read carefully:

> The unpaced soak measures **processing capacity**. Sustained throughput of
> 178 fps means the board has roughly 5.94× the headroom a 29.97 fps camera
> stream needs. It is **not** 178 fps of real-time playback, and this document
> never describes it as such.

**Looped source, not a longer clip.** The only source available is 288 frames of
`sample_walk.mov`. `[tests] file-loop=1` repeats it. DeepStream implements this
as a seek rather than a source restart, and it is not gapless — so the loop
boundary is part of what the run measures, and §8 reports its cost instead of
excluding it.

**Ten minutes, bounded externally.** Long enough for the thermal ramp to reach a
plateau and for a memory trend to separate from noise; short enough to stay safe
on a board with no swap. A looping `deepstream-app` never ends by itself, so the
bound is the supervisor's, not the application's.

### The soak configuration

[`../configs/deepstream_app_walk_soak.txt`](../configs/deepstream_app_walk_soak.txt)
is `deepstream_app_walk_triton.txt` with **exactly three** functional changes,
verifiable by diffing the two files with comments stripped:

| Change | Why |
|---|---|
| `[tests] file-loop=0` → `1` | A 288-frame clip cannot exercise steady state, and there is no CLI override for this key — `deepstream-app` accepts only `-c` and `-i` |
| The four `*-output-dir` keys **removed** | At ~178 fps a ten-minute run is ~109,000 frames. Per-frame KITTI dumping would cost hundreds of MB across hundreds of thousands of files and — worse — would put synchronous per-frame disk I/O *inside* the measurement. Correctness is not under test here; Milestone 7 proved it |
| `perf-measurement-interval-sec=5` → `1` | One throughput sample per second, so trend is resolvable and the loop artifact appears in the distribution instead of being smeared across five seconds |

Source, streammux, inference config, tracker, analytics, ROI, tiler, OSD, sink
and per-class colours are byte-for-byte the Milestone 7 file. The config is
**bind-mounted read-only at run time** and is not baked into any image.

## 5. Instrumentation

[`../scripts/measure_edge.sh`](../scripts/measure_edge.sh) drives the run;
[`../scripts/analyze_edge.py`](../scripts/analyze_edge.py) reduces the telemetry.
The split is deliberate: the shell script does orchestration and safety, where
`set -euo pipefail` and exit codes matter, and the statistics live in Python,
where percentiles and least-squares fits are readable. (The system `awk` is
`mawk`, which lacks three-argument `match()` — an early awk parsing attempt
failed outright, which settled the question.)

Four instruments, all running on the host, none inside the measurement:

| Instrument | Rate | Provides |
|---|---|---|
| `deepstream-app` `**PERF` lines | 1 Hz | The application's own throughput accounting |
| `tegrastats --interval 1000` | 1 Hz | RAM, per-core CPU %/MHz, `GR3D_FREQ`, six thermal zones, three power rails |
| A custom sampler loop | 1 Hz | `deepstream-app` `VmRSS`, `MemAvailable`, GPU devfreq clock, **every** cooling-device state |
| GStreamer's per-seek warning | per loop | An independent frame count (§7) |

Four implementation details are worth recording, because each was a real
obstacle:

- **`stdbuf -oL -eL` runs inside the container.** `deepstream-app`'s stdout is a
  pipe here, so libc would block-buffer it and the PERF lines would arrive in
  bursts with meaningless timestamps. `stdbuf` `exec`s its program, so the
  container's PID 1 is still `deepstream-app` — confirmed in the pilot by
  reading `/proc/<pid>/comm`.
- **The process is found without `--name`.** `--cidfile` yields the container
  id, and `docker inspect --format '{{.State.Pid}}'` yields the host pid of PID
  1. That pid is what `/proc/<pid>/status` is read for RSS. This follows the
  precedent in `verify_container.sh:345`.
- **No `docker exec` polling during the measurement.** Sampling from the host
  keeps the measurement out of the container being measured.
- **`MemAvailable` is the RAM guard, not tegrastats' "used".** tegrastats
  excludes reclaimable cache, so it understates what the kernel could still
  hand out. The guard aborts after **three consecutive** samples below 600 MB;
  a single sample would let a transient buffer-pool reallocation destroy a valid
  run.

### The 600 MB floor is ours, not the kernel's

> 600 MB is **this project's conservative abort threshold**, chosen because this
> board has no swap and the kernel's only recourse under pressure is reclaim and
> then the OOM killer. It is not a kernel limit, not an OOM threshold, and not a
> prediction of one.

### The pilot

A 60 s pilot ran first, purely to validate the machinery. It established that
`file-loop=1` genuinely loops, that PERF reporting survives looping, that an
independent loop counter exists, that PID → RSS sampling works, that tegrastats
and cooling-state sampling work, that shutdown is clean, and that the disk cost
is negligible. It also found four defects, all fixed before the soak:

| Pilot defect | Fix |
|---|---|
| The `.pilot.rc` scratch file survived the run | `RC_FILE` added to the cleanup trap's `rm -f` |
| PERF **header** lines were counted as samples (44 reported, 41 real) | Both the shell count and the Python regex now require a numeric field; headers are counted and reported separately |
| The loop marker was unproven as one-per-loop | Confirmed against the pilot's own loop count before being relied on |
| Boundary-window exclusion was assumed necessary | Measured instead, found negligible, and abandoned — see §8 |

The pilot's own telemetry is retained under `models/edge/pilot_*` and predates
these fixes; its summary is a historical record, not a result.

## 6. Throughput

From `models/edge/soak_analysis.txt` §1. The steady window is load start + 60 s
onward — the warm-up excluded from it covers Triton model load, CUDA context
creation and buffer-pool allocation, which are startup, not steady state.

```
  all data samples        n=595 mean=177.67 median=178.00 min=0.00 p5=176.00 p95=180.00 max=182.00 sd=8.38
  steady window (t+60s+)  n=540 mean=178.14 median=178.00 min=173.00 p5=176.00 p95=180.00 max=182.00 sd=1.36
  all    samples >= 29.97 fps: 594/595 = 99.8%
  steady samples >= 29.97 fps: 540/540 = 100.0%
  deepstream-app final cumulative average: 177.96 fps
  No samples were discarded. Low values are data, not noise.
```

The one sample below 29.97 fps is the **first** PERF line of the run,
`**PERF: 0.00 (0.00)` at t+5.7 s, printed before any frame had been processed.
It is kept in the "all samples" row rather than removed, which is why that row
carries an `sd` of 8.38 against the steady window's 1.36.

**Reading of the result:**

- Sustained throughput is **178.14 fps** (mean) / **178.00 fps** (median), with
  a standard deviation of **1.36 fps** — a spread of well under 1%. For a board
  whose clocks cannot be locked without root, that is a remarkably tight
  distribution, and it is reported as a distribution rather than a single number
  precisely because the inspection required it.
- Every one of the 540 steady samples cleared the 29.97 fps source rate. The
  worst single second of the whole steady window was 173 fps, still **5.77×** the
  requirement.
- The headroom figure is **178.14 / 29.97 = 5.94×**.

> **Correct interpretation.** The deployment has enough processing capacity for
> a 29.97 fps camera stream, with roughly 5.94× headroom, measured under the
> harshest condition the board can be put in. This is a capacity statement, not
> a playback statement.

## 7. Independent throughput cross-check

`**PERF` is `deepstream-app`'s own accounting of its own performance. The
inspection flagged that as a weakness (§9 risk 8) and required a cross-check.

One became available during implementation. GStreamer emits

```
Got data flow before segment event
```

exactly **once per file-loop seek**. That gives a frame count DeepStream's
performance measurement had no part in producing: completed loops × 288 frames,
timed from the marker timestamps in the host-stamped log.

```
  loop markers in log: 379   (GStreamer per-seek warning, one per loop)
  steady-state loops     333 completed in 538.68 s
  frames                 333 x 288 = 95904 (independent count, not derived from PERF)
  independent throughput 178.03 fps
  vs PERF steady mean    178.14 fps   difference -0.11 fps (0.06%)
```

The two methods agree to **0.06%**. They are not forced to agree and were not
tuned to: PERF is a per-interval count the application maintains, the loop
figure is whole clips divided by host wall-clock time. The gap is reported as
measured.

Across the whole run, 379 loop markers correspond to roughly **109,000 frames**
processed — against the 288 frames of every previous run in this project's
history.

This is the single most important number in the milestone, because it converts
the throughput figure from *self-reported* to *corroborated*.

## 8. Loop behaviour

The inspection warned that `file-loop` is not gapless and that boundary stalls
might bias the average downward (§9 risk 4). Measured:

```
  loop period            mean 1.6177 s  min 1.5897 s  max 1.6416 s
  PERF windows containing a loop boundary: n=334 mean=178.03 fps
  PERF windows with no loop boundary:      n=206 mean=178.33 fps
  difference +0.30 fps
```

288 frames at 178 fps is ~1.618 s, which is exactly the observed mean period —
the loop is not inserting a measurable stall. The cost of a boundary is
**~0.30 fps out of 178**, about 0.17%, and the period's full range spans 52 ms.

**Boundary samples were therefore not excluded from any statistic in this
document.** The original design contemplated excluding them; measurement showed
there was nothing worth excluding, and removing 334 of 540 samples to chase a
0.17% effect would have been worse methodology, not better.

## 9. Thermals

```
  metric                 idle baseline              loaded (steady)
  tj (C)                 45.1 - 45.6                58.0 - 65.0
  gpu temp (C)           45.1 - 45.6                58.0 - 65.0
  cpu temp (C)           43.9 - 45.3                55.6 - 62.9
```

Junction temperature peaked at **64.97 °C** and the last third of the run
averaged **64.47 °C** — the curve had flattened into a plateau rather than
still climbing (§12 shows +2.56 °C across the whole steady window, most of it
early).

The kernel's own trip points, read from `/sys/class/thermal/`, are worth
attributing to the right zone rather than quoting as one list:

| Zone | Trip points |
|---|---|
| `cpu-thermal` | **passive 70 °C**, passive 99 °C, critical 104.5 °C |
| `gpu-thermal` | **passive 70 °C**, passive 99 °C, critical 104.5 °C |
| `tj-thermal` | active 35 °C, active 74 °C, active 95 °C, critical 104.5 °C |

The *passive* trips are the frequency-capping ones, and they belong to the CPU
and GPU zones. Those zones peaked at 62.9 °C and 65.0 °C respectively, leaving
roughly **5 °C of margin** below the first passive trip at 70 °C — and the
temperature was plateauing rather than approaching it. The `tj` zone's own trips
are *active* trips, which drive the fan, not the clocks.

No threshold in this section was invented for the purposes of the report; every
one is a value the platform exposes.

## 10. Thermal throttling — direct evidence

**This section supersedes an inspection-phase conclusion.** The Milestone 8.1
inspection recorded that throttling has "no direct flag" and could only be
*inferred* from clocks falling while temperature rises. During implementation
that turned out to be incomplete: the kernel's thermal cooling devices are
world-readable at `/sys/class/thermal/cooling_device*/cur_state`, and they state
the throttling directly. A dated addendum has been appended to
[`milestone-08-inspection.md`](milestone-08-inspection.md); its body is left as
the historical record of what was known before the work started.

The devices are **not equivalent**, and the sampler classifies them:

- **Class A — frequency caps.** `cpufreq-*` and `devfreq-*`. A non-zero state
  *is* the thermal framework capping the hardware. This is throttling.
- **Class B — alerts and the fan.** Everything else. A fan stepping up is
  thermal management doing its job.

```
  [A] cpufreq-cpu0               start=0 max_observed=0
  [A] cpufreq-cpu4               start=0 max_observed=0
  [A] devfreq-17000000.gpu       start=0 max_observed=0
  [B] pwm-fan                    start=0 max_observed=1  ENGAGED, 1 zero-to-nonzero transition(s)
        first transitions: t+46s -> state 1
  [B] soc0/soc1/soc2-throttle-alert, cpu-, gpu-, cv0-, cv1-, cv2-throttle-alert,
      hot-surface-alert          start=0 max_observed=0

  No Class A device left state 0 at any point: the kernel's thermal framework
  applied no frequency capping during this run. That is a statement about
  measured cooling-device state, not an inference from clocks.
```

All three Class A devices have headroom to spare — `cpufreq-cpu0` and
`cpufreq-cpu4` have `max_state` 21, `devfreq-17000000.gpu` has 7 — and all three
sat at state 0 for all 601 samples.

> **The Linux thermal framework applied no CPU or GPU frequency capping during
> the soak.** This is direct evidence from cooling-device state, not an
> inference from clock stability.

The **`pwm-fan` moved from state 0 to state 1 at t+46 s** and stayed there. That
is ordinary thermal management and is **not** throttling; it is reported here so
that "one cooling device changed state" cannot later be misread. Which trip
point drives that transition was not investigated — the fan's binding to the
`tj-thermal` active trips is not something this run establishes.

## 11. CPU, GPU and power

Idle baseline against loaded steady state, from `tegrastats`:

```
  metric                 idle baseline              loaded (steady)
  RAM used (MB)          2827 - 2909                2866 - 3280
  lfb (MB)               8 - 16                     4 - 60
  GR3D_FREQ (%)          0 - 15                     0 - 91
  CPU mean-core (%)      2.2 - 30.8                 2.7 - 47.2
  CPU peak clock (MHz)   729 - 1728                 729 - 1728
  VDD_IN (W)             3.77 - 5.83                4.51 - 17.16
  VDD_CPU_GPU_CV (W)     0.57 - 1.80                0.72 - 8.60
  VDD_SOC (W)            1.13 - 1.49                1.29 - 4.28
  GPU devfreq (MHz)      306 - 306                  1020 - 1020
```

Distributions over the 540 loaded samples, recomputed from the raw `tegrastats`
log for this document:

| Metric | mean | median | p5 | p95 | max |
|---|---|---|---|---|---|
| `GR3D_FREQ` (GPU load %) | 68.63 | 69 | 50 | 84 | 91 |
| CPU mean-core (%) | 38.21 | 38.33 | 36.17 | 40.33 | 47.17 |
| `VDD_IN` (W) | 16.21 | 16.28 | 16.08 | 16.45 | 17.16 |

Read out of that:

- **The GPU is the busy component but is not saturated**, averaging 68.6% load
  and peaking at 91%. The pipeline is not GPU-bound at 178 fps.
- **The GPU clock pinned at 1020 MHz**, its maximum, for the entire loaded
  window — 306 MHz at idle. `GR3D_FREQ` is a **load percentage despite its
  name**; the clock figure comes from devfreq sysfs, a distinction Milestone 4
  first recorded.
- **CPU load is moderate and spread**, ~38% mean across six cores, peaking at
  1728 MHz. No single core is pegged.
- **Board power settles around 16.1–16.5 W**, against 3.8–5.8 W idle.

The `GR3D_FREQ` minimum of 0% and the `VDD_IN` minimum of 4.51 W in the loaded
column are the same artifact, and it is at the **end** of the window rather than
the start: the loaded window runs to `load_end`, which is recorded after
shutdown completes, so its last four samples (t+601 s to t+604 s) are the
post-SIGINT cooldown. Four of 540 samples, which is why the p5 figures
(50% GPU load, 16.08 W) describe the loaded state better than the minima do.

`tegrastats` measures the **whole Jetson**, not the container — the desktop
session is a standing consumer. That is exactly why the 30 s idle baseline
exists, and why every figure above is presented as a pair.

## 12. Performance over time

First third of the steady window against the last third:

```
  metric                    first third     last third       change
  PERF fps                       178.17         178.21        +0.04
  GR3D_FREQ %                     69.22          68.49        -0.73
  CPU mean-core %                 38.37          37.89        -0.48
  tj C                            61.92          64.47        +2.56
  VDD_IN W                        16.22          16.12        -0.10
  RAM used MB                   3218.84        3245.87       +27.03
  GPU clock MHz                 1020.00        1020.00        +0.00
  RSS MB                        1130.37        1168.91       +38.54

  Throughput stable: +0.02% from first third to last third.
  Fitted throughput trend: +0.010 fps/min over the steady window.
```

**Throughput did not degrade while the board heated toward its plateau.** It
rose by 0.04 fps — 0.02% — which is noise, not improvement. The fitted trend of
+0.010 fps/min over ten minutes is likewise indistinguishable from flat.

Everything else moves in the direction that supports this: GPU load and CPU load
drift very slightly *down*, power drifts slightly *down*, the GPU clock does not
move at all, and temperature rises 2.56 °C without any consequence visible in
the other rows. There is no thermal-degradation signature here.

The RSS row is the exception, and §13 deals with it.

## 13. Memory — the unresolved result

```
  steady window start    1099.8 MB   (516 samples)
  steady window min/max  1099.8 / 1184.7 MB
  final                  1184.7 MB
  total change           +84.91 MB over 540 s
  fitted slope           +6.7957 MB/min
  MemAvailable           min 4003 MB   max 4471 MB
```

`deepstream-app`'s resident set grew by **84.91 MB** across the steady window.
That is a real measurement and it is not dismissed.

**The growth is not linear**, which is why the single fitted slope of
+6.80 MB/min is a poor description of it. Splitting the steady window in half:

| Half | Fitted slope |
|---|---|
| First | **+17.412 MB/min** |
| Second | **+1.295 MB/min** |

The shape is **stepwise, not continuous** — long flat regions punctuated by
discrete allocations. Twelve steps larger than 1 MB occurred, front-loaded:

```
  t+67.4s   1099.84 -> 1103.16 MB   (+3.32)
  t+108.3s  1104.32 -> 1106.70 MB   (+2.38)
  t+138.7s  1107.53 -> 1120.08 MB  (+12.55)
  t+149.2s  1120.08 -> 1135.96 MB  (+15.88)
  t+158.7s  1135.96 -> 1151.70 MB  (+15.73)
  t+169.2s  1151.70 -> 1155.51 MB   (+3.81)
  t+229.9s  1155.51 -> 1161.34 MB   (+5.83)
  t+301.3s  1161.34 -> 1165.18 MB   (+3.84)
  t+383.2s  1165.16 -> 1167.09 MB   (+1.93)
  t+445.1s  1167.09 -> 1169.04 MB   (+1.95)
  t+587.8s  1167.17 -> 1177.06 MB   (+9.89)
  t+598.3s  1177.06 -> 1184.74 MB   (+7.68)
```

Between t+445 s and t+588 s the process held a **plateau around 1168 MB** for
well over two minutes — the longest flat region of the run, and the reason a
"converging" reading looked plausible. Then two further steps landed in the last
16 seconds before shutdown, which is the reason it cannot be claimed.

> **Conclusion, stated as it is.** RSS showed sustained but strongly
> decelerating, stepwise growth during the bounded 10-minute test. The cause was
> not isolated, and the run was not long enough to determine whether the process
> eventually converges.

Explicitly **not** claimed, in either direction:

- **Not** "a memory leak was found." Decelerating stepwise growth is equally
  consistent with pool and arena expansion settling toward a working-set
  ceiling, and 84.91 MB on a process holding 1.1 GB is 7.7%.
- **Not** "memory is stable" or "no leak." The final two steps are real, they
  are late, and a ten-minute window cannot see past them.

Resolving this needs a longer run and allocation-level instrumentation, neither
of which is in Milestone 8's scope. It is carried forward as an open question.

System memory was never close to pressure: **`MemAvailable` never fell below
4003 MB**, against a 4471 MB maximum, and the RAM guard never recorded a single
strike. As §5 states, the 600 MB floor is this project's abort threshold and not
a kernel or OOM boundary.

## 14. Shutdown behaviour

The supervisor has a three-rung escalation — SIGINT, then `docker stop -t 10`,
then SIGKILL. **Only the first rung was used.** Verbatim from the tail of the
application log, host timestamps intact:

```
1786550773.561764 ** ERROR: <_intr_handler:136>: User Interrupted..
1786550773.862354 Quitting
1786550775.904694 [NvMultiObjectTracker] De-initialized
1786550775.907865 App run successful
```

- `docker kill --signal=SIGINT` at t+600 s; `App run successful` **2.35 s
  later**; the script measured **4 s** end to end including container teardown.
- **Exit code 0.** Captured through the pipe via `PIPESTATUS[0]` — the runner
  subshell's own status is not the application's, so it is written to a file and
  read back deliberately (`measure_edge.sh:269-279, 399-401`).
- The tracker de-initialised cleanly rather than being torn down.
- Neither `docker stop` nor SIGKILL was needed.

**The `** ERROR:` prefix on the interrupt line is DeepStream's own labelling of
its signal handler, not a fault.** It is followed by an orderly quit and a
success message, and is recorded here so a future reader greping the log for
`ERROR` does not mistake it for one.

Verified afterwards, from the host: no container (`docker ps -a` empty), no
`deepstream-app`, no orphan `tegrastats`, no sampler, no measurement process.
The check used `ps -eo comm= | sort -u` rather than `pgrep -f` — the latter
matches its own command line and produced three false positives before the
method was corrected.

## 15. Disk and resource hygiene

The inspection named storage a first-class constraint (§2). Measured across the
whole experiment:

| | Before | After |
|---|---|---|
| Free space on `/` | 29 GB | 29 GB |
| `docker system df` | — | unchanged |
| Containers | 0 | 0 |

- **No image was built, pulled or pruned.** `measure_edge.sh` contains no
  `docker build`, `docker pull` or `docker *prune`, and refuses to start if the
  image is absent rather than creating it (`measure_edge.sh:140-141`).
- **Everything new entered the container by bind mount** — the soak config, the
  engine, the Triton repository. Zero image space.
- **No output video, no KITTI dump tree, no engine copy, no persistent
  container.** The Milestone 7 dump directories still carry their original
  mtimes, untouched.
- The soak produced **~637 KB** of telemetry; the complete Milestone 8 evidence
  set including the pilot is **~756 KB**.

All of it lives under `models/edge/`, which is **git-ignored** — small text,
regenerated by the script on every run, never committed. The figures that matter
are quoted in this document instead, which is the point of the exclusion.

The disk-free watchdog Milestone 7 described in prose but never implemented is
now real: a 5 GB floor checked at preflight and again on every supervisor tick
(`measure_edge.sh:175-177, 354-357`).

## 16. The Phase A deviation

The Milestone 8.2 design described **two** phases: a cold single-pass run of the
existing 288-frame config, timed end to end, and then the soak.

> **The dedicated Phase A was never executed.**
> [`../scripts/measure_edge.sh`](../scripts/measure_edge.sh) contains no Phase A
> implementation — `grep -i phase` over it returns nothing. Only the soak path
> was built and run.

A figure of **~126.09 fps** exists and was discussed during the work. Its
provenance:

- It was derived **retrospectively**, from the span of modification times across
  the KITTI metadata files left on disk by an earlier **Milestone 7** run.
- That run had **per-frame metadata dumping enabled**, so it includes
  synchronous per-frame disk I/O that the soak configuration deliberately
  removes.
- It is a single 288-frame pass, reconstructed from file timestamps rather than
  from an instrumented measurement.

> The ~126.09 fps value is **contextual evidence** derived retrospectively from
> the Milestone 7 KITTI metadata file mtime span. It is **not** a Milestone 8.2
> Phase A measurement and must not be quoted as one.

In particular, the gap between ~126 fps and ~178 fps is **not** attributed to
dumping overhead. Dumping is one plausible contributor, but the two figures
differ in several ways at once — dumping, warm versus cold start, loop versus
single pass, derivation method — and none of them was isolated. **No overhead
figure is claimed.**

**Phase A was not re-run to fill this gap.** The sustained soak is the milestone's
throughput measurement, it is corroborated by an independent frame count (§7),
and re-running the board to make a document look complete would be the wrong
reason to spend a measurement. The deviation is recorded instead.

## 17. Unresolved observations

Two, both carried forward rather than closed.

**1. RSS growth (§13).** Sustained, strongly decelerating, stepwise. Cause not
isolated; the window is too short to establish convergence either way.

**2. 15,226 empty lines in the application log.** They are 93.6% of the log's
16,271 lines, they were kept as evidence rather than filtered, and they are
counted in `soak_analysis.txt` §7 so they cannot be mistaken for missing output.
Their cadence, measured over the 597.5 s they span, has a median inter-line gap
of **40.2 ms — about 24.9 Hz**.

That cadence is numerically close to `batched-push-timeout=40000` (40 ms) in the
streammux configuration.

> **This is a coincidence of frequency, not a demonstrated cause.** Nothing was
> instrumented to connect the two, no mechanism was traced from the timeout to
> the empty writes, and the correlation is not converted into an explanation
> here. It is recorded as an unexplained observation.

Neither observation affects any conclusion in §6–§12: throughput, thermals,
throttling, power and stability are all measured independently of both.

## 18. Known limitations

1. **Ten minutes is not an endurance test.** It is long enough for the thermal
   plateau and for a throughput trend; it is not long enough to settle the
   memory question (§13), and no claim of long-run stability is made.
2. **One source, one stream, one clip.** 288 frames of `sample_walk.mov` on
   repeat. Throughput on a different resolution, bitrate, scene complexity or
   stream count is unmeasured.
3. **Clocks cannot be locked** — `jetson_clocks` needs root and none is
   available here. DVFS moved freely throughout. Mitigated the Milestone 4 way,
   by reporting distributions and recording clocks and temperature alongside
   every figure.
4. **`tegrastats` is system-wide, not per-container.** The desktop session is a
   standing consumer. Mitigated by the 30 s idle baseline and by using `/proc`
   RSS for the per-process figure — but the loaded column is still a whole-board
   number.
5. **The unpaced result does not characterise the paced deployment.** A
   `sync=1` run would have different thermal, power and scheduling behaviour.
   What is proven is capacity, not the paced steady state.
6. **The dedicated Phase A was not run** (§16), so there is no instrumented
   cold-start or single-pass figure from this milestone.
7. **`GR3D_FREQ` is load, not clock.** Anyone reading the raw `tegrastats` log
   should note the name is misleading; the clock came from devfreq sysfs.

## 19. Completion criteria

| Criterion (set in the inspection, §8) | Result |
|---|---|
| Throughput reported as a distribution, not a single number | **Met** — §6, n=540 with median, p5, p95, min, max and sd |
| Stated against the 29.97 fps real-time threshold | **Met** — 540/540 above it, 5.94× headroom, and stated as capacity rather than playback |
| CPU, GPU load, RAM, `tj`, `VDD_IN` and clocks reported as ranges backed by telemetry | **Met** — §9, §11, idle and loaded columns |
| Loop-boundary artifacts identified rather than averaged away | **Met** — §8, measured at ~0.30 fps and explicitly not excluded |
| Throttling reported honestly | **Exceeded** — §10 gives direct cooling-device evidence rather than the inference the inspection expected |
| RSS trend reported with an explicit statement of whether growth was observed | **Met** — §13 reports growth and declines to classify it |
| Exit status checked, including through pipes | **Met** — `PIPESTATUS[0]`, exit 0, §14 |
| Failures reported as failures | **Met** — no failure occurred; the two unresolved observations in §17 are recorded as unresolved |
| No image built, pulled or pruned; disk bounded | **Met** — §15, 29 GB before and after |

`grep -n '|| true' scripts/measure_edge.sh scripts/analyze_edge.py` returns
nothing: no construct in either file hides a non-zero exit.

**Milestone 8.2 is complete.** Milestone 8 as a whole is not — checkpoint 8.3
remains.

## 20. Remaining work — Milestone 8.3

Redeployment after load: a fresh `docker run` of the same image immediately
after the soak, compared against the frozen Milestone 7 invariants — 288/288
frames, exit 0, clean EOS, zone entry 109 / 75 frames / exit 183, 0 mid-track ID
switches, a 224-frame dominant track, and raw detection counts checked against
the documented ~1% run-to-run tolerance rather than for equality
([`../PLAN.md`](../PLAN.md) §11). `docker ps -a` empty afterwards, and the disk
delta recorded and bounded.

**It has not been run.** The point of placing it after the soak is that it tests
the board in the state the soak left it in, so it is a genuinely different claim
from the Milestone 7 verification rather than a repeat of it.

## 21. Lessons learned

- **A self-reported metric is worth much less than a corroborated one.** The
  single most valuable discovery in this milestone was that GStreamer's per-seek
  warning could be counted as an independent frame source. It cost nothing and
  turned the headline figure from an application's claim about itself into a
  cross-checked measurement.
- **"Cannot be measured directly" deserves a second look before it is written
  down.** The inspection concluded throttling could only be inferred. It was
  wrong — not unreasonably, but wrong — and the cooling-device sysfs was
  world-readable the whole time. §10 is a stronger result than the milestone
  planned for, obtained by re-checking an assumption rather than by working
  around it.
- **Not all cooling devices mean the same thing.** Reporting `pwm-fan 0 → 1` as
  "throttling detected" would have been a false alarm, and reporting "one
  cooling device engaged" without classifying it would have been worse than
  useless.
- **Block buffering silently destroys timestamps.** Without `stdbuf` inside the
  container, every PERF line would have carried the timestamp of the burst that
  flushed it, and both the trend analysis and the loop cross-check would have
  been quietly wrong rather than obviously broken.
- **Plan the exclusion, then measure whether it is needed.** Boundary-sample
  exclusion was designed in and then discarded because the effect was 0.17%.
  Measuring first avoided throwing away 62% of the samples for nothing.
- **A decelerating curve is not a converging one.** The temptation to call the
  RSS plateau "settled" was real, and the last two steps landed 16 seconds
  before shutdown. Ten minutes bought a description, not a verdict.
