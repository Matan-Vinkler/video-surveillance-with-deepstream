# Milestone 05 — Object tracking (checkpoint 2)

**Goal.** Give detections a persistent identity. Insert `nvtracker` after
`nvinfer` and establish, from metadata rather than from appearance, whether the
walking person keeps one `object_id` across the clip.

```
sample_walk.mov → decoder → nvstreammux → nvinfer → nvtracker
                → nvmultistreamtiler → nvdsosd → sink
```

**Status: complete.** `./scripts/verify_tracking.sh` exits 0 with all checks
passing. The measured result is one stable track of **224 consecutive frames**
with **zero mid-track ID switches**, preceded by a **6-frame establishment phase
that used a different ID** (§5).

No Triton, no container. No engine was built. NVIDIA's tracker configuration was
used exactly as installed and was neither copied nor modified. Restricted-zone
analytics was out of scope here and was added by the next checkpoint.

---

## 1. What was added

```
configs/
├── deepstream_app_walk_headless.txt   # + [tracker], + 3 track dumps
└── deepstream_app_walk_display.txt    # + [tracker]

scripts/
├── ds_common.sh          # + tracker asset preflight, + dump paths
├── analyze_tracks.py     # turns the KITTI dumps into tracking evidence
└── verify_tracking.sh    # headless verification, 4 runs, 9 checks
```

`deepstream-app` with `.txt` configs remained sufficient — **no custom C++ or
Python application was written**. `analyze_tracks.py` is an offline analyser of
files the application already writes; it is not part of the pipeline.

## 2. One library, and why the YAML is the real choice

DeepStream 9.1 ships **exactly one** low-level tracker:

```
/opt/nvidia/deepstream/deepstream/lib/libnvds_nvmultiobjecttracker.so
```

There are no separate KLT / IOU / DCF libraries any more. **The tracker
"backend" is selected entirely by the YAML passed to `ll-config-file`**, which
makes that one line the most consequential in the whole `[tracker]` group — and
makes §7 a genuine hazard.

Eight tracker YAMLs ship with the SDK, but only three are usable on this machine
without downloading anything:

| Backend | Extra assets | Present | Usable |
|---|---|---|---|
| **IOU** | none | — | ✅ |
| **NvSORT** | none | — | ✅ |
| **NvDCF_perf / max_perf** | VPI 4 only | ✅ | ✅ |
| NvDCF_accuracy | `resnet50_market1501.etlt` ReID | ❌ | ❌ |
| NvDeepSORT | same ReID model | ❌ | ❌ |
| MaskTracker | 4 SAM2 ONNX files + Segmenter module | ❌ | ❌ |

```
$ ls /opt/nvidia/deepstream/deepstream/samples/models/Tracker/
ls: cannot access '.../samples/models/Tracker/': No such file or directory
```

The three ReID/SAM2 backends reference that directory, which does not exist.
`sources/tracker_ReID/README` confirms the models must be fetched and converted
by hand, so those backends are **unavailable**, not merely unchosen.

## 3. Why NvSORT

| | IOU | **NvSORT** | NvDCF_perf |
|---|---|---|---|
| Appearance model | none | none | ColorNames correlation filter |
| Motion model | **none** — no `StateEstimator` section at all | Kalman, `stateEstimatorType: 2` | Kalman, `stateEstimatorType: 1` |
| Association | IoU + size, GREEDY | IoU + size, CASCADED, `usePrediction4Assoc: 1` | + visual similarity, CASCADED |
| Cost | lowest | low | highest — per-object VPI filter per frame |
| `probationAge` | 4 | 5 | 2 |
| `maxShadowTrackingAge` | 38 | 26 | 51 |

**IOU is strictly the lowest-complexity option**, and on this clip it would
probably have worked: consecutive-frame detection IoU never drops below 0.619
(§4). It was rejected because it has **no state estimator at all** — a missed
detection freezes its box in place, and it has no velocity to offer the
restricted-zone analytics of checkpoint 3.

