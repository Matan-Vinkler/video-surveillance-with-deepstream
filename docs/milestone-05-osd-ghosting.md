# Milestone 05 — The OSD ghosting defect

A rendering defect found during the visible check of checkpoint 1, and the
experiment that isolated its cause. Recorded because the fix is otherwise
inexplicable: the working configuration contains a **1×1 tiler**, which looks
like dead configuration until you know why it is there.

---

## 1. Symptom

The headless verification passed every check, so the pipeline was taken to
visible playback through `nv3dsink`. The current bounding box tracked the walker
correctly, but **boxes from previous frames stayed on screen**, leaving a trail
of stale rectangles behind the moving person.

Nothing in the automated verification had caught it, because every automated
check operated on **metadata**, and the metadata was correct. This is the value
of having kept a visible check in the plan: a metadata-level test cannot see a
rendering artifact.

## 2. Metadata accumulation: ruled out first

Before touching rendering, the obvious alternative explanation had to be
eliminated — that objects were accumulating in `NvDsFrameMeta` across frames.
The KITTI dump writes one file per frame, so accumulation would show as a
growing per-frame count. It does not:

```
frames total                        : 288
max detections in any single frame  : 1
  0 det/frame : 58 frames
  1 det/frame : 230 frames

frame 000: 0    frame 099: 1    frame 199: 1    frame 287: 0
```

If detections were accumulating, frame 199 would carry ~199 objects. It carries
**1**, and the final frames return to **0**. Metadata is clean; the defect is
purely in rendering, downstream of `nvinfer`.

## 3. What the OSD was actually configured to do

Our `[osd]` group did not set `process-mode`, but that does **not** mean the
element's own default applied. `deepstream-app` supplies its own defaults before
parsing (`deepstream_config_file_parser.c:1184-1187`) and then always applies
them (`deepstream_osd_bin.c:64,76-78`):

| Property | In our file | Effective | Source |
|---|---|---|---|
| `process-mode` | unset | **1 = MODE_GPU** | `parse_osd`: `config->mode = MODE_GPU` |
| `display-bbox` | unset | `TRUE` | `config->draw_bbox = TRUE` |
| `display-text` | unset | `TRUE` | `config->draw_text = TRUE` |
| `display-mask` | unset | `FALSE` | `config->draw_mask = FALSE` |

