#!/usr/bin/env bash
# run_container.sh - build and run the containerised surveillance application.
#
# Containerisation is a DEPLOYMENT change. The pipeline, configs, engine,
# tracker and analytics geometry are exactly the host-native ones; this script
# only decides where they run.
#
# Modes:
#   --build      build the image (fails loudly if the TensorRT pin did not take)
#   --headless   deepstream-app -> fakesink, writes the detector/tracker dumps
#   --zone       analytics_probe, writes the restricted-zone verdict
#   --display    visible playback on the physical monitor
#   --shell      interactive shell with the same mounts
#
#   --triton     use the Milestone 7 in-process Triton image and configs.
#                Without it, every mode is exactly the Milestone 6 nvinfer path.
#
# Every mount and runtime flag is printed before the container starts: nothing
# important is hidden inside this script.
#
# Deliberately NOT used: --privileged, --device, --gpus, host networking.
# On Jetson the NVIDIA runtime injects the GPU, NVDEC, VIC and display nodes
# through its CSV mode, which was verified before writing this
# (docs/milestone-06-containerization.md).
#
# Usage:
#   ./scripts/run_container.sh --build
#   ./scripts/run_container.sh --headless
#   DISPLAY=:1 ./scripts/run_container.sh --display

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

IMAGE_NAME="${IMAGE_NAME:-video-surveillance-deepstream}"

# --triton selects the Milestone 7 serving layer. It changes THREE things and
# nothing else: the image, the Dockerfile it builds from, and the app config.
# Without it every mode behaves exactly as it did in Milestone 6, so the M6 path
# stays independently runnable and verifiable.
MODE=""
TRITON=0
while (( $# > 0 )); do
    case "$1" in
        --build|--headless|--zone|--display|--shell)
            [[ -z "$MODE" ]] || die "Pick one mode, not '$MODE' and '$1'."
            MODE="$1" ;;
        --triton) TRITON=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
    shift
done
[[ -n "$MODE" ]] || die "No mode given. Try --help."

if (( TRITON )); then
    IMAGE_TAG="${IMAGE_TAG:-m7-triton}"
    DOCKERFILE="$REPO_ROOT/Dockerfile.triton"
    APP_CONFIG_NAME="deepstream_app_walk_triton.txt"
    INFER_ELEMENT="nvinferserver"
    INFER_CFG_NAME="config_inferserver_trafficcamnet.txt"
    DISPLAY_CONFIG_NAME="deepstream_app_walk_triton_display.txt"
else
    IMAGE_TAG="${IMAGE_TAG:-m6}"
    DOCKERFILE="$REPO_ROOT/Dockerfile"
    APP_CONFIG_NAME="deepstream_app_walk_headless.txt"
    INFER_ELEMENT="nvinfer"
    INFER_CFG_NAME="config_infer_primary_trafficcamnet.txt"
    DISPLAY_CONFIG_NAME="deepstream_app_walk_display.txt"
fi
IMAGE="$IMAGE_NAME:$IMAGE_TAG"

# ------------------------------------------------------------- preflight ----
require_docker() {
    command -v docker >/dev/null 2>&1 || die "'docker' is not in PATH."
    docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon.
       Is it running, and is $(id -un) in the 'docker' group?
       'sudo' is deliberately not used by this repository."
}

require_nvidia_runtime() {
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"' \
        || die "The 'nvidia' container runtime is not registered with Docker.
       Without it the container gets no GPU, no NVDEC and no display nodes."
}

require_image() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
        || die "Image '$IMAGE' not found. Build it first:
           ./scripts/run_container.sh --build"
}

require_docker

# ---------------------------------------------------------------- build -----
if [[ "$MODE" == "--build" ]]; then
    bold "== Building $IMAGE =="
    printf '  %-24s %s\n' "context" "$REPO_ROOT"
    printf '  %-24s %s\n' "dockerfile" "$DOCKERFILE"
    printf '  %-24s %s\n' "TensorRT pin" "10.16.2.10-1+cuda13.2 (deliberate: see the Dockerfile)"
    docker build -f "$DOCKERFILE" -t "$IMAGE" "$REPO_ROOT"
    bold "Built $IMAGE"
    docker image inspect "$IMAGE" --format '  size: {{.Size}} bytes   id: {{.Id}}'
    exit 0
fi

require_nvidia_runtime
require_image
require_analytics_config

# The engine is never built or copied: the host's Milestone 4 artifact is
# mounted read-only, so the container physically cannot write one.
ENGINE_TARGET="$(ensure_engine_link)"
[[ -s "$STABLE_ENGINE" ]] || die "Stable engine link does not resolve: $STABLE_ENGINE"

for d in "$DETECTION_DIR" "$TRACK_DIR" "$TERMINATED_DIR" "$SHADOW_DIR" "$ZONE_DIR"; do
    mkdir -p "$d"
done

# ----------------------------------------------------------------- mounts ---
COMMON_ARGS=(
    --rm
    --runtime nvidia
    -v "$ENGINE_DIR:/app/models/engines:ro"
    -v "$DETECTION_DIR:/app/models/detections"
    -v "$TRACK_DIR:/app/models/tracks"
    -v "$TERMINATED_DIR:/app/models/tracks_terminated"
    -v "$SHADOW_DIR:/app/models/tracks_shadow"
    -v "$ZONE_DIR:/app/models/zone"
)

