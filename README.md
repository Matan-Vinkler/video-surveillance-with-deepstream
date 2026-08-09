# Video Surveillance with DeepStream

**Real-time person detection and tracking on an NVIDIA Jetson Orin Nano**, built
from GStreamer, TensorRT and DeepStream.

A recorded video is replayed as a simulated camera — paced in real time, not
consumed as fast as the hardware allows — and every frame is run through a
TensorRT-optimised person detector. Each detected person is then given a
persistent identity that survives from frame to frame. Results are drawn on
screen and exposed as structured metadata, so they can be checked by a machine
rather than by eye.

Everything runs on the device. Nothing is downloaded at run time, no model is
trained, and no cloud service is involved.

---

## Pipeline

```mermaid
flowchart LR
    A["sample_walk.mov<br/>H.264 1080p 29.97 fps"]
    B["nvv4l2decoder<br/>NVDEC hardware decode"]
    C["nvstreammux<br/>batch = 1"]
    D["nvinfer<br/>TrafficCamNet FP16"]
    E["nvtracker<br/>NvSORT"]
    F["nvmultistreamtiler<br/>1x1"]
    G["nvdsosd<br/>boxes, labels, track ids"]
    H["nv3dsink<br/>or fakesink, headless"]
    I["detector dump<br/>class, confidence, box"]
    J["tracker dump<br/>+ object_id"]

    A --> B --> C --> D --> E --> F --> G --> H
    D -. "NvDsObjectMeta" .-> I
    E -. "+ object_id" .-> J
```

Frames stay in NVMM (NVIDIA hardware memory) from decode to display, so there is
no copy into system memory anywhere in the path.

## What it does

- **Simulates a camera** from a recorded clip, paced by the pipeline clock so it
  behaves like a live 30 fps source rather than a file being read at full speed.
- **Detects people** with TrafficCamNet, running as a TensorRT engine on the GPU.
- **Tracks each person across frames** with NvSORT, so a detection becomes an
  identity — the prerequisite for saying "*this* person entered the zone".
- **Draws bounding boxes, labels and track IDs** on screen, colour-coded per class.
- **Emits per-frame metadata twice** — once from the detector and once from the
  tracker — so correctness is asserted from data, never from "it looked right".
- **Verifies itself headlessly**: two commands run the whole pipeline with no
  display, check seventeen properties of the result, and exit non-zero on failure.

## Results

Detection and tracking on the default clip, at the model's stock reference
thresholds and NVIDIA's stock NvSORT configuration:

| | |
|---|---|
| Frames processed | **288 of 288** |
| `person` detections | **230**, across 230 frames (79.9%) |
| False positives | **zero** `car`, `bicycle` or `road_sign` in 288 frames |
| Confidence on the subject | 0.67 – 0.82 |
| Frames with a tracked person | **230 of 230** — every detection got an identity |
| Longest continuous track | **224 frames** (50 → 273), one unbroken ID |
| Mid-track ID switches | **zero** |
| Unique track IDs | 2 — one ID change, in the first 6 frames as the person enters |

The tracker is not credited with what this clip cannot test. There are **no
interior detector gaps**, so gap bridging, shadow tracking and occlusion recovery
were never invoked and are recorded as
[NOT EXERCISED](docs/milestone-05-tracking.md) rather than as passing.

Inference cost, measured per precision at batch 1, 960×544 (3 interleaved
repetitions each):

| Engine | GPU compute | End-to-end | Throughput | Size | Frame budget used |
|---|---|---|---|---|---|
| FP32 | 12.70 ms | 12.95 ms | 78.7 qps | 9.01 MiB | 38.8% |
| **FP16** *(default)* | **3.22 ms** | **3.53 ms** | **310.1 qps** | **3.05 MiB** | **10.6%** |
| INT8 | 1.93 ms | 2.29 ms | 517.4 qps | 2.59 MiB | 6.9% |

All three are comfortably real-time for one 29.97 fps camera (a 33.37 ms budget
per frame), so precision is a headroom decision rather than a feasibility one.
FP16 is the default; INT8 is built and benchmarked but held in reserve.

> These are **performance** figures. They say nothing about whether reduced
> precision preserves detection accuracy — that is a separate experiment, and the
> evidence it would require is
> [defined but not yet gathered](docs/milestone-04-tensorrt-optimization.md).

## Requirements

- **NVIDIA Jetson** with L4T and DeepStream. Developed on a Jetson Orin Nano,
  L4T R39.2, Ubuntu 24.04, DeepStream 9.1.0, TensorRT 10.16.2, CUDA 13.2.
