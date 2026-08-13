# Milestone 08.3 — Redeployment after the sustained-load characterisation

**Goal.** Establish that the deployment artifact survived Milestone 8.2 intact,
by launching it again in fresh independent containers and checking that it still
reproduces the established application behaviour.

**Status: complete. M8.3 PASSES.** Two fresh `docker run --rm` invocations of
`video-surveillance-deepstream:m7-triton` on 2026-08-13, both exit 0, with every
primary behavioural invariant matching exactly:

| | |
|---|---|
| Frames | **288 / 288**, clean EOS, `App run successful` |
| Exit codes | `deepstream-app` **0**, `analytics_probe` **0** |
| Tracking | **0** mid-track ID switches, **2** unique ids, **224**-frame run over frames **50..273** |
| Restricted zone | entry **109**, **75** frames inside, exit **183**, **1** unbroken interval |
| Analytics agreement | **100.00%**, 0 disagreements over 230 frames |
| Detector variance vs the pre-soak reference | **0 of 288** frames differ (tolerance ≤ 5) |
| Hygiene | no container, no orphan process, no new image or layer, engine hash unchanged |

The single most important qualifier, stated before any result is read:

> This was **not** an immediate hot restart. The Milestone 8.2 soak finished on
> 2026-08-12 at 19:07; these runs began on 2026-08-13 at 17:56, roughly 23 hours
> later, with the board idle at 45.12 °C. M8.3 proves **later** redeployment. It
> proves nothing about restarting the application while the Jetson is still hot
> or still holding post-load state.

---

## 1. Purpose

Milestone 8.2 subjected the deployed artifact to 604 s of unpaced load, roughly
109,000 frames, at a sustained 178 fps. Milestone 8.3 asks the obvious follow-up
and nothing more:

> After completing the sustained-load characterisation, can the existing
> deployment artifact still be launched in fresh independent containers and
> reproduce the established application behaviour?

This is a **redeployment and reproducibility check**. It is not another
performance measurement: no throughput distribution, no thermal characterisation,
no RSS trend, no power figure, and no looping. Milestone 8.2 owns all of those
([`milestone-08-edge-deployment.md`](milestone-08-edge-deployment.md)).

It also closes a gap that predates the soak. `verify_triton.sh` launches the
image five times in a single pass, so "the image can be launched repeatedly" was
true in practice — but agreement between two **independent, separately invoked**
deployments was never *asserted*
([`milestone-08-inspection.md`](milestone-08-inspection.md) §4).

## 2. Scope

**In scope:** two fresh container invocations, the behavioural invariants those
runs compute about themselves, a detector-variance comparison against the
pre-soak dumps, and deployment hygiene afterwards.

**Deliberately out of scope:**

- Re-running `verify_triton.sh`. That script is Milestone 7's statement of
  record; re-running it would re-assert M7's claims rather than M8.3's. It also
  depends on the external `/home/matan/m6-baseline`, launches five containers
  including a deliberately failing one, and asserts `objcount_mismatches == 0`
  strictly (`verify_triton.sh:583-588`) — a criterion the project's own
  documented detector jitter could break for reasons unrelated to deployment.
- Comparing against `/home/matan/m6-baseline`. That is the **nvinfer** path, and
  diffing against it would resurface the M7 nvinfer-vs-nvinferserver numerical
  divergence. M8.3 does not reopen Milestone 7.
- Any new verification script. The existing machinery was sufficient, and §6
  records exactly what was used instead.

## 3. The timing limitation

This is recorded first because it bounds every claim that follows.

| Event | Time |
|---|---|
| M8.2 soak ended | 2026-08-12 19:07 |
| M8.3 pre-test state captured | 2026-08-13 17:55:42 |
| M8.3 Run A started | 2026-08-13 17:56:37 |
| Gap | **~23 hours** |

The board was measurably cold when the runs began — `tj` **45.12 °C**, GPU
devfreq at its **306 MHz** idle floor — against the soak's 64.97 °C peak and
pinned 1020 MHz.

**The soak was deliberately not re-run to recreate the hot condition.** Doing so
would have cost another ten minutes of full-load operation to manufacture a
state that the milestone's actual question does not require, and re-running a
completed experiment to make a later test look stronger is the wrong reason to
spend a measurement. §14 states plainly what this costs.

