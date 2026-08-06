# Milestone 02 — Video input: a reproducible simulated camera stream

**Goal.** Replay a recorded video through an explicit GStreamer pipeline so it
behaves like a live camera, on a Jetson Orin Nano. No AI inference, no
tracking, no DeepStream inference plugins — video input only.

**Status: complete.** Every claim below is backed by output captured on this
machine.

---

## 1. Environment

| Item | Value | How it was determined |
|---|---|---|
| Board | NVIDIA Jetson Orin Nano Engineering Reference Developer Kit Super | `/proc/device-tree/model` |
| L4T | R39, revision 2.0 (GCID 45755727) | `/etc/nv_tegra_release` |
| OS | Ubuntu 24.04.4 LTS (noble) | `/etc/os-release` |
| Kernel | 6.8.12-1021-tegra, aarch64 | `uname -a` |
| GStreamer | 1.24.2 | `gst-launch-1.0 --version` |
| DeepStream | 9.1.0 at `/opt/nvidia/deepstream/deepstream-9.1` | `version` file via the `deepstream` symlink |
| Display | X11 (Xorg on vt2), monitor on `DP-1` at 1920x1080, reachable as `DISPLAY=:1` | `xrandr`, `/tmp/.X11-unix`, `loginctl` |

Two things worth recording because they shaped the design:

- **DeepStream is not registered with `dpkg`.** `dpkg -l | grep deepstream`
  returns nothing; it was installed from the SDK/tarball. So the version cannot
  be discovered with package tools. `scripts/common.sh` resolves the
  unversioned symlink `/opt/nvidia/deepstream/deepstream` and parses its
  `version` file instead, which is why no version string is hard-coded here.
- **`ffmpeg`/`ffprobe` are not installed** and installing packages was out of
  scope, so `gst-discoverer-1.0` is the media-probing tool throughout.

---

## 2. Source selection

Eight local sample videos were probed with `gst-discoverer-1.0`, and their
content was checked by **actually decoding frames to JPEG and looking at
them** — not by trusting the filenames.

| File | Codec | Resolution | FPS | Duration | Audio | People (verified visually) |
|---|---|---|---|---|---|---|
| **`sample_walk.mov`** (default) | H.264 Main | 1920x1080 | 30000/1001 | **9.61 s** | AAC | **One person walking across frame** |
| **`sample_1080p_h264.mp4`** (`--crowded`) | H.264 High | 1920x1080 | 30/1 | **48.10 s** | AAC | **Many** — pedestrians, a cyclist, seated people, traffic |
| `sample_720p.mp4` | H.264 High | 1280x720 | 30/1 | 48.07 s | AAC | Same scene as the crowded source, lower resolution |
| `sample_qHD.mp4` | H.264 High | 960x540 | 25/1 | 72.08 s | none | Dashcam; mostly cars, few distant people |
| `sample_run.mov` | H.264 Main | 1920x1080 | 30000/1001 | 5.97 s | AAC | One person running in an atrium |
| `sample_office.mp4` | H.264 Main | 1728x1080 | 30/1 | 5.43 s | AAC | Fisheye office cam; people are tiny |
| `sample_cam6.mp4` | H.264 High | 1472x1384 | **2/1** | 60.00 s | none | Parking garage; no people seen; 2 fps |
| `fisheye_dist.mp4` | H.264 | — | — | — | — | Heavily distorted fisheye |

### Chosen: `sample_walk.mov` (default), `sample_1080p_h264.mp4` (`--crowded`)

**`sample_walk.mov` is the default simulated camera source.**

- A **single person walking across frame** — the cleanest analogue of someone
  entering a restricted area, and the easiest scene to reason about when
  detection is added in a later milestone.
- **9.61 s** — short enough that looping is the natural way to watch it, and
  short enough for a verification run to complete in seconds.
- **H.264 Main in a QuickTime `.mov` container with an AAC track**, so it still
  exercises a real demux step, a deliberate video-pad selection, and the
  `avc` -> `byte-stream` conversion.
- Decoded in hardware by `nvv4l2decoder`.

**`sample_1080p_h264.mp4` is retained as the optional crowded-scene source**,
selected with `--crowded`. It contains many pedestrians, a cyclist and traffic
over 48.10 s, which is the useful stress case for a busier scene.

### Do the two sources need different pipelines? No.