NvSORT is the lowest-complexity choice that is appropriate for where this
milestone is going: the same already-installed library, a different vendor YAML,
nothing to download — but with a Kalman filter behind it.

**NvDCF_perf was deferred** despite being NVIDIA's own default. It is the most
expensive of the three, and its distinguishing benefit — visual re-association
through occlusion — is *untestable* on a clip containing one person who is never
occluded. Adopting it would have meant paying for a capability this milestone
could not verify. It is the natural upgrade if checkpoint 3 or the crowded
source produces ID switches.

## 4. What this clip can and cannot test — established first

Before proposing anything, the checkpoint-1 detection dump was analysed to find
out what tracking behaviour the clip would actually exercise:

```
frames: 288   with detection: 230   without: 58
no-detection runs:  0..43 (len 44)   274..287 (len 14)
first detection frame: 44   last: 273
interior gaps: NONE

max detections in any frame: 1
consecutive-frame IoU: n=229  min=0.619  p05=0.691  median=0.874  max=0.990
```

**The detector never misses the person mid-clip.** The 58 frames without a
detection are 44 before they enter and 14 after they leave; frames 44–273 are
230 *consecutive* hits. Association therefore never has to survive a low-overlap
frame, and the tracker is never asked to bridge anything.

This is why §6 exists: a set of capabilities is recorded as **NOT EXERCISED**
rather than quietly counted as working.

## 5. Verification results

`./scripts/verify_tracking.sh` — headless, no display, terminates on its own.
**Exit status 0, all checks passed.**

```
== CHECK 1: application ran to clean EOS ==
  PASS  deepstream-app exited 0
  PASS  no pipeline errors in the log
== CHECK 2: nvtracker instantiated with the vendor NvSORT config ==
  PASS  nvtracker loaded libnvds_nvmultiobjecttracker.so
  PASS  no tracker initialisation errors
  PASS  config references the vendor NvSORT yml, unmodified and uncopied
  PASS  no obsolete tracker keys (enable-batch-process, enable-past-frame)
== CHECK 3: prebuilt FP16 engine still deserialized, not rebuilt ==
  PASS  engine deserialized: trafficcamnet_b1_960x544_fp16_trt10.16.2_orin-nano.engine
  PASS  engine file unchanged (sha256, mtime and size identical)
== CHECK 4: both dumps cover every frame ==
  detector per-frame files   288
  tracker per-frame files    288
  PASS  both probes wrote one file per frame for all 288 frames
== CHECK 5: the tracker did not change detection ==
  PASS  control run has no tracker (nothing loaded a low-level lib)
  detector rows, tracked run 230
  detector rows, control run 230
  per-frame files differing  0
  PASS  detector output is materially identical with and without the tracker
== CHECK 6: every tracked object carries a valid object_id ==
  PASS  the tracker emitted person objects on 230 frames
  PASS  no row carries UNTRACKED_OBJECT_ID (0xFFFFFFFFFFFFFFFF)
== CHECK 7: no MID-TRACK id switch under continuous detection ==
  unique track ids           2        [metric, not a criterion]
  dominant id coverage       97.4%    [metric, not a criterion]
  establishment switches     1        [reported separately]
  MID-TRACK switches         0        [the criterion]
  PASS  identity never changed after the stable track was established
== RUN 3 / CHECK 8a: a missing tracker LIBRARY must fail the run ==
  PASS  a nonexistent ll-lib-file makes deepstream-app fail (exit 255)
== RUN 4 / CHECK 8b: a missing tracker CONFIG degrades SILENTLY ==
  PASS  confirmed: a bad ll-config-file only WARNS and falls back to defaults
== CHECK 8c: RUN 1 actually read the vendor NvSORT yml ==
  PASS  RUN 1 shows no config-fallback warning: the NvSORT yml was read
  PASS  ds_common.sh preflight fails clearly when the assets are missing
== CHECK 9: nothing beyond the approved scope ==
  PASS  no secondary-gie, line-crossing, overcrowding, direction or messaging group
  PASS  no messaging element appeared at runtime
```