## 4. The artifact used

Unchanged from Milestone 7 and Milestone 8.2. Nothing was built, pulled or
pruned.

| | |
|---|---|
| Image | `video-surveillance-deepstream:m7-triton`, id `6e53ea730fc6` |
| Engine | sha256 `35677da6a31aa3724b1d7d93f6b8925a64a7a64b6790a55c18413562725270a6` |
| Serving | `nvinferserver` → in-process Triton → TensorRT |
| App config | `deepstream_app_walk_triton.txt` (the **M7** config, `file-loop=0`) |
| Network | `--network none` on both runs |

Note that M8.3 uses the ordinary Milestone 7 application config, **not** the
Milestone 8.2 soak config. The soak config exists to loop and to suppress the
KITTI dumps; M8.3 needs exactly the opposite — a single bounded 288-frame pass
that writes the dumps the analysers consume.

## 5. Pre-test state

Captured read-only before anything ran. No power mode or clock was changed.

```
date            2026-08-13T17:55:42+03:00

/dev/mmcblk0p1  116G   86G   25G  78% /

TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          2         0         42.51GB   14.08GB (33%)
Containers      0         0         0B        0B
Local Volumes   0         0         0B        0B
Build Cache     81        0         24.49GB   397.3kB

docker ps -a    (no rows)

engine sha256   35677da6a31aa3724b1d7d93f6b8925a64a7a64b6790a55c18413562725270a6
power mode      2  (MAXN_SUPER)
tj temp C       45.12
gpu devfreq MHz 306
```

The engine hash matching the value frozen since Milestone 6 is the first result
of this milestone, not a formality: it establishes that the soak did not disturb
the artifact under test.

### Preserving the pre-soak dump reference

`models/{detections,tracks,zone}/` held 1152 files, **all** carrying a single
mtime of `2026-08-12 00:36`. The fresh runs overwrite them in place, so they were
copied to a scratch location first (3.9 MB, outside the repository, never staged).

Their provenance is stated honestly in §11.

## 6. Test procedure

No new script was written. Two existing modes of `run_container.sh`, then the two
existing analysers.

```
1.  capture pre-test state                                   [read-only]
2.  snapshot models/{detections,tracks,zone} to scratch
3.  ./scripts/run_container.sh --headless --triton   | tee run_a_headless.log
4.  ./scripts/run_container.sh --zone     --triton   | tee run_b_zone.log
5.  analyze_tracks.py --detections/--tracks/--terminated/--shadow --verdict
6.  analyze_zone.py   --zone/--tracks/--config --verdict
7.  assert invariants; diff fresh dumps against the snapshot
8.  capture post-test state and hygiene checks               [read-only]
```

**Two runs, not one, and the split is not cosmetic.** `deepstream-app` can *run*
`nvdsanalytics` but cannot *report* it — the finding that forced
`tools/analytics_probe.cpp` into existence in Milestone 5. So Run A produces the
detector and tracker KITTI dumps, and Run B is the only thing that can produce
the restricted-zone verdict. Each is a separate, fresh `docker run --rm`, which
is also what makes this a two-invocation redeployment test rather than one.

Exit status was taken from `PIPESTATUS[0]` in both cases, because `tee` would
otherwise mask a failure. No `|| true` was used anywhere.

## 7. Headless deployment result — Run A

```
$ ./scripts/run_container.sh --headless --triton
...
nvstreammux: Successfully handled EOS for source_id=0
** INFO: <bus_callback:685>: Received EOS. Exiting ...
Quitting
[NvMultiObjectTracker] De-initialized
App run successful

RUN A exit status: 0
```

| Criterion | Required | Observed |
|---|---|---|
| Exit status | 0 | **0** |
| Detector dump files | 288 | **288** |
| Tracker dump files | 288 | **288** |
| `ERROR from element` | absent | **0 occurrences** |
| `App run failed` | absent | **0 occurrences** |
| Clean EOS | present | **present** |
| `App run successful` | present | **present** |

The run also confirmed the serving path from its own log: `INFO: TrtISBackend
id:1 initialized model: trafficcamnet` — Triton loaded the model from the mounted
repository, exactly as in Milestone 7.

### Log lines that look alarming and are not

