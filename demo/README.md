# demo/

The capstone's third deliverable: a short screen capture of the finished system
detecting a person, tracking them, and reporting the restricted zone.

**Recorded 2026-08-15 (Milestone 10.3).** Every command below was executed and is
the one that actually produced the artifact — nothing here is aspirational.

## The artifact

| File | Tracked by git? | What it is |
|---|---|---|
| `demo.mp4` | **No** | **The deliverable.** Both segments, captioned, 19.98 s |
| `demo-visual.mp4` | No | Segment 1 alone, uncaptioned, 12.99 s |
| `demo-mqtt.mp4` | No | Segment 2 alone, uncaptioned, 6.99 s |
| `README.md` — this file | **Yes** | How the capture was made |

All 1280×720, 15 fps, H.264 (Constrained Baseline), QuickTime container; 11 MB
for all three. The video is a **submission artifact, not source**, and follows
the same standing rule as every other piece of media here: large binaries are not
committed ([`../media/README.md`](../media/README.md),
[`../PLAN.md`](../PLAN.md) §8). It is delivered alongside the repository, and
`.gitignore` carries `demo/*.mp4` and friends so it cannot be added by accident.

> **The video is evidence of functionality, not a benchmark.** It is captured
> with a CPU software encoder on the same six cores as the pipeline. Nothing in
> it should be read as a throughput measurement — the performance evidence is
> [`../docs/milestone-08-edge-deployment.md`](../docs/milestone-08-edge-deployment.md)
> and [`../docs/final-report.md`](../docs/final-report.md) §5.

## Capture method

No screen recorder is installed on this machine — `ffmpeg`, `recordmydesktop`,
OBS, `peek` and the rest are all absent, and installing one would need `sudo`,
which this project does not use. GStreamer is already here, so the recorder is
itself a pipeline. `nvv4l2h264enc` is **absent**, so encoding is `x264enc` on the
CPU; `speed-preset=ultrafast` and a 1280×720/15 fps target keep that cheap enough
not to disturb the application.

| | |
|---|---|
| Display captured | `:1` — Xorg on vt2, DP-1, 1920×1080, the physically attached monitor |
| Capture size | 1280×720 (downscaled from 1920×1080) |
| Capture rate | 15 fps |
| Encoder | `x264enc speed-preset=ultrafast tune=zerolatency bitrate=2500–3000` |
| Muxer | `mp4mux` |

```bash
gst-launch-1.0 -e \
  ximagesrc display-name=:1 use-damage=0 show-pointer=false \
  ! video/x-raw,framerate=15/1 \
  ! videoscale ! video/x-raw,width=1280,height=720 \
  ! videoconvert ! video/x-raw,format=I420 \
  ! x264enc speed-preset=ultrafast tune=zerolatency bitrate=2500 key-int-max=30 \
  ! h264parse ! mp4mux ! filesink location=demo/demo-visual.mp4
```

`-e` is load-bearing: it makes `gst-launch-1.0` send EOS on SIGINT, so `mp4mux`
writes its `moov` atom and the file is playable. Killing it any other way leaves
an unfinalised container.

**Proven before use.** A 60-buffer test capture of the bare desktop was recorded
and inspected with `gst-discoverer-1.0` — 1280×720, 15/1, H.264, 3.989 s, exit 0
— before DeepStream was started at all.

## Segment 1 — the visual application, in real time

```bash
DISPLAY=:1 ./scripts/run_container.sh --display --triton
```

The deployed path: `nvinferserver` → in-process Triton → TensorRT FP16, rendered
on the physical monitor from
`configs/deepstream_app_walk_triton_display.txt`, whose sink is `type=2`
(`nv3dsink`) with **`sync=1`** and `file-loop=0`. Playback is clock-paced at the
source's **29.97 fps** — genuinely real time. The run reported
`**PERF: 29.80 (32.93)`, reached a clean EOS, printed `App run successful` and
exited **0**.

**This is not the soak configuration.** `configs/deepstream_app_walk_soak.txt`
sets `sync=0` and `file-loop=1` and exists only to measure capacity; recording it
and calling it real time would misrepresent the result. The display config is
paced by construction and cannot make that mistake.

Visible in the clip, confirmed frame by frame after recording:

| | |
|---|---|
| Blue bounding box tracking the walker | yes |
| `person 1` label — one stable tracker identity throughout | yes |
| Yellow restricted-zone rectangle | yes |
| `RF=0` before entry → `RF=1` while inside → `RF=0` after exit | yes |

**Timing the capture.** Container start plus Triton model load takes ~19 s, and
recording that is dead air. The capture is therefore started once the
application's own log prints