*(CHECK 9 originally read "no analytics yet". Checkpoint 3 adds `nvdsanalytics`
deliberately, so it was narrowed to what is still out of scope. The output above
is from a re-run after that change.)*

### The measured tracking behaviour

```
== Frames ==
  frames processed                   288
  frames with a person detection     230
  frames with a tracked person       230
  detector observation window        44..273
  tracker output window              44..273

== Track establishment (measured, not assumed) ==
  first person detection at frame    44
  first tracker output at frame      44
  delay before first emission        0 frame(s)
  id emitted on that first frame     0
  stable track established at frame  50

== Identity ==
  unique person track ids            2
    id 0      first 44    last 49    frames 6     coverage   2.6%
    id 1      first 50    last 273   frames 224   coverage  97.4%
  longest continuous track           id 1, 224 frames (50..273)

== ID switches ==
  switches during establishment      1
    frame 50: id 0 -> 1
  MID-TRACK switches                 0
```

**Every one of the 230 detected frames also carries a tracked object.** The
tracker adds no frames and drops none.

### Why the criterion is not "dominant ID ≥ 90%"

A coverage percentage cannot distinguish *a track that settles after a couple of
frames* from *a track that breaks in the middle*. Those are completely different
failures, and only the second one matters for restricted-zone analytics: a
person who acquires a new ID halfway across the zone breaks any "same person
entered and stayed" rule.

So the pass/fail criterion is **zero mid-track ID switches while the detector is
continuously observing the person**, and a switch counts as mid-track only when
the transition happens between two consecutive frames that *both* carry a
detection. Unique-ID count and dominant coverage are printed as **metrics**.

By that criterion the result is unambiguous: after frame 50, identity never
changed again for 224 consecutive frames, to the end of the detector's
observation window.

## 6. NOT EXERCISED — capabilities this clip did not test

Recorded explicitly, because a passing verification could otherwise be read as
proving more than it does:

| Capability | Why it was not exercised |
|---|---|
| **Gap bridging** through missed detections | **0** interior detector gaps existed |
| **Shadow tracking** / `maxShadowTrackingAge: 26` | **0** rows in the shadow-track dump |
| **Occlusion recovery / re-association** | max 1 person per frame; nothing ever occluded them |
| **Track termination** | **0** rows in the terminated-track dump |
| **Multi-object association** | one target throughout |

No claim is made about any of these. Testing them needs a different input —
the crowded source, or a real camera — which is outside this checkpoint.

## 7. A discovered hazard: a bad `ll-config-file` fails silently

The negative control was originally written to assert that a nonexistent
`ll-config-file` would fail the run. **It did not.** The run exited 0:

```
$ deepstream-app -c <config with ll-config-file=/nonexistent/config_tracker_NOPE.yml>
gstnvtracker: Loading low-level lib at /opt/.../libnvds_nvmultiobjecttracker.so
[NvTrackerParams::getConfigRoot()] !!![WARNING] File doesn't exist. Will go ahead with default values
[NvMultiObjectTracker] Initialized
...
$ echo $?
0
```

Since the YAML is the *only* thing that selects the backend (§2), **a typo in
`ll-config-file` silently substitutes a different tracker** and the pipeline
still produces plausible IDs. Every other check in this verification would pass.

The missing **library**, by contrast, is fatal:

```
gstnvtracker: Failed to open low-level lib at /nonexistent/libnvds_NOPE.so
 dlopen error: /nonexistent/libnvds_NOPE.so: cannot open shared object file
gstnvtracker: Failed to initilaize low level lib.
** ERROR: <main:719>: Failed to set pipeline to PAUSED
$ echo $?
255
```

The hazard was turned into a guard rather than a footnote. The verification now:

1. **reproduces** the silent fallback (CHECK 8b) so the warning string is known
   to be current, and
2. **asserts that warning is absent** from the real run (CHECK 8c).

That is what makes "NvSORT was the backend in use" an assertion rather than an
assumption. `ds_common.sh` also preflight-checks both assets before starting any
pipeline, so the common case fails early with a readable message.