Both runs emit the same benign noise Milestone 7 already characterised
([`milestone-07-triton.md`](milestone-07-triton.md) §10), reproduced here so a
future reader does not treat a passing run as suspicious:

- Twelve `GStreamer-WARNING ... Failed to load plugin` lines — optional codecs
  (`libmp3lame`, `libFLAC`, `libdca`, …) absent from the image. None is in the
  pipeline.
- `(Argus) Error ... Connecting to nvargus-daemon failed` — the CSI camera stack
  probing for a camera that does not exist. The source is a file.
- `lsmod: command not found` — a DeepStream startup probe; `kmod` is not in the
  image.
- `Driver is unsupported. Must be at least 384.00.` and `Unable to get device
  UUID` — Triton applying desktop-driver assumptions on Jetson, where the driver
  version string and device UUID are not exposed in the expected form.
- `WARNING from src_elem: No decoder available for type 'audio/mpeg...'` — the
  clip has an AAC audio track that nothing in the pipeline consumes.

None appears in the `ERROR from element` or `App run failed` forms that
`verify_triton.sh:482-487` treats as failures, and both are asserted absent above.

## 8. Tracking result

`scripts/analyze_tracks.py` on the fresh Run A dumps. Verdict verbatim, with the
asserted keys marked:

```
frames_total=288                    <-- required 288
det_frames=230
trk_frames=230
unique_ids=2                        <-- required 2
id_list=0,1
longest_run_id=1
longest_run_len=224                 <-- required 224
longest_run_start=50                <-- required 50
longest_run_end=273                 <-- required 273
dominant_id=1
dominant_coverage_pct=97.4
mid_track_switches=0                <-- required 0
establishment_switches=1
untracked_rows=0
duplicate_id_frames=0
reacquisitions=0
ids_with_internal_holes=0
interior_det_gaps=0
```

**All five asserted invariants match exactly.**

`unique_ids=2` is asserted deliberately rather than merely printed. Zero
mid-track switches plus a 224-frame dominant run would still hold if the tracker
had invented a third identity somewhere else in the clip; the established
behaviour is exactly two ids, and only checking the count catches that
(`verify_triton.sh:606-609`).

`establishment_switches=1` is the single early ID change as the walker enters at
the image border — characterised but never explained since Milestone 5
([`milestone-05-tracking.md`](milestone-05-tracking.md) §11), and expected here.
It is not a mid-track switch and does not affect zone logic.

## 9. Restricted-zone result

`scripts/analyze_zone.py` on the fresh Run B zone dumps paired with the fresh Run
A tracker dumps — the same cross-run pairing `verify_triton.sh:701-703` uses.

```
roi_label=RF
zone_files=288
frames_with_analytics_meta=288
ds_entry=109                        <-- required 109
ds_exit=183                         <-- required 183
ds_frames_inside=75                 <-- required 75
ds_runs=1                           <-- required 1
ds_longest_run=75
obj_roistatus_frames=75             <-- required 75
frame_obj_agree=1                   <-- required 1
centroid_rule_frames_inside=0       <-- required 0 (control)
compared_frames=230
disagreements=0                     <-- required 0
agreement_pct=100.00                <-- required 100.00
rect_vs_trk_max_dev=0.00
```

**All nine asserted invariants match exactly.**

Three of these are worth naming individually, because each guards a different
failure mode:

- **`agreement_pct=100.00` / `disagreements=0`** — DeepStream's own
  `NvDsAnalyticsFrameMeta` still agrees with an independent recomputation from
  the tracker boxes on every one of 230 frames. A corrupted or stale zone dump
  could not produce this.
- **`frame_obj_agree=1` with `obj_roistatus_frames=75`** — the per-*object* ROI
  flag agrees with the per-*frame* verdict on every frame. A frame counter can be
  right while the object flags are wrong.
- **`centroid_rule_frames_inside=0`** — the counterfactual control from
  Milestone 5. The ROI geometry was chosen so the foot rule gives 75 frames and a
  centroid rule gives 0; that separation still holds, which proves the reference
  point is still the feet and not the centroid.

## 10. Detection-variance comparison

Secondary, corroborating evidence — not the verdict.

