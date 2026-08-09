# Milestone 05 — Restricted-zone analytics (checkpoint 3)

**Goal.** Turn a tracked identity into an application statement: *is this person
inside the restricted zone?* Insert `nvdsanalytics` after `nvtracker`, define one
ROI, and prove entry, dwell and exit from DeepStream's own metadata.

```
sample_walk.mov → decoder → nvstreammux → nvinfer → nvtracker
                → nvdsanalytics → nvmultistreamtiler → nvdsosd → sink
```

**Status: complete.** `./scripts/verify_zone.sh` exits 0 with all checks passing.
The walker enters the zone at **frame 109**, stays for **75 consecutive frames
(2.50 s)**, exits after **frame 183**, and remains tracked for **90 more frames**.
DeepStream's verdict agrees with an independent recomputation on **100% of 230
frames**.

ROI filtering only. No line crossing, no overcrowding, no direction detection,
no messaging. No engine was built; detector, thresholds, tracker and vendor YAML
are untouched.

---

## 1. What was added

```
configs/
├── config_nvdsanalytics_restricted_zone.txt   # the zone -- our application logic
├── deepstream_app_walk_headless.txt           # + [nvds-analytics]
└── deepstream_app_walk_display.txt            # + [nvds-analytics]

tools/
├── analytics_probe.cpp    # reads the ROI verdict back out of the pipeline
└── Makefile               # builds it into build/, installs nothing

scripts/
├── ds_common.sh           # + analytics config helper, probe build-on-demand
├── analyze_zone.py        # recomputes the expected verdict, compares
└── verify_zone.sh         # headless verification, 5 runs, 14 checks
```

This is the first checkpoint that required code. §5 records why, and what was
ruled out first.

## 2. The zone, and why it is not a model problem

```ini
config-width=1920
config-height=1080
roi-RF=650;640;1260;640;1260;820;650;820
inverse-roi=0
class-id=2
```

A rectangle **x ∈ [650, 1260], y ∈ [640, 820]** in 1920×1080 reference
coordinates, given as a 4-point polygon. Coordinates are pixels, not normalised;
every ROI point is rescaled by `surface_width / config-width` when the analytics
context is created (`nvds_analytics.cpp:271-280`), so with a 1920×1080 streammux
output the scale factor is exactly 1.0.

The detector answers *"is this a person, and where"* — a property of the image.
The zone answers *"does that location matter to me"* — a property of the
**installation**: a doorway, a platform edge, a fenced area. It changes when the
camera moves or the policy changes, with no retraining, and an operator must be
able to audit and adjust it. That is why it is a config file in this repository
and not something the network learned, and it is the reason this is the only
configuration here that is genuinely ours rather than a vendor file used as
shipped.

## 3. The geometry was derived, not chosen

The coordinates come from the checkpoint-2 tracker dump, evaluated with the test
point `nvdsanalytics` actually uses (§4):

| Phase | Frames | |
|---|---|---|
| Outside, approaching | 44 – 108 | 65 frames |
| **Enters** | **109** | |
| **Inside** | **109 – 183** | **75 frames = 2.50 s**, one contiguous run |
| **Exits** | after **183** | |
| Outside, departing | 184 – 273 | 90 frames, still tracked |

Boundaries were placed to maximise distance from the trajectory rather than
rounded to convenient numbers: 8 px of clearance at each x boundary (the subject
advances 8–12 px per frame), 67 px and 86 px at the y boundaries. The 8 px x
margin is why entry and exit are asserted with a **±2 frame tolerance** — some
frame must land near any vertical boundary the subject walks through.

## 4. The reference point is the feet, not the centroid

This is the detail that decided the whole design, and reading the source
carefully overturned the obvious assumption. `nvds_analytics.cpp:600`:

```cpp
roi_status = NvDsAnalytics_CheckObjInROI(roi.roi_pts, curr_x, curr_y + (int)mean_h/2);
```

with `curr_x = left + width/2`, `curr_y = top + height/2`, and `mean_h` the
running mean box height over the last `obj-cnt-win-in-ms` frames (default 50) for
that `object_id`. So the test point is the centroid shifted **down by half the
smoothed height** — approximately the object's **feet**. Measured against our own
track it stays within −5/+23 px of the true box bottom.

Two consequences: the ROI must be drawn where the feet are; and because the
height is smoothed over 50 frames, occupancy is **history-dependent**, not a pure
function of the current box.

**The zone is placed so this is testable rather than asserted.** The centroid
stays at y 535–605, entirely above the zone; the feet stay at 707–755, inside it.
So the same ROI gives:

| Rule | Frames inside |
|---|---|
| **Foot point** (what DeepStream uses) | **75** |
| Centroid | **0** |
| **DeepStream, measured** | **75** |

A 75-vs-0 experiment, not a citation.

Related details, all established from source: the polygon test is a ray cast in
the −x direction (odd crossings = inside), half-open in y; the box arrives as
`uint32_t` (`nvds_analytics.h:108-112`), so float coordinates are truncated
before the test; and `nvdsanalytics` consumes `obj_meta->rect_params`, which
downstream of the tracker is the tracker's **clipped** box — measured here as
identical to the unclipped one on every frame (max deviation 0.00 px), since
nothing on this clip is clipped.

## 5. deepstream-app cannot report analytics — established, not assumed

`deepstream-app` can **run** `nvdsanalytics` but cannot **report** it. Before
writing any code, every shipped route was checked:

| Route | Result |
|---|---|
| `deepstream-app` source | Never reads `NVDS_USER_OBJ_META_NVDSANALYTICS` or `NVDS_USER_FRAME_META_NVDSANALYTICS` — only config parsing and bin creation |
| The four KITTI dumps | Label, id, box, confidence. No ROI status |
| `nvmsgconv` payloads | `NVDS_USER_OBJ_META_NVDSANALYTICS` appears **nowhere** in `sources/libs/`. The schema's `analyticsModule` is static module identity from the msgconv config, not rule results |
| `debug-payload-dir` | Would give a broker-free file dump — of data we already have |
| `pyds` | Not installed |
| `deepstream-nvdsanalytics-test` | Does print `Objs in ROI RF = N`, but hard-codes `config_tracker_NvDCF_perf.yml` and `nv3dsink` — it would change the tracker backend and require a display |

So the ROI verdict exists only in-process. `tools/analytics_probe.cpp` (~330
lines including commentary) builds the pipeline with `gst_parse_launch` from the
**same** nvinfer config, the **same** tracker library and vendor YAML and the
**same** analytics config, and attaches two pad probes: one on `nvdsanalytics`'s
src pad for the verdict, one on `nvinfer`'s src pad for the pre-tracker detector
output.

**It is test equipment, not the application.** `deepstream-app` driven by the
`.txt` configs remains the surveillance application; the probe is never part of
it, is not installed, and its binary is not committed.

**It is cross-checked, not trusted.** §7 CHECK 3 compares its output against
`deepstream-app`'s own dumps frame by frame. Detector output is **bit-identical
on all 288 frames** (max deviation 0.0000 px).

## 6. A known, bounded divergence — deliberately not papered over

The probe and `deepstream-app` disagree on **10 frames**: 44–48 and 50–54.

```
detector frames compared      288
detector mismatches           0, max dev 0.0000 px
post-tracker diverging frames 10 (max frame 54)
diverging frames              44,45,46,47,48,50,51,52,53,54
```

Those are exactly the **5-frame probation windows** of the two tracks
(`probationAge: 5` in the NvSORT YAML; track 0 begins at 44, track 1 at 50).
Under `deepstream-app` the low-level tracker claims the target immediately; here
it does not until probation completes, so the object is still
`UNTRACKED_OBJECT_ID` and `removeUntrackedObjects()`
(`nvtracker_proc.cpp:2169-2192`) drops it.

**A fix that was found and rejected.** Setting `operate-on-class-ids=2` on the
probe's tracker makes the object *counts* agree exactly — that gate also disables
the removal. But the retained objects still carry `UNTRACKED_OBJECT_ID` and an
empty tracker bbox, so it **hides the difference rather than resolving it**. It
was reverted; the divergence is reported instead.

**What is established:** the detector is bit-identical; the divergence is
entirely in low-level tracker state; it is confined to the first frames of each
track; every other frame matches exactly, including object ids and box
coordinates to within 0.01 px.

**What is not established:** why the low-level tracker claims a target
immediately under `deepstream-app` and only after probation here. The candidate
`attach-sys-ts` was checked and ruled out (`deepstream-app` defaults it to `TRUE`,
which is also the element default). Mechanism **unproven**.

The verification does not absorb this into a tolerance. It **bounds** it: the
divergence must end more than 20 frames before the zone is entered, or the
analytics evidence is rejected. Measured: last divergence at frame 54, entry at
109.

## 7. Verification results

`./scripts/verify_zone.sh` — headless, no display, terminates on its own.
Five runs, 14 checks. **Exit status 0, all checks passed.**