Available modes (`gst-inspect-1.0 nvdsosd`): `0 = MODE_CPU` ("CPU_MODE only
support RGBA format"), `1 = MODE_GPU`, `2 = MODE_NONE` ("Invalid mode. Falls
back to GPU"). So there was exactly one alternative to test: CPU mode.

**All 21 stock NVIDIA configs with an `[osd]` group leave `process-mode` unset**,
so they all run GPU mode too. The defect was occurring in the same mode NVIDIA
ships — which meant mode alone was unlikely to be the differentiator, and made
one other difference conspicuous: every stock rendering config enables a tiler,
while ours had `[tiled-display] enable=0`.

## 4. A measurement that changed the diagnosis

`osd_bin` contains **no capsfilter** — only
`osd_queue → osd_conv → osd_conv_queue → nvosd0` — and `nvdsosd`'s sink pad
accepts **both** NV12 and RGBA. So the format is negotiated freely. Measured on
the running pipeline:

```
gst_nvvideoconvert_fixate_caps:<osd_conv> fixated othercaps to
    width=(int)1920, height=(int)1080, format=(string)NV12
```

**`osd_conv` fixates NV12 → NV12 and converts nothing.** It is a no-op, so
`nvdsosd` draws into a buffer it received by reference rather than one allocated
for it.

This also corrected an error in the earlier inspection document, which had
claimed `osd_conv` converts NV12 → RGBA. That claim was reasoned from the
element's presence in the bin, not measured.

## 5. The experiment

Three configurations, everything else held identical — same source, same FP16
engine, same nvinfer config and thresholds, same `nvstreammux`, same sink and
pacing.

| Configuration | OSD draw | `osd_conv` fixates | Fresh buffer before OSD? | Ghosting |
|---|---|---|---|---|
| **Baseline** | GPU | NV12 → NV12 (no-op) | **no** | **yes** |
| **Test A** — `process-mode=0` | **CPU** | NV12 → **RGBA** | **yes** (conversion allocates) | **no** |
| **Test B** — 1×1 tiler, GPU mode | GPU | NV12 → NV12 (no-op) | **yes** (tiler composites) | **no** |

### Test A — CPU OSD mode

Ran cleanly (exit 0, no errors), and the ghosting disappeared.

A prediction made before running it was **wrong**: the plan expected CPU mode to
fail its RGBA precondition, since the negotiated format was NV12. In fact
putting `nvdsosd` in CPU mode **restricts its sink caps**, and `nvvideoconvert`
renegotiates to RGBA automatically — no manual capsfilter needed.

But that same renegotiation made Test A **confounded**: changing `process-mode`
also flipped `osd_conv` from a no-op into a real conversion, which necessarily
allocates a new buffer. Two variables moved at once, so a positive result could
not say which one mattered.

### Test B — 1×1 tiler, OSD left in GPU mode

`[tiled-display] enable=1, rows=1, columns=1, width=1920, height=1080`, with
`process-mode` untouched.

The tiler was confirmed genuinely instantiated by dumping the pipeline graph and
diffing element lists against the baseline, rather than trusting the config key:

```
Test B :  GstNvMultiStreamTiler tiled_display_tiler   ← present
Baseline: (absent)
```

Ran cleanly, `osd_conv` still fixated NV12 → NV12, detection metadata was
identical — and the ghosting disappeared.

*(A note recorded during inspection had flagged `deepstream_app.c:1268` as
possibly skipping the tiler for a single source. That was a misreading: the
branch is inside `process_meta` and only controls `show_bbox_text`. Tiler
creation has no single-source exception.)*

## 6. The isolated variable

**The draw backend is not the cause.** Test B keeps GPU mode *and* keeps
`osd_conv` as a no-op — identical to the ghosting baseline in both respects —
and the trail is still gone.

The one factor common to both fixes is that **something upstream of `nvdsosd`
produced a fresh buffer**: in Test A the RGBA conversion, in Test B the tiler's
composite. In the baseline nothing did.

CPU mode therefore worked only *incidentally*, as a side effect of the format
change it triggered.

## 7. Chosen fix

**Test B: a 1×1 tiler, OSD left in GPU mode.** Applied to both
`deepstream_app_walk_display.txt` and `deepstream_app_walk_headless.txt`.

| Reason | |
|---|---|
| Keeps the GPU draw path | The DeepStream default, and the one NVIDIA ships |
| Matches NVIDIA's topology | All 21 stock rendering configs use a tiler; ours was the outlier |
| Metadata provably unchanged | 288 frames, 230 person detections, **per-frame identical** to the pre-tiler baseline |
| No unexplained divergence | Unlike CPU mode, which would have been adopted for a reason that turned out to be wrong |

The checkpoint-1 display topology was amended accordingly:

```
source → decoder → nvstreammux → nvinfer → nvmultistreamtiler → nvdsosd → sink
```

Both configs carry a comment explaining why a 1×1 tiler exists, so it is not
later removed as redundant.

## 8. The mechanism is NOT proven

A plausible explanation is that `nvdsosd`, drawing in place into a buffer it did
not own, modified a surface still referenced upstream — possibly one of NVDEC's
H.264 reference frames, in which case motion compensation would propagate the
drawn pixels into subsequent frames and smear them along the direction of
motion. That would match the observed symptom.

**This has not been demonstrated.** What the experiment establishes is narrower
and should not be overstated:

- ✅ Metadata accumulation is ruled out — measured.
- ✅ The fix requires a fresh buffer upstream of `nvdsosd` — isolated across three
  configurations.
- ✅ The draw backend is irrelevant — Test B keeps GPU mode and works.
- ❌ *Why* in-place drawing persists across frames — **hypothesis only.**

Confirming it would mean showing that `osd_conv` runs in passthrough and that
`nvdsosd` writes to a decoder-owned surface. `GST_BASE_TRANSFORM` logging
produced no output for `osd_conv`, so that route was not available, and the
question was not pursued further because the fix does not depend on the answer.

## 9. What this cost, and what it bought

A performance comparison between GPU and CPU OSD modes was attempted and is
**inconclusive**: medians differed by less than the run-to-run spread, one run
was a 2× outlier, and total wall time is dominated by fixed startup rather than
288 frames of OSD work. It established only that both modes run at 65–84 fps
headless, comfortably above the 29.97 fps the source requires.

The broader lesson is recorded deliberately: **the automated verification passed
while the output was visibly wrong.** Metadata-level checks proved `nvinfer` was
producing correct objects, and were entirely blind to what `nvdsosd` did with
them. Keeping a human visible check in the plan is what caught this.