| Comparison | Differing | Threshold | Result |
|---|---|---|---|
| Detector dumps, fresh vs pre-soak | **0** of 288 | ≤ 5 | Pass |
| Tracker dumps, fresh vs pre-soak | **0** of 288 | ≤ 5 | Pass |
| Zone dumps, fresh vs pre-soak | **0** of 576 | — (context) | — |

| Metric | Fresh run | Pre-soak reference |
|---|---|---|
| Detecting frames | **230 / 288** | 230 / 288 |
| Total detected objects | **230** | 230 |

The tolerance is the project's own, and it is a file count rather than a
percentage: `DET_DIFF <= 5` out of 288, used identically in
`verify_container.sh:277,287` and `verify_zone.sh:186,192`. It exists because
Milestone 5 measured three identical runs producing 232, 230 and 230 detections,
with the variation "confined to two frames and one borderline detection"
([`milestone-05-inspection.md`](milestone-05-inspection.md) §3).

**The result came in far inside that tolerance: all 1152 files are byte-identical
to the pre-soak set.** No jitter occurred on this run. That is a stronger outcome
than the criterion demanded, and it is reported as what it is — one run's result,
not a claim that jitter has gone away. The tolerance remains the correct
criterion precisely because the next run might differ on two frames.

## 11. Provenance of the historical reference

The reference set is dated but **not attested**, and the distinction matters
enough to state separately.

| | |
|---|---|
| What it is | 1152 files under `models/{detections,tracks,zone}/` |
| Uniform mtime | `2026-08-12 00:36` across every file |
| Believed to be | The Milestone 7 `verify_triton.sh` **subject** run (nvinferserver + in-process Triton) |
| Basis for that belief | File mtimes and project history |
| What it lacks | Any manifest or fingerprint. Unlike `/home/matan/m6-baseline`, which carries `MANIFEST.sha256` and a `FINGERPRINT` over that manifest, this set was never sealed |

Because of that gap, **M8.3's acceptance never depended on it.** The verdict in
§15 rests entirely on the invariants in §7–§9, every one of which the fresh runs
compute about themselves with no reference of any kind.

One observation does strengthen the provenance, offered as evidence rather than
proof: Milestone 7 recorded that the nvinfer and nvinferserver paths differ
byte-wise on **230 of 288** detector files
([`milestone-07-triton.md`](milestone-07-triton.md) §7). The fresh Triton run
differs from this reference on **0**. Had the snapshot actually been an nvinfer
capture, 230 files would differ. So the snapshot is not from the nvinfer path —
which is consistent with, though not conclusive of, its being the M7 Triton
subject run.

## 12. Post-run hygiene

Every check below compares against the §5 pre-test capture.

| Check | Before | After |
|---|---|---|
| `docker ps -a` | no rows | **no rows** |
| Images | 2 (`6e53ea730fc6`, `fd31f5b44aba`) | **2, same ids** |
| `docker system df` — Images | 42.51 GB, 14.08 GB reclaimable | **identical** |
| `docker system df` — Containers | 0, 0 B | **identical** |
| `docker system df` — Build Cache | 81, 24.49 GB, 397.3 kB | **identical** |
| Free space on `/` | 25 GB | **25 GB** |
| Engine sha256 | `35677da6…` | **`35677da6…`** |
| `.engine` files in `models/engines/` | 4 | **4, all dated Aug 8** |

Process and artifact checks:

- **No orphan `deepstream-app`, no orphan `analytics_probe`**, checked with
  `ps -eo comm= | sort -u` — the self-match-free method, after `pgrep -f`
  produced three false positives during Milestone 8.2 by matching its own command
  line. The only related process present is `nvargus-daemon`, a host service that
  started at **16:02:56**, one hour and fifty-four minutes before Run A. It is not
  ours.
- **No output video.** A search for `*.mp4`/`*.mkv`/`*.h264`/`*.plan`/`*.engine`
  created today returns 0 files.
- **No unexpected generated file.** Every file created during the test lives in
  `models/{detections,tracks,zone}/`; the largest is 189 bytes.
- **No new Docker image and no new layer attributable to M8.3.** Both runs used
  `--rm`, and the writable-layer total is still 0 B.
- **Disk impact is effectively zero.** The dumps are overwritten in place —
  936 KB, 936 KB and 2.1 MB, the same files as before — and `df` reports 25 GB
  free on both sides.

