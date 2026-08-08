# Milestone 04 — Optimising TrafficCamNet with TensorRT

**Goal.** Build FP32, FP16 and INT8 TensorRT engines from the TrafficCamNet ONNX
model selected in Milestone 3, and compare their **computational performance**
fairly on the Jetson Orin Nano. No DeepStream inference, no video, no
detection-quality claims.

**Status: complete.** Every number below was produced by the scripts in this
repository and captured from real output.

Inspection-phase record: [`milestone-04-inspection.md`](milestone-04-inspection.md).

---

## 1. What was built

Three engines from one ONNX model, all with an identical optimisation profile
(`min = opt = max = 1x3x544x960`), built with `--skipInference` so that no
builder work could perturb a later timing.

| Engine | Build flags | Purpose |
|---|---|---|
| FP32 | `--noTF32` | A **controlled baseline**. Without this flag TensorRT enables TF32 on Ampere and "FP32" silently means a 10-bit mantissa |
| FP16 | `--fp16` | A **deployment engine**. TF32 deliberately left enabled so non-FP16 layers fall back as they would in production |
| INT8 | `--int8 --fp16 --calib=cal_trt.bin` | A **deployment engine**. INT8 where TensorRT selects it, FP16 as fallback rather than FP32 |

The asymmetry is intentional and it matters when reading the results: **FP32 is an
experiment, FP16 and INT8 are deployment configurations.** The FP32→FP16
comparison is therefore baseline-versus-deployment, not a single-variable
experiment — the FP16 engine's measured gain includes any TF32 contribution on
layers the builder left out of FP16.

Reproduce with:

```bash
./scripts/inspect_model.sh                      # model contract + cache coverage
./scripts/build_engines.sh --precision all      # fp32, fp16, int8
./scripts/engine_report.sh                      # what each engine ACTUALLY is
./scripts/benchmark_engines.sh                  # interleaved comparison
```

## 2. Build results

| | FP32 | FP16 | INT8 |
|---|---|---|---|
| Exit status | 0 | 0 | 0 |
| Build time | **46.15 s** | **67.65 s** | **153.19 s** |
| Engine size | 9,443,956 B (9.01 MiB) | 3,196,724 B (3.05 MiB) | 2,716,140 B (2.59 MiB) |
| Size vs FP32 | 100% | 33.8% | 28.8% |
| Errors | 0 | 0 | 0 |
| Warnings | **0** | 1 | 1 |

The single warning in the FP16 and INT8 builds is identical and expected:

```
[W] Weakly-typed networks have been deprecated in TensorRT. You can use the
    AutoCast tool (...) to convert the network to be strongly typed.
```

`--fp16` and `--int8` create a weakly-typed network. This is a deprecation
notice, not a defect. The FP32 build produced **no warnings at all** — verified
by tallying severities across the whole 8,604-line log: 147 `[I]`, 8,420 `[V]`,
zero `[W]`, zero `[E]`.

Engine sizes are slightly inflated by `--profilingVerbosity=detailed`, which
embeds layer metadata. Applied uniformly to all three, so the comparison holds.

## 3. What the engines actually are

`--fp16` and `--int8` mean **allow**, not **force** — TensorRT chooses a precision
per layer by measured timing. So an engine must be inspected, not assumed. From
`./scripts/engine_report.sh`, reading the `--exportLayerInfo` JSON:

| Engine | Fused layers | Weight datatypes | Output datatypes |
|---|---|---|---|
| FP32 | 28 | `Float` 27 | `Float` 28 |
| FP16 | 30 | `Half` 27 | `Half` 28, `Float` 2 |
| INT8 | 32 | **`Int8` 16, `Half` 11** | `Int8` 17, `Half` 12, `Float` 3 |

**FP32 and FP16 are uniform** — every weight tensor is `Float` and `Half`
respectively, with zero layers off the dominant precision. The two `Float`
outputs in the FP16 engine are the network's final bindings (`output_cov`,
`output_bbox`).

**The INT8 engine is genuinely mixed, and not uniformly INT8.** Eleven layers run
in FP16, and they are not scattered at random:

```
Half   block_3b_conv_1 / block_3b_conv_2 / block_3b_conv_shortcut
Half   block_4a_conv_1 / block_4a_conv_2 / block_4a_conv_shortcut
Half   block_4b_conv_1 / block_4b_conv_2 / block_4b_conv_shortcut
Half   output_cov/convolution
Half   output_bbox/convolution
```

Every FP16 layer is in the **deep blocks (3b, 4a, 4b) or one of the two detection
heads**. The autotuner declined INT8 there — plausibly because those layers have
small spatial dimensions and many channels, where the quantise/dequantise
reformat costs more than the INT8 arithmetic saves. This was measured, not
assumed, and it is the reason this document says "the INT8 engine" only as
shorthand for a configuration that is **INT8 in the early and middle network and
FP16 in the deep layers and both output heads**.

> **A caveat this method cannot resolve.** TF32 is a *compute mode* for FP32
> tensors, not a distinct datatype, so a TF32 layer is indistinguishable from
> FP32 in this JSON. The only evidence that the FP32 engine is genuinely FP32 is
> the `--noTF32` build flag itself.

## 4. Did the INT8 calibration cache work?

**Yes.** This was the milestone's main risk: the shipped cache header records
TensorRT 10.3.0, while the installed runtime is 10.16.2.

The build succeeded with **no version warning whatsoever**, and the log shows the
cache being read and applied:

```
[I] Calibration: .../Primary_Detector/cal_trt.bin
[I] Calibration Profile Index: 0
[I] Set calibration profile for input tensor input_1:0 to 1x3x544x960
[I] [TRT] Reading Calibration Cache for calibrator: EntropyCalibration2
[I] [TRT] Generated calibration scales using calibration cache.
[V] [TRT] INT8 Inference Tensor scales and zero-points: input_1:0 scale and
          zero-point Quantization(scale: {0.00787594,}, zero-point: {0,})
```

**211 tensors received INT8 scales** — every entry in the cache.

The scales were verified to come from the file rather than from a silent
recalibration. The cache's raw entry for `input_1:0` is the hex `3c010a14`, which
decoded as an IEEE-754 float is:

```
cache hex 3c010a14 -> 0.007875937968492508
TensorRT applied    -> 0.00787594
```

An exact match. No calibration dataset was needed or created.

## 5. Benchmark methodology

Build and benchmark are separate operations. Each engine was measured by loading
its saved plan (`--loadEngine`), at batch 1 with the same shape, warm-up,
duration, iteration floor and percentile set.

**The GPU clock cannot be locked on this machine** — `jetson_clocks` requires
root and no `sudo` is available. DVFS moves the GPU between 306 and 1020 MHz.
This could not be eliminated, so it was accounted for:

- **Interleaved round-robin** order (`fp32, fp16, int8` × 3), never grouped, so a
  monotonic drift cannot be mistaken for a property of one engine.
- **A discarded pre-heat run** before the first measurement. This was added after
  a short validation run exposed the problem directly: the GPU idles at 306 MHz,
  and the first three runs began at 306, 714 and 816 MHz respectively —
  systematically penalising whichever engine ran first. The pre-heat brought the
  clock from **306 MHz to 1020 MHz** before run 1.
- **Three repetitions per engine**, reporting spread rather than a single number.
- **A 30 s cool-down** between runs, with `tj` recorded around each.
- **`tegrastats` running throughout** (849 samples).
- **A process-isolation gate** that refuses to start if the GPU is more than 40%
  busy. Measured 3% at start.

Conditions during the benchmark: GPU load peaked at **99%**, `tj` ranged
**51.3–66.0 °C**, system RAM 3,105–3,329 MB, `VDD_IN` peaked at **20.6 W**.

## 6. Results

Nine measured runs of 60 s each. Median GPU compute time per repetition:

```
engine  GPU compute median (ms)           throughput (qps)            spread
        min / median / max of reps        min / median / max
--------------------------------------------------------------------------
fp32    12.688 / 12.695 / 14.488          71.4 / 78.7 / 78.8           1.801
fp16    3.215 / 3.218 / 3.508             287.0 / 309.8 / 310.1        0.293
int8    1.926 / 1.926 / 1.928             516.7 / 517.4 / 518.2        0.002

Speedup vs FP32 baseline (median GPU compute):
  fp32 -> fp16   3.95x   difference +9.478 ms   worst spread 1.801 ms  [resolved]
  fp32 -> int8   6.59x   difference +10.770 ms  worst spread 1.801 ms  [resolved]
```