if (( TRITON )); then
    # Two nested read-only mounts. The repository ENTRY (config.pbtxt) is
    # committed and mounted with the tree; the model ARTIFACT is the Milestone 4
    # engine, mounted straight onto 1/model.plan. Nothing is copied, and because
    # both are :ro Triton physically cannot write an engine back.
    require_triton_repo
    COMMON_ARGS+=(
        -v "$TRITON_REPO_DIR:/app/models/triton_model_repo:ro"
        -v "$(readlink -f "$STABLE_ENGINE"):/app/models/triton_model_repo/trafficcamnet/1/model.plan:ro"
    )
fi

show_and_run() {
    bold "== docker run =="
    printf '  %s\n' "docker run ${*}" | fold -s -w 100 | sed '2,$s/^/      /'
    info ""
    docker run "$@"
}

case "$MODE" in
    --headless)
        bold "== Containerised detection + tracking + restricted zone (headless) =="
        printf '  %-24s %s\n' "image" "$IMAGE"
        printf '  %-24s %s (read-only)\n' "engine" "$(basename "$ENGINE_TARGET")"
        printf '  %-24s %s\n' "outputs" "$REPO_ROOT/models/{detections,tracks,zone}"
        info ""
        show_and_run "${COMMON_ARGS[@]}" --network none "$IMAGE" \
            deepstream-app -c "/app/configs/$APP_CONFIG_NAME"
        ;;

    --zone)
        bold "== Containerised restricted-zone probe =="
        show_and_run "${COMMON_ARGS[@]}" --network none "$IMAGE" \
            /app/build/analytics_probe \
              --video /opt/nvidia/deepstream/deepstream/samples/streams/sample_walk.mov \
              --infer-config "/app/configs/$INFER_CFG_NAME" \
              --inference-element "$INFER_ELEMENT" \
              --tracker-lib /opt/nvidia/deepstream/deepstream/lib/libnvds_nvmultiobjecttracker.so \
              --tracker-config /opt/nvidia/deepstream/deepstream/samples/configs/deepstream-app/config_tracker_NvSORT.yml \
              --analytics-config /app/configs/config_nvdsanalytics_restricted_zone.txt \
              --out-dir /app/models/zone
        ;;

    --shell)
        show_and_run "${COMMON_ARGS[@]}" -it --network none "$IMAGE" /bin/bash
        ;;

    --display)
        # X11 on this host authorises by LOCAL UID, not by cookie:
        #   $ DISPLAY=:1 xhost  ->  SI:localuser:matan
        # and ~/.Xauthority holds no cookie for :1 at all. So the narrowest
        # method is to run the container AS that uid -- no xhost change, no
        # cookie mount, nothing weakened on the host.
        if ! DETECTED_DISPLAY="$(find_display)"; then
            die "No usable X display found, so visible playback is not possible.
       This shell has DISPLAY='${DISPLAY:-unset}'.
       If a desktop session is running on the console, point at it explicitly:
           DISPLAY=:1 $0 --display
       For the headless equivalent:
           $0 --headless"
        fi
        UID_NUM="$(id -u)"; GID_NUM="$(id -g)"
        VIDEO_GID="$(getent group video  | cut -d: -f3)"
        RENDER_GID="$(getent group render | cut -d: -f3)"
        [[ -n "$VIDEO_GID" && -n "$RENDER_GID" ]] \
            || die "Could not resolve the 'video'/'render' group ids; the container
       would not be able to open /dev/dri or /dev/nvhost-*."
        if ! DISPLAY="$DETECTED_DISPLAY" xhost 2>/dev/null | grep -q "SI:localuser:$(id -un)"; then
            warn "X access control does not list SI:localuser:$(id -un) for $DETECTED_DISPLAY.
         If the window fails to open, the narrowest fix is to authorise the
         container's user for THIS display only:
             DISPLAY=$DETECTED_DISPLAY xhost +SI:localuser:$(id -un)
         Do not use a bare 'xhost +'."
        fi

        bold "== Containerised visible playback =="
        printf '  %-24s %s\n' "image" "$IMAGE"
        printf '  %-24s %s\n' "display" "$DETECTED_DISPLAY"
        printf '  %-24s %s:%s (+video=%s, render=%s)\n' "running as" \
            "$UID_NUM" "$GID_NUM" "$VIDEO_GID" "$RENDER_GID"
        info ""
        info "  Expect a blue box labelled 'person <id>' following the walker,"
        info "  the restricted zone outlined, and RF changing 0 -> 1 -> 0."
        info ""
        show_and_run "${COMMON_ARGS[@]}" \
            -e DISPLAY="$DETECTED_DISPLAY" \
            -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
            --user "$UID_NUM:$GID_NUM" \
            --group-add "$VIDEO_GID" --group-add "$RENDER_GID" \
            -e HOME=/tmp -e GST_REGISTRY=/tmp/gst-registry.bin \
            "$IMAGE" \
            deepstream-app -c "/app/configs/$DISPLAY_CONFIG_NAME"
        ;;
esac