- **GStreamer 1.x** with `gst-launch-1.0`, `gst-inspect-1.0`, `gst-discoverer-1.0`.
- **NVIDIA GStreamer elements**: `nvv4l2decoder`, `nvstreammux`, `nvinfer`,
  `nvtracker`, `nvmultistreamtiler`, `nvdsosd`, `nv3dsink`.
- A display, **only** for the visible playback commands. Everything else runs
  headlessly.

Nothing needs to be installed or downloaded. The model, the calibration data, the
tracker library, the tracker configuration and the sample video all ship with
DeepStream and are read from their install path.
The DeepStream version is discovered at run time through the
`/opt/nvidia/deepstream/deepstream` symlink, so no version is hard-coded anywhere.

## Quick start

```bash
# 1. Check the environment
./scripts/common.sh --selftest        # GStreamer, DeepStream, elements, display
./scripts/trt_common.sh --selftest    # TensorRT toolchain and model assets

# 2. Build the TensorRT engines (~4.5 min; one-off)
./scripts/build_engines.sh --precision all

# 3. Run detection and tracking, and verify both headlessly
./scripts/ds_common.sh --selftest
./scripts/verify_inference.sh       # detection
./scripts/verify_tracking.sh        # identity across frames

# 4. Watch it, if a display is attached
./scripts/run_inference.sh
```

If `DISPLAY` is unset in your shell but a desktop session is running on the
console, point at it explicitly:

```bash
DISPLAY=:1 ./scripts/run_inference.sh
```

The window opens on the physically attached monitor, not in an SSH client.

## Usage

**Inference and tracking**

| Command | What it does |
|---|---|
| `./scripts/run_inference.sh` | Visible detection and tracking with boxes and IDs, paced in real time |
| `./scripts/verify_inference.sh` | Headless detection run with eight machine-checked assertions |
| `./scripts/verify_tracking.sh` | Headless tracking run: four pipelines, nine checks, and a full identity report |

**Model and engines**

| Command | What it does |
|---|---|
| `./scripts/inspect_model.sh` | Reports the model's input/output contract and INT8 calibration coverage. Builds nothing |
| `./scripts/build_engines.sh --precision fp16` | Builds one engine (`fp32`, `fp16`, `int8` or `all`) and verifies the artifact |
| `./scripts/engine_report.sh` | Reports what an engine **actually** is — the per-layer precisions TensorRT selected, not the ones requested |
| `./scripts/benchmark_engines.sh` | Interleaved, repeated precision comparison with spread reporting |

**Video source**

| Command | What it does |
|---|---|
| `./scripts/inspect_video.sh [--caps]` | Container, codec, resolution, frame rate, duration; `--caps` dumps negotiated caps per link |
| `./scripts/run_simulated_stream.sh [--loop]` | Visible playback of the source alone, no inference |
| `./scripts/verify_simulated_stream.sh` | Headless check of frame flow and real-time pacing |

Two sources are available: `sample_walk.mov` (default — one person walking,
9.61 s) and `sample_1080p_h264.mp4` (`--crowded` — many pedestrians, a cyclist and
traffic, 48.10 s). Both are H.264 in an ISO-BMFF container, so the same pipeline
serves both unchanged.

## How it works

**Simulated camera.** Nothing about a file is inherently real-time. The pacing
comes from clock synchronisation at the sink: each decoded frame is held until its
presentation timestamp arrives, which back-pressures the decoder and the file
reader until the whole pipeline settles at the clip's natural frame rate. Proven
by measurement — 9.80 s paced against a 9.61 s clip, versus 1.53 s unpaced.
[Full detail →](docs/milestone-02-video-input.md)

**Detection model.** TrafficCamNet is a DetectNet_v2 detector on a pruned ResNet18
backbone. It is fully convolutional with no anchor boxes and no NMS inside the
network: for each cell of a 60×34 grid it predicts a per-class confidence and four
box-edge offsets. Clustering those overlapping predictions into single detections
happens outside the model, in DeepStream, and is configurable.
[Full detail →](docs/milestone-03-model-selection.md)

**Precision.** The ONNX model is compiled into TensorRT engines at FP32, FP16 and
INT8. INT8 uses the calibration cache NVIDIA ships, so no calibration dataset is
needed. Engines are treated as build artifacts, never committed — one is valid
only for the TensorRT version, GPU and batch profile that produced it.
[Full detail →](docs/milestone-04-tensorrt-optimization.md)

**Inference pipeline.** `nvstreammux` batches frames and attaches the metadata
structure; `nvinfer` preprocesses, runs the engine and attaches one
`NvDsObjectMeta` per detection; `nvdsosd` draws them. The 1×1 tiler looks
redundant with a single source but is required — without a fresh buffer upstream,
the OSD draws in place and previous frames' boxes persist as a visible trail.
[Full detail →](docs/milestone-05-inference-pipeline.md) ·
[the ghosting investigation →](docs/milestone-05-osd-ghosting.md)