**The comparison is resolved, not inconclusive.** The largest within-engine
spread (1.801 ms) is well under half the smallest between-engine difference
(9.478 ms), so run-to-run variation is clearly smaller than the effect measured.

**Repetition 1 is the sole source of that spread**, for both FP32 (14.488 ms) and
FP16 (3.508 ms). Repetitions 2 and 3 agree to within 0.1%:

| Engine | rep 2 | rep 3 | difference |
|---|---|---|---|
| FP32 | 12.6875 ms | 12.6953 ms | 0.008 ms |
| FP16 | 3.21484 ms | 3.21777 ms | 0.003 ms |
| INT8 | 1.92578 ms | 1.92773 ms | 0.002 ms |

The first pass through the sequence is a warm-up artefact of the *whole run*, not
of any engine. Using the median of three discards it automatically, which is why
the median was chosen over the mean.

### Full metrics, from the steady-state repetition

| Metric (rep 3) | FP32 | FP16 | INT8 |
|---|---|---|---|
| **GPU compute** median | 12.6953 ms | 3.21777 ms | 1.92773 ms |
| GPU compute p99 | 12.7715 ms | 3.28906 ms | 1.96875 ms |
| **End-to-end latency** median | 12.9463 ms | 3.5332 ms | 2.28906 ms |
| End-to-end p99 | 13.0273 ms | 3.62793 ms | 2.36133 ms |
| **Throughput** | 78.71 qps | 310.06 qps | 517.40 qps |
| Enqueue time median | 0.2617 ms | 0.2852 ms | 0.2656 ms |
| H2D latency median | 0.2383 ms | 0.2964 ms | 0.3379 ms |
| D2H latency median | 0.0117 ms | 0.0205 ms | 0.0234 ms |

### Why both compute and end-to-end are reported

| | FP32 | FP16 | INT8 |
|---|---|---|---|
| Speedup on **GPU compute** | 1.00× | **3.95×** | **6.59×** |
| Speedup on **end-to-end** | 1.00× | **3.66×** | **5.66×** |
| Transfer overhead | 0.251 ms | 0.315 ms | 0.361 ms |
| Overhead as % of end-to-end | 1.9% | 8.9% | **15.8%** |

Reduced precision shrinks compute but not the FP32 input transfer, which is
identical (1×3×544×960 float ≈ 6.3 MB) for all three. So the overhead is
approximately fixed while compute shrinks around it, and quoting only the compute
speedup would overstate the real-world gain — 6.59× becomes 5.66× once the data
actually has to move.

Measured H2D also *grew* slightly as compute shrank (0.238 → 0.296 → 0.338 ms)
even though the transfer is identical. The likely explanation is reduced overlap
between transfer and compute when compute is short, exposing more of the transfer
in the measurement. **This is an observation, not an established mechanism** — it
was not investigated further because it does not affect the comparison.

## 7. The conclusion that matters for this project

Milestone 2 established the source as 29.97 fps, giving a **33.37 ms per-frame
budget** for a single real-time camera:

| Engine | End-to-end latency | Budget used | Headroom |
|---|---|---|---|
| FP32 | 12.95 ms | 38.8% | 2.6× |
| FP16 | 3.53 ms | 10.6% | 9.4× |
| INT8 | 2.29 ms | 6.9% | **14.6×** |

**All three engines are comfortably real-time for one camera — including FP32.**

This reframes the precision decision. It is *not* a question of feasibility;
inference is not the bottleneck at any precision here. It is a question of how
much of the frame budget to leave for everything else the pipeline still has to
do in Milestone 5 and beyond: `nvstreammux`, the tracker, `nvdsanalytics`,
on-screen display, and any encoding or streaming.