`docker system df` is byte-identical before and after, and `df` reports the same
figure at 1 GB granularity. The stronger claim — that the filesystem is
byte-identical — is **not** made, because it was not measured.

## 13. What this test proves

1. **The deployment artifact survived the sustained-load work intact.** The
   image, the FP16 engine (hash unchanged), the Triton model repository and the
   configs are all still exactly what Milestone 7 certified.
2. **A fresh container reproduces the established behaviour exactly.** 288
   frames, clean EOS, exit 0, and all fourteen asserted tracking and zone
   invariants at their established values.
3. **Two independent invocations agree.** This is the claim the inspection
   identified as never having been *asserted*, despite `verify_triton.sh`
   launching the image five times per pass.
4. **The soak left no residue that interferes with a later deployment.** No
   container, no orphan process, no Docker state change, no engine mutation, no
   disk growth.
5. **Detector output is reproducible well inside the documented tolerance** — in
   this instance byte-identical across all 1152 files.

## 14. What this test does not prove

1. **Nothing about a hot restart.** The board was at 45.12 °C and 306 MHz. A
   redeployment at 65 °C with the GPU pinned at 1020 MHz is a different
   experiment, and this one says nothing about it.
2. **Nothing about immediate post-load recovery.** Roughly 23 hours passed, so
   any transient GPU, driver or allocator state the soak left has had a full day
   to clear.
3. **Nothing about the unresolved M8.2 memory question.** This is a 9.61-second
   process. Its RSS trajectory is irrelevant to whether a long-lived
   `deepstream-app` converges, and **M8.3 does not close that question.**
4. **Nothing about the unexplained blank log lines.** That observation stands
   open.
5. **Nothing about clean-machine reproducibility.** `verify_triton.sh` still
   depends on `/home/matan/m6-baseline`, outside the repository. That debt is
   unchanged.
6. **Nothing about repeated redeployment at scale.** Two invocations were run,
   not twenty. Nor was reboot persistence, autostart or unattended restart
   tested — all deliberately out of scope for this project.

## 15. M8.3 verdict

| Criterion group | Result |
|---|---|
| Execution — 288 frames, both exits 0, clean EOS, no pipeline error | **PASS** |
| Tracking — 0 switches, 2 ids, 224 frames, 50..273 | **PASS** |
| Restricted zone — 109 / 75 / 183, 1 run, 100.00%, 75, 1, control 0 | **PASS** |
| Detector variance — 0 of 288 differ, tolerance ≤ 5 | **PASS** (corroborating) |
| Deployment hygiene | **PASS** |

> **M8.3: PASS.**

Every primary invariant was met by the fresh runs on their own evidence. The
historical comparison agreed, and would not have been allowed to overturn the
verdict had it not.

## 16. Milestone 8 verdict

> **Milestone 8 — Deploy on Edge Device (Jetson): COMPLETE.**

| # | Checkpoint | Status |
|---|---|---|
| 8.1 | Edge environment and deployment inspection | Complete — [`milestone-08-inspection.md`](milestone-08-inspection.md) |
| 8.2 | Full-pipeline characterisation and bounded soak | Complete — [`milestone-08-edge-deployment.md`](milestone-08-edge-deployment.md) |
| 8.3 | Redeployment after load | Complete — this document |

The capstone requirement — *"Edge: run on Jetson Orin/Xavier with
`deepstream-app`"* — was literally satisfied back at Milestone 6. What Milestone 8
adds is the evidence that makes the claim worth anything: the deployed pipeline
sustains ~178 fps with 5.94× real-time headroom, does not thermally throttle,
does not degrade over ten minutes, and can still be redeployed afterwards
reproducing behaviour exactly.

**Two questions remain open and are not closed by this milestone**, carried
forward in [`../PLAN.md`](../PLAN.md) §10:

- Whether `deepstream-app`'s resident set converges. M8.2 measured +84.91 MB of
  decelerating, stepwise growth over ten minutes; no leak is claimed and none is
  ruled out.
- What writes the ~15,226 empty lines into the application log at a ~24.9 Hz
  cadence. The cause was not isolated.

Neither affects the Milestone 8 verdict, and neither is resolved by a fresh
9.61-second run.

Next: **Milestone 9 — Monitoring and Logging.**