## 8. Two DeepStream 9.1 facts that contradict older material

**`enable-batch-process` and `enable-past-frame` do not exist.** They appear in
much of the DeepStream tracker material online, but in 9.1 they are absent from
both `gst-inspect-1.0 nvtracker` and the config parser
(`deepstream_config_file_parser.c:159-175`) — they would be **silently
ignored**. Batch processing is unconditional; past-frame output is decided by the
low-level library's capability query (`nvtracker_proc.cpp:1159`). The
verification asserts neither key is present.

The complete key set `deepstream-app` accepts in `[tracker]`:

```
enable, tracker-width, tracker-height, gpu-id, ll-lib-file, ll-config-file,
tracker-surface-type, tracking-surface-type, display-tracking-id,
tracking-id-reset-mode, input-tensor-meta, tensor-meta-gie-id, compute-hw,
user-meta-pool-size, sub-batches, sub-batch-err-recovery-trial-cnt,
operate-on-class-ids
```

**`tracker-width`/`tracker-height` is a separate resolution.** It matches neither
the source nor the network by requirement: metadata bounding boxes stay in
streammux (1920×1080) coordinates. 960×544 is the element default and NVIDIA's
sample value. That it equals the network input size is a coincidence.

## 9. Where the evidence comes from

`nvtracker` writes nothing itself. The evidence comes from **four different
probes that `deepstream-app` attaches at different points in the pipeline** —
which is what makes it possible to compare detector output against tracker
output *within a single run*:

| `[application]` key | Probe attach point | Contains |
|---|---|---|
| `gie-kitti-output-dir` | `primary-gie` bin **src** pad (`deepstream_app.c:1951`) | detector rows, **no ID column** |
| `kitti-track-output-dir` | the **tracker's** src pad (`deepstream_app.c:1979`) | tracker rows, **ID in column 2** |
| `terminated-track-output-dir` | same | tracks the library reports as ended |
| `shadow-track-output-dir` | same | frames tracked without a detection |

```
detector   label       0.0 0 0.0 l t r b 0.0 x6 conf     -> box $5..$8
tracker    label  id   0.0 0 0.0 l t r b 0.0 x7 conf     -> id $2, box $6..$9
```

The detector dump is written **upstream of the tracker**, so a tracker cannot
alter it. That is asserted rather than assumed: RUN 2 repeats the run with
`[tracker] enable=0` and diffs the detector dumps — **0 of 288 per-frame files
differ**.

> **Correction to checkpoint 1's documentation.** The headless config previously
> stated that the detector dump is written "from a probe on the nvdsosd sink
> pad". It is not; it is the `primary-gie` bin's src pad. The consequence
> claimed there — that it is after `nvinfer` and before any tracker — remains
> true, and now matters.

## 10. What NvSORT adds to the metadata

| Field | Before the tracker | After |
|---|---|---|
| `object_id` | `UNTRACKED_OBJECT_ID` = `0xFFFFFFFFFFFFFFFF` (`nvdsmeta.h:59`) | a `uint64` track ID |
| `tracker_confidence` | unset | NvSORT reports a constant `0.500` on this clip |
| `tracker_bbox_info.org_bbox_coords` | unset | the tracker's own (Kalman-filtered) box |
| `detector_bbox_info` | detector box | unchanged |

With `useUniqueID: 0` in the vendor YAML, IDs are small per-stream integers
starting at 0 — which is why the observed IDs are literally `0` and `1`.

The tracker's box is **not** the detector's box. Measured offset between them:

| Phase | Frames | Median | Max |
|---|---|---|---|
| Establishment (44–49, id 0) | 6 | 7.67 px | 32.37 px |
| **Stable track (50–273, id 1)** | **224** | **0.00 px** | **17.58 px** |

Once the track is stable the Kalman estimate agrees with the detector exactly on
most frames, and departs only when the detection moves quickly. This is expected
behaviour for a state estimator, not a defect.

## 11. The establishment phase — reported, not tuned around

Two IDs occurred, and both were in the first six frames. This is the raw data:

```
frame 044 | det: person conf=0.275 box=(0,323)-(66,750)   | trk: id=0 box=(0,323)-(66,750)
frame 045 | det: person conf=0.469 box=(0,324)-(69,749)   | trk: id=0 box=(1,324)-(67,749)
frame 046 | det: person conf=0.657 box=(0,321)-(78,743)   | trk: id=0 box=(5,322)-(70,745)
frame 047 | det: person conf=0.496 box=(0,324)-(103,739)  | trk: id=0 box=(14,323)-(81,741)
frame 048 | det: person conf=0.743 box=(0,324)-(126,743)  | trk: id=0 box=(24,324)-(93,742)
frame 049 | det: person conf=0.727 box=(0,328)-(157,741)  | trk: id=0 box=(0,328)-(157,741)
frame 050 | det: person conf=0.759 box=(0,332)-(183,740)  | trk: id=1 box=(0,332)-(183,740)
frame 051 | det: person conf=0.669 box=(0,330)-(190,741)  | trk: id=1 box=(2,330)-(187,741)
```

What is **measured**: the person is entering from the left edge, so every
detector box is clipped at `left=0` and the width grows fast (66 → 157 px in six
frames). The tracker's estimate lags and drifts right — its left edge reaches 24
while the detector still says 0. At frame 49 the tracker box snaps back to match
the detector exactly, and at frame 50 a new ID appears.

What is **hypothesis, not established**: that the rapid growth of a
border-clipped box pushed the size-similarity term below NvSORT's
`minMatchingScore4SizeSimilarity: 0.4019`, so association failed; and that with
`probationAge: 5` the six-frame-old target was still probational, so
`earlyTerminationAge: 1` terminated it immediately rather than shadow-tracking
it. The vendor YAML's `enableBboxUnClipping: 0` (NvDCF_perf sets `1`) is
consistent with this, since NvSORT makes no attempt to compensate for border
clipping.

**This was not investigated further and nothing was tuned.** Confirming it would
mean instrumenting the low-level library's association scores, and the vendor
YAML is used unmodified by design. Two facts make it a low-priority question:
the terminated-track dump is **empty**, so the library never reported ID 0 as a
terminated track at all; and the phenomenon is confined to object *entry*, which
`nvdsanalytics` zone logic can be designed to tolerate.

Two useful side-findings did come out of it:

- **Tracker output begins on the very first detected frame** (delay 0), so
  probational/TENTATIVE targets *are* emitted into `NvDsObjectMeta`. That was an
  open question before this run; it is now measured.
- `tracker_confidence` is a constant `0.500` for NvSORT on this clip, so it is
  not a useful discriminator here.

> **Amended by checkpoint 3.** `nvdsanalytics` now sits between `nvtracker` and
> the tiler, and CHECK 9 was narrowed from "no analytics" to "nothing beyond the
> approved scope". Tracking itself is unaffected and is re-measured on every
> checkpoint-3 run: **0 mid-track ID switches, same 224-frame longest run**, and
> the tracker dump is identical with and without analytics (0 of 288 frames
> differ). Record: [`milestone-05-restricted-zone.md`](milestone-05-restricted-zone.md).

## 12. Impact on checkpoint 1

Checkpoint 1's CHECK 8 asserted that **no tracker and no analytics** existed.
Checkpoint 2 invalidates the first half by design, so the assertion was narrowed
to analytics only, with its intent unchanged: checkpoint 3 has not started.

Nothing else in checkpoint 1 changed. What it actually owns — detection
metadata — is still fully regression-tested, because CHECKS 1–7 of
`verify_inference.sh` read only the **pre-tracker** detector dump. Confirmed
after this change:

```
$ ./scripts/verify_inference.sh   ; echo $?
...
== CHECK 6: detections produced (RAW counts, stock thresholds) ==
  person detections        230
  frames with a person     230 of 288
  PASS  at least one 'person' detection was produced
== CHECK 8: no analytics yet (checkpoint 3 not started) ==
  PASS  no analytics or secondary-gie group in any config
  PASS  no analytics element appeared at runtime
All checks passed.
0

$ ./scripts/verify_simulated_stream.sh ; echo $?
  PASS  paced run (9.77 s) matches clip duration (9.610 s)
All checks passed.
0
```

