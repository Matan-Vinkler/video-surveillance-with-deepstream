# PLAN.md

Engineering roadmap. Living document — updated after every completed milestone.

For *how* to work in this repository, see [`CLAUDE.md`](CLAUDE.md).
For usage, see [`README.md`](README.md).

---

## 1. Objective

Build a video-surveillance system on an NVIDIA Jetson Orin Nano that detects
**people in a restricted zone**, from video input through optimised inference to
a deployed, containerised, monitored edge application.

The project is as much a learning exercise as a deliverable: each milestone must
be understood and explained, not merely made to work.

**Capstone-level success:** a reproducible, documented, deployed edge application
performing person detection on a video stream, with its engineering decisions and
verification evidence recorded.

---

## 2. Architecture summary

Target end state, and where the work currently sits:

```
  video input  ──►  inference  ──►  tracking  ──►  analytics  ──►  output
   [DONE M2]      [DONE M3-M5.1]   [DONE M5.2]    [DONE M5.3]      [M9]
             all of the above now also runs containerised  [DONE M6]
       │                │               │              │             │
  DeepStream:      TrafficCamNet FP16   NvSORT via   restricted   monitoring,
  source ! decoder   TensorRT engine    nvtracker    zone via     logging
  ! nvstreammux      via nvinfer        -> object_id nvdsanalytics
  ! nvinfer          -> NvDsObjectMeta               -> in/out
  ! nvtracker
  ! nvdsanalytics
  ! nvmultistreamtiler
  ! nvdsosd ! sink
```

Currently implemented: **the full detection → tracking → restricted-zone path**.
A recorded video is replayed as a simulated camera (M2), TrafficCamNet was
selected (M3) and optimised into TensorRT engines (M4), the FP16 engine runs on
that source through `deepstream-app` producing verified `person` metadata and
on-screen bounding boxes (M5 checkpoint 1), those detections carry a persistent
`object_id` (M5 checkpoint 2), and the application now determines whether that
tracked person is inside a restricted zone (M5 checkpoint 3).

**Milestones 5 and 6 are complete.** The application now runs containerised,
with detector and tracker metadata byte-identical to the host-native run.

Pipeline detail and rationale: [`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md).
Engine detail and benchmarks: [`docs/milestone-04-tensorrt-optimization.md`](docs/milestone-04-tensorrt-optimization.md).
Inference pipeline: [`docs/milestone-05-inference-pipeline.md`](docs/milestone-05-inference-pipeline.md).
Tracking: [`docs/milestone-05-tracking.md`](docs/milestone-05-tracking.md).
Restricted zone: [`docs/milestone-05-restricted-zone.md`](docs/milestone-05-restricted-zone.md).

---

## 3. Project Progress

Milestones follow the capstone structure. Project progress tracks *deliverables*;
learning progress (§7) is tracked separately.

- [x] **1. Define Use Case**
- [x] **2. Collect or Simulate Video Input**
- [x] **3. Select Pretrained Model**
- [x] **4. Optimize Model using TensorRT**
- [x] **5. Build DeepStream Inference Pipeline**
- [x] **6. Containerize the Application**
- [ ] **7. Deploy Inference with Triton Inference Server** ← next (blocked, see §10)
- [ ] **8. Deploy on Edge Device (Jetson)**
- [ ] **9. Monitoring and Logging**
- [ ] **10. Final Report and Deliverables**

| № | Milestone | Status | Documentation |
|---|---|---|---|
| 1 | Define Use Case | Complete | §5 below (no artifacts in this repo) |
| 2 | Collect or Simulate Video Input | Complete | [`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md), [`docs/milestone-02-inspection.md`](docs/milestone-02-inspection.md) |
| 3 | Select Pretrained Model | Complete | [`docs/milestone-03-model-selection.md`](docs/milestone-03-model-selection.md) |
| 4 | Optimize Model using TensorRT | Complete | [`docs/milestone-04-tensorrt-optimization.md`](docs/milestone-04-tensorrt-optimization.md), [`docs/milestone-04-inspection.md`](docs/milestone-04-inspection.md) |
| 5 | Build DeepStream Inference Pipeline | **Complete** — all 3 checkpoints | [`docs/milestone-05-inference-pipeline.md`](docs/milestone-05-inference-pipeline.md), [`docs/milestone-05-tracking.md`](docs/milestone-05-tracking.md), [`docs/milestone-05-restricted-zone.md`](docs/milestone-05-restricted-zone.md), [`docs/milestone-05-osd-ghosting.md`](docs/milestone-05-osd-ghosting.md), [`docs/milestone-05-inspection.md`](docs/milestone-05-inspection.md) |
| 6 | Containerize the Application | **Complete** | [`docs/milestone-06-containerization.md`](docs/milestone-06-containerization.md) |
| 7 | Deploy Inference with Triton | Not started — **blocked**, see §10 | — |
| 8 | Deploy on Edge Device (Jetson) | Not started | — |
| 9 | Monitoring and Logging | Not started | — |
| 10 | Final Report and Deliverables | Not started | — |

