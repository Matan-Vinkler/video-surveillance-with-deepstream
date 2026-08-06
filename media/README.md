# media/

This directory is intentionally empty of video files.

## Why no video is committed

The simulated camera sources are existing **DeepStream sample videos**, read
directly from their install path at run time:

```
/opt/nvidia/deepstream/deepstream/samples/streams/sample_walk.mov          # default
/opt/nvidia/deepstream/deepstream/samples/streams/sample_1080p_h264.mp4    # --crowded
```

The `deepstream` path component is a symlink to the versioned directory
(`deepstream-9.1` on this machine), so the scripts resolve it at run time and
never hard-code a version number.

Reasons for not copying it into the repository:

1. **Size.** The files are ~49 MiB (`sample_walk.mov`, 51,436,729 bytes) and
   ~33 MiB (`sample_1080p_h264.mp4`, 34,952,625 bytes). Git stores binaries
   badly and every future revision would be stored in full.
2. **They are already on every target machine.** Any Jetson with DeepStream
   installed already has these exact files, so committing them adds nothing.
3. **Licensing.** The DeepStream sample streams are covered by the NVIDIA
   DeepStream SDK licence, not by this project's terms. See the note below.

## Licence and origin

What can be established locally, without guessing:

| Item | Value |
|---|---|
| Origin | NVIDIA DeepStream SDK sample stream |
| DeepStream version | 9.1.0 (from `/opt/nvidia/deepstream/deepstream/version`) |
| Install path | `/opt/nvidia/deepstream/deepstream-9.1/samples/streams/` |
| Licence documents | `/opt/nvidia/deepstream/deepstream/LICENSE.txt` and `LicenseAgreement.pdf` |
| Per-stream licence | **None found.** There is no README or licence file inside the `streams/` directory. |

The licence documents cover the SDK as a whole. Because no separate,
per-stream redistribution grant could be found on this system, **this project
does not redistribute the video** — it only reads the file already installed
on the machine. That is a further reason for the choice above.

## If you want to use your own footage

Drop a file here and pass it explicitly; nothing in the scripts assumes the
DeepStream path:

```bash
./scripts/inspect_video.sh          media/my_camera.mp4
./scripts/run_simulated_stream.sh   media/my_camera.mp4
./scripts/verify_simulated_stream.sh media/my_camera.mp4
```

The pipeline currently assumes **H.264 in an MP4/MOV container**, because it
uses `qtdemux` and `h264parse` explicitly rather than an auto-plugging
element. Other codecs or containers would need the corresponding demuxer and
parser swapped in.