| Aspect | `sample_walk.mov` (default) | `sample_1080p_h264.mp4` (`--crowded`) | Pipeline impact |
|---|---|---|---|
| Container | QuickTime `.mov` | MP4 | **None** — both ISO-BMFF/QuickTime family, both `qtdemux` |
| Codec | H.264 **Main**, level 4 | H.264 **High**, level 4 | **None** — `h264parse` and `nvv4l2decoder` handle both |
| In-container format | `stream-format=avc` | `stream-format=avc` | **None** — same `avc` -> `byte-stream` conversion |
| Resolution | 1920x1080 | 1920x1080 | None |
| Frame rate | 30000/1001 (29.97) | 30/1 | None structurally; changes expected durations only |
| Video bitrate | 42.7 Mbps | 5.7 Mbps | None — decode stays far faster than real time |
| Audio | AAC 48 kHz stereo | AAC 48 kHz stereo | None — audio pad left unlinked |
| Decoder output | `NV12` / `NVMM` | `NV12` / `NVMM` | Identical |

This was verified rather than assumed: the *unmodified* inspection script was
run against the new source and negotiated the same chain, differing only in
`profile` and framerate.

```
$ ./scripts/inspect_video.sh --caps sample_walk.mov          # rc=0
H264Parse.sink:      video/x-h264, stream-format=avc,         alignment=au, level=4, profile=main
H264Parse.src:       video/x-h264, stream-format=byte-stream, alignment=au, level=4, profile=main, parsed=true
nvv4l2decoder.src:   video/x-raw(memory:NVMM), format=NV12, 1920x1080, ...
```

So changing the default source is a **source-selection change, not a pipeline
change.**

Licence and origin are documented in [`../media/README.md`](../media/README.md).
Summary: NVIDIA DeepStream 9.1.0 sample, no per-stream licence file exists on
this system, so the video is read in place and never redistributed.

---

## 3. Container versus codec

The **container** — QuickTime/MP4 here — is the envelope. It interleaves one
or more elementary streams and stores the index (`moov` atom), per-stream
timestamps, durations and language tags. It says nothing about how pixels are
compressed.

The **codec** — H.264/AVC here — is the compression scheme for one elementary
stream inside that envelope.

`sample_1080p_h264.mp4` is an MP4 container holding an H.264 video stream plus
an AAC audio stream. The same H.264 codec also appears in
`sample_720p.h264` in the same directory with *no* container at all, which is
exactly the distinction.

---

## 4. The pipeline

```
filesrc location=<video>
  ! qtdemux name=demux
demux.video_0
  ! queue
  ! h264parse
  ! nvv4l2decoder
  ! nv3dsink sync=true          # visible mode
  # ! fakesink sync=true        # headless mode
```

`playbin` is deliberately **not** used: every element here is chosen and
explainable.

### What each element contributes

| Element | Contribution |
|---|---|
| `filesrc` | Reads the recording as raw bytes. Knows nothing about MP4 or H.264; its src pad caps are `ANY`. This is what makes a *file* the origin of the stream. |
| `qtdemux` | Parses the QuickTime/MP4 structure, splits the interleaved file into elementary streams, and attaches container timestamps (PTS/DTS) to each frame. Also extracts the H.264 `codec_data` (SPS/PPS) from the `moov` atom. |
| `demux.video_0` | Selects **only** the video stream. The audio pad is left unlinked on purpose — a surveillance camera has no audio track. Verified: leaving it unlinked does not break the pipeline (runs exit 0). |
| `queue` | Adds a thread boundary and buffering between demuxing and decoding, decoupling the two and absorbing jitter. It is also where back-pressure from the sink accumulates. |
| `h264parse` | Re-frames the bitstream and publishes authoritative stream metadata. See below — this is the element people most often omit and then wonder why the decoder fails. |
| `nvv4l2decoder` | NVIDIA's V4L2 wrapper around the Orin's dedicated **NVDEC** hardware block. Turns compressed access units into raw frames without spending CPU or CUDA cores on the decode. |
| `nv3dsink` | Displays `NV12` frames living in `NVMM` memory directly, with no conversion. Also the clock-synchronisation point that paces playback. |
| `fakesink` | Headless equivalent: really consumes decoded frames, displays nothing. |

### Why the parser cannot be dropped

MP4 stores H.264 as `stream-format=avc`: length-prefixed NAL units with SPS/PPS
hidden away in `codec_data`. `nvv4l2decoder` wants `stream-format=byte-stream`:
Annex-B start codes with SPS/PPS carried in-band. `h264parse` performs exactly
that conversion, visible as a caps change across the one element:

```
H264Parse.sink: video/x-h264, stream-format=(string)avc,         alignment=(string)au, level=4, profile=high,
                codec_data=(buffer)01640028ffe1001a67640028acd940780227e584...
H264Parse.src:  video/x-h264, stream-format=(string)byte-stream, alignment=(string)au, level=4, profile=high,
                chroma-format=(string)4:2:0, bit-depth-luma=(uint)8, parsed=(boolean)true
```

### Static and dynamic pads

| Pad | Availability | Note |
|---|---|---|
| `filesrc.src` | Static (Always) | |
| `qtdemux.sink` | Static | |
| **`qtdemux.video_0` / `audio_0`** | **Dynamic ("sometimes")** | Created at run time, only once the `moov` atom has been parsed |
| `queue`, `h264parse` sink/src | Static | |
| `nvv4l2decoder` sink/src | Static | `gst-inspect-1.0 nvv4l2decoder` reports `SRC template 'src' — Availability: Always` |
| `nv3dsink.sink`, `fakesink.sink` | Static | |

The dynamic demuxer pads are precisely why the pipeline is written as
`qtdemux name=demux` … `demux.video_0 ! …`. `gst-launch` defers that link until
the pad appears; in C you would connect to the `pad-added` signal instead.

### Where caps negotiation happens

Reproduce with `./scripts/inspect_video.sh --caps`. Real output from this
machine, in pipeline order:

```
Queue.sink:          video/x-h264, stream-format=avc,         alignment=au, profile=high, level=4, 1920x1080, 30/1
Queue.src:           video/x-h264, stream-format=avc,         alignment=au, profile=high, level=4, 1920x1080, 30/1
H264Parse.sink:      video/x-h264, stream-format=avc,         alignment=au, profile=high, codec_data=...
H264Parse.src:       video/x-h264, stream-format=byte-stream, alignment=au, profile=high, parsed=true, chroma-format=4:2:0
nvv4l2decoder.sink:  video/x-h264, stream-format=byte-stream, alignment=au, profile=high, bit-depth-luma=8
nvv4l2decoder.src:   video/x-raw(memory:NVMM), format=NV12, 1920x1080, framerate=30/1, colorimetry=bt601,
                     nvbuf-memory-type=nvbuf-mem-surface-array, gpu-id=0
FakeSink.sink:       video/x-raw(memory:NVMM), format=NV12, 1920x1080, framerate=30/1
```

Four negotiations matter:

1. **`filesrc` -> `qtdemux`** — `ANY` meets `video/quicktime`. Accepted without
   a `typefind` step because the demuxer is named explicitly.
2. **`qtdemux` -> `h264parse`** — the container's view of the stream.
3. **`h264parse` -> `nvv4l2decoder`** — `avc` becomes `byte-stream`. The single
   most instructive negotiation in the pipeline.
4. **`nvv4l2decoder` -> sink** — raw video appears, carrying the
   `memory:NVMM` caps *feature*.

### The raw pixel format the decoder produces

**`NV12` in `memory:NVMM`** — discovered from the negotiated caps above, not
assumed.

`NV12` is 8-bit 4:2:0: a full-resolution Y (luma) plane followed by a single
interleaved UV plane at half resolution in both directions, so 12 bits per
pixel. The `(memory:NVMM)` caps feature is the important part: the buffer is an
NVIDIA hardware surface, not CPU-addressable memory. That is why it can be
handed to `nv3dsink` with zero copies, and why a generic sink such as
`xvimagesink` would first need an `nvvidconv` to copy it into system memory.

---

## 5. How playback is paced like a live camera

Nothing about a file is inherently real-time. `filesrc` and `nvv4l2decoder`
will happily run far faster than 30 fps. The pacing comes entirely from
**clock synchronisation at the sink**:

1. `qtdemux` gives every buffer a **PTS** derived from the container timescale.
2. A sink with **`sync=true`** (the default) compares each buffer's
   `PTS + base_time` against the pipeline clock and **blocks** until that
   moment arrives.
3. That blocking propagates upstream as **back-pressure**: the `queue` fills,
   the decoder stalls, `filesrc` stops reading. The whole pipeline settles at
   the stream's natural 30 fps.

Measured on this machine, playing each clip to its natural end of stream:

