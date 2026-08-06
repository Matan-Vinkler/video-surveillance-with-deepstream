# Inspection report — video-input milestone

Read-only inspection of the Jetson environment carried out before any files
were created. Every claim is backed by command output; no file was modified,
downloaded or installed to produce it.

> This is the record of the **inspection phase**. Two of its expectations were
> later contradicted by measurement during implementation — see the
> [Addendum](#addendum-corrections-from-the-implementation-phase) at the end.

---

## 1. Environment findings

### 1.1 Working directory

```
/home/matan/Documents/projects/video-surveillance
```

Completely empty (`ls -la` showed only `.` and `..`), and not a git repository.

### 1.2 Platform / OS

| Item | Value | Evidence |
|---|---|---|
| Board | NVIDIA Jetson Orin Nano Engineering Reference Developer Kit **Super** | `/proc/device-tree/model` |
| L4T | **R39, REVISION 2.0** (GCID 45755727, built 2026-06-01) | `/etc/nv_tegra_release` |
| OS | Ubuntu **24.04.4 LTS** (noble) | `/etc/os-release` |
| Kernel | `6.8.12-1021-tegra` | `uname -a` |
| Arch | `aarch64` / `arm64` | `dpkg --print-architecture` |

`/etc/l4t_version.txt` does **not** exist on this JetPack — `/etc/nv_tegra_release`
is the reliable source.

### 1.3 GStreamer

**1.24.2** (Ubuntu-packaged), 322 plugins / 1701 features.

### 1.4 Tool availability

| Tool | Path |
|---|---|
| `gst-launch-1.0` | `/usr/bin/gst-launch-1.0` — available |
| `gst-inspect-1.0` | `/usr/bin/gst-inspect-1.0` — available |
| `gst-discoverer-1.0` | `/usr/bin/gst-discoverer-1.0` — available |
| `gst-play-1.0` | `/usr/bin/gst-play-1.0` — available |
| `ffprobe` / `ffmpeg` | **NOT installed** |

Since ffprobe is absent (and packages may not be installed), `gst-discoverer-1.0`
is the media-probing tool for this milestone.

### 1.5 Relevant NVIDIA GStreamer elements (all verified present)

| Element | Role |
|---|---|
| `nvv4l2decoder` | Hardware H.264/H.265 decode into NVMM memory |
| `nvvidconv` / `nvvideoconvert` | Hardware colour-convert and scale; NVMM <-> system memory |
| `nv3dsink` | NVIDIA 3D display sink (X11) |
| `nveglglessink` + `nvegltransform` | EGL/GLES sink (requires the transform element) |
| `nvdrmvideosink` | Direct DRM/KMS sink (requires DRM master) |
| `nvjpegdec` / `nvjpegenc` | Hardware JPEG |
| `nvarguscamerasrc`, `nvv4l2camerasrc` | Real CSI/USB camera sources (for a later milestone) |

The full DeepStream element set (`nvstreammux`, `nvinfer`, `nvtracker`, …) is
also installed but is **not used in this milestone**.

### 1.6 DeepStream

| Item | Value |
|---|---|
| Version | **9.1.0** (GCID 46117240, 2026-06-25) — from `/opt/nvidia/deepstream/deepstream/version` |
| Versioned directory | `/opt/nvidia/deepstream/deepstream-9.1` |
| Stable symlink | `/opt/nvidia/deepstream/deepstream` -> `deepstream-9.1` |
| dpkg registration | **None** (`dpkg -l | grep deepstream` was empty) — installed via SDK Manager/tarball |

**Implication for the "do not hard-code the version" requirement:** `dpkg`
cannot be used to discover the version. The safe discovery order is to use the
stable symlink `/opt/nvidia/deepstream/deepstream` and read the human-readable
version from its `version` file (`Version: 9.1.0`), with `readlink -f` as a
cross-check.

### 1.7 Display availability

| Signal | Value |
|---|---|
| This shell's `DISPLAY` | **unset**; `XDG_SESSION_TYPE=tty` (this session is headless) |
| Real GUI session | **Yes** — `Xorg vt2`, `gdm-x-session`, `gnome-shell` running as `matan` on tty2/seat0 |
| Server type | **X11** (Xorg on vt2), not Wayland |
| Display manager | `gdm3` **active**; `systemctl get-default` = `graphical.target` |
| Monitor | `card2-DP-1` = **connected** |
| `DISPLAY=:1 xrandr` | **works** -> `1920x1080 DP-1` |
| `DISPLAY=:1001` | fails: `Invalid MIT-MAGIC-COOKIE-1 key` |

A graphical display **is** available, but only via an explicit `DISPLAY=:1`.
A window opened this way appears on the physical DP monitor, not in an SSH
client.

### 1.8 Recommended sinks

**Visible mode -> `nv3dsink`.** Its sink pad accepts
`video/x-raw(memory:NVMM), format=NV12` directly, so decoder output reaches the
sink with no conversion and no extra element. `nveglglessink` would
additionally require `nvegltransform`; `nvdrmvideosink` needs DRM master and
would collide with the running Xorg; `xvimagesink`/`autovideosink` would force
an NVMM -> system-memory copy through `nvvidconv`.

**Headless mode -> `fakesink sync=true`**, bounded so that it terminates by
itself. This consumes genuinely decoded frames (proving frame flow) with no
window.

---

## 2. Candidate videos

All from `/opt/nvidia/deepstream/deepstream/samples/streams/`. Probed with
`gst-discoverer-1.0`; **people content was verified by decoding frames to JPEG
and inspecting them**, not inferred from filenames.

| File | Container | Codec | Resolution | FPS | Duration | Audio | People — verified visually |
|---|---|---|---|---|---|---|---|
| **`sample_1080p_h264.mp4`** | QuickTime/MP4 | H.264 **High** | 1920x1080 | 30/1 | **48.10 s** | AAC 48 kHz stereo | **Many** — pedestrians on a sidewalk, seated people, a cyclist, plus traffic. Faces already blurred. |
| `sample_720p.mp4` | MP4 | H.264 High | 1280x720 | 30/1 | 48.07 s | AAC stereo | Same scene, lower resolution |
| `sample_qHD.mp4` | MP4 | H.264 High | 960x540 | 25/1 | 72.08 s | none | Dashcam driving footage; mostly cars, few distant pedestrians |
| `sample_walk.mov` | QuickTime | H.264 Main | 1920x1080 | 30000/1001 | **9.61 s** | AAC stereo | One person walking past a wall — but very short |
| `sample_run.mov` | QuickTime | H.264 Main | 1920x1080 | 30000/1001 | **5.97 s** | AAC stereo | One person running through an atrium (very surveillance-like) — but very short |
| `sample_office.mp4` | MP4 | H.264 Main | 1728x1080 | 30/1 | 5.43 s | AAC stereo | Fisheye office ceiling cam; people are tiny, 5 s only |
| `sample_cam6.mp4` | MP4 | H.264 High | 1472x1384 | **2/1** | 60.00 s | none | Fisheye parking garage; no people in sampled frames; **2 fps** makes it a poor pacing demo |
| `fisheye_dist.mp4` | MP4 | H.264 | — | — | — | — | Fisheye, heavily distorted; not surveillance-plausible without dewarp |

---

## 3. Recommended candidate

### `/opt/nvidia/deepstream/deepstream/samples/streams/sample_1080p_h264.mp4`

1. **Verified people content** — multiple pedestrians throughout, matching the
   eventual "person in a restricted area" use case.
2. **48 s at a true 30 fps** — long enough to observe sustained real-time
   pacing, short enough to loop repeatedly for testing.
3. **H.264 High in MP4 with an AAC audio track** — pedagogically ideal: it
   forces a demux step, a deliberate choice of the video pad, and an
   `avc` -> `byte-stream` conversion in the parser. A raw `.h264` elementary
   stream would skip all of that.
4. **`nvv4l2decoder` handles it in hardware.**
5. **Already local** — nothing is downloaded.
6. It is the canonical DeepStream reference stream, so later milestones can
   reuse it unchanged.

**Licence/origin note.** There is **no per-stream README or licence file** in
the `streams/` directory (verified). The only licensing artefacts are
`/opt/nvidia/deepstream/deepstream/LICENSE.txt` and `LicenseAgreement.pdf` at
the DeepStream root, covering the SDK as a whole. The path, DeepStream version
and the absence of a separate per-stream licence are documented; no
redistribution right is claimed. This is a further reason not to commit the
video to git.

---

## 4. Proposed explicit GStreamer pipelines

No `playbin`. Both pipelines share the same explicit front end.

### 4.1 Visible playback (requires a display)

```bash
DISPLAY=:1 gst-launch-1.0 -e \
  filesrc location="$VIDEO" \
  ! qtdemux name=demux \
  demux.video_0 \
  ! queue \
  ! h264parse \
  ! nvv4l2decoder \
  ! nv3dsink sync=true
```

### 4.2 Bounded headless verification (no window, exits by itself)

```bash
gst-launch-1.0 -e \
  filesrc location="$VIDEO" \
  ! qtdemux name=demux \
  demux.video_0 \
  ! queue \
  ! h264parse \
  ! nvv4l2decoder \
  ! identity eos-after="$FRAMES" \
  ! fakesink sync=true
```

---

## 5. Explanation of every element

### (1) Container vs codec

The **container** (QuickTime/MP4 here) is the file envelope: it interleaves one
or more elementary streams and stores the index/`moov` atom, per-stream
timestamps, durations and language tags. It says nothing about how pixels are
compressed. The **codec** (H.264/AVC here) is the compression algorithm for one
elementary stream. `sample_1080p_h264.mp4` is an MP4 container holding an H.264
video stream plus an AAC audio stream. The same codec can live in a different
container — or none at all, as in `sample_720p.h264`.

### (2) `filesrc`

Reads raw bytes from a path and pushes them downstream as untyped buffers. It
knows nothing about MP4 or H.264; its src pad caps are `ANY`. It is the source
that makes this a file-based rather than network-based pipeline.

### (3) `qtdemux` — the demuxer

Parses the QuickTime/MP4 structure (the `moov` atom: sample tables, timescales,
codec configuration). It **splits the interleaved file into separate elementary
streams** and attaches correct timestamps (PTS/DTS) to each frame. It emits
`video_0` and `audio_0` pads, and extracts the H.264 `codec_data` (SPS/PPS)
from the container — visible in the captured caps as
`codec_data=(buffer)01640028ffe1...`.

*Verified:* leaving the `audio_0` pad unlinked is fine here — a full-file
extraction run on this exact file completed with exit 0.

### (4) `h264parse` — the codec parser

Two jobs. First it **re-frames** the bitstream: MP4 stores H.264 as
`stream-format=avc` (length-prefixed NAL units, SPS/PPS hidden in `codec_data`),
while `nvv4l2decoder` requires `stream-format=byte-stream` (Annex-B start codes
with SPS/PPS in-band). Second, it **parses the SPS** to publish authoritative
stream metadata. Both are visible in the real captured caps:

```
h264parse sink: video/x-h264, stream-format=(string)avc,         alignment=(string)au, profile=high, level=4
h264parse src:  video/x-h264, stream-format=(string)byte-stream, alignment=(string)au, profile=high, level=4,
                chroma-format=(string)4:2:0, bit-depth-luma=(uint)8, parsed=(boolean)true
```

The `avc` -> `byte-stream` change across that one element is precisely why the
parser cannot be omitted.

### (5) `nvv4l2decoder` — the decoder

NVIDIA's V4L2-backed wrapper around the Orin's dedicated **NVDEC hardware
block**. It turns compressed H.264 access units into full raw frames without
using CPU or CUDA cores for the decode itself.

### (6) Raw pixel format produced — discovered, not assumed

```
nvv4l2decoder src: video/x-raw(memory:NVMM), format=(string)NV12,
                   width=1920, height=1080, framerate=30/1,
                   interlace-mode=progressive, colorimetry=bt601,
                   nvbuf-memory-type=nvbuf-mem-surface-array, gpu-id=0
```

**`NV12`** — 8-bit 4:2:0: a full-resolution Y plane followed by one interleaved
UV plane at half resolution, 12 bits per pixel. Critically it carries the
**`(memory:NVMM)`** caps feature: the buffer is an NVIDIA hardware surface, not
CPU-accessible memory. That is why it can go to `nv3dsink` with zero copies,
and why a non-NVIDIA sink would need an `nvvidconv` copy first.

### (7) Contribution of each element

| Element | Contribution |
|---|---|
| `filesrc` | Byte source; makes the recording the origin of the stream |
| `qtdemux` | Splits MP4 into video/audio elementary streams; applies container timestamps |
| `demux.video_0` | Selects **only** the video stream; audio is deliberately dropped (a camera has no audio track) |
| `queue` | Thread boundary plus buffering, decoupling demux from decode; also where back-pressure absorbs jitter |
| `h264parse` | `avc` -> Annex-B `byte-stream`, in-band SPS/PPS, AU alignment, stream metadata |
| `nvv4l2decoder` | Hardware NVDEC decode -> `NV12` in `NVMM` |
| `identity eos-after=N` | *(headless)* counts buffers and emits EOS after N — the bounded, self-terminating exit |
| `fakesink sync=true` | *(headless)* consumes real frames, no window, still clock-paced |
| `nv3dsink sync=true` | *(visible)* renders `NVMM`/`NV12` directly; the clock-synchronised pacing point |

### (8) Static vs dynamic pads

| Pad | Type | Note |
|---|---|---|
| `filesrc.src` | **Static** (Always) | |
| `qtdemux.sink` | **Static** | |
| `qtdemux.video_0` / `audio_0` | **DYNAMIC** ("sometimes") | Created only after the `moov` atom is parsed at run time |
| `h264parse` sink/src | **Static** | |
| `nvv4l2decoder` sink/src | **Static** | Confirmed: `gst-inspect-1.0 nvv4l2decoder` reports `SRC template 'src' — Availability: Always` |
| `queue`, `identity`, sinks | **Static** | |

The dynamic demuxer pads are exactly why the pipeline is written as
`qtdemux name=demux` … `demux.video_0 ! …` — `gst-launch` defers that link
until the pad appears. In C you would connect the `pad-added` signal.

### (9) Where caps negotiation occurs — with captured evidence

1. **`filesrc` -> `qtdemux`**: `ANY` meets `video/quicktime`; accepted because
   the demuxer is named explicitly (no `typefind` needed).
2. **`qtdemux` -> `h264parse`**:
   `video/x-h264, stream-format=avc, alignment=au, profile=high, level=4, 1920x1080, 30/1`
   — derived from the container.
3. **`h264parse` -> `nvv4l2decoder`**: renegotiated to
   `stream-format=byte-stream, parsed=true, chroma-format=4:2:0`.
   **The most instructive negotiation in the pipeline.**
4. **`nvv4l2decoder` -> sink**:
   `video/x-raw(memory:NVMM), format=NV12, 1920x1080, 30/1`. Negotiating the
   **`memory:NVMM` caps feature** is what selects the zero-copy path; a sink
   that cannot accept it fails here rather than silently degrading.

### (10) How playback is paced like a live camera

`filesrc` plus `nvv4l2decoder` will run far faster than real time — nothing in
a file makes it real-time. Pacing comes from the **sink's clock
synchronisation**:

- Each buffer carries a **PTS** from `qtdemux` (container timescale).
- A sink with **`sync=true`** (the default) compares each buffer's
  PTS + `base_time` against the **pipeline clock** and *blocks* until that
  instant arrives.
- Blocking at the sink propagates upstream as **back-pressure**: the `queue`
  fills, the decoder stalls, `filesrc` stops reading. The pipeline settles at
  exactly 30 fps.

The file is therefore *consumed* at wall-clock speed, which is what makes it a
faithful simulated camera.

*Scope note:* this simulates real-time **pacing**, not live-source
**semantics**. There is no `is-live` source, so no frames are dropped under
load. True drop-when-late behaviour would come from `rtspsrc`/`nvurisrcbin` or
a `queue leaky=downstream`, and is out of scope for this milestone.

---

## 6. Expected files to create

The working directory is already named `video-surveillance` and is empty.
Creating `deepstream-video-surveillance/` inside it would give
`.../video-surveillance/deepstream-video-surveillance/` — redundant nesting.
The current directory is therefore used as the project root, keeping the
requested layout otherwise identical:

```text
/home/matan/Documents/projects/video-surveillance/
├── README.md                              # project overview + how to run this milestone
├── .gitignore                             # excludes media/*.mp4|mov, keeps large video out of git
├── media/
│   └── README.md                          # why no video is committed; source path & licence note
├── scripts/
│   ├── common.sh                          # shared: discover DeepStream dir/version, resolve video,
│   │                                      #   check required elements, detect display
│   ├── inspect_video.sh                   # gst-discoverer-1.0 probe + caps dump
│   ├── run_simulated_stream.sh            # visible real-time playback (nv3dsink)
│   └── verify_simulated_stream.sh         # bounded headless verification + pacing proof
└── docs/
    └── milestone-02-video-input.md        # findings, element-by-element docs, verification output
```

`common.sh` is the one addition to the sketched structure. It holds
version-discovery and preflight checks so all three scripts share them rather
than duplicating, and it is where the "clear error messages" live.

---

## 7. Exact verification plan

Each step shows real output; nothing is claimed without it. No `|| true`
anywhere — scripts use `set -euo pipefail` and check `PIPESTATUS`.

| # | Check | Command | Expected evidence |
|---|---|---|---|
| 1 | Preflight | `./scripts/common.sh --selftest` | DeepStream directory and version discovered via symlink/`version` file; all required elements OK; explicit failure text otherwise |
| 2 | Source properties | `./scripts/inspect_video.sh` | `gst-discoverer-1.0`: Quicktime / H.264 High / 1920x1080 / 30/1 / 0:00:48.100000000 / AAC audio present |
| 3 | Caps chain | `./scripts/inspect_video.sh --caps` | The four negotiations above, including `avc -> byte-stream` and `video/x-raw(memory:NVMM), format=NV12` |
| 4 | Headless frame flow | `./scripts/verify_simulated_stream.sh --frames 150` | Pipeline exits **0** by itself; 150 buffers consumed |
| 5 | Real-time pacing | same script, `sync=true` vs `sync=false` | Paced run tracks real time; unpaced run is far quicker. Script **fails** if the paced elapsed time is outside tolerance |
| 6 | Visible playback | `DISPLAY=:1 ./scripts/run_simulated_stream.sh` | Window on DP-1 showing pedestrians; smooth 30 fps; clean EOS, exit 0 |
| 7 | No-display error path | `DISPLAY= ./scripts/run_simulated_stream.sh` | Refuses with a clear message pointing at the headless script — not a crash |
| 8 | Reproducibility | fresh shell, repeat 2–6 | Identical results |
| 9 | No inference | `grep -rE 'nvinfer|nvtracker|nvdspreprocess|trt' scripts/` | No matches |

Step 5 is what earns the "paced in real time" claim; step 4 earns "bounded
headless".

---

## 8. Risks and uncertainties

1. **`DISPLAY=:1` is not guaranteed to keep working.** It works from this shell
   because the GNOME session on tty2 is logged in and the X cookie is
   accessible. From a different SSH session, or after logout/reboot,
   `XAUTHORITY` may need to point at `/run/user/1000/gdm/Xauthority`. `:1001`
   already rejects connections. *Mitigation:* the script auto-detects a usable
   display, allows a `DISPLAY`/`XAUTHORITY` override, and fails with an
   explicit message rather than hanging.
2. **A window opened over SSH appears on the physical DP monitor**, not on the
   remote client. Expected, but worth stating so that "nothing happened" is not
   misread as failure.
3. **X11 today, but the session could become Wayland.** `nv3dsink` is chosen
   for the current Xorg session; behaviour under Wayland was not tested. The
   script reports the detected session type.
4. **`identity eos-after=N` exit semantics were not yet verified** at
   inspection time. To be confirmed during implementation; fallback is
   `fakesink num-buffers=N` with `-e`, or a `timeout`-driven run.
5. **`videorate` anomaly found during inspection.** In the chain
   `nvvidconv ! video/x-raw,format=I420 ! videorate ! video/x-raw,framerate=1/N`
   the pipeline failed with `qtdemux … reason not-linked (-1)`, while
   `videorate` works standalone with `videotestsrc`. The root cause was not
   pursued because `videorate` is not needed for this milestone;
   `identity drop-probability` was used for frame sampling instead. Recorded
   because it is reproducible on this system.
6. **Licensing is only partially documentable locally.** No per-stream licence
   exists; only the SDK-wide `LICENSE.txt`/`LicenseAgreement.pdf`. This is
   documented as such, without overstatement — reinforcing the decision to keep
   the video out of git.
7. **Faces in `sample_1080p_h264.mp4` appear pre-blurred by NVIDIA**, which is
   good for a privacy-sensitive surveillance project but makes the clip
   unsuitable for any future face-related work. Person detection is unaffected.
8. **The audio track is present and intentionally discarded.** Correct for
   camera simulation; noted so it reads as a deliberate choice.

---

## Addendum: corrections from the implementation phase

Two expectations recorded above did not survive measurement. Both are covered
in detail in [`milestone-02-video-input.md`](milestone-02-video-input.md).

**1. The bounded headless pipeline in §4.2 does not behave as predicted.**
Risk 4 was well placed. `identity eos-after=N` does exit 0, but under
`sync=true` the wall-clock time tracks the **clip duration**, not `N/fps`:
150 frames took 45.6 s, and 30 frames took *longer* (47.7 s) than 150.
`GST_DEBUG=basesink:5` showed the frame bound was honoured
(`rendered: 20, dropped: 0`), but after the sink stops consuming, upstream runs
on to the end of the file, the sink receives GAP events for the remainder, and
`basesink` **synchronises the final EOS event to the segment end**
(`sync times for EOS 0:00:47.3`). Cutting the stream earlier does not help,
because the segment still advertises the full duration.

As a result the shipped `verify_simulated_stream.sh` proves the two claims with
**two separate runs** rather than one: bounded frame flow via
`fakesink num-buffers=N sync=false` (fast, exact count), and real-time pacing
via a full clip at `sync=true` versus `sync=false`. Verification plan steps 4
and 5 were split accordingly.

**2. Pacing was confirmed, by a different measurement than planned.**
Elapsed time under `sync=true` tracks the clip's real duration:

| Clip | Real duration | `sync=true` | `sync=false` |
|---|---|---|---|
| `sample_run.mov` | 5.97 s | 6.14 s | 1.23 s |
| `sample_walk.mov` | 9.61 s | 9.78 s | 1.55 s |
| `sample_1080p_h264.mp4` | 48.10 s | 48.27 s | 6.01 s |

Everything else in this report — the environment findings, the candidate
survey, the source choice, the caps chain, the pad analysis and the raw pixel
format — was confirmed unchanged during implementation.
