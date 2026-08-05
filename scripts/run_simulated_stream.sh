#!/usr/bin/env bash
# run_simulated_stream.sh - replay a recorded video through an explicit
# GStreamer pipeline as a real-time simulated camera stream, on screen.
#
# The pipeline is written out element by element on purpose (no playbin), so
# that every stage can be explained. Pacing comes from the sink's clock
# synchronisation (sync=true): each decoded frame is held until its
# presentation timestamp arrives, which back-pressures the decoder and the
# file reader, so the file is consumed at 1x speed instead of as fast as
# possible.
#
# Usage:
#   ./scripts/run_simulated_stream.sh                    # default source
#   ./scripts/run_simulated_stream.sh --quick            # short ~6 s clip
#   ./scripts/run_simulated_stream.sh --loop             # replay forever
#   ./scripts/run_simulated_stream.sh --sink nveglglessink
#   ./scripts/run_simulated_stream.sh sample_walk.mov

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SINK="nv3dsink"
LOOP=0
VIDEO_ARG=""

while (( $# > 0 )); do
    case "$1" in
        --quick) VIDEO_ARG="$QUICK_VIDEO_NAME" ;;
        --loop)  LOOP=1 ;;
        --sink)  shift; (( $# > 0 )) || die "--sink needs a value."; SINK="$1" ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        -*) die "Unknown option '$1'. Try --help." ;;
        *)  VIDEO_ARG="$1" ;;
    esac
    shift
done

require_tools
require_elements "${REQUIRED_ELEMENTS[@]}" "$SINK"
VIDEO="$(resolve_video "${VIDEO_ARG:-$DEFAULT_VIDEO_NAME}")"

# A window needs somewhere to go. Fail loudly and usefully rather than
# hanging or crashing deep inside the sink.
if ! DETECTED_DISPLAY="$(find_display)"; then
    die "No usable X display found, so visible playback is not possible.

       This shell has DISPLAY='${DISPLAY:-unset}'.
       If a desktop session is running on the console, point at it explicitly:
           DISPLAY=:1 $0 $*
       For a headless check that needs no window, use instead:
           ./scripts/verify_simulated_stream.sh"
fi
export DISPLAY="$DETECTED_DISPLAY"

DURATION="$(video_duration_seconds "$VIDEO")"

bold "== Simulated camera stream =="
printf '  %-20s %s\n' "source" "$VIDEO"
printf '  %-20s %s s (expect roughly this much wall-clock time per pass)\n' "duration" "$DURATION"
printf '  %-20s %s\n' "display" "$DISPLAY"
printf '  %-20s %s (sync=true -> real-time pacing)\n' "sink" "$SINK"
printf '  %-20s %s\n' "loop" "$( ((LOOP)) && echo yes || echo no )"
info ""
info "The window opens on the display above - on this machine that is the"
info "physically attached monitor, not an SSH client. Press Ctrl-C to stop."
info ""

# filesrc      : read the recording as raw bytes
# qtdemux      : split the MP4/MOV container into elementary streams
# demux.video_0: take only the video stream (a camera has no audio track)
# queue        : thread boundary + buffering between demux and decode
# h264parse    : re-frame H.264 from avc (length-prefixed) to byte-stream
#                (Annex-B) with in-band SPS/PPS, which nvv4l2decoder requires
# nvv4l2decoder: hardware NVDEC decode -> NV12 frames in NVMM memory
# <sink>       : renders NVMM/NV12 directly and paces on the pipeline clock
build_pipeline() {
    printf '%s\n' \
        "filesrc location=$VIDEO" \
        "! qtdemux name=demux" \
        "demux.video_0" \
        "! queue" \
        "! h264parse" \
        "! nvv4l2decoder" \
        "! $SINK sync=true"
}

bold "== Pipeline =="
build_pipeline | sed 's/^/  /'
info ""

run_once() {
    # shellcheck disable=SC2046  # word splitting of the pipeline is intended
    gst-launch-1.0 -e $(build_pipeline)
}

if (( LOOP )); then
    # Looping is done by re-running the pipeline, not inside GStreamer, so the
    # pipeline itself stays the minimal explainable one shown above.
    pass=1
    while true; do
        bold "-- pass $pass --"
        run_once
        pass=$(( pass + 1 ))
    done
else
    run_once
    bold "Playback finished (clean EOS)."
fi