| Clip | Real duration | `sync=true` | `sync=false` |
|---|---|---|---|
| `sample_walk.mov` (default) | 9.61 s | **9.80 s** | 1.53 s |
| `sample_1080p_h264.mp4` (`--crowded`) | 48.10 s | **48.28 s** | 6.02 s |
| `sample_run.mov` (earlier measurement) | 5.97 s | **6.14 s** | 1.23 s |

Paced playback tracks the real duration; unpaced playback consumes the same
file several times faster. That contrast is what the verification script
asserts, rather than simply claiming "it looks smooth".

> **Scope note.** This reproduces real-time *pacing*, not full live-source
> *semantics*. There is no `is-live` source, so nothing is dropped when the
> pipeline falls behind. True drop-when-late behaviour belongs to `rtspsrc` /
> `nvurisrcbin` or a `queue leaky=downstream`, and is out of scope here.

### A platform behaviour worth knowing about

While building the headless check, an initially confusing result turned up:
bounding the run with `fakesink num-buffers=150` still took ~48 s of wall
clock, and asking for *fewer* frames (30) took *longer* (47.7 s) than asking
for more (150 -> 45.6 s).

`GST_DEBUG=basesink:5` explained it. The sink really did honour the bound —

```
gst_base_sink_change_state:<fakesink0> rendered: 20, dropped: 0
```

— but after the sink stopped consuming, upstream kept running to the end of the
file, the sink received **GAP events** covering the remaining 48 s, and
`basesink` **synchronises the final EOS event to the end of the segment**:

```
gst_base_sink_get_sync_times:<fakesink0> sync times for EOS 0:00:47.3
gst_base_sink_do_sync:<fakesink0> possibly waiting for clock to reach ...
```

So under `sync=true`, wall-clock time tracks the **clip duration**, not the
number of frames requested. Cutting the stream earlier (`identity eos-after=N`
before the decoder) does not help either, because the segment still advertises
the full duration.

The consequence for this milestone is a deliberate design choice:
**the two claims are verified by two separate runs.**

- *Bounded frame flow* — `fakesink num-buffers=N sync=false`. Fast, and
  proves exactly N frames were decoded and consumed.
- *Real-time pacing* — play a clip to natural EOS with `sync=true` and
  compare against `sync=false`. Bounded by the clip's own length.

Trying to make one command prove both would have meant reporting a 48 s
runtime as though it were a 5 s one.

### Continuous looping

The default clip is 9.61 s, so looping is the normal way to watch it.
`run_simulated_stream.sh --loop` replays until Ctrl-C; `--passes N` runs a
fixed number of times.

Looping **re-runs the pipeline per pass** rather than seeking inside it, which
keeps the pipeline the minimal explainable one. Measured cost, three
sequential passes of the 9.6096 s clip:

```
pass 1: exit=0 elapsed=9.779s  overhead=+0.170s
pass 2: exit=0 elapsed=9.779s  overhead=+0.170s
pass 3: exit=0 elapsed=9.784s  overhead=+0.175s
```

A consistent **+0.17 s** per pass (~1.8%) for NVDEC teardown and
re-initialisation, seen as a brief black frame between passes.

Two alternatives were considered and rejected:

- **`multifilesrc loop=true`** re-reads the file's bytes from the start, which
  feeds a second container header into `qtdemux` mid-stream and restarts
  timestamps. Not valid for containerised input.
- **Segment seek on EOS** (`GST_SEEK_FLAG_SEGMENT` plus a bus watch) is the
  genuinely gapless approach, but it requires a Python or C application with a
  bus handler. That would replace an explainable `gst-launch` pipeline with a
  program, working against the point of this milestone. It is the upgrade path
  if the 0.17 s gap ever matters.

**Headless verification is deliberately unaffected** — it stays bounded and
never loops.

#### A signal-handling bug this exposed

The first implementation of `--loop` **could not be stopped with Ctrl-C**.
`gst-launch -e` traps SIGINT itself, converts it to EOS and exits **0**, so the
shell's `while true` immediately began another pass:

```
sending SIGINT to process group 199732
RESULT: loop STILL RUNNING after SIGINT -> Ctrl-C does not stop it
passes recorded: PASS 1 … PASS 6        # kept going; needed SIGKILL
```

Fixed with `trap 'STOP=1' INT TERM` and a loop that checks the flag. Regression
test:

```
$ ./scripts/run_simulated_stream.sh --loop --sink fakesink   # SIGINT during pass 2
-- pass 1 --
-- pass 2 --
Stopped after 2 pass(es).                # process exited; no strays left behind
```

---

## 6. Repository layout

