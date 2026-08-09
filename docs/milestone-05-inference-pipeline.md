# Milestone 05 — DeepStream inference pipeline (checkpoint 1)

**Goal.** Prove that the FP16 TrafficCamNet engine from Milestone 4 runs on the
simulated camera source from Milestone 2 and produces person detections, through
an explicit `deepstream-app` pipeline.

```
sample_walk.mov → decoder → nvstreammux → nvinfer → nvmultistreamtiler
                → nvdsosd → sink
```

**Status: complete.** Headless verification passes and on-screen rendering is
confirmed (§7).

> **Amended by checkpoints 2 and 3.** `nvtracker` and then `nvdsanalytics` now
> sit between `nvinfer` and the tiler, and CHECK 8 below was narrowed twice —
> see §11. Everything else in this document still describes behaviour that is
> re-verified on every run.

The `nvmultistreamtiler` stage was **not** in the originally specified topology.
It was added after visible playback exposed a rendering defect, and it is
required for correct OSD output even with a single source. The full experiment
is in [`milestone-05-osd-ghosting.md`](milestone-05-osd-ghosting.md).

No Triton, no container. No engine was built. A tracker and restricted-zone
analytics were out of scope for this checkpoint and were added by the next two
(§11).

Inspection-phase record: [`milestone-05-inspection.md`](milestone-05-inspection.md).

---

## 1. What was added

```
configs/
├── config_infer_primary_trafficcamnet.txt   # nvinfer: the FP16 engine
├── deepstream_app_walk_headless.txt         # fakesink + KITTI metadata dump
└── deepstream_app_walk_display.txt          # nv3dsink, real-time paced

scripts/
├── ds_common.sh          # engine symlink, config/preflight helpers (--selftest)
├── verify_inference.sh   # headless, machine-checked verification
└── run_inference.sh      # visible playback (opens a window)
```

`deepstream-app` with `.txt` configs was sufficient throughout — **no custom C++
or Python application was needed**, and none was written.

A third document, [`milestone-05-osd-ghosting.md`](milestone-05-osd-ghosting.md),
records the rendering defect found at the visible stage and the experiment that
resolved it.

As in Milestone 4, the scripts of completed milestones are left byte-identical:
`ds_common.sh` sources `trt_common.sh`, which sources `common.sh`.

## 2. The engine symlink

The committed nvinfer config references a **version-free** name:

```
model-engine-file=../models/engines/trafficcamnet_fp16.engine
```

`ds_common.sh` maintains that symlink, pointing it at the engine the *current*
environment implies — derived exactly as Milestone 4 derived it: input dims from
the ONNX contract, TensorRT version and GPU discovered at run time. So no
version string is hard-coded in a checked-in file, and a mismatch fails loudly:

```
$ ENGINE_DIR=<empty dir> ./scripts/verify_inference.sh
ERROR: The FP16 engine this environment expects is missing:
           …/trafficcamnet_b1_960x544_fp16_trt10.16.2_orin-nano.engine

       This milestone does not build engines. Build it first with the
       Milestone 4 script, which is unchanged:
           ./scripts/build_engines.sh --precision fp16
$ echo $?
1
```

## 3. Three deliberate omissions in the nvinfer config

| Omitted | Why |
|---|---|
| **`onnx-file`** | With no ONNX to fall back to, a failed engine load **cannot** silently rebuild. Proven in §6 |
| **`infer-dims`** | `checkBackendParams` validates input dims only when this is set; omitting it lets the engine's bindings govern |
| **`output-blob-names`** | Likewise for output names |

`int8-calib-file` is also absent — it applies only to an INT8 build.

Thresholds are the **stock reference values, unchanged** (`cluster-mode=2` NMS,
`topk=20`, `nms-iou-threshold=0.5`, `pre-cluster-threshold=0.2`). Raw counts were
recorded at these settings before any tuning was considered — and none was done.

## 4. Verification results

`./scripts/verify_inference.sh` — headless, no display, terminates on its own.
**Exit status 0, all checks passed.**

```
== CHECK 1: application ran to clean EOS ==
  PASS  deepstream-app exited 0
  PASS  no pipeline errors in the log
== CHECK 2: prebuilt FP16 engine loaded, not rebuilt ==
  PASS  engine deserialized: trafficcamnet_b1_960x544_fp16_trt10.16.2_orin-nano.engine
  PASS  no rebuild was attempted
  PASS  engine file unchanged (sha256, mtime and size identical)
== CHECK 3: source decoded ==
  per-frame files          288
  clip holds               288 frames
  PASS  inference ran on 288 frames
  PASS  every frame in the clip was processed
== CHECK 4: batch size is 1 end to end ==
  streammux batch-size     1
  primary-gie batch-size   1
  nvinfer batch-size       1
  PASS  all three declare batch-size 1
  PASS  nvinfer accepted the engine without a capability mismatch
== CHECK 5: nvinfer configuration and parsing ==
  PASS  no nvinfer config or parser errors
== CHECK 6: detections produced (RAW counts, stock thresholds) ==
  total detections         230
    per-class breakdown:
    person         230
  person detections        230
  frames with a person     230 of 288
  PASS  at least one 'person' detection was produced
== CHECK 7: class_id 2 is 'person' (filter-out-class-ids run) ==
  surviving detections     230
  non-person survivors     0
  PASS  with classes 0,1,3 filtered out, every surviving detection is 'person' -> class_id 2
== CHECK 8: nothing beyond the approved scope ==
  PASS  no secondary-gie, line-crossing, overcrowding, direction or messaging group
  PASS  no messaging element appeared at runtime
```

