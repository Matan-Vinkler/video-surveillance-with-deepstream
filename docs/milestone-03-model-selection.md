# Milestone 03 — Selecting a pretrained person-detection model

**Goal.** Choose a person-detection model for the restricted-zone use case,
justify the choice against that use case, and document its input/output contract.
No TensorRT conversion (Milestone 4), no pipeline integration (Milestone 5).

**Status: complete.** Selected model: **TrafficCamNet**
(`resnet18_trafficcamnet_pruned.onnx`), with **PeopleNet** recorded as the
upgrade target.

> **Written retrospectively.** Milestone 3 was an investigation milestone that
> produced no code, and its findings initially lived only in `PLAN.md`. This
> document was written during Milestone 4 to close that gap, from the same
> command output the original investigation produced. Environment facts were
> re-confirmed on the machine at the time of writing; anything not re-confirmed is
> marked as such.

---

## 1. What the milestone had to decide

The use case fixed by Milestone 1 is **detecting people in a restricted zone**.
That makes object detection the required task, and it makes `person` the only
class that must be present. Everything else was an engineering choice, and the
governing question was deliberately *not* "which model scores highest".

The criteria actually applied, in priority order:

1. **Can it be obtained and run here at all?** No `sudo`, no NGC credentials, and
   a machine where several NVIDIA paths turn out to be unavailable.
2. **What integration work does DeepStream need?** A model requiring a compiled
   custom bbox parser is a sub-project, not a model choice.
3. **Does it detect people natively?**
4. **Does it leave a clean upgrade path** if the first choice proves inadequate?
5. **Detection quality** — last, because it cannot be measured without labelled
   ground truth this project does not have.

## 2. What is actually installed

Surveyed read-only across the DeepStream 9.1 install.

**Detectors shipped with DeepStream:** exactly one.

| Directory | File | Task |
|---|---|---|
| **`Primary_Detector`** | `resnet18_trafficcamnet_pruned.onnx` (5,365,751 B) | **Object detection** |
| `Secondary_VehicleMake` | `resnet18_vehiclemakenet_pruned.onnx` | Classification |
| `Secondary_VehicleTypes` | `resnet18_vehicletypenet_pruned.onnx` | Classification |
| `SONYC_Audio_Classifier` | `sonyc_audio_classify.onnx` | Audio |

`Primary_Detector` ships `labels.txt` (`car`, `bicycle`, **`person`**,
`road_sign`) and `cal_trt.bin`, an INT8 calibration cache.

**TAO models: none installed.** `samples/configs/tao_pretrained_models/` holds a
README pointing at GitHub. `samples/triton_tao_model_repo/` has three scaffold
directories containing a `config.pbtxt` each and **no weights**.
`prepare_ds_triton_tao_model_repo.sh` fetches only PeopleNet Transformer and
PeopleSemSegNet, and **`nvcr.io` returns HTTP 401** — NGC downloads need an API
key this machine does not have.

**Model families DeepStream 9.1 supports**, evidenced by the parsers compiled
into `lib/libnvds_infercustomparser.so`:

| Exported parser | Family |
|---|---|
| *(none — built in)* | **DetectNet_v2** — TrafficCamNet, PeopleNet, DashCamNet |
| `NvDsInferParseCustomNMSTLT`, `…BatchedNMSTLT` | TAO detectors with NMS plugins |
| `NvDsInferParseYoloV5CustomBatchedNMSTLT` | TAO YOLOv5 only |
| `NvDsInferParseCustomYoloV11OBB` | YOLO11 **oriented-bbox** only |
| `NvDsInferParseCustomRTDETRTAO`, `…DDETRTAO` | RT-DETR, Deformable-DETR |
| `NvDsInferParseCustomEfficientDetTAO`, `…MrcnnTLT`, `…TfSSD` | EfficientDet, Mask R-CNN, SSD |
| `NvDsInferParseCustomPeopleSemSegNet` | PeopleSemSegNet (segmentation) |