The project root is used directly rather than nesting a
`deepstream-video-surveillance/` folder inside a directory already called
`video-surveillance`.

```
video-surveillance/
├── README.md
├── .gitignore
├── media/
│   └── README.md                        # why no video is committed; licence/origin
├── scripts/
│   ├── common.sh                        # discovery, preflight, display detection
│   ├── inspect_video.sh                 # container/codec/resolution/fps/duration + caps
│   ├── run_simulated_stream.sh          # visible real-time playback
│   └── verify_simulated_stream.sh       # bounded headless verification
└── docs/
    └── milestone-02-video-input.md      # this file
```

`common.sh` is the one addition to the originally sketched structure. It holds
DeepStream discovery, element preflight and display detection so that all three
scripts share them instead of duplicating, and so error messages live in one
place.

---

## 7. Verification results

All output below was produced by the scripts in this repository.

### Preflight — `./scripts/common.sh --selftest`

```
== DeepStream ==
  symlink                /opt/nvidia/deepstream/deepstream
  resolved root          /opt/nvidia/deepstream/deepstream-9.1
  version (discovered)   9.1.0
  streams dir            /opt/nvidia/deepstream/deepstream-9.1/samples/streams
== Required elements ==
  filesrc  qtdemux  queue  h264parse  nvv4l2decoder  fakesink        all OK
== Video sources ==
  default                .../samples/streams/sample_walk.mov
  crowded                .../samples/streams/sample_1080p_h264.mp4
== Display ==
  usable DISPLAY         :1 (visible playback available)
Selftest passed.
```

### Source properties — `./scripts/inspect_video.sh`

```
file                 .../samples/streams/sample_walk.mov
Duration: 0:00:09.609600000
container #0: Quicktime
  video #1: H.264 (Main Profile)   1920x1080   30000/1001
  audio #2: MPEG-4 AAC             48000 Hz    stereo
```

### Headless verification — `./scripts/verify_simulated_stream.sh`

```
== CHECK 1: bounded frame flow (150 frames, no window) ==
  source             .../samples/streams/sample_walk.mov
  frames requested   150 (clip holds 288)
  exit status        0
  sink counters      rendered: 150, dropped: 0
  PASS  pipeline exited cleanly on its own
  PASS  sink rendered exactly 150 frames
  PASS  no frames dropped
== CHECK 2: real-time pacing ==
  clip duration      9.610 s
  sync=true          9.80 s (exit 0)
  sync=false         1.53 s (exit 0)
  PASS  both playback runs exited cleanly
  PASS  paced run (9.80 s) matches clip duration (9.610 s)
  PASS  unpaced run (1.53 s) is much faster than real time
== Summary ==
All checks passed.
```

Exit status `0`. The `--crowded` variant also passes, pacing the 48.10 s source
at 48.28 s against 6.02 s unpaced.

### Bounded looping — `./scripts/run_simulated_stream.sh --sink fakesink --passes 3`

```
mode                 3 pass(es)
display              not required (headless sink 'fakesink')
-- pass 1 --   Execution ended after 0:00:09.610028503
-- pass 2 --   Execution ended after 0:00:09.610070565
-- pass 3 --   Execution ended after 0:00:09.609939343
Completed 3 pass(es).
EXIT=0  total=29.89s
```

### Error path — no display available

```
$ X11_SOCKET_DIR=/nonexistent DISPLAY= ./scripts/run_simulated_stream.sh
ERROR: No usable X display found, so visible playback is not possible.
       This shell has DISPLAY='unset'.
       If a desktop session is running on the console, point at it explicitly:
           DISPLAY=:1 ./scripts/run_simulated_stream.sh
       To exercise the same pipeline without a window:
           ./scripts/run_simulated_stream.sh --sink fakesink
       For the full headless check, use instead:
           ./scripts/verify_simulated_stream.sh
$ echo $?
1
```

A frame request the clip cannot satisfy is rejected before any work is done:

```
$ ./scripts/verify_simulated_stream.sh --frames 300
ERROR: Requested 300 frames but '.../sample_walk.mov' contains only 288.
       The clip would reach end of stream first and the check could never pass.
       Use --frames 288 or fewer, or --crowded for a longer source.
$ echo $?
1
```

Conflicting options are rejected too:

```
$ ./scripts/run_simulated_stream.sh --loop --passes 3
ERROR: --loop (run until Ctrl-C) and --passes N (run N times) are mutually exclusive.
$ echo $?
1
```

