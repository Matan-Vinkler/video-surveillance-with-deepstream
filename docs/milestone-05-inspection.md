# Inspection report — DeepStream inference pipeline milestone

Read-only inspection carried out before any file was created. Every claim is
backed by command output. Nothing under `/opt` was modified, nothing was
installed, no engine was built, and the power mode and clocks were untouched.

Dated record of the inspection phase. Corrections found during implementation
are appended as an [Addendum](#addendum-corrections-from-the-implementation-phase);
the body is not rewritten.

Scope: **checkpoint 1 only** —
`source → decoder → nvstreammux → nvinfer → nvdsosd → sink`.
No tracker, no analytics, no Triton, no container.

---

## 1. Inputs this milestone consumes

| Item | Path |
|---|---|
| FP16 engine (Milestone 4) | `models/engines/trafficcamnet_b1_960x544_fp16_trt10.16.2_orin-nano.engine` |
| Labels | `/opt/nvidia/deepstream/deepstream/samples/models/Primary_Detector/labels.txt` |
| Video (Milestone 2) | `/opt/nvidia/deepstream/deepstream/samples/streams/sample_walk.mov` |
| `deepstream-app` | `/usr/bin/deepstream-app` (DeepStream 9.1.0) |

Labels and video are read through the **unversioned** `deepstream` symlink, so
no DeepStream version appears in any committed file.

## 2. Closest stock starting point

Fourteen stock configs reference `Primary_Detector`. Counting `[source*]` groups
and checking for `[tracker]` / `[secondary-gie]`:

| Candidate | Verdict |
|---|---|
| **`source30_1080p_dec_infer-resnet_tiled_display.txt`** | **Chosen.** Groups are `[application] [tiled-display] [source0] [source1] [sink0..2] [osd] [streammux] [primary-gie] [tests]` — primary detector only, **no tracker, no secondary-gie**, file source |
| `source4_…_tracker_sgie_…` | Has `[tracker]` and `[secondary-gie]` — out of scope |
| `source1_usb…`, `source1_csi…` | Single source, but **camera** (`type=1`), not a file |
| `config_infer_primary.txt` | The nvinfer base to derive from |

## 3. Element and type mappings, from the DeepStream sources

| Setting | Value | Evidence |
|---|---|---|
| Source type | `1=CameraV4L2 2=URI 3=MultiURI 4=RTSP` | stock config comments |
| Sink type | `1=FakeSink 2=EglSink/nv3dsink (Jetson) 3=File 4=RTSP` | stock config comments |
| Sink type 2 on Tegra | → **`nv3dsink`** (`NV_DS_SINK_RENDER_3D`) | `deepstream_sink_bin.c`, `deepstream_config.h:77` |
| OSD conversion | `nvvideoconvert` named **`osd_conv`** inserted before `nvdsosd` | `deepstream_osd_bin.c:36` |
| nvstreammux version | legacy (`USE_NEW_NVSTREAMMUX` unset) | environment |
| Relative path base | nvinfer resolves paths against **its own** config file | `gstnvinfer_property_parser.cpp:602` |
| Single-source path | with `num_source_sub_bins == 1`, `deepstream-app` takes the same branch whether or not tiled display is enabled | `deepstream_app.c:1268` |

## 4. Person class ID = 2, provable rather than assumed

From `gstnvinfer_meta_utils.cpp`:

```
line 151:  obj_meta->class_id = obj.classIndex;
line 192:  g_strlcpy (obj_meta->obj_label, obj.label, MAX_LABEL_SIZE);
line 118:  filter_out_class_ids->find (obj.classIndex)     // filter acts on class_id
```

`class_id` and `obj_label` are the **same index** into the label table, and
`labels.txt` line 3 is `person`. Because `filter-out-class-ids` filters on that
same index, excluding classes 0, 1 and 3 leaves only class 2 — which turns the
class-mapping claim into an experiment rather than an inference.

## 5. The built-in parser is sufficient

`parse-bbox-func-name` stays unset. `DetectPostprocessor::parseBoundingBox`
locates the box tensor by the substring `bbox` in its name; the engine's outputs
are `output_cov/Sigmoid:0` and `output_bbox/BiasAdd:0`. No custom library, no
compilation.

## 6. Machine-verifiable detection evidence

`deepstream-app` supports **`gie-kitti-output-dir`**, which writes one file per
frame from a probe on the `nvdsosd` sink pad — i.e. after `nvinfer` and *before*
any tracker (`deepstream_app.c:1428`, probe attached at `:1639`).

Line format (`deepstream_app.c:815`):

```
<label> 0.0 0 0.0 <left> <top> <right> <bottom> 0.0 0.0 0.0 0.0 0.0 0.0 0.0 <confidence>
```

**The directory must already exist** — the writer does `fopen(..., "w")` and
`continue`s on failure, so a missing directory yields silence rather than an
error. The verification script creates it.

## 7. Engine-compatibility analysis

`checkBackendParams` (`nvdsinfer_context_impl.cpp:2116`) enforces:

1. `engine maxBatchSize >= configured batch-size`. Our engine was built
   `min=opt=max=1`, config asks for 1 → **1 ≥ 1 passes**.
2. Input dims are validated **only if `infer-dims` is set**.
3. Output names are checked **only if `output-blob-names` is set**.

Omitting both removes two chances of a spurious mismatch and lets the engine's
own bindings govern.

The success line is `Use deserialized engine model: <path>`
(`nvdsinfer_context_impl.cpp:2291`); failure paths print `try rebuild` /
`trying rebuild`. Both are usable as assertions.

## 8. Where frames are copied or converted

| # | Boundary | What happens |
|---|---|---|
| 1 | decoder → `nvstreammux` | NV12/NVMM, batched **by reference** — no pixel copy |
| 2 | inside `nvstreammux` | scales only if source ≠ mux resolution. Ours match at 1920×1080 → **no scaling** |
| 3 | inside `nvinfer` | the real conversion: NV12 → 960×544 RGB planar float, ×1/255, NCHW |
| 4 | `osd_conv` | ~~NV12 → **RGBA**, required by `nvdsosd`~~ — **wrong, corrected below** |
| 5 | `nvdsosd` → sink | NVMM, rendered directly |

> **Correction (implementation phase).** Row 4 was reasoned from the presence of
> an `nvvideoconvert` in `osd_bin`, not measured. `nvdsosd`'s sink pad accepts
> **both** NV12 and RGBA, and `osd_bin` contains **no capsfilter**, so the format
> is negotiated freely. Measured on the running pipeline:
>
> ```
> gst_nvvideoconvert_fixate_caps:<osd_conv> fixated othercaps to
>     width=(int)1920, height=(int)1080, format=(string)NV12
> ```
>
> In the default GPU OSD mode `osd_conv` fixates **NV12 → NV12** and converts
> nothing. It only produces RGBA when `nvdsosd` is put in CPU mode, which
> restricts its sink caps. See
> [`milestone-05-osd-ghosting.md`](milestone-05-osd-ghosting.md).

**960×544 is never a streammux setting** — it is the engine's input dimension,
applied inside `nvinfer`.

## 9. Risks identified before starting

1. `nvinfer` might reject a `trtexec`-built engine — analysis said it should
   pass; only a run could confirm.
2. Fixed `min=opt=max=1` profile might be rejected.
3. A silent rebuild would violate the milestone constraints.
4. **TrafficCamNet might detect few or no people** on `sample_walk.mov` — the
   Milestone 3 viewpoint mismatch. Agreed handling: report raw counts, do not
   tune thresholds to manufacture detections.
5. Aspect-ratio squash at 1920×1080 → 960×544 (1.778 vs 1.765).
6. Visible playback opens a window on the physical monitor — to be run manually.

---

## Addendum: corrections from the implementation phase

**1. The engine-load assertion had to match the *resolved* path.**
The committed config references the stable symlink `trafficcamnet_fp16.engine`,
but `nvinfer` calls `realpath` and logs the symlink's **target**:

```
Use deserialized engine model: .../trafficcamnet_b1_960x544_fp16_trt10.16.2_orin-nano.engine
```

The first verification run therefore failed a check that the pipeline had
actually satisfied. The assertion now matches the resolved basename, which is
the stronger check anyway — it proves *which* versioned engine loaded.

**2. Risk 4 did not materialise.** TrafficCamNet detects the walking person
reliably on this clip, at 0.67–0.82 confidence. See the implementation record.

**3. An unanticipated finding: run-to-run detection counts are not perfectly
reproducible.** Three identical headless runs produced 232, 230 and 230 person
detections. The variation is confined to two frames and one borderline
detection. This was not predicted by any risk above and is documented in the
implementation record rather than smoothed over.

**4. §6 named the wrong probe.** The KITTI detection dump is *not* written from
a probe on the `nvdsosd` sink pad. `write_kitti_output` is called by
`gie_primary_processing_done_buf_prob`, which `deepstream-app` attaches to the
**`primary-gie` bin's src pad** (`deepstream_app.c:1951-1954`). The consequence
claimed in §6 — that the dump is taken after `nvinfer` and before any tracker —
is correct, and checkpoint 2 shows it is load-bearing: the tracker's own dump
comes from a *different* probe on a *different* pad
(`kitti-track-output-dir`, attached at `deepstream_app.c:1979-1981`), which is
what allows detector and tracker output to be compared within one run. Found
during checkpoint 2; see
[`milestone-05-tracking.md`](milestone-05-tracking.md) §9.