*(CHECK 8 originally read "no tracker or analytics". It was narrowed twice --
checkpoint 2 adds a tracker and checkpoint 3 adds analytics, both deliberately;
§11 records why and what was preserved. The output above is from a re-run after
both changes.)*

### Detection quality on this clip

Every one of the 288 frames was processed, and **230 of them contain a person
detection (79.9%)**. The detector tracks the walking figure across the frame
with high confidence:

```
frame 048  person  conf=0.7432  box=(0,324)-(126,743)
frame 049  person  conf=0.7266  box=(0,328)-(157,741)
frame 050  person  conf=0.7593  box=(0,332)-(183,740)
frame 051  person  conf=0.6689  box=(0,330)-(190,741)
frame 052  person  conf=0.7285  box=(0,331)-(207,740)
frame 053  person  conf=0.7603  box=(0,338)-(215,742)
frame 054  person  conf=0.8242  box=(0,341)-(218,743)
```

The box moves steadily left-to-right, which matches the clip's content. **Not a
single `car`, `bicycle` or `road_sign` false positive** appeared in 288 frames.

**The Milestone 3 viewpoint-mismatch risk did not materialise.** TrafficCamNet's
`person` class was trained on traffic-camera geometry, and the concern was that a
close-range indoor walk would detect poorly. On this clip it does not.

## 5. Class mapping proven by experiment

Milestone 3 established from source that `class_id` and `obj_label` are the same
index, so `person` implies class 2. Checkpoint 1 turns that into an experiment.

A second bounded run adds `filter-out-class-ids=0;1;3`, which `nvinfer` applies to
`obj.classIndex` directly. Only class 2 can survive. Result: **230 detections
survived, 0 of them non-person** — so the surviving detections are class_id 2 by
construction, not by inference.

## 6. Negative cases

| Case | Result |
|---|---|
| Engine absent | Clear error naming the expected file and the M4 command to build it; **exit 1** |
| `batch-size=2` against a max-batch-1 engine | See below; `deepstream-app` **exit 255** |
| Unknown script option | `ERROR: Unknown option '--nope'. Try --help.`; **exit 1** |
| No display (visible script) | Refuses with guidance, points at the headless script; **exit 1**. No window opened |

The batch-size case is the one worth quoting, because it demonstrates that
omitting `onnx-file` does what it was meant to:

```
WARN : Backend has maxBatchSize 1 whereas 2 has been requested
WARN : …failed to match config params, trying rebuild
ERROR: failed to build network since there is no model file matched.
ERROR: failed to build network.
```

A rebuild was attempted and **could not happen**. The run failed loudly instead
of silently producing a different engine.

## 7. On-screen OSD rendering — verified, after a defect

Everything in §4 is metadata-level evidence: it proves `nvinfer` produced
`NvDsObjectMeta` with the right class and plausible boxes. It does **not** prove
`nvdsosd` draws them correctly. That required a visible run:

```bash
./scripts/run_inference.sh          # or: DISPLAY=:1 ./scripts/run_inference.sh
```

**The first visible run exposed a defect the automated verification could not
see.** The current box tracked the walker, but boxes from previous frames stayed
on screen, leaving a trail. Metadata was correct throughout — max 1 detection per
frame, no accumulation — so every headless check passed while the output was
visibly wrong.

The cause was isolated to `nvdsosd` drawing into a buffer it received by
reference: `osd_conv` negotiated NV12 → NV12 and converted nothing, so no fresh
buffer existed. A 1×1 `nvmultistreamtiler` composites into its own buffer and
removes the artifact while keeping the GPU draw path. Detection metadata is
**per-frame identical** before and after.

Confirmed on screen with the tiler in place: a single blue box labelled `person`
tracking the walking figure, no trail. Class colours — 0 car red, 1 bicycle cyan,
**2 person blue**, 3 road_sign green.

Full experiment, the rejected alternative, and the limits of what was proven:
[`milestone-05-osd-ghosting.md`](milestone-05-osd-ghosting.md).

## 8. An unexpected finding: detection counts are not perfectly reproducible

Three identical headless runs of the same config produced **232, 230 and 230**
person detections. The pipeline is deterministic in every structural respect —
288 frames processed every time, same exit status, same engine — but the
detection count varies slightly.

Diffing per-frame counts across the three runs isolates it precisely:

```
frame 050:  run1=2  run2=1  run3=1
frame 052:  run1=2  run2=1  run3=1
```

