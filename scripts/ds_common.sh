#!/usr/bin/env bash
# ds_common.sh - shared helpers for the DeepStream inference pipeline milestone.
#
# Source it from the other scripts:
#     source "$(dirname "$0")/ds_common.sh"
# Or run its preflight checks directly:
#     ./scripts/ds_common.sh --selftest
#
# Like trt_common.sh before it, this file does NOT modify the scripts belonging
# to completed milestones. It sources trt_common.sh (which sources common.sh),
# so the video-input and TensorRT milestones stay byte-identical.
#
# Read-only with respect to the system. The one thing it writes is the stable
# engine symlink inside models/engines/, described below.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trt_common.sh"

CONFIG_DIR="${CONFIG_DIR:-$REPO_ROOT/configs}"
DETECTION_DIR="${DETECTION_DIR:-$REPO_ROOT/models/detections}"

# The committed nvinfer config references a version-free engine name, so that no
# TensorRT version or GPU name is hard-coded in a checked-in file. The wrapper
# maintains this symlink and points it at whatever engine the CURRENT
# environment expects. If that engine is absent the run fails loudly: this
# milestone never builds an engine.
STABLE_ENGINE_NAME="${STABLE_ENGINE_NAME:-trafficcamnet_fp16.engine}"
STABLE_ENGINE="$ENGINE_DIR/$STABLE_ENGINE_NAME"

require_deepstream_app() {
    command -v deepstream-app >/dev/null 2>&1 \
        || die "'deepstream-app' is not in PATH.
       It ships with DeepStream, normally at $(ds_root)/bin/deepstream-app."
}

expected_fp16_engine() {
    # The exact engine filename the current environment implies, derived the
    # same way build_engines.sh derived it: model dims from the ONNX contract,
    # TensorRT version and GPU discovered at run time.
    local contract w h
    contract="$(mktemp)"
    if ! model_contract >"$contract"; then
        rm -f "$contract"
        die "TensorRT could not parse the ONNX model; cannot determine the expected engine name."
    fi
    w="$(contract_field "$contract" input_w)"
    h="$(contract_field "$contract" input_h)"
    rm -f "$contract"
    engine_path fp16 "$w" "$h"
}

ensure_engine_link() {
    # Point the stable name at the versioned engine, or fail with instructions.
    # Never builds anything.
    local target current
    target="$(expected_fp16_engine)"

    if [[ ! -s "$target" ]]; then
        die "The FP16 engine this environment expects is missing:
           $target

       This milestone does not build engines. Build it first with the
       Milestone 4 script, which is unchanged:

           ./scripts/build_engines.sh --precision fp16

       Present in $ENGINE_DIR:
$(ls -1 "$ENGINE_DIR"/*.engine 2>/dev/null | sed 's|^|           |' || echo '           (none)')"
    fi

    if [[ -L "$STABLE_ENGINE" ]]; then
        current="$(readlink -f "$STABLE_ENGINE" || true)"
        [[ "$current" == "$(readlink -f "$target")" ]] || ln -sfn "$(basename "$target")" "$STABLE_ENGINE"
    elif [[ -e "$STABLE_ENGINE" ]]; then
        die "'$STABLE_ENGINE' exists but is not a symlink.
       Refusing to replace a real file. Move it aside and re-run."
    else
        ln -s "$(basename "$target")" "$STABLE_ENGINE"
    fi

    [[ -s "$STABLE_ENGINE" ]] \
        || die "Stable engine link '$STABLE_ENGINE' does not resolve to a readable engine."
    printf '%s\n' "$target"
}

engine_fingerprint() {
    # Used to prove the engine was not rebuilt or modified by a run.
    local resolved
    resolved="$(readlink -f "$STABLE_ENGINE")"
    printf '%s  %s  %s\n' \
        "$(sha256sum "$resolved" | cut -d' ' -f1)" \
        "$(stat -c %Y "$resolved")" \
        "$(stat -c %s "$resolved")"
}

require_config() {
    local path="$CONFIG_DIR/$1"
    [[ -r "$path" ]] || die "Configuration file not found: '$path'."
    printf '%s\n' "$path"
}

# --------------------------------------------------------------- selftest ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == "--selftest" ]] || die "Usage: $0 --selftest"

    bold "== DeepStream application =="
    require_deepstream_app
    printf '  %-24s %s\n' "deepstream-app" "$(command -v deepstream-app)"
    printf '  %-24s %s\n' "DeepStream" "$(ds_version)"

    bold "== Required elements =="
    require_elements nvstreammux nvinfer nvvideoconvert nvdsosd nv3dsink fakesink
    printf '  %-24s %s\n' "pipeline elements" "all present"

    bold "== Engine =="
    resolved="$(ensure_engine_link)"
    printf '  %-24s %s\n' "expected (discovered)" "$(basename "$resolved")"
    printf '  %-24s %s -> %s\n' "stable link" "$STABLE_ENGINE_NAME" "$(readlink "$STABLE_ENGINE")"
    printf '  %-24s %s bytes\n' "size" "$(stat -c %s "$(readlink -f "$STABLE_ENGINE")")"

    bold "== Configuration =="
    for cfg in config_infer_primary_trafficcamnet.txt \
               deepstream_app_walk_headless.txt \
               deepstream_app_walk_display.txt; do
        printf '  %-24s %s\n' "$cfg" "$([[ -r "$CONFIG_DIR/$cfg" ]] && echo OK || echo MISSING)"
    done

    bold "== Source =="
    printf '  %-24s %s\n' "video" "$(resolve_video)"
    printf '  %-24s %s\n' "labels" "$(model_labels)"

    bold "Selftest passed."
fi