### Visible playback

Run end-to-end through the script, with `nv3dsink` rendering to the attached
`DP-1` monitor via the auto-detected display:

```
$ ./scripts/run_simulated_stream.sh
== Simulated camera stream ==
  source               .../samples/streams/sample_walk.mov
  duration             9.610 s per pass
  display              :1
  sink                 nv3dsink (sync=true -> real-time pacing)
  mode                 single pass
...
New clock: GstSystemClock
Got EOS from element "pipeline0".
Execution ended after 0:00:09.609986358
Playback finished (clean EOS).
EXIT=0
```

`0:00:09.609986358` against a clip duration of 9.6096 s — the display path is
paced in real time exactly as the headless path is, and exits on a clean EOS.

The script's other behaviour (argument handling, looping, per-pass sequencing,
signal handling) is exercised separately via `--sink fakesink`, so it can be
regression-tested without opening a window.

### No inference component

```
$ grep -rEn 'nvinfer|nvtracker|nvdspreprocess|nvdsanalytics|tensorrt|trtexec' scripts/
$ echo $?
1
```

No matches: nothing under `scripts/` references an inference, tracking or
preprocessing element. (The names appear in this document only, as prose.)

---

## 8. Known limitations

1. **`DISPLAY=:1` depends on the console session.** It works while the GNOME
   session on tty2 is logged in. From a different SSH session `XAUTHORITY` may
   need to point at `/run/user/1000/gdm/Xauthority`. `:1001` (Xwayland) rejects
   connections with `Invalid MIT-MAGIC-COOKIE-1 key`. The scripts detect a
   usable display and fail with guidance rather than hanging.
2. **A window opens on the physical monitor**, not in an SSH client.
3. **`nv3dsink` was chosen for the current Xorg session.** Behaviour under a
   Wayland session has not been tested here. `--sink` allows an override.
4. **The pipeline is H.264-in-MP4/MOV specific** by design, since `qtdemux`
   and `h264parse` are named explicitly. Another codec needs the matching
   demuxer and parser.
5. **`videorate` misbehaved** in an unrelated frame-sampling pipeline
   (`nvvidconv ! video/x-raw,format=I420 ! videorate ! video/x-raw,framerate=1/N`
   failed with `qtdemux … reason not-linked`, while `videorate` works standalone
   with `videotestsrc`). It is not used by this milestone; recorded only
   because it is reproducible on this system.
6. **Faces in `sample_1080p_h264.mp4` are already blurred** by NVIDIA. Good for
   a privacy-sensitive project, but the clip is unsuitable for any future
   face-related work. Person detection is unaffected.
7. **`--frames N` is bounded by the clip's length.** The default source holds
   exactly **288 frames** (9.6096 s x 29.97 fps), so a larger request can never
   be satisfied — the clip reaches end of stream first. This surfaced as a real
   test failure when the default source changed (`--frames 300` rendered 288).
   `verify_simulated_stream.sh` now computes the clip's frame count up front and
   refuses out-of-range requests with the maximum and a suggested alternative,
   instead of running and then reporting a confusing shortfall. The crowded
   source holds 1443 frames.

---

## 9. Completion criteria

| Criterion | Status |
|---|---|
| Suitable recorded surveillance-style source selected | Done — `sample_walk.mov` (default), `sample_1080p_h264.mp4` via `--crowded`; people confirmed by decoding frames |
| Codec, resolution, frame rate, duration documented | Done — H.264 Main, 1920x1080, 30000/1001, 9.61 s (and High, 30/1, 48.10 s) |
| Explicit pipeline replays it visibly when a display exists | Done — `run_simulated_stream.sh` with `nv3dsink` on `DISPLAY=:1`, window on `DP-1`, 9.609986358 s for a 9.6096 s clip, exit 0 |
| Headless pipeline decodes a bounded number of frames and exits | Done — `rendered: 150, dropped: 0`, exit 0 |
| Stream is paced in real time | Done — 9.80 s vs 9.610 s actual; 1.53 s unpaced |
| Continuous looping for visible playback | Done — `--loop` / `--passes N`, 3 passes at 9.610 s each, stops correctly on SIGINT |
| Headless verification stays bounded and non-looping | Done — by construction; `--loop`/`--passes` exist only in the playback script |
| Scripts reproducible from the repository | Done — all four scripts run from a clean shell |
| Every pipeline element documented | Done — §4 |
| No AI inference component added | Done — `grep` over `scripts/` returns no matches |
