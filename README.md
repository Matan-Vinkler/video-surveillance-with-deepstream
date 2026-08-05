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

**Source:** `sample_1080p_h264.mp4` from the DeepStream samples — H.264 High,
1920x1080, 30 fps, 48.10 s, containing multiple pedestrians. It is read from
its install path and **not committed** to this repository; see
[`media/README.md`](media/README.md).

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
./scripts/inspect_video.sh --caps        # also dump negotiated caps per link

# 3. Verify headlessly - needs no display, exits on its own
./scripts/verify_simulated_stream.sh     # ~10 s, uses a short clip for pacing
./scripts/verify_simulated_stream.sh --full   # ~55 s, paces the 48 s source

# 4. Watch it, if a display is available
./scripts/run_simulated_stream.sh        # full 48 s source
./scripts/run_simulated_stream.sh --quick     # short ~6 s clip
./scripts/run_simulated_stream.sh --loop      # replay continuously
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
| `scripts/run_simulated_stream.sh` | Visible real-time playback. Fails with guidance when no display is usable. |
| `scripts/verify_simulated_stream.sh` | Headless verification: bounded frame flow, plus a measured real-time pacing check. Non-zero exit on failure. |

## What "paced in real time" means here

The sink's `sync=true` holds every decoded frame until its presentation
timestamp arrives, which back-pressures the decoder and the file reader. The
verification script proves it by measurement rather than assertion:

| Clip | Real duration | `sync=true` | `sync=false` |
|---|---|---|---|
| `sample_run.mov` | 5.97 s | 6.14 s | 1.23 s |
| `sample_1080p_h264.mp4` | 48.10 s | 48.27 s | 6.01 s |

## Documentation

[`docs/milestone-02-video-input.md`](docs/milestone-02-video-input.md) covers
container vs codec, what each element does, static vs dynamic pads, where caps
negotiation happens, the raw pixel format the decoder produces
(`NV12` in `memory:NVMM`), how pacing works, full verification output, and
known limitations.
