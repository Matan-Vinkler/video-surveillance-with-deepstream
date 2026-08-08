# video-surveillance

A capstone project on an NVIDIA Jetson Orin Nano, built one milestone at a
time. The eventual use case is **detecting people in a restricted area**.

Current state: **video input and optimised TensorRT engines — not yet joined.**
A recorded video is replayed as a simulated camera, and TrafficCamNet has been
built into FP32/FP16/INT8 TensorRT engines and benchmarked. Nothing yet feeds
decoded frames into an engine. There is no DeepStream inference, no tracking, no
Triton, no Docker, no MQTT and no monitoring in this repository yet.

---

## Milestone 02 — Simulated camera stream

A recorded video is replayed through an **explicit** GStreamer pipeline so it
behaves like a live camera: paced in real time rather than consumed as fast as
the hardware allows.

```
filesrc ! qtdemux ! queue ! h264parse ! nvv4l2decoder ! nv3dsink sync=true
```

No `playbin` — every element is chosen deliberately and explained in
[`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md).

**Sources** (both from the DeepStream samples, read from their install path and
**not committed** to this repository — see [`media/README.md`](media/README.md)):

| Role | File | Codec | Resolution | FPS | Duration | Scene |
|---|---|---|---|---|---|---|
| **Default** | `sample_walk.mov` | H.264 Main | 1920x1080 | 29.97 | 9.61 s | One person walking across frame |
| `--crowded` | `sample_1080p_h264.mp4` | H.264 High | 1920x1080 | 30 | 48.10 s | Many pedestrians, a cyclist, traffic |

Both are H.264 inside an ISO-BMFF/QuickTime container, so the **same explicit
pipeline serves both unchanged** — only the negotiated `profile` and framerate
differ. The short default clip is meant to be looped.

---

## Milestone 04 — TensorRT engines

TrafficCamNet (DetectNet_v2, pruned ResNet18) is built into three TensorRT
engines at batch 1, `1x3x544x960`. Engines are **generated locally and never
committed** — see [`models/README.md`](models/README.md).

Measured on this Jetson Orin Nano, 3 interleaved repetitions each:

| Engine | GPU compute | End-to-end | Throughput | Size | Frame budget used |
|---|---|---|---|---|---|
| FP32 (`--noTF32`) | 12.70 ms | 12.95 ms | 78.7 qps | 9.01 MiB | 38.8% |
| FP16 | 3.22 ms | 3.53 ms | 310.1 qps | 3.05 MiB | 10.6% |
| INT8 (+FP16 fallback) | 1.93 ms | 2.29 ms | 517.4 qps | 2.59 MiB | 6.9% |

**All three are real-time for one 29.97 fps camera** (33.37 ms per frame), so
precision is a headroom decision rather than a feasibility one.

> These are **performance** measurements only. `trtexec` runs on random input
> tensors and never sees a video frame, so nothing here says whether FP16 or INT8
> preserves detection quality. See
> [`docs/milestone-04-tensorrt-optimization.md`](docs/milestone-04-tensorrt-optimization.md) §8.

---

## Requirements

- NVIDIA Jetson with L4T and DeepStream installed (developed on L4T R39.2,
  Ubuntu 24.04, DeepStream 9.1.0)
- GStreamer 1.x with `gst-launch-1.0`, `gst-inspect-1.0`, `gst-discoverer-1.0`
- The NVIDIA GStreamer elements `nvv4l2decoder` and `nv3dsink`

Nothing needs to be installed, downloaded or built. The DeepStream version is
discovered at run time through the `/opt/nvidia/deepstream/deepstream` symlink,
so no version is hard-coded.

## Quick start

```bash
# 1. Check the environment (tools, DeepStream, elements, display)
./scripts/common.sh --selftest

# 2. Inspect the source: container, codec, resolution, frame rate, duration
./scripts/inspect_video.sh
./scripts/inspect_video.sh --caps             # also dump negotiated caps per link
./scripts/inspect_video.sh sample_1080p_h264.mp4   # any other sample or path

# 3. Verify headlessly - needs no display, exits on its own, never loops
./scripts/verify_simulated_stream.sh          # ~12 s, default 9.61 s source
./scripts/verify_simulated_stream.sh --crowded     # ~56 s, paces the 48 s source

# 4. Watch it, if a display is available
./scripts/run_simulated_stream.sh             # one pass of the default source
./scripts/run_simulated_stream.sh --loop      # replay until Ctrl-C
./scripts/run_simulated_stream.sh --passes 3  # replay exactly 3 times
./scripts/run_simulated_stream.sh --crowded   # busier 48 s source
./scripts/run_simulated_stream.sh --sink fakesink --passes 2   # no window

# 5. TensorRT: check the toolchain, then the model contract
./scripts/trt_common.sh --selftest
./scripts/inspect_model.sh                    # parses only; builds nothing

# 6. Build the engines (~4.5 min total), then see what they actually are
./scripts/build_engines.sh --precision all
./scripts/engine_report.sh

# 7. Compare them (~16 min, interleaved with repetitions)
./scripts/benchmark_engines.sh
```

On this machine the desktop session runs on the console, so the shell needs to
be pointed at it explicitly if `DISPLAY` is unset:

```bash
DISPLAY=:1 ./scripts/run_simulated_stream.sh
```

The window opens on the physically attached monitor, not in an SSH client.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/common.sh` | Shared helpers: DeepStream discovery, video resolution, element preflight, display detection. Run with `--selftest`. |
| `scripts/inspect_video.sh` | Reports container, codec, resolution, frame rate, duration; `--caps` shows caps negotiated at each link. |
| `scripts/run_simulated_stream.sh` | Visible real-time playback, optionally looping. Fails with guidance when no display is usable. |
| `scripts/verify_simulated_stream.sh` | Headless verification: bounded frame flow, plus a measured real-time pacing check. Always bounded, never loops. Non-zero exit on failure. |
| `scripts/trt_common.sh` | Milestone 4 helpers: TensorRT discovery, model paths, engine naming, GPU and thermal state. Run with `--selftest`. |
| `scripts/inspect_model.sh` | Parses the ONNX with TensorRT and reports its input/output contract plus INT8 calibration-cache coverage. Builds nothing. |
| `scripts/build_engines.sh` | Builds FP32/FP16/INT8 engines and verifies each artifact. Never benchmarks. |
| `scripts/engine_report.sh` | Reports what an engine **actually** is — the per-layer precisions TensorRT selected, not the ones requested. |
| `scripts/benchmark_engines.sh` | Interleaved, repeated comparison of the built engines, with spread reporting. Never builds. |

## Looping

`--loop` replays until Ctrl-C; `--passes N` runs a fixed number of times.
Each pass re-runs the pipeline rather than seeking inside it, which keeps the
pipeline the minimal explainable one. The cost is a short gap between passes
(~0.17 s on this machine) while NVDEC is torn down and re-initialised. Gapless
looping would need a segment seek driven from an application with a bus
handler — deliberately out of scope here.

Headless verification is unaffected: it is always bounded and never loops.

## What "paced in real time" means here

The sink's `sync=true` holds every decoded frame until its presentation
timestamp arrives, which back-pressures the decoder and the file reader. The
verification script proves it by measurement rather than assertion:

| Clip | Real duration | `sync=true` | `sync=false` |
|---|---|---|---|
| `sample_walk.mov` (default) | 9.61 s | 9.80 s | 1.53 s |
| `sample_1080p_h264.mp4` (`--crowded`) | 48.10 s | 48.28 s | 6.02 s |

## Documentation

[`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md) covers
container vs codec, what each element does, static vs dynamic pads, where caps
negotiation happens, the raw pixel format the decoder produces
(`NV12` in `memory:NVMM`), how pacing works, full verification output, and
known limitations.
