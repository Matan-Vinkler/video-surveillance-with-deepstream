# Inspection report — TensorRT optimisation milestone

Read-only inspection of the Jetson environment and the selected model, carried
out before any engine was built. Every claim is backed by command output; no
file was created, downloaded or installed to produce it, no package was
installed, and neither the power mode nor the clocks were changed.

Dated record of the inspection phase. Corrections discovered during
implementation are appended as an [Addendum](#addendum-corrections-from-the-implementation-phase);
the body is not rewritten.

---

## 1. Environment findings

| Item | Value | Evidence |
|---|---|---|
| TensorRT | **10.16.2.10** | `dpkg -l`, `tensorrt.__version__` |
| `trtexec` | `/usr/bin/trtexec`, banner `TensorRT v101602 [b10]` | `command -v`, `--help` |
| CUDA | 13.2.1 (nvcc 13.2.78), driver 595.78 | `nvcc --version`, `version.json` |
| Disk | 70 GB available of 116 G | `df -h` |
| RAM | 7.3 GiB unified, ~4.7 GiB available | `free -h` |
| Swap | **none configured (0 B)** | `swapon --show` |
| Power mode | `MAXN_SUPER` (mode 2) — **not changed** | `nvpmodel -q` |
| GPU clock | 306–1020 MHz, governor `nvhost_podgov` | devfreq sysfs |
| FP16 | **supported** (`platform_has_fast_fp16 = True`) | TensorRT builder query |
| INT8 | **supported** (`platform_has_fast_int8 = True`) | TensorRT builder query |
| DLA | **none** (`num_DLA_cores = 0`) | TensorRT builder query |

Four findings shaped the plan:

- **There is no DLA on Orin Nano.** Every engine is GPU-only; `--useDLACore` is
  not an option on this board.
- **The GPU clock cannot be locked.** `jetson_clocks` exists but applying it
  requires root, and no `sudo` is available here. DVFS will move the GPU across
  its full range during any measurement. This cannot be eliminated — only
  measured and accounted for.
- **`nvidia-smi` reports no memory or utilisation on Jetson** (`Not Supported`,
  `N/A`). GPU memory is unified with system RAM. `tegrastats` is therefore the
  only usable instrument, and it runs as a normal user with `--logfile`.
- **There is no swap.** An out-of-memory event during a build would be a hard
  kill rather than a slowdown, which is why the builder workspace is capped.

DeepStream 9.1's own README states CUDA 13.0 / TensorRT 10.13 as its baseline.
The installed CUDA 13.2.1 and TensorRT 10.16.2 are both *ahead* of that. Recorded
as an assumption to test at build time rather than asserted as safe.

## 2. Model findings

```
/opt/nvidia/deepstream/deepstream-9.1/samples/models/Primary_Detector/
├── resnet18_trafficcamnet_pruned.onnx   5,365,751 B  sha256 d92f97bd…6bab7d
├── cal_trt.bin                              8,630 B  sha256 97af95a4…82604a
└── labels.txt                                  29 B  car bicycle person road_sign
```

The directory is **root-owned and not writable**, so engines cannot be written
where DeepStream's stock configuration expects them. See
[`../models/README.md`](../models/README.md).

Verified with TensorRT's own ONNX parser (parse only — `build_serialized_network()`
was never called, and no engine was produced):

```
parse succeeded : True        parser errors : 0
input   'input_1:0'              (-1, 3, 544, 960)   FLOAT
output  'output_cov/Sigmoid:0'   (-1, 4, 34, 60)     FLOAT
output  'output_bbox/BiasAdd:0'  (-1, 16, 34, 60)    FLOAT
210 layers: ELEMENTWISE 77, CONSTANT 69, CONVOLUTION 27, SHUFFLE 19, ACTIVATION 18
```

- **No plugins and no unsupported operators** — the parser resolved the whole
  graph with zero errors.
- **Dynamic in batch only.** The `-1` batch dimension obliges an optimisation
  profile; the spatial dimensions are fixed at 544×960.
- **No pooling layer.** This DetectNet_v2 ResNet18 downsamples with strided
  convolutions.

An independent `strings`-based operator scan agreed exactly: Add 52 + Mul 25 = 77
ELEMENTWISE, 17 Relu + 1 Sigmoid = 18 ACTIVATION, 27 Conv = 27 CONVOLUTION. Two
methods, same answer.

## 3. The calibration cache

The highest-risk unknown, so it was checked rather than assumed. `cal_trt.bin`
is plain ASCII in TensorRT's standard format:

```
TRT-100300-EntropyCalibration2
input_1:0: 3c010a14
conv1/convolution:0: 3d0b7086
…
output_bbox/BiasAdd:0: 3da418a9
```