---

## 4. Current milestone

**Milestone 6 is complete.** The application is containerised and verified
against the host-native baseline: **0 of 288 per-frame files differ** in both the
detector and tracker dumps, and the restricted-zone result is unchanged (entry
109, 75 frames, exit 183). Full record:
[`docs/milestone-06-containerization.md`](docs/milestone-06-containerization.md).

The one deliberate deviation is recorded there in full: the container's
TensorRT was upgraded 10.16.1 → 10.16.2 to match the host, so the existing FP16
engine is reused rather than a second one built. That is what makes a
byte-identical comparison possible at all.

---

### Milestone 5 (complete, all 3 checkpoints)

| # | Checkpoint | Status |
|---|---|---|
| 5.1 | Inference pipeline producing visible person detections | **Complete** |
| 5.2 | Tracking (`nvtracker`) — object identity across frames | **Complete** |
| 5.3 | Restricted-zone analytics (`nvdsanalytics`) | **Complete** |

**Checkpoint 1 delivered:** `deepstream-app` running the FP16 engine on
`sample_walk.mov`, producing 230 verified `person` detections across 288 frames
and visible bounding boxes. Verified headlessly against detection metadata, not
appearance. Full record:
[`docs/milestone-05-inference-pipeline.md`](docs/milestone-05-inference-pipeline.md).

**Checkpoint 2 delivered:** `nvtracker` running NVIDIA's NvSORT configuration,
used exactly as installed. Every one of the 230 detected frames carries a tracked
object with a valid `object_id`; one track holds for **224 consecutive frames**
with **zero mid-track ID switches**. Detection is provably unchanged — a control
run with the tracker disabled differs on 0 of 288 frames. Full record:
[`docs/milestone-05-tracking.md`](docs/milestone-05-tracking.md).

Two things checkpoint 2 deliberately did *not* claim: the clip has **no interior
detector gaps**, so gap bridging, shadow tracking and occlusion recovery were
recorded as **NOT EXERCISED**; and the single ID change that did occur, in the
first six frames as the person enters at the image border, is characterised but
**not explained** — nothing was tuned around it.

**Checkpoint 3 delivered:** one ROI-filtering zone, with geometry derived from
the measured track rather than chosen. The walker enters at **frame 109**, stays
**75 consecutive frames (2.50 s)**, exits after **frame 183** and remains tracked
for **90 more**. DeepStream's own `NvDsAnalyticsFrameMeta` confirms it, and
agrees with an independent recomputation on **100% of 230 frames**. Detection and
tracking are provably unchanged (0 of 288 frames differ). Full record:
[`docs/milestone-05-restricted-zone.md`](docs/milestone-05-restricted-zone.md).

Checkpoint 3 needed the project's **first code**: `deepstream-app` can run
`nvdsanalytics` but cannot report it, so `tools/analytics_probe.cpp` reads the
ROI verdict back. It is test equipment, cross-checked against `deepstream-app`
rather than trusted, and `deepstream-app` remains the application.

Carried forward:

- **FP16 remains the default.** INT8 stays available if the added stages consume
  enough of the 33.37 ms frame budget to justify revisiting it.
- **The 1x1 tiler is load-bearing**, not decoration — removing it reintroduces the
  OSD trail ([detail](docs/milestone-05-osd-ghosting.md)).
- **A bad `ll-config-file` fails silently.** DeepStream warns and falls back to
  tracker defaults, so a typo would substitute a different backend without any
  error. The verification guards it; DeepStream does not
  ([detail](docs/milestone-05-tracking.md) §7).
