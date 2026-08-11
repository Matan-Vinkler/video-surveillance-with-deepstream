# Milestone 07 — Serving the model through in-process Triton

**Goal.** Replace DeepStream's direct `nvinfer` inference with a model-serving
architecture — `nvinferserver` driving an in-process Triton Inference Server —
and prove that the surveillance application still does the same thing.

**Status: complete.** `./scripts/verify_triton.sh` exits 0 with all checks
passing, and the visible pipeline was confirmed by hand on the physical display.

The application behaviour is preserved end to end: **288 frames**, the same
**230 detecting frames**, **0 mid-track ID switches**, a **224-frame** stable
track, and the restricted zone unchanged at **entry 109, 75 frames inside, exit
183**, with **100.00%** analytics agreement.

One real difference was found and is **not** engineered away:

> nvinfer and nvinferserver+Triton produced numerically different detector
> metadata around the same TensorRT engine, while preserving detection
> structure, tracking behavior, and restricted-zone behavior.

The cause is **not attributed**. It was not isolated, so this document does not
blame preprocessing, postprocessing, or anything else. §7 records what was
measured and stops there.

Serving is a **deployment** change. No inference configuration, threshold,
parser setting, model, tracker setting or ROI geometry was altered, and the FP16
engine was reused byte for byte rather than rebuilt.

---

## 1. Goal

Milestone 6 ran the application in a container, but inference was still
DeepStream calling TensorRT directly. Milestone 7 inserts a serving layer:

```
Milestone 6:  DeepStream ──► nvinfer ──────────────────────► TensorRT ──► FP16 engine

Milestone 7:  DeepStream ──► nvinferserver ──► Triton ──► TensorRT ──► FP16 engine
                                              (in-process)  (backend)   (unchanged)
```

The point is to learn and validate a model-serving architecture on real
hardware, while keeping the surveillance application's behaviour fixed as the
control. Any behavioural change is therefore attributable to the serving layer
and nothing else.

## 2. Architecture: what actually changed

**`nvinfer` (M5/M6)** is a DeepStream plugin that owns a TensorRT execution
context directly. It loads the `.engine` file, runs preprocessing, executes the
network, and parses the output tensors into `NvDsObjectMeta`.

**`nvinferserver` (M7)** is a different DeepStream plugin that does not execute
networks at all. It hands tensors to Triton and receives tensors back. Triton
selects a **backend** — here `tensorrt_plan` — which deserializes our existing
FP16 plan and executes it. Bounding-box parsing still happens in DeepStream,
after Triton returns raw tensors: **Triton itself knows nothing about bounding
boxes.**

The essential relationship, because it is easy to get backwards:

> **Triton does not replace TensorRT.** TensorRT remains the engine executing
> the neural network. Triton is a serving and orchestration layer *around* it —
> model repositories, versioning, backends, instance groups, batching policy.
> They solve different problems and compose.

**In-process, not networked.** Setting `model_repo` in the `triton { }` block
selects Triton's **C API**, so Triton runs as a *library* inside the
`deepstream-app` process. There is no second process, no daemon, no HTTP, no
gRPC and no port. The verification container still runs with `--network none`,
which is itself evidence that nothing is served over a socket. The gRPC
alternative would replace that block with `grpc { url: ... }` and require a
separate server.

**The model repository** is the standard Triton layout:

```
models/triton_model_repo/
└── trafficcamnet/
    ├── config.pbtxt          # committed: application configuration
    └── 1/
        └── model.plan        # NOT committed: the M4 FP16 engine, mounted read-only
```

