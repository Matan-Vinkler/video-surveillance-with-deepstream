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
   [DONE M2]        [M3-M5]         [M5]           [M5]           [M9]
       │                │                                           │
  GStreamer:       TensorRT /                                  monitoring,
  filesrc ! qtdemux    DeepStream                              logging
  ! queue ! h264parse  nvinfer /
  ! nvv4l2decoder      Triton
  ! sink
```

Currently implemented: the leftmost stage only — a recorded video replayed
through an explicit GStreamer pipeline as a simulated camera, paced in real time.
No inference component exists yet.

Pipeline detail and rationale: [`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md).

---

## 3. Project Progress

Milestones follow the capstone structure. Project progress tracks *deliverables*;
learning progress (§7) is tracked separately.

- [x] **1. Define Use Case**
- [x] **2. Collect or Simulate Video Input**
- [ ] **3. Select Pretrained Model** ← next
- [ ] **4. Optimize Model using TensorRT**
- [ ] **5. Build DeepStream Inference Pipeline**
- [ ] **6. Containerize the Application**
- [ ] **7. Deploy Inference with Triton Inference Server**
- [ ] **8. Deploy on Edge Device (Jetson)**
- [ ] **9. Monitoring and Logging**
- [ ] **10. Final Report and Deliverables**

| № | Milestone | Status | Documentation |
|---|---|---|---|
| 1 | Define Use Case | Complete | §5 below (no artifacts in this repo) |
| 2 | Collect or Simulate Video Input | Complete | [`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md), [`docs/milestone-02-inspection.md`](docs/milestone-02-inspection.md) |
| 3 | Select Pretrained Model | Not started | — |
| 4 | Optimize Model using TensorRT | Not started | — |
| 5 | Build DeepStream Inference Pipeline | Not started | — |
| 6 | Containerize the Application | Not started | — |
| 7 | Deploy Inference with Triton | Not started | — |
| 8 | Deploy on Edge Device (Jetson) | Not started | — |
| 9 | Monitoring and Logging | Not started | — |
| 10 | Final Report and Deliverables | Not started | — |

---

## 4. Current milestone

**None active.** Milestone 2 is complete; Milestone 3 has not been opened.

**Next up — Milestone 3: Select Pretrained Model.** Expected shape: choose a
person-detection model, justify the choice against the use case, and document
its input/output contract. No optimisation (M4) and no pipeline integration (M5).

Out of scope until explicitly opened: TensorRT conversion, `nvinfer`/`nvtracker`,
Triton, Docker, MQTT, monitoring.

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

---

## 6. Future milestones

Deliberately thin — detail is added when a milestone is opened.

| № | Milestone | Expected focus |
|---|---|---|
| 3 | Select Pretrained Model | Model choice and justification; input/output contract |
| 4 | Optimize using TensorRT | FP16/INT8 conversion, accuracy vs latency trade-off |
| 5 | Build DeepStream Inference Pipeline | `nvstreammux`, `nvinfer`, tracking, restricted-zone analytics |
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
- **Milestone 3 model choice** — which person-detection model, and evaluated against
  what criteria?

---

## 11. Technical debt

| Item | Impact | Trigger to repay |
|---|---|---|
| Git identity not configured globally | Low — commits pass it inline via `git -c` | Before any multi-author work |
| Pipeline is H.264-in-MP4/MOV specific | None today; blocks other sources | If a non-H.264 source is introduced |