Given that FP16 costs 10.6% of the budget against INT8's 6.9% — a 1.24 ms
difference on a 33.37 ms budget — the performance argument for INT8 over FP16 is
real but modest, while INT8 carries an unquantified accuracy risk (§8). **FP16 is
the recommended starting point for Milestone 5**, with INT8 held as a measured,
available option if the assembled pipeline turns out to need the headroom.

That recommendation rests on performance evidence plus an explicit acknowledgement
of unmeasured risk — not on a quality comparison, which has not been done.

## 8. What this milestone does NOT establish

**No claim is made that FP16 or INT8 preserves detection quality.** These
benchmarks measure computational performance only. `trtexec` feeds random input
tensors; it never saw a video frame, a person, or a bounding box.

The risk is concrete and asymmetric: the INT8 scales in `cal_trt.bin` were
calibrated by NVIDIA on **their** dataset. Whether they suit this project's
footage is entirely unmeasured. The FP16 engine carries far less risk, but "less
risk" is still not evidence.

Establishing quality would take three tiers of increasing cost:

1. **Raw tensor divergence** — feed byte-identical inputs to all three engines and
   compare `output_cov` and `output_bbox` numerically (max/mean absolute error,
   correlation) against FP32. Needs no labels, is deterministic, and isolates
   precision loss from all postprocessing. The correct first step.
2. **Detection agreement on video** — same decoded frames, identical clustering
   configuration; boxes matched by IoU against the FP32 reference, plus confidence
   drift and detections gained or lost.
3. **Absolute accuracy** — requires labelled ground truth, which **this project
   does not have.** The DeepStream sample clips ship unannotated.

The honest limit: without labels, only **divergence from the FP32 baseline** can
be measured, not correctness. FP32 is a reference, not truth — if FP32 misses a
person, an FP16 engine that agrees with it scores perfectly while both are wrong.

## 9. Known limitations

1. **The GPU clock could not be locked.** `jetson_clocks` needs root. Mitigated by
   pre-heat, interleaving and repetition, and the reproducibility of repetitions
   2 and 3 (<0.1%) is good evidence conditions were stable — but it is mitigation,
   not control.
2. **The per-run clock reading is indicative, not authoritative.** It is sampled
   from sysfs immediately after `trtexec` exits, so it can catch the GPU already
   ramping down. `tegrastats` records GPU *load*, not clock frequency in MHz.
3. **The desktop session shares the GPU.** Measured at 3% busy before the run and
   gated at 40%, but it is a standing background consumer that was not shut down.
4. **Memory figures are system-wide.** Jetson memory is unified and `nvidia-smi`
   reports `N/A` for GPU memory, so the 3,105–3,329 MB range is whole-system RAM
   during the benchmark, not a per-engine GPU allocation.
5. **The FP32↔FP16 comparison is baseline-versus-deployment**, by explicit
   decision (§1). It is not a controlled single-variable measurement of FP16.
6. **Batch 1 only.** Chosen deliberately for one real-time camera; these numbers
   say nothing about multi-stream throughput.
7. **Engines are not portable.** Bound to TensorRT 10.16.2, this GPU and this
   profile. Regenerate rather than copy.

## 10. Completion criteria

| Criterion | Status |
|---|---|
| FP32 engine built from the selected ONNX | Done — exit 0, 46.15 s, 9,443,956 B, 0 warnings |
| FP16 engine built | Done — exit 0, 67.65 s, 3,196,724 B |
| INT8 engine built using the shipped calibration cache | Done — exit 0, 153.19 s, 2,716,140 B, 211 scales applied |
| Calibration cache compatibility resolved empirically | Done — accepted with no version warning; scale verified against the file's own hex |
| Actual per-layer precisions inspected, not assumed | Done — §3; INT8 engine shown to be mixed Int8/Half |
| Fair comparison at identical shape and batch | Done — `min=opt=max=1x3x544x960` for all three |
| Spread reported; inconclusive results flagged | Done — §6; comparison resolved, rep-1 artefact identified |
| Build and benchmark kept separate | Done — `--skipInference` on builds, `--loadEngine` on benchmarks |
| TensorRT warnings preserved | Done — §2, all logs retained in `models/engines/` |
| No detection-accuracy claims | Done — §8 states explicitly what is not established |
| Reproducible from the repository | Done — four scripts, no manual steps |