`config.pbtxt` declares `platform: "tensorrt_plan"`, `max_batch_size: 1`, and the
exact tensor names and shapes of the engine's bindings. `strict_model_config:
true` in the nvinferserver config forces Triton to validate the plan against that
declaration, so a wrong tensor name or dimension fails **loudly at load time**
instead of silently auto-completing into something we did not intend.

`max_batch_size: 1` — not NVIDIA's sample value of 30 — because the M4 engine was
built with a fixed optimisation profile of min = opt = max = 1. It physically
cannot serve a larger batch.

**Two config files describe one thing in two languages.** `nvinfer` takes a
key=value ini; `nvinferserver` takes protobuf text. Every parameter was
translated, not redesigned:

| nvinfer (M5/M6) | nvinferserver (M7) |
|---|---|
| `net-scale-factor=0.0039215686…` | `normalize { scale_factor: … }` |
| `model-color-format=0`, `process-mode=1` | `TENSOR_ORDER_LINEAR`, `FULL_FRAME` |
| `num-detected-classes=4` | `detection { num_detected_classes: 4 }` |
| `cluster-mode=2` (NMS) | `nms { … }` |
| `topk=20`, `nms-iou-threshold=0.5` | `topk: 20`, `iou_threshold: 0.5` |
| `[class-attrs-all] pre-cluster=0.2` | `nms { confidence_threshold: 0.2 }` |
| `[class-attrs-0] pre-cluster=0.4` | `per_class_params { key: 0 … 0.4 }` |

The app config changes **exactly two lines** in `[primary-gie]`:
`plugin-type=1` selects `nvinferserver`, and `config-file` points at the new
config. Source, streammux, tracker, analytics, ROI, tiler, OSD, sink and dump
directories are byte-for-byte the Milestone 6 file.

## 3. What was added

```
Dockerfile.triton                              # derived image on the Triton base
configs/
├── config_inferserver_trafficcamnet.txt        # nvinferserver protobuf config
├── deepstream_app_walk_triton.txt              # headless app config
└── deepstream_app_walk_triton_display.txt      # visible app config
models/triton_model_repo/
└── trafficcamnet/{config.pbtxt, 1/.gitkeep}    # repository entry
scripts/verify_triton.sh                        # the M7 verification
```

Modified: `scripts/run_container.sh` gained a `--triton` flag,
`scripts/ds_common.sh` gained `require_triton_repo()`, `tools/analytics_probe.cpp`
gained `--inference-element`, and `.gitignore` excludes `*/*/model.plan`.

Milestone 6's `Dockerfile`, `verify_container.sh` and configs are **untouched**,
so the M6 nvinfer path remains independently runnable.

## 4. The container

| | |
|---|---|
| Base image | `nvcr.io/nvidia/deepstream:9.1-triton-multiarch` |
| Base digest | `sha256:fd31f5b44ababdbdee8cd397a375e888191b49e402ac237254a4cdc239130f5b` |
| Derived image | `video-surveillance-deepstream:m7-triton` |
| DeepStream | 9.1.0 |
| Triton Server | 2.68.0, with the `tensorrt` backend |
| TensorRT | 10.16.2.10-1+cuda13.2, matching the host |
| Engine sha256 | `35677da6a31aa3724b1d7d93f6b8925a64a7a64b6790a55c18413562725270a6` |

**Why a different base than Milestone 6.** The samples image cannot serve Triton
at all. Measured in both the samples image and on the host,
`libnvdsgst_inferserver.so` ships but has exactly one unmet dependency —
`libtritonserver.so => not found` — so `gst-inspect-1.0 nvinferserver` fails. The
triton-multiarch image carries Triton at `/opt/tritonserver` and
`nvinferserver` loads there with **zero** unmet dependencies. This also closes
the open question recorded in `PLAN.md` §10, which had M7 blocked on the host
route needing `sudo ./triton_backend_setup.sh`.

**The same deliberate TensorRT deviation as Milestone 6.** This base ships
TensorRT 10.16.1.11 while the host — and therefore our engine — is 10.16.2.10.
Plan files are version-locked, so the engine would not deserialize. The image
upgrades to match the host, for the same reason M6 did: behavioural equivalence
is only provable if the inference library **and** the engine file are identical
on both sides.

**One difference from Milestone 6 bit us.** This base ships **eighteen** TensorRT
packages, not seven. The extra eleven are development packages (`libnvinfer-dev`,
`tensorrt-dev`, the headers, `libnvinfer-bin`). Pinning only the seven runtime
packages is not enough: `libnvinfer-dev` depends on `libnvinfer10` at an exact
version, so forcing the runtime to 10.16.2 forces the dev packages to move too —
and their unpinned candidate is **11.2.1.2-1+cuda13.3**. A first attempt planned
`18 upgraded, 7 newly installed`, pulling a 2369 MB `libnvinfer11` from the SBSA
repo. The build was aborted before it landed. All eighteen are now pinned
together, all eighteen are held, and a build-time assertion fails if any
version-11 package appears.

Note there is no `tensorrt-libs` here — the samples image has it, this one has
`tensorrt-dev` instead. Only packages already present are upgraded; none is
added.

**Mounts.** The model repository is mounted `:ro` with the engine bind-mounted
straight onto `1/model.plan`, also `:ro`. Nothing is copied into the image, and
because both mounts are read-only Triton physically cannot write an engine back
even if it wanted to.

A zero-byte placeholder is required at `1/model.plan` in the source tree.
Docker mounts parent before child, so by the time runc mounts the file the
parent is already read-only and it cannot create the mountpoint:

```
error mounting "...engine" to rootfs at ".../1/model.plan": create
mountpoint for .../model.plan mount: read-only file system
```

`require_triton_repo()` creates that placeholder, and refuses to continue if it
finds a **non-empty** real file there — because a real plan file at that path
would silently become the model Triton loads.

### The storage cost, stated plainly

| | Content size |
|---|---|
| M6 image (samples base) | 8.99 GB |
| M7 base (triton-multiarch) | 10.41 GB |
| **M7 derived image** | **16.03 GB** |

Docker reports the base and derived images together occupying **~71 GB** of a
116 GB root filesystem once layers and build cache are counted. That pressure is
not theoretical: the M6 image and its samples base were **deleted** to make room
(§6), and during the one M7 rebuild performed in this milestone, free space fell
to a measured low of **14.48 GB** under a 10 GB watchdog floor.

This is the honest engineering tradeoff. Triton buys a serving architecture —
model repositories, versioning, backend abstraction, multi-model hosting — and
charges roughly **1.8×** the image size of the direct-inference path to do it.
For a single model on a single Jetson, that is a poor trade on resources alone;
its value here is architectural and educational (§13).

## 5. Automated verification

`./scripts/verify_triton.sh` — **exit 0, all checks passing.**

The subject is the live M7 run; the baseline is the frozen M6 capture (§6). Both
sides load the same engine file, byte for byte, which is what makes the
comparison mean anything.

| Check | Result |
|---|---|
| 0 — frozen baseline intact and this engine's | 1152 files revalidated, fingerprint matched |
| 1 — image is what we intended | TensorRT 10.16.2.10 on all 7 sampled packages, held; DeepStream 9.1.0; Triton 2.68.0 with tensorrt backend; `nvinferserver` loads with **0** unmet deps |
| 2 — nvinferserver used, nvinfer not | `nvinferserver` element created; **no** `nvinfer` element created |
| 3 — Triton loaded our model | `INFO: TrtISBackend id:1 initialized model: trafficcamnet` |
| 4 — engine unchanged, not rebuilt | sha256 identical before/after; no build attempted; repository mount read-only (write exits 1) |
| 5 — broken repository fails loudly | run without the repository exits **255** |
| 6 — whole clip processed | **288 of 288** frames; `deepstream-app` and `analytics_probe` both exit 0; clean EOS; no pipeline errors |
| 7 — detector structure | identical: 288 frames, 230/230 detecting, 0 count, 0 class mismatches (§7) |
| 8 — tracking | 0 mid-track switches, 2 ids, 224-frame track 50..273 (§8) |
| 9 — restricted zone | entry 109, exit 183, 75 frames, one interval, 100.00% agreement (§9) |
| 10 — baseline provenance and limits | recorded, including what this run does **not** prove (§6) |

Two of these are **negative controls**, and they matter more than the positives:

- **Check 5** removes the model repository mount and requires the run to fail.
  Without it, "Triton loaded our model" could be true while Triton was in fact
  irrelevant to the output. Its earlier form repeated `--network none`, which
  made `docker` refuse the command outright with exit **125** — the container
  never started, and the check passed on "non-zero" while proving nothing. Exit
  125 is now rejected explicitly as inconclusive.
- **Check 4** asserts the engine sha256 is unchanged and that no engine build was
  attempted, so "we reused the M4 engine" is measured, not assumed.

## 6. The frozen Milestone 6 baseline, and its limitation

Earlier drafts of this verification ran the M6 container live and diffed two
live runs. **That is no longer possible.** The M6 image and its
samples-multiarch base were intentionally deleted to recover disk space (§4);
rebuilding M6 would need more space than exists.

Immediately **before** that deletion, a full M6 run was captured to
`/home/matan/m6-baseline`: all 1152 dump files, both run logs, both verdict
files, a `MANIFEST.sha256` over every dump, and a `FINGERPRINT` over the
manifest.

| | |
|---|---|
| Location | `/home/matan/m6-baseline` (outside the repository; ~4.1 MB) |
| Coverage | 1152 files = 288 detector + 288 tracker + 576 zone |
| Fingerprint | `1acdc44dc4a307a44c7e934febe91b5ccb8a27ad986b79be24ce8b0f621f00e3` |

`CHECK 0` refuses to proceed unless **all five** hold: the manifest validates,
the fingerprint over the manifest matches, all three dump sets are present at
full length with nothing outside the hashed set, the baseline's own logs name
the expected engine file, and the **host** engine still hashes to
`35677da6…`. Any failure is a hard `die`, not a counted FAIL — a comparison
against a baseline that does not validate is not a weaker result, it is a
meaningless one.

Both layers were negative-tested: appending one byte to a baseline dump was
caught by `sha256sum -c`, and re-signing the manifest to hide that was then
caught by the fingerprint.

### The limitation, stated as a limitation

> **A live same-session M6 container rerun was not performed.** Milestone 7 is
> compared against a fresh, hash-verified baseline captured immediately before
> the M6 image was removed. This is **not** equivalent to a live regression run.

What is undiminished: the behavioural comparison is still 1152 files diffed
against a real M6 nvinfer run, with hashes proving the baseline has not drifted.

What is **not** proven: that the M6 image would still pass its own verification
today. `verify_container.sh` remains the M6 statement of record, and its last
passing run predates the image deletion.

`verify_triton.sh` prints this limitation on **every run, including passing
ones**, so it cannot be lost in a green result.

## 7. The detector finding

> nvinfer and nvinferserver+Triton produced numerically different detector
> metadata around the same TensorRT engine, while preserving detection
> structure, tracking behavior, and restricted-zone behavior.

**The cause is not attributed.** It was not isolated. Attributing it to
preprocessing or postprocessing would be a guess dressed as a finding.

### Structure is identical

| Property | Result |
|---|---|
| Frames compared | 288 |
| Frames containing detections | **230 / 230** — the same frames |
| Empty frames | **58 / 58** — the same frames |
| Detecting-frame mismatches | **0** |
| Object-count mismatches | **0** |
| Class mismatches | **0** |
| Classes present | `person` only, both sides |

### Numbers differ

Per-frame files differing byte-wise: **230 of 288** — precisely the detecting
frames. Measured over 230 objects:

| Field | max | median | mean |
|---|---|---|---|
| left | 11.663 px | 0.701 px | 1.067 px |
| top | 14.114 px | 0.679 px | 0.977 px |
| right | 9.570 px | 1.025 px | 1.448 px |
| bottom | 3.649 px | 0.407 px | 0.687 px |
| confidence | 0.2568 | 0.0142 | 0.0240 |

Typical deviation is sub-pixel to ~1 px on a 1920×1080 frame. The figures were
identical across two independent M7 runs, so the difference is **deterministic
and systematic**, not run-to-run noise.

### Why byte-identity is not the acceptance criterion

The strict byte comparison was **the right tool for discovery** — it is what
surfaced this difference at all, and a looser criterion from the start would
have hidden it. Having found it, the question became whether it *matters*, and
that cannot be answered by the same comparison that raised it.

So the criterion was changed deliberately and on the record, after measurement:

- **CHECK 7** requires detection **structure** to be identical and **measures**
  the numeric deviation, printing it on every run whether or not anything fails.
  A structural change — an object appearing, vanishing, or changing class —
  still fails.
- **CHECK 9** compares analytics **semantics** rather than whole dump files (§9).

The application's semantics were then verified independently (§8, §9), which is
the claim the milestone actually needs. Nothing was tuned to reduce the
differences: thresholds, parser, preprocessing, engine, tracker, ROI geometry and
model repository are byte for byte what they were when the difference was found.

## 8. Tracking equivalence

The tracker absorbs the coordinate deviations entirely.

| Property | M6 baseline | M7 Triton |
|---|---|---|
| Mid-track ID switches | 0 | **0** |
| Unique track IDs | 2 | **2** |
| Longest continuous track | 224 frames | **224 frames** |
| Track span | frames 50..273 | **frames 50..273** |

Tracker dump files differ byte-wise on 230 frames — the same 230 — because they
carry the shifted boxes. The **identity behaviour** is unchanged: same number of
identities, same stable track, same start and end frame, no new switch anywhere
in the clip.

This is the substantive result of the milestone. Detector coordinates moved by
about a pixel, and nothing downstream noticed.

## 9. Analytics equivalence

| Property | Result |
|---|---|
| Entry frame | **109** |
| Exit frame | **183** |
| Frames inside | **75** |
| Contiguous inside intervals | **1** |
| Per-frame RF count/state differences | **0** of 288 |
| Per-object ROI-status differences | **0** of 288 |
| Agreement with independent recomputation | **100.00%**, 0 disagreements over 230 frames |
| Frames with object ROI status set | 75, with frame/object metadata agreeing |
| Centroid-rule control | **0** inside frames |

The centroid control is worth keeping in view: the ROI was placed so the
subject's **feet** fall inside while the **centroid** never does, so the same
zone yields 75 frames under the rule nvdsanalytics actually uses and 0 under a
centroid rule. That it still yields 0 under Triton means the reference point did
not quietly change.

**Why whole zone dumps are not compared byte-wise.** 450 of 576 zone files differ
— but those files **embed the detector coordinates** from §7. Failing on them
would re-report one difference twice under two names while saying nothing about
analytics. The comparison is therefore of the analytics verdict itself: the
per-frame `frame N RF <count>` line, and each object's id, class, label and ROI
status. Those are identical on **all 288 frames**.

## 10. The manual visible test

The headless path is machine-checked; on-screen rendering is not, and Milestone 5
recorded that the automated suite once passed while output was visibly wrong. So
the visible pipeline was run by hand on the physically attached display:

```
DISPLAY=:1 ./scripts/run_container.sh --display --triton
```

| Observation | Result |
|---|---|
| Video renders normally | yes |
| Person bounding box visible | yes, blue (class 2) |
| Tracking ID visible and stable | `person 1` throughout the useful track |
| RF ROI visible | fixed rectangle with an `RF=` label |
| RF begins at 0 | yes |
| RF → 1 on entry | yes |
| RF → 0 on exit | yes |
| Exactly one moving box | yes |
| Ghosting / stale-box trail | **none** |
| Box disappears when detection ends | yes, cleanly |
| ROI crisp and stationary | yes |
| Playback pacing | `**PERF: 28.20 (36.01)`, then `29.20 (32.19)` — ~29–30 FPS, real time |
| Termination | `Received EOS. Exiting ...` → `App run successful` |

Container evidence from the same run: `INFO: TrtISBackend id:1 initialized model:
trafficcamnet`, the repository and engine both mounted `:ro`, and
`[NvMultiObjectTracker] Initialized`.

**The 1×1 tiler continues to earn its place.** It is not decoration: without it,
`nvdsosd` draws into a buffer it received by reference and previous frames' boxes
persist as a visible trail — the artifact isolated in Milestone 5
([detail](milestone-05-osd-ghosting.md)). Milestone 7 changed what feeds the OSD,
so this needed re-confirming, and it held.

**What is deliberately not expected on screen:** the person's box does not change
colour or gain a `ROI:` suffix when they step inside the zone. `nvdsanalytics`
sets both, but `deepstream-app`'s `process_meta` frees `display_text` and resets
`border_color` downstream, so per-object indications never reach the OSD. That is
a Milestone 5 finding ([detail](milestone-05-restricted-zone.md)), unchanged
here.

### Log lines that look alarming and are not

| Line | Explanation |
|---|---|
| `Driver is unsupported. Must be at least 384.00.` | Triton's metrics module probing via NVML, which does not apply to Jetson's integrated GPU. It failed **after** the backend initialised the model |
| `Unable to get device UUID: Bad parameter passed to function` | Same NVML probe |
| `auto-update preprocess.network_format to IMAGE_FORMAT_RGB` | nvinferserver resolving `MEDIA_FORMAT_NONE` to RGB — matching nvinfer's `model-color-format=0`. Filling in the same value, not overriding ours |
| `(Argus) Connecting to nvargus-daemon failed` | No camera attached |
| `No decoder available for type 'audio/mpeg…'` | The `.mov` carries an AAC track we do not decode |

All five also appear in the Milestone 6 path.

## 11. Known limitations

- **No live same-session M6 re-verification** (§6). Documented, printed on every
  run, and not treated as equivalent to a live regression run.
- **The detector numerical divergence is unexplained** (§7). Measured,
  characterised, deterministic — and its cause deliberately not attributed.
- **The image is large** (§4), 16.03 GB, and the base+derived pair dominates the
  root filesystem.
- **Triton features are unexercised.** Dynamic batching, multiple model versions,
  multiple instances, ensembles and model control are all available and none is
  used. `max_batch_size: 1` and a single instance group are what the M4 engine
  supports.
- **The gRPC/HTTP serving path is untested.** In-process C API only.
- **Throughput is still unmeasured end to end.** The visible run's `**PERF`
  figures are paced by `sync=1` and are not a throughput measurement. This
  remains open from Milestone 5.
- **`verify_triton.sh` cannot be run from a clean machine** without the frozen
  baseline directory, which lives outside the repository and is not committed.

## 12. Lessons learned

- **TensorRT and Triton solve different problems.** TensorRT compiles and
  executes a network. Triton serves models — repositories, versions, backends,
  instance and batching policy.
- **Triton does not replace TensorRT**; it orchestrates models that may use
  TensorRT as a backend. Getting this backwards makes the whole milestone
  incoherent.
- **`nvinferserver` is DeepStream's integration point for Triton**, and it is a
  different plugin from `nvinfer` rather than a mode of it.
- **In-process Triton avoids network and server overhead entirely** — one
  process, no sockets, no daemon, and the container still runs `--network none`.
- **Changing the serving path can alter numerical metadata even with the same
  engine.** This was the milestone's most valuable surprise: a byte-identical
  model does not guarantee byte-identical output when the code around it changes.
- **End-to-end behavioural verification is therefore necessary in addition to
  byte-level comparison.** Byte comparison is the better *discovery* tool;
  semantic comparison is the right *acceptance* criterion. Choosing between them
  in advance would have been wrong either way.
- **A verification harness needs its own negative tests.** Three separate
  false-passes were found and fixed in this milestone: a control that "passed" on
  docker's exit 125 without ever starting a container, a check that reported
  failure while its own diagnostic printed the contradicting proof, and a build
  gate whose `grep -c … || echo 0` produced a two-line string that made its
  arithmetic invalid, so it could not fail at all.
- **Triton's container and storage overhead may not be justified for a
  single-model Jetson application**, despite being architecturally valuable.
  ~1.8× the image size buys serving features this deployment does not use.

## 13. Completion criteria

| Criterion | Evidence |
|---|---|
| `nvinferserver` drives inference, `nvinfer` does not | CHECK 2 |
| Triton runs in-process and loads our model | CHECK 3, `--network none` |
| The existing FP16 engine is reused, not rebuilt | CHECK 4, sha256 unchanged |
| A broken model repository fails the run | CHECK 5, exit 255 |
| The whole clip is processed cleanly | CHECK 6, 288/288, EOS, exit 0 |
| Detection structure preserved | CHECK 7 |
| Tracking behaviour preserved | CHECK 8 |
| Restricted-zone behaviour preserved | CHECK 9 |
| Visible pipeline correct on screen | §10 |
| Divergences reported, not tuned away | §7, and the criteria change recorded in `verify_triton.sh` |

Reproduce with:

```
./scripts/run_container.sh --build --triton     # once; expensive, see §4
./scripts/verify_triton.sh                       # automated, exits 0
DISPLAY=:1 ./scripts/run_container.sh --display --triton   # visible, needs a monitor
```