```
== CHECK 1: the application runs, with nvdsanalytics instantiated ==
  PASS  deepstream-app exited 0
  PASS  no pipeline errors in the log
  PASS  GStreamer created an nvdsanalytics element
  PASS  nvdsanalytics parsed its configuration without error
  PASS  the FP16 engine was not rebuilt or modified
== CHECK 2: analytics changed neither detection nor tracking ==
  PASS  control run has no nvdsanalytics element
  detector frames differing    0
  tracker frames differing     0
  PASS  detector output is materially identical with and without analytics
  PASS  tracker output is materially identical with and without analytics
== CHECK 3: the probe ran the SAME pipeline as the application ==
  PASS  detector output is bit-identical on all 288 frames
  PASS  post-tracker divergence ends at frame 54, more than 20 frames before
        the zone is entered at 109
== CHECK 4: analytics metadata is present and machine-readable ==
  PASS  every frame carries NvDsAnalyticsFrameMeta
  PASS  per-object roiStatus agrees with the frame-level count on every frame
== CHECK 5: the person is OUTSIDE the zone before entering ==
  PASS  no ROI occupancy on any frame before 109
== CHECK 6: the person ENTERS the zone ==
  PASS  entry at frame 109, within +/-2 of the predicted 109
== CHECK 7: the person REMAINS inside for a measurable interval ==
  PASS  75 frames inside (>= 70)
  PASS  occupancy is a single unbroken interval
== CHECK 8: the person EXITS and remains visible afterwards ==
  PASS  exit after frame 183, within +/-2 of the predicted 183
  PASS  the person stays tracked for 90 frames after leaving the zone
== CHECK 9: DeepStream's verdict vs an independent recomputation ==
  PASS  100.00% agreement with the recomputed foot-point rule
== CHECK 10: class-id=2 is what restricts the rule ==
  PASS  only class 2 (person) was ever flagged inside the zone
  PASS  with class-id=0 the identical ROI reports zero occupancy
== CHECK 11: the ROI test point is the FEET, not the centroid ==
  PASS  the same ROI gives 75 frames under the foot rule and 0 under a
        centroid rule; DeepStream reports 75
== CHECK 12: a broken analytics config must fail the run ==
  PASS  a nonexistent analytics config fails the run (exit 255)
== CHECK 13: nothing beyond the approved scope ==
  PASS  ROI filtering only
== CHECK 14: earlier checkpoints still pass ==
  PASS  no new ID switches were introduced by analytics
  PASS  verify_tracking.sh exited 0
  PASS  verify_inference.sh exited 0
  PASS  verify_simulated_stream.sh exited 0
```

### The measured occupancy

```
frames written by the probe      288
frames with analytics frame meta 288
frames with objInROIcnt > 0      75
entry frame                      109
exit frame (last inside)         183
contiguous runs                  1
    frames 109..183  (75 frames, 2.50 s)
per-object roiStatus agrees      yes

foot rule (what DeepStream uses) 75 frames  (entry 109, exit 183, 1 run)
centroid rule (counterfactual)   0 frames

frames compared                  230
disagreements                    0
agreement                        100.00%
```

**Zero disagreements across 230 frames** between DeepStream's own verdict and an
arithmetic reimplementation of its rule driven from `deepstream-app`'s track
dump. Because the recomputation is a reimplementation rather than a call into the
library, agreement is evidence about the pipeline rather than a tautology.

## 8. The class filter is what selects the person

`class-id=2` is checked *before* the ROI test (`CheckValidClass`,
`nvds_analytics.cpp:594-598`), so it filters the rule, not the output. Rather
than cite that, the verification runs the experiment: the **identical** ROI on
the **identical** clip with `class-id=0` (car).

```
class-id=0 run exit status   0
frames with occupancy > 0    0
objects flagged in ROI       0
```

The person walks through the zone exactly as before and is never flagged. The
class filter, not the geometry, is what selects them.

## 9. Two behaviours worth knowing

**A broken analytics config fails loudly** — unlike the tracker. Checkpoint 2
found that a nonexistent `ll-config-file` only warns and silently substitutes
tracker defaults. `nvdsanalytics` is stricter:

```
ERROR nvdsanalytics_property_parser.cpp:863: Failed to parse config file
      /nonexistent/config_zone_NOPE.txt: No such file or directory
** ERROR: <main:719>: Failed to set pipeline to PAUSED
$ echo $?
255
```

