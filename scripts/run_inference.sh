#!/usr/bin/env bash
# run_inference.sh - VISIBLE playback of the Milestone 5 checkpoint-1 pipeline:
#
#   file source -> decoder -> nvstreammux -> nvinfer -> nvdsosd -> nv3dsink
#
# This opens a window on the physically attached monitor, not in an SSH client.
# One pass of the 9.61 s clip, paced in real time, then a clean EOS. It never
# loops: press q or Ctrl-C to stop early.
#
# The headless, machine-checked equivalent is scripts/verify_inference.sh, which
# needs no display and asserts its results. This script exists to confirm the
# one thing that cannot be asserted from metadata: that nvdsosd actually draws
# the boxes and labels on screen.
#
# Usage:
#   ./scripts/run_inference.sh
#   DISPLAY=:1 ./scripts/run_inference.sh     # if DISPLAY is unset in this shell

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
done

require_tools
require_deepstream_app
require_elements nvstreammux nvinfer nvvideoconvert nvdsosd nv3dsink

APP_CFG="$(require_config deepstream_app_walk_display.txt)"

# A window needs somewhere to go. Fail loudly and usefully rather than hanging
# or crashing inside the sink -- the same contract as Milestone 2's playback.
if ! DETECTED_DISPLAY="$(find_display)"; then
    die "No usable X display found, so visible playback is not possible.

       This shell has DISPLAY='${DISPLAY:-unset}'.
       If a desktop session is running on the console, point at it explicitly:
           DISPLAY=:1 $0
       For the headless, machine-checked equivalent:
           ./scripts/verify_inference.sh"
fi
export DISPLAY="$DETECTED_DISPLAY"

ENGINE_TARGET="$(ensure_engine_link)"

bold "== Person detection on the simulated camera stream =="
printf '  %-24s %s\n' "source" "$(resolve_video)"
printf '  %-24s %s s (single pass)\n' "duration" "$(video_duration_seconds "$(resolve_video)")"
printf '  %-24s %s\n' "display" "$DISPLAY"
printf '  %-24s %s\n' "sink" "nv3dsink (sync=1 -> real-time pacing)"
printf '  %-24s %s\n' "engine" "$(basename "$ENGINE_TARGET")"
printf '  %-24s %s\n' "app config" "$APP_CFG"
info ""
info "  Expect a blue box labelled 'person' tracking the walking figure."
info "  Class colours: 0 car=red  1 bicycle=cyan  2 person=blue  3 road_sign=green"
info ""

rc=0
deepstream-app -c "$APP_CFG" || rc=$?

info ""
if (( rc == 0 )); then
    bold "Playback finished (clean EOS)."
else
    die "deepstream-app exited with status $rc."
fi