**The DetectNet_v2 family needs no custom parser at all** — `nvinfer` decodes its
coverage/bbox output natively, which is why the stock `config_infer_primary.txt`
leaves `parse-bbox-func-name` commented out. Every other family needs an
explicitly named parser function.

### Two blocking findings

**YOLOv8 and YOLO11 detection are not supported.** A case-insensitive search for
`yolov8`/`yolo11`/`ultralytics` across the whole install returns one file — the
OBB parser source, incidentally. The shipped `NvDsInferParseCustomYoloV11OBB`
expects a single output shaped `[4 + num_classes + 1, num_anchors]` where the
trailing channel is a **rotation angle**. A standard axis-aligned YOLO11 emits no
angle channel, so that parser would consume the last class score *as* an angle.
It is not a usable path for this use case.

**`nvinferserver` is unusable on this machine.**

```
gst-inspect-1.0 nvinferserver     -> No such element or plugin 'nvinferserver'
ldd libnvdsgst_inferserver.so     -> libtritonserver.so => not found
/opt/tritonserver                 -> does not exist
```

The plugin binary ships, but the Triton backend was never installed, and
installing it requires `sudo ./triton_backend_setup.sh`. This blocks every
Triton-only model — including PeopleNet Transformer, whose config is present but
whose weights are not — and it is a standing risk to Milestone 7.

## 3. Candidate comparison

Performance and quality columns are **estimates from architecture and precedent,
not measurements.** Nothing was benchmarked during this milestone.

| | **TrafficCamNet** | **PeopleNet** (DetectNet_v2) | **PeopleNet Transformer** | **YOLO11n / YOLOv8n** |
|---|---|---|---|---|
| Task | Detection | Detection | Detection | Detection |
| Training data | NVIDIA proprietary, traffic/intersection cameras | NVIDIA proprietary, person-centric | Same person-centric corpus | COCO |
| Classes | `car`, `bicycle`, **`person`**, `road_sign` *(verified from `labels.txt`)* | `person`, `bag`, `face` *(model card; not verified locally)* | 4 per `config.pbtxt` | 80 COCO incl. `person` |
| Input | **3×544×960 NCHW** *(verified from the ONNX)* | 3×544×960 *(model card)* | **3×544×960** *(verified from `config.pbtxt`)* | 3×640×640 |
| Size | **5,365,751 B** *(verified)* | ~20 MiB *(unverified)* | ~150 MiB *(unverified)* | 6–12 MiB |
| Availability | **On disk** | NGC 401 | Config only, no weights | External download |
| DeepStream effort | **None** — built-in parser, config shipped | **None** — same built-in parser | **Blocked** — needs Triton | **High** — repo, PyTorch, ONNX export, compiled parser |
| Upgrade path | → PeopleNet is a config change | — | — | Isolated; no shared contract |
| Verdict | **Selected** | **Upgrade target** | Rejected | Rejected for now |

## 4. Decision and rationale

**TrafficCamNet is the baseline.** Not because it is the best person detector —
it is not — but because it is the only candidate that is already present, needs
no download, no NGC credentials, no compilation and no `sudo`, while still
exercising the entire teaching path this project cares about. `person` is a native
output class, and the shipped INT8 calibration cache makes Milestone 4's
precision trade-off directly executable with no calibration dataset to assemble.

**PeopleNet is the recorded upgrade target.** It is purpose-built for people and,
decisively, uses the **same DetectNet_v2 output contract and the same built-in
parser**. Swapping it in is a change of paths and `num-detected-classes`, not an
integration project. That property is what makes it safe to start with the
convenient model.

### The honest counter-argument

TrafficCamNet's `person` class was trained on **traffic and intersection
viewpoints**. The use case is a restricted zone, and Milestone 2's default source
`sample_walk.mov` is a close-range indoor walking shot. That is a genuine
viewpoint mismatch and it is the strongest argument for PeopleNet.