**Per-object analytics indications never reach the screen.** At `osd-mode=2`
`nvdsanalytics` appends `" ROI:RF"` to each object's label and inverts its box
border colour (`gstnvdsanalytics.cpp:1021-1048`). But `deepstream-app`'s
`process_meta` runs downstream and does `g_free(display_text); display_text =
NULL;`, then rebuilds the label from the GIE config and resets
`rect_params.border_color` from `bbox-border-colorN`. **Both are discarded.**
What *does* draw is the frame-level display meta — the ROI outline and the live
`RF=<count>` label — because `deepstream-app` never touches
`frame_meta->display_meta_list`.

## 10. Impact on earlier checkpoints

`nvdsanalytics` is the second stage to invalidate an earlier "this must not
exist" assertion by design. Both were narrowed, and the narrowing is recorded
where it happened:

| Script | Was | Now |
|---|---|---|
| `verify_inference.sh` CHECK 8 | no tracker, then no analytics | nothing beyond the approved scope |
| `verify_tracking.sh` CHECK 9 | no analytics | nothing beyond the approved scope |

Both now assert the absence of secondary inference, line crossing, overcrowding,
direction detection and messaging — the things that really are still out of
scope. What each checkpoint owns is unaffected, and checkpoint 3 proves it
rather than asserting it: with analytics disabled, the detector and tracker
dumps differ on **0 of 288 frames**.

One further consequence had to be fixed: since checkpoint 3 there are **two**
config groups carrying a `config-file=` key, and `verify_inference.sh`'s
class-filter run used a blanket `sed` on it — which pointed `nvdsanalytics` at an
nvinfer config and failed the whole run. It now rewrites the key for
`[primary-gie]` only and disables analytics for that detector-only check.

## 11. Negative cases

| Case | Result |
|---|---|
| Analytics `config-file` nonexistent | `Failed to parse config file`; `deepstream-app` **exit 255** |
| Probe `--analytics-config` nonexistent | `ERROR: --analytics-config does not exist`; **exit 1** |
| Probe `--out-dir` not a directory | `ERROR: --out-dir must name an existing directory`; **exit 1** |
| Unknown script option | `ERROR: Unknown option '--nope'. Try --help.`; **exit 1** |
| `[nvds-analytics] enable=0` | Runs cleanly with no analytics element; used as the control in CHECK 2 |
| `make -C tools clean && make -C tools` | Rebuilds from scratch, exit 0, no warnings at `-Wall -Wextra` |

## 12. Known limitations

1. **A probe was needed at all.** The ROI verdict cannot be obtained from the
   shipped application (§5). The evidence therefore comes from a second binary,
   admissible only because of the cross-check in §6.
2. **10 frames diverge between the probe and the application** (§6), and the
   mechanism is unproven. Bounded, far from the ROI interval, and reported —
   but not explained.
3. **One clip, one person, one zone.** Overcrowding, multi-object occupancy,
   line crossing, direction detection and re-entry are all untested.
4. **Occupancy is history-dependent** through `mean_h` (§4), so it is not a pure
   function of the current frame. The recomputation models this; it is still a
   model.
5. **`obj-cnt-win-in-ms` is misnamed** — it is a frame count for the history
   window, not milliseconds. Left at its default rather than tuned.
6. **No performance claim.** `nvdsanalytics` adds work, and this pipeline's
   end-to-end throughput has never been measured.
7. **On-screen confirmation is a human check.** No headless test covers what
   `nvdsosd` draws, and per-object analytics indications never reach it (§9).

## 13. Completion criteria

| Criterion | Status |
|---|---|
| `nvdsanalytics` inserted after `nvtracker` | Done — placement is fixed by `deepstream-app` |
| Restricted zone defined from measured geometry | Done — §3 |
| Person outside the zone initially | Done — no occupancy before frame 109 |
| Person enters at ~frame 109 | Done — frame 109, within ±2 |
| Person remains inside ~75 frames | Done — 75 frames, one unbroken run |
| Person exits after ~frame 183 | Done — frame 183, within ±2 |
| Person remains visible after leaving | Done — 90 tracked frames |
| DeepStream's own metadata confirms it | Done — `NvDsAnalyticsFrameMeta` on all 288 frames |
| Detection unchanged | Done — 0 of 288 frames differ |
| Tracking unchanged | Done — 0 of 288 frames differ, 0 new ID switches |
| `class-id=2` proven to control the rule | Done — `class-id=0` gives zero occupancy |
| Verdict matches independent recomputation | Done — 100.00% over 230 frames |
| Broken analytics config fails loudly | Done — exit 255 |
| No line crossing / overcrowding / direction / messaging | Done — static check |
| Checkpoints 1–2 and Milestone 2 regressions pass | Done — all exit 0 |
| On-screen ROI rendering confirmed | **Not done** — needs a visible run |
