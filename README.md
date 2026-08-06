# video-surveillance

A capstone project on an NVIDIA Jetson Orin Nano, built one milestone at a
time. The eventual use case is **detecting people in a restricted area**.

Current state: **video input only.** There is no object detection, no
TensorRT or DeepStream inference, no tracking, no Triton, no Docker, no MQTT
and no monitoring in this repository yet.

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