It does not change the decision, because Milestone 3 selects and documents a
model rather than validating detection quality. But it does mean the switch to
PeopleNet should be an **evidenced** decision later, not a preference — which is
why the mismatch is recorded here rather than discovered again in Milestone 5.

## 5. The model contract — verified, not assumed

Established by parsing the ONNX with TensorRT's own parser. Reproduce with
`./scripts/inspect_model.sh` (added in Milestone 4; the original investigation
used an equivalent inline parse).

```
parse succeeded : True        parser errors : 0        opset : 12
producer        : tf2onnx 1.9.2

input   'input_1:0'              (-1, 3, 544, 960)   FLOAT
output  'output_cov/Sigmoid:0'   (-1, 4, 34, 60)     FLOAT
output  'output_bbox/BiasAdd:0'  (-1, 16, 34, 60)    FLOAT

210 layers: ELEMENTWISE 77, CONSTANT 69, CONVOLUTION 27, SHUFFLE 19, ACTIVATION 18
```

- **Dynamic in batch only**; spatial dimensions fixed at 544×960.
- **No plugins, no unsupported operators.**
- **No pooling layer** — this DetectNet_v2 downsamples with strided convolutions.
- `block_1a…block_4b` tensor names confirm a **ResNet18** backbone; `pruned` in
  the filename explains 5.1 MiB against ~45 MiB for an unpruned FP32 ResNet18.

An independent `strings`-based operator scan agreed exactly: Add 52 + Mul 25 = 77
ELEMENTWISE, 17 Relu + 1 Sigmoid = 18 ACTIVATION, 27 Conv = 27 CONVOLUTION.

**Preprocessing contract**, from the shipped `config_infer_primary.txt`: RGB,
`net-scale-factor` = 1/255, **no mean subtraction**, NCHW. Compare the PeopleNet
Transformer config in the same install, which *does* specify
`channel_offsets: [123.675, 116.280, 103.53]` — different families, different
contracts, and exactly the kind of thing that fails silently if assumed.

## 6. How the model works, and how DeepStream consumes it

### Dense grid regression, not anchors

DetectNet_v2 is a **fully convolutional dense grid regressor**. There are no
anchor boxes, no region proposals, and **no NMS inside the network**. For every
grid cell, independently for every class, it answers two questions: *is this cell
covered by an object of class c?* and *where are that object's four edges relative
to me?*

Everything else — thresholding, merging duplicates, mapping to frame coordinates —
happens outside the network, in DeepStream. That clean division is why a
*built-in* parser suffices, and why every stage from raw tensor to drawn box
remains a knob you can turn and observe.

### Stride 16 sets the resolution limits

```
input 960 × 544  ──÷16──▶  output 60 × 34
```

Each cell covers a 16×16 patch of network input. Two consequences:

- **One object per cell per class.** Two people whose centres fall in the same
  cell cannot both be represented; in a crowd, adjacent people merge.
- **A practical size floor.** At 1920×1080 → 960×544, a person 100 px tall in the
  source becomes ~50 px and spans ~3 cells vertically — comfortable. A distant
  person 30 px tall becomes ~15 px, under one cell, and is unlikely to be detected.

### The two heads

| Tensor | Shape | Meaning |
|---|---|---|
| `output_cov/Sigmoid:0` | `[N, 4, 34, 60]` | Per-class confidence, already in [0,1] via sigmoid |
| `output_bbox/BiasAdd:0` | `[N, 16, 34, 60]` | 4 classes × 4 edge offsets; **raw linear, no activation** |

Channel index is class index: 0 `car`, 1 `bicycle`, **2 `person`**, 3 `road_sign`.
The bbox head groups class-major, so `person` boxes are channels 8–11.

> **The most fragile joint in the pipeline.** Nothing in the model states that
> channel 2 is `person`. The mapping comes entirely from **line order in
> `labels.txt`**. Reorder those four lines and the model still runs, still
> produces plausible boxes, and silently mislabels every one of them. There is no
> checksum, no name, no assertion — the coupling is positional and implicit.