Milestone 2 and Milestone 4 scripts are byte-identical; `git status` lists
neither.

## 13. Negative cases

| Case | Result |
|---|---|
| `ll-lib-file` nonexistent | `dlopen error`, `Failed to initilaize low level lib`; **exit 255** |
| `ll-config-file` nonexistent | **exit 0** with a warning — silent fallback to defaults (§7) |
| DeepStream root missing (preflight) | `require_tracker_assets` fails with the expected path; **exit 1** |
| Unknown script option | `ERROR: Unknown option '--nope'. Try --help.`; **exit 1** |
| `[tracker] enable=0` | Runs cleanly with no tracker; used as the control in CHECK 5 |

## 14. Known limitations

1. **One clip, one person, no occlusion.** Nothing here generalises to the
   crowded source or to a real camera.
2. **Six capabilities are untested** (§6) — most importantly gap bridging and
   occlusion recovery, the two things a tracker is usually chosen *for*.
3. **The establishment-phase ID change is not explained**, only characterised
   (§11).
4. **A bad `ll-config-file` cannot be caught by the pipeline** (§7). The
   repository guards it; DeepStream does not.
5. **No performance claim.** Adding NvSORT costs something, and this pipeline's
   end-to-end throughput has never been measured. Milestone 4 measured the
   engine in isolation only.
6. **IOU was not run as a comparison.** The choice in §3 is argued from the
   shipped configurations, not from a head-to-head measurement on this clip.
7. **On-screen confirmation is a human check, not an automated one** (§16). As in
   checkpoint 1, no headless test covers what `nvdsosd` actually draws.

## 15. Completion criteria

| Criterion | Status |
|---|---|
| `nvtracker` inserted after `nvinfer` | Done — `nvinfer → nvtracker → tiler → osd` |
| Tracker really instantiated | Done — logged library load + a fatal negative control |
| NvSORT actually in effect | Done — silent-fallback warning reproduced, then asserted absent |
| Vendor YAML unmodified and uncopied | Done — referenced in place; preflight-checked |
| No obsolete tracker keys | Done — asserted absent |
| Detector metadata unchanged | Done — 0 of 288 frames differ vs a tracker-disabled run |
| Valid `object_id` on every tracked object | Done — 0 rows with `UNTRACKED_OBJECT_ID` |
| Track establishment measured, not assumed | Done — 0-frame delay; stable at frame 50 |
| No mid-track ID switch | Done — 0, across 224 consecutive frames |
| Unique IDs and coverage reported as metrics | Done — 2 ids, 97.4% |
| Untested capabilities reported as NOT EXERCISED | Done (§6) |
| Engine not rebuilt | Done — `Use deserialized engine model`, sha256 unchanged |
| No analytics | Done — static and runtime checks |
| Checkpoint 1 and Milestone 2 regressions pass | Done — both exit 0 (§12) |
| Visible playback still correct with the tracker in the path | Done — confirmed on screen (§16) |

## 16. On-screen confirmation

Everything above is metadata-level evidence. It proves `nvtracker` attached a
stable `object_id`; it does not prove `nvdsosd` renders anything sensible with
it. Checkpoint 1 exists as a warning here: its automated suite passed in full
while the output was visibly wrong.

`./scripts/run_inference.sh` was run on the physically attached monitor and
**reported as working**. That confirms the tracker in the pipeline does not
regress the rendering that checkpoint 1 established — in particular that the 1×1
tiler still does its job with an extra element upstream of it, and that the
`display-tracking-id=1` label draws without breaking the OSD.

This is a **human check, not an automated one**, and it is recorded at exactly
the strength it was made: the run worked. No claim is made here about the
specific ID text on screen, which nothing measured. The identity claims in §5 all
rest on the metadata dumps, not on this run.