Every cache key was diffed against every activation tensor in the freshly parsed
network:

```
network activation tensors  : 142
IN NETWORK BUT NOT IN CACHE : 0     ← every required scale is present
IN CACHE BUT NOT IN NETWORK : 69    ← stale Reshape__*/ONNXTRT_Broadcast_* keys
```

Zero missing scales, so an INT8 build should need no calibration dataset. The 69
unused keys are constant-folding artefacts of the older parse — and 69 is exactly
the CONSTANT layer count, which is a useful cross-check.

**The residual uncertainty:** the header records TensorRT 10.3.0 but the runtime
is 10.16.2. Static inspection cannot establish whether this runtime accepts a
cache written by that one. Recorded as an empirical question to be answered by an
actual build, with the agreed rule that a rejection is captured and documented
and the INT8 phase stops — no improvised calibration dataset.

Reproduce with `./scripts/inspect_model.sh`.

## 4. A syntax trap worth recording

The input tensor is named **`input_1:0`**, and `trtexec` shape specs are
themselves colon-delimited. The help text resolves it:

> *Note: Input names can be wrapped with escaped single quotes (ex: 'Input:0').*

So the name must carry literal single quotes into the argument:

```
--optShapes="'input_1:0':1x3x544x960"
```

Getting this wrong produces a confusing parse error rather than an obvious one.

## 5. Decisions taken before implementation

| Decision | Rationale |
|---|---|
| Batch **1**, `min=opt=max` | One real-time camera. Not optimised for hypothetical multi-stream work |
| FP32 built with `--noTF32` | TensorRT enables TF32 by default on Ampere, so an unqualified "FP32" build is really TF32. This makes the baseline genuine |
| FP16 built **without** `--noTF32` | A deployment engine, not a controlled experiment: layers the builder leaves out of FP16 should fall back the way a real deployment would |
| INT8 built as `--int8 --fp16` | Deployment-realistic: INT8 where TensorRT selects it, FP16 as fallback rather than FP32 |
| Build and benchmark kept separate | `--skipInference` on builds, `--loadEngine` on benchmarks, so builder work cannot perturb a timing |
| No timing cache | Sharing one across precisions would make build-time comparison meaningless |
| Engines generated locally, git-ignored | An engine is bound to TensorRT version, GPU and profile; committing one would be committing an unusable, unverifiable binary |
| `common.sh` left untouched | It belongs to the completed video-input milestone. M4 helpers live in `trt_common.sh`, which sources it |

## 6. Risks identified before starting

1. **Calibration cache version mismatch** — mitigated by the coverage diff;
   resolvable only empirically.
2. **DVFS cannot be locked** — the largest threat to fair measurement.
3. **Thermal drift** across a long benchmark sequence.
4. **The desktop session shares the GPU** — a standing background consumer.
5. **Zero swap** with 4.7 GiB free — capped via `--memPoolSize`.
6. **"FP32" silently meaning TF32** — addressed with `--noTF32`.
7. **`--fp16`/`--int8` mean "allow", not "force"** — the engine must be inspected,
   not assumed.
8. **INT8 quality is unvalidated on this project's footage** — the shipped scales
   were calibrated by NVIDIA on their data. Explicitly out of scope here.

---

## Addendum: corrections from the implementation phase

Two expectations recorded above needed correction during implementation. Both are
covered in [`milestone-04-tensorrt-optimization.md`](milestone-04-tensorrt-optimization.md).

**1. `--exportLayerInfo` alone does not report per-layer precisions.**
The plan called for exporting layer information to establish which precisions
were actually selected. `--profilingVerbosity` defaults to `layer_names_only`,
which emits names and nothing else. **`--profilingVerbosity=detailed` is
required**, and was added to all three builds before any engine was built. It
embeds extra metadata in the engine, so absolute engine sizes are slightly
inflated — applied uniformly, so size comparisons remain valid.

**2. The benchmark methodology needed a GPU pre-heat.**
Risk 2 proved sharper than anticipated. A short validation run showed the GPU
idling at its 306 MHz minimum and ramping across the sequence — 306 MHz for the
first run, 714 MHz for the second, 816 MHz for the third. The 30 s cool-down,
intended to equalise *thermal* conditions, actively defeats *clock* equality by
letting the GPU return to idle between runs. Whichever engine ran first was
systematically penalised.

Two changes were made before the measured benchmark: a discarded pre-heat run
before the first measurement, and per-run recording of the GPU clock sampled
immediately after each run (before the cool-down), so the clock each run actually
experienced is reported as measured data rather than assumed constant.