### Decoding a box

Confidence is read directly from the coverage map and discarded below
`pre-cluster-threshold` — the cheap filter that eliminates most of the 2,040 cells
before any arithmetic. The four bbox values are **not** a box; they are distances
from the cell centre to the object's edges, normalised by a constant that
DeepStream hard-codes as `bboxNorm = 35.0`:

```
cell centre  cx = gx·16 + offset,  cy = gy·16 + offset      (network-input pixels)
left = cx − bbox[4c+0]·35    right  = cx + bbox[4c+2]·35
top  = cy − bbox[4c+1]·35    bottom = cy + bbox[4c+3]·35
```

The 35× scaling is what lets a single 16 px cell describe a box hundreds of pixels
across — how a cell near a torso describes a whole body. Coordinates emerge in
network space (960×544) and `nvinfer` rescales them to the source frame.

### Clustering is mandatory

Every cell overlapping an object fires, so a person spanning 3×6 cells produces up
to 18 near-identical boxes. **Raw output is a voting field, not a detection list.**
DeepStream ships four strategies — GroupRectangles, DBSCAN, NMS, DBSCAN+NMS — and
the stock config uses NMS with `topk=20`, `nms-iou-threshold=0.5`,
`pre-cluster-threshold=0.2`.

DBSCAN was DetectNet_v2's historical companion, and the difference is
architectural: NMS *picks a winner* from the cloud while DBSCAN *merges* it, which
fits "many cells vote for one object" more naturally. Which behaves better for
overlapping people is a Milestone 5 experiment, not a claim to make here. Mode 4
(no clustering) is the useful diagnostic — it exposes the raw voting field, making
it obvious whether a miss was a model failure or a clustering failure.

### Layer identification, and why it matters

The built-in parser finds the two tensors by **searching their names for the
substring `bbox`**. No shape check, no metadata, no configuration. Re-export the
model with outputs named `boxes`/`scores` and the built-in path stops working.
That convention is the whole reason TrafficCamNet's integration effort is zero.

### Into the metadata graph

Surviving boxes become `NvDsObjectMeta` carrying `class_id`, `confidence`,
`rect_params` in source-frame coordinates, and `obj_label`. From there the model
is out of the picture:

```
nvv4l2decoder → nvstreammux → nvinfer → nvtracker → nvdsanalytics → nvdsosd → sink
   [M2 done]                 the model   object_id    restricted-zone logic
                             ends here   across frames
```

**"Person in a restricted zone" is never a model question.** The model answers
*is there a person, and where*. Persistence is `nvtracker`'s job; the zone polygon
and crossing test are `nvdsanalytics`', operating purely on metadata. That is a
large part of why this model choice is lower-stakes than it first appears.

## 7. Known limitations

1. **One detection per cell per class.** Relevant to the `--crowded` source; less
   so to `sample_walk.mov`.
2. **Small-object floor** at roughly 30 px in the source frame.
3. **Viewpoint mismatch** — traffic-camera training against a close-range indoor
   scene. The most likely reason to move to PeopleNet.
4. **Positional class mapping** — silent, total failure if `labels.txt` drifts.
5. **PeopleNet's specification is unverified locally.** Classes, resolution and
   size come from NVIDIA's model card; the model is not on this machine.
6. **No detection quality was measured.** No inference was run in this milestone.

## 8. Completion criteria

| Criterion | Status |
|---|---|
| Person-detection model selected | Done — TrafficCamNet |
| Choice justified against the use case | Done — §4, on engineering suitability with the counter-argument recorded |
| Input/output contract documented | Done — §5, verified by parsing rather than from documentation |
| Alternatives surveyed and rejections explained | Done — §2, §3 |
| Upgrade path identified | Done — PeopleNet, same output contract |
| Integration effort established | Done — built-in parser, zero custom code |
| No optimisation or pipeline work | Done — deferred to M4 and M5 |