**286 of 288 frames are identical across all three runs.** Only two frames differ,
and each by a single extra detection.

The likely cause is a borderline detection oscillating around the
`pre-cluster-threshold=0.2` cutoff. The confidence distribution has a thin tail
sitting just above it:

```
conf 0.24  count 1
conf 0.25  count 1
conf 0.28  count 1
conf 0.33  count 2
```

A detection whose score lands within floating-point noise of 0.2 will sometimes
pass and sometimes not. That is consistent with non-associative floating-point
reduction order on the GPU, which does not guarantee bit-identical results
between runs even for identical input.

**This has not been proven**, only reasoned from the evidence. Establishing it
would mean dumping the raw `output_cov` tensor for frames 50 and 52 across runs
and comparing values near the threshold — worth doing if reproducibility ever
becomes a requirement, but out of scope here.

**Practical consequence:** the verification asserts `person detections > 0`, not
an exact count. An exact-count assertion would be flaky by roughly 1%.

## 9. Known limitations

1. **The 1x1 tiler is load-bearing.** It tiles nothing, but removing it
   reintroduces the OSD trail (§7). Both configs carry a comment saying so, to
   stop it being deleted as redundant.
2. **Detection counts vary by ~1% between runs** (§8).
3. **Aspect ratio is slightly squashed**: 1920×1080 (1.778) → 960×544 (1.765),
   because `maintain-aspect-ratio` is left at the stock default of unset.
4. **One clip only.** `sample_walk.mov`; the crowded source is untested here.
5. **No performance claim.** Milestone 4 measured the engine in isolation; this
   pipeline's end-to-end throughput has not been measured.
6. **`sync=0` headless.** The headless path runs as fast as possible; it is not a
   real-time-pacing test. Milestone 2 owns that claim.

## 10. Completion criteria

| Criterion | Status |
|---|---|
| `deepstream-app` starts successfully | Done — exit 0 |
| FP16 engine loaded, not rebuilt | Done — `Use deserialized engine model`, no rebuild, sha256 unchanged |
| `sample_walk.mov` decoded | Done — 288 of 288 frames |
| `nvstreammux` batch size 1 | Done — all three declarations, no capability mismatch |
| `nvinfer` runs without parser/config errors | Done |
| `person` detections produced | Done — 230 detections across 230 frames |
| Machine-verifiable object metadata | Done — KITTI dump, not "I saw a box" |
| At least one detection with class_id 2 | Done — proven by `filter-out-class-ids` |
| Headless execution exits cleanly | Done — exit 0, no display, no loop |
| Nothing beyond the approved scope | Done — static and runtime checks (narrowed in checkpoints 2 and 3, §11) |
| Milestone 2 tests still pass | Done — `verify_simulated_stream.sh` exit 0, M2 files byte-identical |
| Bounding boxes visible with OSD | Done — confirmed on screen after adding the 1x1 tiler (§7) |
| Rendering defect understood and documented | Done — variable isolated; mechanism recorded as hypothesis only |

## 11. Amended by checkpoints 2 and 3

Checkpoint 2 inserted `nvtracker` between `nvinfer` and the tiler; checkpoint 3
inserted `nvdsanalytics` after it. Each invalidated exactly one thing here,
deliberately.

**CHECK 8 was narrowed, twice.** It originally asserted that neither a tracker
nor analytics existed:

```bash
grep -rqE '^\[tracker\]|^\[secondary-gie|nvdsanalytics|kitti-track-output-dir' "$CONFIG_DIR"/
```

Adding a tracker, and then analytics, makes that fail by construction. It now
asserts only that what is *still* out of scope is absent:

```bash
grep -rqE '^\[secondary-gie|^\[line-crossing|^\[overcrowding|^\[direction-detection|^\[message-broker|^\[message-converter' "$CONFIG_DIR"/
```

The intent has never changed — nothing beyond the approved scope has crept in —
and the checkpoint-1 claim that mattered is untouched. **What this document owns
is detection**, and CHECKS 1–7 read only the pre-tracker detector dump, which
`deepstream-app` writes from a probe on the `primary-gie` bin's src pad. Both
later checkpoints prove that independently rather than asserting it: control runs
with `[tracker] enable=0` and with `[nvds-analytics] enable=0` each produced a
detector dump in which **0 of 288 per-frame files differ**.

**One further fix was required by checkpoint 3.** Since a second config group now
carries a `config-file=` key, CHECK 7's blanket `sed` on it pointed
`nvdsanalytics` at an nvinfer config and failed the run. It now rewrites the key
for `[primary-gie]` only, and disables analytics for that detector-only check.

Nothing else changed. The topology in §1, the omissions in §3, the class-mapping
experiment in §5, the negative cases in §6, the ghosting fix in §7 and the
reproducibility finding in §8 all still hold and are still re-verified on every
run of `verify_inference.sh`.

Later records: [`milestone-05-tracking.md`](milestone-05-tracking.md) and
[`milestone-05-restricted-zone.md`](milestone-05-restricted-zone.md).