```
INFO: TrtISBackend id:1 initialized model: trafficcamnet
```

which fires a moment before playback. A first take that recorded from t=0 ran
52.7 s, of which ~43 s was startup; the marker-triggered take is 12.99 s and
covers the whole clip.

## Segment 2 — MQTT delivery, a separate run

**This is a second, separate run**, and the video says so in its caption. There is
no single invocation that produces both the visible window and the MQTT stream:
`--display --triton` runs `deepstream-app`, which renders but cannot report
`nvdsanalytics` metadata at all; `--events-mqtt --triton` runs `analytics_probe`,
whose pipeline ends in `fakesink sync=0` — no window. Building a combined mode
purely for a presentation would be new feature work on a finished, verified
system, so it was not done.

A subscriber is opened on the recorded display, **before** the pipeline starts, so
nothing can pass on a retained message:

```bash
# on the captured display
DISPLAY=:1 xterm -geometry 128x32+40+60 -fa 'DejaVu Sans Mono' -fs 12 \
    -bg '#101010' -fg '#e8e8e8' -T 'MQTT subscriber -- surveillance/zone' \
    -e mosquitto_sub -h 127.0.0.1 -p 1883 -t surveillance/zone -v
```

Then, from a separate shell that is deliberately *not* on the recorded display:

```bash
./scripts/run_container.sh --events-mqtt --triton
```

Received during the recorded run, verbatim:

```
surveillance/zone {"event":"zone_enter","event_time_utc":"2026-08-15T20:39:44.962Z","frame_number":109,
 "stream_time_seconds":3.637,"zone":"RF","track_id":1,"class":"person","occupancy":1}
surveillance/zone {"event":"zone_exit","event_time_utc":"2026-08-15T20:39:45.391Z","frame_number":183,
 "stream_time_seconds":6.106,"zone":"RF","track_id":1,"class":"person","occupancy":0,
 "frames_inside":75,"duration_seconds":2.502,"exit_reason":"left_zone"}
```

The run reported `events written: 2`, `mqtt published: 2`, `mqtt acked: 2`,
`mqtt failures: 0`. Delivery is QoS 1 — **at-least-once**, not exactly-once.

## Assembly

The two captures are concatenated and captioned in one GStreamer pass:

```bash
gst-launch-1.0 -e \
  concat name=c ! queue ! videoconvert ! video/x-raw,format=I420 \
    ! x264enc speed-preset=ultrafast tune=zerolatency bitrate=3000 key-int-max=30 \
    ! h264parse ! mp4mux ! filesink location=demo/demo.mp4 \
  filesrc location=demo/demo-visual.mp4 ! qtdemux ! h264parse ! avdec_h264 ! videoconvert \
    ! textoverlay text="1/2  Real-time paced playback at the 29.97 fps source rate  |  DeepStream 9.1 + in-process Triton + TensorRT FP16" \
        valignment=bottom halignment=center font-desc="Sans Bold 11" shaded-background=true ypad=8 \
    ! videoconvert ! video/x-raw,format=I420,width=1280,height=720,framerate=15/1 ! c.sink_0 \
  filesrc location=demo/demo-mqtt.mp4 ! qtdemux ! h264parse ! avdec_h264 ! videoconvert \
    ! textoverlay text="2/2  SEPARATE RUN  |  restricted-zone events delivered over MQTT to an external subscriber" \
        valignment=bottom halignment=center font-desc="Sans Bold 11" shaded-background=true ypad=8 \
    ! videoconvert ! video/x-raw,format=I420,width=1280,height=720,framerate=15/1 ! c.sink_1
```

Result: 19.981 s and 300 frames, exactly 12.99 s + 6.99 s and 195 + 105 frames.
The captions are the only pixels added; nothing was cut, sped up or reordered.

## Caveats, recorded rather than tidied away

- **The desktop is in shot.** It is a real screen capture, so the GNOME dock, two
  transient notifications (`"DeepStream" is ready`, and a NoMachine
  "your desktop is currently viewed" banner) and the desktop wallpaper appear.
  Nothing was staged or cropped out.
- **Encoding is CPU-side**, competing with the pipeline for the same six cores.
  No stutter was observed and the application's own `**PERF` stayed at the paced
  ~29.8 fps, but the recording is not evidence about throughput either way.
- **The capture rate is 15 fps while the application renders at 29.97 fps**, so
  the video shows roughly every other rendered frame. That is a property of the
  recorder, not of the pipeline.
- **Segment 2 shows a terminal, not the pipeline**, because the event path has no
  display. That is the architecture, not a shortcut.