- **A bad analytics `config-file` fails LOUDLY**, unlike the tracker's — a useful
  asymmetry to remember ([detail](docs/milestone-05-restricted-zone.md) §9).
- **End-to-end pipeline throughput is unmeasured.** M4 benchmarked the engine in
  isolation. The assembled pipeline now contains a tracker and analytics as well,
  so a throughput figure is no longer only an inference cost.
- **The probe diverges from deepstream-app on 10 early frames**
  ([detail](docs/milestone-05-restricted-zone.md) §6) — bounded and far from the
  ROI, mechanism unproven.

Out of scope until explicitly opened: Triton, Docker, MQTT, monitoring.

---

## 5. Completed milestones

### Milestone 1 — Define Use Case

- Selected **"Person Detection in a Restricted Zone"** as the surveillance scenario
- Defined the expected system behaviour
- Established **object detection** as the required AI task
- Chose the scenario because it aligns naturally with the later DeepStream,
  TensorRT, tracking and Triton milestones

*Predates this repository; no artifacts committed.*

### Milestone 2 — Collect or Simulate Video Input

- Simulated camera stream built from a recorded DeepStream sample replayed through
  an **explicit** GStreamer pipeline (no `playbin`)
- Source: `sample_walk.mov` (H.264 Main, 1920×1080, 29.97 fps, 9.61 s, one person
  walking); `sample_1080p_h264.mp4` retained as a crowded-scene option
- **Real-time pacing verified by measurement**, not assertion: 9.80 s paced vs
  9.610 s actual duration, against 1.53 s unpaced
- Bounded headless verification with exact frame accounting (`rendered: N, dropped: 0`)
- Visible playback with continuous looping; headless verification stays bounded
- 13/13 checks pass from a clean environment, positive and negative cases
- No inference component added

