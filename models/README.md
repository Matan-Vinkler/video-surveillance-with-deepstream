# models/

This directory holds **no committed model artifacts**. `models/engines/` is
generated locally and ignored by git.

## Why no engines are committed

A TensorRT engine (`.engine`, a serialized "plan") is not a portable file. It is
specialised at build time to:

| Bound to | On this machine |
|---|---|
| TensorRT version | discovered at run time (10.16.2 at time of writing) |
| GPU architecture | Jetson Orin Nano (Ampere, no DLA) |
| Optimisation profile | batch 1, `1x3x544x960`, fixed |
| Selected per-layer precisions | chosen by the builder's own timing measurements |

Loading an engine built for a different TensorRT version or GPU fails. So
committing one would put a binary in git that is **unusable elsewhere and
unverifiable here** — the opposite of reproducibility. The reproducible artifact
is the *build command*, which lives in `scripts/build_engines.sh`.

This matches the reasoning for not committing video (see
[`../media/README.md`](../media/README.md)): the input is regenerated from what
is already installed on the target, rather than redistributed.

## Where the source model comes from

The ONNX model and its INT8 calibration cache are DeepStream sample assets, read
from their install path and never copied into this repository:

```
/opt/nvidia/deepstream/deepstream/samples/models/Primary_Detector/
├── resnet18_trafficcamnet_pruned.onnx    # 5,365,751 bytes
├── cal_trt.bin                           # 8,630 bytes, INT8 calibration cache
└── labels.txt                            # car, bicycle, person, road_sign
```

The `deepstream` path component is a symlink to the versioned directory, so the
scripts resolve it at run time and no version is hard-coded.

**That directory is root-owned and not writable**, and no `sudo` is available on
this machine. Engines therefore cannot be written where DeepStream's stock
configuration expects them (`../../models/Primary_Detector/*.engine`); they are
written here instead, and any DeepStream configuration must be pointed at this
location explicitly.

## Naming convention

```
<model>_b<batch>_<width>x<height>_<precision>_trt<version>_<gpu>.engine

trafficcamnet_b1_960x544_fp32_trt10.16.2_orin-nano.engine
```

Every component that invalidates an engine appears in its name. DeepStream's own
convention (`resnet18_trafficcamnet_pruned.onnx_b30_gpu0_fp16.engine`) omits both
the TensorRT version and the input resolution — precisely the two things that
make an engine unusable somewhere else.

## Regenerating

```bash
./scripts/inspect_model.sh                 # verify the model contract first
./scripts/build_engines.sh --precision all # build fp32, fp16, int8
./scripts/benchmark_engines.sh             # interleaved comparison
```

Build and benchmark are deliberately separate operations, so that benchmark
timings are never perturbed by builder work.