**Tracking.** DeepStream 9.1 ships a single tracker library; the backend is
chosen entirely by the YAML handed to it. NvSORT was picked over the simpler IOU
tracker because IOU has no motion model at all, and over NVIDIA's default NvDCF
because NvDCF's appearance matching cannot be tested on a clip with one person
who is never occluded. NVIDIA's configuration is used exactly as installed.
Identity is asserted from the tracker's own metadata dump: the criterion is zero
ID switches *mid-track*, not a coverage percentage, because only a break in the
middle of a trajectory would defeat zone logic.
[Full detail →](docs/milestone-05-tracking.md)

## Verification

Two headless suites. Neither needs a display, both terminate on their own, and
both exit non-zero on any failure. All evidence comes from per-frame metadata
dumps, so a passing run is a statement about data rather than about appearance.

**`./scripts/verify_inference.sh` — detection**

1. The application runs to a clean end of stream.
2. The prebuilt engine was **deserialized, not rebuilt** — checked in the log and
   by an unchanged checksum.
3. Every frame in the clip was decoded and processed.
4. Batch size is 1 end to end, with no engine/config capability mismatch.
5. `nvinfer` reports no configuration or parser errors.
6. `person` detections exist, with raw per-class counts reported.
7. `class_id 2` really is `person` — proven by re-running with the other classes
   filtered out, so anything surviving is class 2 by construction.
8. No analytics metadata exists.

**`./scripts/verify_tracking.sh` — identity.** Four pipeline runs, nine checks:

1. Clean end of stream.
2. `nvtracker` is genuinely instantiated, and no obsolete config keys are used.
3. The engine is still deserialized, not rebuilt.
4. Both the detector and tracker dumps cover all 288 frames.
5. **The tracker did not change detection** — a control run with the tracker
   disabled produces a detector dump differing on 0 of 288 frames.
6. Every tracked object carries a valid `object_id`, never `UNTRACKED_OBJECT_ID`.
7. **Zero mid-track ID switches** while the detector observes the person
   continuously. Unique IDs and dominant-ID coverage are reported as metrics, not
   as the criterion.
8. A missing tracker **library** is fatal, a missing tracker **config** is not —
   DeepStream silently falls back to defaults, so the real run is checked for the
   absence of that warning. Otherwise a typo would substitute a different tracker
   and every other check would still pass.
9. No analytics yet.

It also prints a full identity report: per-track lifespans, the longest
continuous track, when the track was established, and an explicit list of the
capabilities this clip did **not** exercise.

## Project structure

```
├── configs/     DeepStream application and nvinfer configuration
├── scripts/     Inspection, build, run and verification scripts
├── docs/        Design notes, investigations and verification records
├── models/      Generated TensorRT engines (git-ignored) + rationale
└── media/       Video sources are read from DeepStream, never committed
```

## Documentation

| Topic | Document |
|---|---|
| Video input and real-time pacing | [`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md) |
| Model selection and DetectNet_v2 internals | [`docs/milestone-03-model-selection.md`](docs/milestone-03-model-selection.md) |
| TensorRT optimisation and benchmarks | [`docs/milestone-04-tensorrt-optimization.md`](docs/milestone-04-tensorrt-optimization.md) |
| Inference pipeline | [`docs/milestone-05-inference-pipeline.md`](docs/milestone-05-inference-pipeline.md) |
| The OSD ghosting investigation | [`docs/milestone-05-osd-ghosting.md`](docs/milestone-05-osd-ghosting.md) |
| Object tracking | [`docs/milestone-05-tracking.md`](docs/milestone-05-tracking.md) |
| Engineering roadmap and decisions | [`PLAN.md`](PLAN.md) |

Each document records not just what was built but **why**, along with the
verification evidence and an explicit statement of what remains unproven.

## Roadmap

Person detection and tracking work end to end. Restricted-zone analytics is next,
followed by containerisation and deployment — see [`PLAN.md`](PLAN.md).

## Third-party assets

The detection model, its INT8 calibration cache, the low-level tracker library,
the NvSORT tracker configuration and the sample videos are **NVIDIA DeepStream
SDK assets**, read from their install path on the target machine and never
redistributed here. The tracker configuration in particular is referenced in
place and used unmodified — copying it into this repository would silently fork a
vendor file that can drift. They are covered by the DeepStream SDK
licence, not by this project. See [`media/README.md`](media/README.md) and
[`models/README.md`](models/README.md).