Full record: [`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md).
Inspection-phase record: [`docs/milestone-02-inspection.md`](docs/milestone-02-inspection.md).

### Milestone 3 — Select Pretrained Model

- Surveyed every locally installed detector, the TAO catalogue, and the YOLO
  integration paths available in DeepStream 9.1
- Selected **TrafficCamNet** (`resnet18_trafficcamnet_pruned.onnx`, DetectNet_v2,
  pruned ResNet18) — chosen on **engineering suitability, not benchmark
  accuracy**: already on disk, no download, no NGC credentials, no custom parser
  to compile, no `sudo`, and `person` is a native output class
- Documented the input/output contract by parsing the model, not by assumption
- **PeopleNet recorded as the upgrade target** — purpose-built for people and,
  critically, the *same* DetectNet_v2 output contract, so switching is a config
  change rather than an integration project. Blocked today: `nvcr.io` returns 401
- Found that **YOLOv8/YOLO11 detection is not supported in DeepStream 9.1** — the
  only YOLO11 parser shipped is oriented-bounding-box, which would mis-decode an
  axis-aligned model
- Found that **`nvinferserver` is unusable on this machine** (`libtritonserver.so`
  absent, setup needs root) — a risk carried forward to M7

Full record: [`docs/milestone-03-model-selection.md`](docs/milestone-03-model-selection.md).
*Investigation milestone; no code produced. Its document was written
retrospectively during M4 and says so.*

### Milestone 4 — Optimize Model using TensorRT

- Built **FP32, FP16 and INT8** engines at batch 1, `1x3x544x960`, identical
  optimisation profile, all verified against their exported layer information
- FP32 uses `--noTF32` so the baseline is genuinely FP32; TensorRT enables TF32 by
  default on Ampere, which would have silently made "FP32" a 10-bit mantissa
- **The shipped INT8 calibration cache worked** despite a TensorRT 10.3 header on
  a 10.16 runtime — accepted with no version warning, 211 scales applied, verified
  by decoding the cache's own hex against the scale TensorRT reported
- **The INT8 engine is mixed, not uniformly INT8**: 16 `Int8` weight tensors and
  11 `Half`, with every FP16 layer in the deep blocks or the two detection heads.
  Established by inspection — `--fp16`/`--int8` mean *allow*, not *force*
- Measured, interleaved, 3 repetitions per engine, spread reported:
  **FP32 12.70 ms, FP16 3.22 ms, INT8 1.93 ms** GPU compute (3.95× and 6.59×)
- **All three are real-time for one 29.97 fps camera** — FP32 uses 38.8% of the
  frame budget, FP16 10.6%, INT8 6.9%. Precision is a headroom decision, not a
  feasibility one
- **No detection-quality claim made** — `trtexec` never saw a video frame

Full record: [`docs/milestone-04-tensorrt-optimization.md`](docs/milestone-04-tensorrt-optimization.md).
Inspection-phase record: [`docs/milestone-04-inspection.md`](docs/milestone-04-inspection.md).

---

## 6. Future milestones

Deliberately thin — detail is added when a milestone is opened.

| № | Milestone | Expected focus |
|---|---|---|
| 6 | Containerize the Application | Reproducible image for the Jetson target |
| 7 | Deploy with Triton | Model serving, `nvinferserver` |
| 8 | Deploy on Edge Device | Standalone operation on the Jetson |
| 9 | Monitoring and Logging | Metrics, event output, observability |
| 10 | Final Report | Consolidated deliverables |

---

## 7. Learning Progress

Cumulative learning log. Grows as each milestone completes. Tracked separately
from project progress (§3) — a delivered milestone and a mastered concept are
related but not identical.

**From Milestone 1 — Define Use Case**

- [x] Requirements engineering
- [x] Image classification vs. object detection
- [x] AI task selection
- [x] Relationship between use case, model selection, and application logic

**From Milestone 2 — Video Input**

- [x] GStreamer fundamentals
- [x] Pipeline architecture
- [x] Elements
- [x] Pads (static vs. dynamic)
- [x] Caps negotiation
- [x] Container vs. codec
- [x] Demuxing
- [x] Parsing (`avc` vs. Annex-B `byte-stream`)
- [x] Hardware decoding (NVDEC)
- [x] NVMM zero-copy memory
- [x] Real-time pacing (clock sync and back-pressure)

**From Milestone 3 — Select Pretrained Model**

- [x] Model selection against engineering constraints, not leaderboards
- [x] DetectNet_v2 architecture: dense grid regression, no anchors, no in-graph NMS
- [x] Coverage vs bbox output heads; stride-16 grid; `bboxNorm` decode
- [x] Why clustering (NMS/DBSCAN) is mandatory for this output shape
- [x] Positional class↔channel mapping and its fragility
- [x] Model formats `nvinfer` accepts; where custom bbox parsers are needed
- [x] Reading an ONNX contract from the model rather than from documentation

**From Milestone 4 — Optimize using TensorRT**

- [x] ONNX → TensorRT engine build; the engine as a non-portable artifact
- [x] Optimisation profiles and why a dynamic batch dimension requires one
- [x] TF32 as an Ampere default, and why it invalidates a naive FP32 baseline
- [x] `--fp16`/`--int8` mean *allow*, not *force*; per-layer autotuning
- [x] INT8 post-training quantisation via an entropy calibration cache
- [x] Reading calibration scales and verifying them against the cache bytes
- [x] Separating build from benchmark; why timing caches break build-time comparison
- [x] Benchmarking under uncontrollable DVFS: pre-heat, interleaving, spread
- [x] GPU compute time vs end-to-end latency, and when each misleads
- [x] Distinguishing performance measurement from accuracy validation

**From Milestone 5 — Inference Pipeline (checkpoint 1)**

- [x] `deepstream-app` configuration model: `[source]`, `[streammux]`,
      `[primary-gie]`, `[tiled-display]`, `[osd]`, `[sink]`
- [x] `nvstreammux` batching, and why its width/height is the source resolution
      rather than the network input size
- [x] Where `NvDsBatchMeta` first appears and where `NvDsObjectMeta` is attached
- [x] Loading a prebuilt engine into `nvinfer` and preventing a silent rebuild
- [x] `checkBackendParams`: how nvinfer validates an engine against config
- [x] KITTI metadata dump as machine-verifiable detection evidence
- [x] Proving a class mapping by experiment (`filter-out-class-ids`) rather than
      by reading source
- [x] GStreamer caps negotiation as a *runtime* fact: an element's presence does
      not imply it converts anything
- [x] `nvdsosd` process modes, and why in-place drawing without a fresh buffer
      produces rendering artifacts
- [x] That metadata-level tests can pass while rendered output is visibly wrong

**From Milestone 5 — Tracking (checkpoint 2)**

- [x] DeepStream 9.1 ships one tracker library; the backend is chosen entirely
      by the YAML given to `ll-config-file`
- [x] IOU vs NvSORT vs NvDCF: motion model, appearance model, and what each
      actually costs
- [x] Which backends need assets that are not installed (ReID, SAM2), and how to
      establish that before choosing one
- [x] `object_id`, `UNTRACKED_OBJECT_ID`, and `tracker_bbox_info` vs
      `detector_bbox_info`
- [x] `probationAge`, `maxShadowTrackingAge`, `earlyTerminationAge` — and that a
      probational target is still emitted into `NvDsObjectMeta`
- [x] That `deepstream-app` attaches four different KITTI probes at four
      different points, which is what lets one run compare pre- and post-tracker
      metadata
- [x] Designing a tracking criterion that distinguishes track *establishment*
      from a mid-track ID switch, instead of a coverage percentage
- [x] Reporting untested capabilities as NOT EXERCISED rather than as passing
- [x] That a missing `ll-config-file` only warns — a silent backend substitution,
      and why the verification asserts the *absence* of a warning
- [x] That obsolete config keys (`enable-batch-process`, `enable-past-frame`) are
      silently ignored rather than rejected

**From Milestone 5 — Restricted zone (checkpoint 3)**

- [x] `nvdsanalytics` rule types, group naming (`roi-filtering-stream-<id>`) and
      the `roi-<label>` key whose label keys all downstream metadata
- [x] ROI coordinates as pixels against a declared `config-width`/`config-height`,
      rescaled to the surface at context creation
- [x] That the ROI test point is the **feet** (`centroid_y + mean_height/2`), not
      the centroid — and how to design an ROI that proves which is used
- [x] That occupancy is history-dependent through a 50-frame smoothed height
- [x] `NvDsAnalyticsObjInfo` / `NvDsAnalyticsFrameMeta`, and that analytics only
      annotates — it never removes objects, despite NVIDIA's sample comment
- [x] That `deepstream-app` can RUN analytics but cannot REPORT it, and how to
      establish that exhaustively before writing code
- [x] Writing a GStreamer pad probe against DeepStream metadata in C++, and
      building it without root or touching `/opt`
- [x] Cross-checking purpose-built test equipment against the real application
      instead of trusting it
- [x] Bounding a known divergence instead of absorbing it into a tolerance
- [x] Why zone logic is application configuration rather than a model capability

**From Milestone 6 — Containerisation**

- [x] Jetson container runtime uses **CSV mode**, injecting device nodes and
      driver libraries — but neither DeepStream nor TensorRT, which must come
      from the image
- [x] That the NVIDIA runtime supplies GPU, NVDEC, VIC and display without
      `--privileged`, `--device` or `--gpus`
- [x] That `docker build` runs **without** that runtime, so no DeepStream plugin
      can be inspected at build time
- [x] TensorRT plan files are version-locked, while DeepStream links TensorRT by
      **major soname only** — the difference between ABI compatibility and
      engine compatibility
- [x] Reading `apt-cache policy` origins and priorities to prove two packages are
      the same artifact from the same repository
- [x] `apt-get -s` as a way to prove an upgrade removes nothing, before doing it
- [x] Why a metapackage with exact-version dependencies forces an atomic upgrade
- [x] Overriding, then restoring, a vendor `apt-mark hold`
- [x] X11 authorisation by local uid (`SI:localuser:`) versus by MIT cookie, and
      why that makes `--user` the narrowest container display method
- [x] Asserting container privilege from the live `HostConfig` rather than by
      grepping one's own scripts

---

## 8. Key engineering decisions

| Decision | Rationale | M | Status |
|---|---|---|---|
| Person detection in a restricted zone | Aligns with later DeepStream/TensorRT/tracking milestones | 1 | Active |
| Simulate the camera from a recorded file | Reproducible and repeatable; a live camera is not | 2 | Active |
| Explicit pipeline, never `playbin` | Every element must be explainable; auto-plugging hides the mechanism | 2 | Active |
| `sample_walk.mov` as default source | Single-subject scene matches the use case; short enough to loop | 2 | Active |
| Video never committed to git | Large binaries; already on every target; no per-stream redistribution licence | 2 | Active |
| DeepStream version discovered, never hard-coded | Not registered with `dpkg`; resolved via the unversioned symlink | 2 | Active |
| Frame-bound and pacing verified by **two separate runs** | `basesink` syncs EOS to the segment end, so a frame bound cannot shorten a paced run ([detail](docs/milestone-02-video-input.md)) | 2 | Active |
| Looping re-runs the pipeline, not a segment seek | Keeps the pipeline minimal and explainable; costs ~0.17 s per pass | 2 | Active |
| Flat repository root | Avoids `video-surveillance/deepstream-video-surveillance/` nesting | 2 | Active |
| All milestone documentation lives in `docs/`, named `milestone-NN-<topic>.md` | A root-level report per milestone does not scale; one predictable location and naming scheme | 2 | Active |
| TrafficCamNet as the baseline detector | On disk, no download, no NGC credentials, no custom parser, no `sudo`; `person` is a native class | 3 | Active |
| PeopleNet held as the upgrade target, not adopted now | Same DetectNet_v2 contract, so switching is a config change; blocked by NGC 401 | 3 | Active |
| YOLOv8/YOLO11 rejected for this milestone | Not supported in DeepStream 9.1; needs an external repo, PyTorch and a compiled parser | 3 | Active |
| FP32 baseline built with `--noTF32` | TensorRT enables TF32 by default on Ampere; without this, "FP32" silently means a 10-bit mantissa | 4 | Active |
| FP16/INT8 built *without* `--noTF32` | They are deployment engines, not controlled experiments; fallback should behave as in production | 4 | Active |
| INT8 built as `--int8 --fp16` | Deployment-realistic: INT8 where selected, FP16 rather than FP32 as fallback | 4 | Active |
| Batch 1, `min=opt=max` | One real-time camera; not optimised for hypothetical multi-stream work | 4 | Active |
| Engines generated locally, never committed | Bound to TensorRT version, GPU and profile; a committed engine is unusable elsewhere and unverifiable here | 4 | Active |
| Build and benchmark kept as separate operations | `--skipInference` on builds, `--loadEngine` on benchmarks, so builder work cannot perturb a timing | 4 | Active |
| Benchmark uses pre-heat + interleaving + repetition | The GPU clock cannot be locked without root; DVFS is measured and reported rather than assumed away | 4 | Active |
| `common.sh` left untouched; M4 helpers in `trt_common.sh` | Milestone 2 is frozen (CLAUDE.md §9); its scripts and verification stay byte-identical | 4 | Active |
| **FP16 is the default for M5** | All precisions are real-time; FP16 costs 10.6% of the frame budget vs INT8's 6.9%, and INT8's accuracy risk is unquantified | 4 | Active |
| INT8 retained, not discarded | Built, benchmarked and reproducible. Reconsider if M5's added stages (mux, tracker, analytics, OSD) consume enough of the 33.37 ms budget that the extra 1.24 ms of headroom matters | 4 | Active |
| `deepstream-app` with `.txt` configs, not a custom app | Faithful to the capstone requirement; nothing in checkpoint 1 needed code | 5 | Active |
| `onnx-file` omitted from the nvinfer config | With no ONNX to fall back to, a failed engine load cannot silently rebuild — it fails loudly. Demonstrated | 5 | Active |
| Engine referenced via a version-free symlink | Keeps the TensorRT version and GPU name out of a committed config, while the wrapper resolves the exact expected engine | 5 | Active |
| Detections verified from KITTI metadata, never from appearance | "I saw a box" is not evidence; the dump gives per-frame, per-class counts | 5 | Active |
| **A 1x1 `nvmultistreamtiler` in the display path** | Without a fresh buffer upstream, `nvdsosd` draws in place and previous frames' boxes persist as a trail. The tiler fixes it while keeping the GPU draw path; matches all 21 stock NVIDIA configs ([detail](docs/milestone-05-osd-ghosting.md)) | 5 | Active |
| OSD left in GPU mode, CPU mode rejected | CPU mode also removed the trail, but only as a side effect of forcing an RGBA conversion. Adopting it would have meant fixing the symptom for the wrong reason | 5 | Active |
| **NvSORT as the tracker**, not IOU or NvDCF | IOU is simpler but has no state estimator at all — a missed detection freezes its box and it offers no velocity to zone analytics. NvDCF is NVIDIA's default but is the most expensive, and its distinguishing benefit (visual re-association through occlusion) is untestable on a clip with one never-occluded person ([detail](docs/milestone-05-tracking.md) §3) | 5 | Active |
| NVIDIA's tracker YAML referenced in place, never copied | Copying would silently fork a vendor file that can drift. The repository preflight-checks the path instead | 5 | Active |
| Tracking criterion is "zero mid-track ID switches", not a coverage percentage | A percentage cannot separate a track that settles after a few frames from one that breaks mid-clip. Only the second breaks zone logic. Unique-ID count and coverage are reported as metrics | 5 | Active |
| Untested tracker capabilities recorded as NOT EXERCISED | The clip has no interior detector gaps and no occlusion, so gap bridging and re-association were never invoked. A passing run must not be read as evidence for them | 5 | Active |
| **ROI filtering, not line crossing**, for the restricted zone | Occupancy is a state ("is someone in the zone now"), which is the use case. Line crossing is an event at a boundary, needs `mode`/`extended` tuning, and depends on tracker continuity in a way occupancy does not ([detail](docs/milestone-05-restricted-zone.md) §2) | 5 | Active |
| ROI geometry **derived from the measured track**, not chosen | Boundaries placed to maximise clearance from the trajectory, and positioned so the foot rule and a centroid rule give 75 vs 0 frames — making the reference point an experiment rather than a citation | 5 | Active |
| **A purpose-built C++ probe** to read analytics metadata | `deepstream-app` never reads `NVDS_USER_*_META_NVDSANALYTICS`, `nvmsgconv` does not carry it, `pyds` is absent, and the shipped analytics sample forces NvDCF and a display. Every shipped route was checked before writing code ([detail](docs/milestone-05-restricted-zone.md) §5) | 5 | Active |
| The probe is **cross-checked, not trusted** | Its detector output must be bit-identical to `deepstream-app`'s or its analytics evidence is rejected. Test equipment that cannot be audited is not evidence | 5 | Active |
| `operate-on-class-ids` rejected as a "fix" for the probe divergence | It made object counts agree by disabling the tracker's removal path, while the retained objects still carried `UNTRACKED_OBJECT_ID` — hiding the difference rather than resolving it | 5 | Active |
| Base image `deepstream:9.1-samples-multiarch`, pinned by tag and digest | arm64-verified, ships DeepStream 9.1.0 with the same GCID as the host, plus the tracker assets and a byte-identical `sample_walk.mov`. `-triton-multiarch` rejected: far larger and drags in out-of-scope Triton | 6 | Active |
| **Container TensorRT upgraded 10.16.1 → 10.16.2** | The milestone's claim is "containerisation changed nothing", which is only provable if the inference library and engine file are identical on both sides. Building a second engine with a different TensorRT would change the inference stack itself ([detail](docs/milestone-06-containerization.md) §3) | 6 | Active |
| The seven TensorRT packages re-`apt-mark hold`ed at the new version | Preserves NVIDIA's intent that they not drift, rather than abandoning the pin | 6 | Active |
| Engine bind-mounted **read-only**, never copied into the image | Machine-specific artifact; a read-only mount also makes a silent rebuild physically impossible, on top of the existing `onnx-file` omission | 6 | Active |
| No Python TensorRT bindings, dev packages or `trtexec` in the image | The container never resolves the engine's *name* — it follows the host-maintained stable symlink. `ensure_engine_link()` stays on the host | 6 | Active |
| Element checks moved from build time to run time | `docker build` gets no NVIDIA CSV injection, so no DeepStream plugin can load during a build ([detail](docs/milestone-06-containerization.md) §6) | 6 | Active |
| Visible container runs as uid 1000, not via `xhost +` | Display `:1` authorises by local uid (`SI:localuser:matan`), not by cookie, so running as that uid needs **no host X11 change at all** | 6 | Active |

---

## 9. Future improvements

Off the critical path; recorded so they do not become scope.

- Gapless looping via segment seek (needs an application with a bus handler)
- Support containers/codecs beyond H.264 in MP4/MOV
- Live camera source (`nvarguscamerasrc` / `nvv4l2camerasrc`) alongside the file source
- RTSP source to exercise true live-stream semantics (drop-when-late)

---

## 10. Open questions

- **`docs/platform-notes.md`** — cross-milestone Jetson/GStreamer findings (EOS
  segment-sync, `DISPLAY=:1`, `videorate` anomaly, SIGINT handling) currently live
  inside the Milestone 2 document. They will matter in later milestones. Promote
  them to a durable platform-notes file?
- ~~**Milestone 3 model choice**~~ — answered: TrafficCamNet, on engineering
  suitability. See §5.
- **Detection-quality validation of FP16 and INT8** — M4 measured performance
  only. Three tiers of evidence are defined in
  [`docs/milestone-04-tensorrt-optimization.md`](docs/milestone-04-tensorrt-optimization.md) §8.
  Tier 1 (raw tensor divergence on identical inputs) is cheap, needs no labels and
  is the obvious next step. Tier 3 (absolute accuracy) is **blocked** — the sample
  clips ship unannotated and this project has no labelled ground truth. Run Tier 1
  as its own experiment, or fold it into M5?
- **Triton is unusable on this machine** — `libtritonserver.so` is absent and
  `triton_backend_setup.sh` needs root. M7 assumes a capability that does not
  currently exist. Resolve before opening M7.
- **The OSD ghosting mechanism is unproven.** The *variable* is isolated — a fresh
  buffer upstream of `nvdsosd` is required — but *why* in-place drawing persists
  across frames was not established
  ([detail](docs/milestone-05-osd-ghosting.md) §8). The fix does not depend on the
  answer. Worth closing only if the artifact reappears in another topology.
- **End-to-end pipeline throughput is unmeasured.** M4 benchmarked the engine
  alone; the assembled pipeline has no performance figure, and it now contains a
  tracker as well. Measure once analytics is in, rather than twice.
- **Why the entering track changed ID once** — measured and characterised, not
  explained. A border-clipped box grows fast enough that NvSORT's association
  plausibly fails while the target is still probational, but the low-level
  library's association scores were not instrumented and the vendor YAML is used
  unmodified by design ([detail](docs/milestone-05-tracking.md) §11). Revisit if
  entry-time ID churn interferes with checkpoint 3's zone logic.
- **Tracking capabilities that this clip cannot test** — gap bridging, shadow
  tracking, occlusion recovery, track termination and multi-object association
  were all recorded as NOT EXERCISED ([detail](docs/milestone-05-tracking.md) §6).
  Testing them needs the crowded source or a real camera. Open a separate
  experiment, or accept the gap until the input changes?
- **Visible playback inside the container is unverified.** The headless path is
  fully machine-checked; the on-screen path needs a human run, exactly as in
  Milestone 5. `./scripts/run_container.sh --display` when you want it.
- **IOU was never run head to head.** NvSORT was chosen from the shipped
  configurations rather than from a measurement on this clip. The comparison is a
  one-line config change if the choice is ever questioned.

---

## 11. Technical debt

| Item | Impact | Trigger to repay |
|---|---|---|
| Git identity not configured globally | Low — commits pass it inline via `git -c` | Before any multi-author work |
| Pipeline is H.264-in-MP4/MOV specific | None today; blocks other sources | If a non-H.264 source is introduced |
| No labelled ground truth for any sample clip | Medium — caps quality work at "divergence from FP32", never "correctness" | When detection accuracy must be claimed rather than compared |
| Detection counts vary ~1% between identical runs | Low — two frames of 288 differ by one borderline detection; verification asserts `> 0`, not an exact count | If reproducible counts ever become a requirement |
| Rendering correctness needs a human | Medium — the automated suite passed while output was visibly wrong. No headless check covers OSD drawing | If visible regressions recur; would need frame capture and comparison |
| A bad `ll-config-file` silently substitutes a different tracker backend | Medium — DeepStream only warns and falls back to defaults, so every other check would still pass. Guarded by asserting the warning is absent ([detail](docs/milestone-05-tracking.md) §7) | If more vendor configs are referenced by path; the same guard would be needed per file |
| The `[tracker]` group is duplicated across two app configs | Low — `deepstream-app` has no include mechanism, and keeping the two configs readable side by side was judged worth the duplication | If a third app config appears, or the groups drift |
| The container image is a **custom artifact**, not NVIDIA's shipped one | Medium — supported as a software combination on this device, unsupported as an image. Overriding a vendor `apt-mark hold` is deliberate and documented | If NVIDIA ships a Jetson image already carrying TensorRT 10.16.2, simplify the Dockerfile rather than leave the pin as archaeology |
| Container image is 8.99 GB | Low — both TensorRT versions transit the layers | If image size becomes a deployment constraint (M8) |
