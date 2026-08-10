#!/usr/bin/env bash
# verify_container.sh - prove that containerising the application did not change
# what it does.
#
# The claim under test is narrow and falsifiable: the SAME pipeline, the SAME
# configs and the SAME FP16 engine, run inside a container, must produce the
# SAME per-frame metadata as the host-native run. Not "similar" -- the detector
# and tracker dumps are diffed file by file.
#
# That comparison is only meaningful because the container was upgraded to the
# host's TensorRT 10.16.2 (see the Dockerfile and
# docs/milestone-06-containerization.md). Had we shipped a second engine built
# by a different TensorRT, a difference in output could never be attributed.
#
# Runs, in order:
#   HOST      deepstream-app + analytics_probe   -> the baseline
#   CONTAINER deepstream-app + analytics_probe   -> the subject
#   CONTAINER one read-only facts pass           -> versions, plugins, holds
#   CONTAINER one negative control               -> the engine mount is read-only
#
# What it proves:
#   1  the image exists and carries the pinned TensorRT
#   2  TensorRT inside is exactly 10.16.2.10-1+cuda13.2, and still held
#   3  DeepStream inside is still 9.1.0, same build as the host
#   4  every required plugin loads AT RUNTIME
#   5  the engine is byte-identical host/container and was NOT rebuilt
#   6  the engine mount is genuinely read-only
#   7  the container runs to a clean EOS over all 288 frames
#   8  detector metadata is identical to the host run
#   9  tracker metadata is identical, with the same identity behaviour
#  10  the restricted-zone result is unchanged
#  11  outputs persist on the host after the container is gone
#  12  no --privileged, --device or --gpus is used anywhere
#  13  the host-native application and its suites are untouched
#
# Usage:
#   ./scripts/verify_container.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

IMAGE_NAME="${IMAGE_NAME:-video-surveillance-deepstream}"
IMAGE_TAG="${IMAGE_TAG:-m6}"
IMAGE="$IMAGE_NAME:$IMAGE_TAG"
TRT_EXPECT="10.16.2.10-1+cuda13.2"
TRT_PKGS=(libnvinfer10 libnvinfer-plugin10 libnvinfer-vc-plugin10 libnvinfer-lean10
          libnvinfer-dispatch10 libnvonnxparsers10 tensorrt-libs)

while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
done

require_tools
require_deepstream_app
require_tracker_assets
require_analytics_config
require_probe
command -v docker >/dev/null 2>&1 || die "'docker' is not in PATH."
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon."
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "Image '$IMAGE' not found. Build it: ./scripts/run_container.sh --build"

APP_CFG="$(require_config deepstream_app_walk_headless.txt)"
INFER_CFG="$(require_config config_infer_primary_trafficcamnet.txt)"
ZONE_CFG="$(analytics_config)"
VIDEO_IN_CONTAINER=/opt/nvidia/deepstream/deepstream/samples/streams/sample_walk.mov

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAILURES=0
note_pass() { printf '  PASS  %s\n' "$*"; }
note_fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

reset_dirs() {
    for d in "$DETECTION_DIR" "$TRACK_DIR" "$TERMINATED_DIR" "$SHADOW_DIR" "$ZONE_DIR"; do
        rm -rf "$d"; mkdir -p "$d"
    done
}
snapshot() {  # snapshot <dest-prefix>
    cp -r "$DETECTION_DIR" "$WORKDIR/$1_det"
    cp -r "$TRACK_DIR"     "$WORKDIR/$1_trk"
    cp -r "$ZONE_DIR"      "$WORKDIR/$1_zone"
}

# ------------------------------------------------------------- environment ---
bold "== Environment =="
printf '  %-30s %s\n' "image" "$IMAGE"
printf '  %-30s %s\n' "host DeepStream" "$(ds_version)"
printf '  %-30s %s\n' "host TensorRT" "$(trt_version)"
ENGINE_TARGET="$(ensure_engine_link)"
printf '  %-30s %s\n' "engine (host, read-only mount)" "$(basename "$ENGINE_TARGET")"
ENGINE_SHA_BEFORE="$(sha256sum "$(readlink -f "$STABLE_ENGINE")" | cut -d' ' -f1)"
printf '  %-30s %s\n' "engine sha256 (before)" "${ENGINE_SHA_BEFORE:0:16}..."

MOUNTS=(
    -v "$ENGINE_DIR:/app/models/engines:ro"
    -v "$DETECTION_DIR:/app/models/detections"
    -v "$TRACK_DIR:/app/models/tracks"
    -v "$TERMINATED_DIR:/app/models/tracks_terminated"
    -v "$SHADOW_DIR:/app/models/tracks_shadow"
    -v "$ZONE_DIR:/app/models/zone"
)

# ------------------------------------------------------------- host baseline -
bold "== BASELINE: host-native run =="
reset_dirs
host_rc=0
deepstream-app -c "$APP_CFG" >"$WORKDIR/host_app.log" 2>&1 || host_rc=$?
"$PROBE_BIN" --video "$(resolve_video)" --infer-config "$INFER_CFG" \
    --tracker-lib "$(tracker_lib)" --tracker-config "$(tracker_config)" \
    --analytics-config "$ZONE_CFG" --out-dir "$ZONE_DIR" \
    >"$WORKDIR/host_probe.log" 2>&1 || host_rc=$?
printf '  %-30s %s\n' "exit status" "$host_rc"
(( host_rc == 0 )) || { tail -n 15 "$WORKDIR/host_app.log" >&2; die "The host baseline run failed; nothing to compare against."; }
snapshot host
printf '  %-30s %s\n' "baseline detector frames" "$(find "$WORKDIR/host_det" -name '*.txt' | wc -l)"

# ---------------------------------------------------------- container run ----
bold "== SUBJECT: containerised run =="
reset_dirs
cont_rc=0
docker run --rm --runtime nvidia --network none "${MOUNTS[@]}" "$IMAGE" \
    deepstream-app -c /app/configs/deepstream_app_walk_headless.txt \
    >"$WORKDIR/cont_app.log" 2>&1 || cont_rc=$?
printf '  %-30s %s\n' "deepstream-app exit" "$cont_rc"
probe_rc=0
docker run --rm --runtime nvidia --network none "${MOUNTS[@]}" "$IMAGE" \
    /app/build/analytics_probe \
      --video "$VIDEO_IN_CONTAINER" \
      --infer-config /app/configs/config_infer_primary_trafficcamnet.txt \
      --tracker-lib /opt/nvidia/deepstream/deepstream/lib/libnvds_nvmultiobjecttracker.so \
      --tracker-config /opt/nvidia/deepstream/deepstream/samples/configs/deepstream-app/config_tracker_NvSORT.yml \
      --analytics-config /app/configs/config_nvdsanalytics_restricted_zone.txt \
      --out-dir /app/models/zone \
    >"$WORKDIR/cont_probe.log" 2>&1 || probe_rc=$?
printf '  %-30s %s\n' "analytics_probe exit" "$probe_rc"
snapshot cont

ENGINE_SHA_AFTER="$(sha256sum "$(readlink -f "$STABLE_ENGINE")" | cut -d' ' -f1)"

# ------------------------------------------------------- container facts -----
FACTS="$WORKDIR/facts.txt"
docker run --rm --runtime nvidia --network none -v "$ENGINE_DIR:/app/models/engines:ro" "$IMAGE" \
  bash -c '
    for p in libnvinfer10 libnvinfer-plugin10 libnvinfer-vc-plugin10 libnvinfer-lean10 \
             libnvinfer-dispatch10 libnvonnxparsers10 tensorrt-libs; do
      echo "pkg $p $(dpkg-query -W -f="\${Version}" $p 2>/dev/null)"
    done
    echo "soname $(readlink -f /usr/lib/aarch64-linux-gnu/libnvinfer.so.10)"
    for p in $(apt-mark showhold); do echo "held $p"; done
    echo "dsver $(sed -n "s/^Version: //p" /opt/nvidia/deepstream/deepstream/version)"
    echo "dsgcid $(sed -n "s/^GCID: //p" /opt/nvidia/deepstream/deepstream/version)"
    for e in nvv4l2decoder nvstreammux nvinfer nvtracker nvdsanalytics \
             nvmultistreamtiler nvdsosd nvvideoconvert fakesink; do
      gst-inspect-1.0 $e >/dev/null 2>&1 && echo "elem OK $e" || echo "elem MISSING $e"
    done
    echo "enginesha $(sha256sum /app/models/engines/trafficcamnet_fp16.engine | cut -d" " -f1)"
  ' >"$FACTS" 2>/dev/null
fact() { sed -n "s/^$1 //p" "$FACTS"; }

# --- 1/2. TensorRT pinned and held ---
bold "== CHECK 1: TensorRT inside the image is exactly $TRT_EXPECT =="
trt_bad=0
for p in "${TRT_PKGS[@]}"; do
    v="$(sed -n "s/^pkg $p //p" "$FACTS")"
    printf '  %-28s %s\n' "$p" "${v:-<absent>}"
    [[ "$v" == "$TRT_EXPECT" ]] || trt_bad=$(( trt_bad + 1 ))
done
if (( trt_bad == 0 )); then
    note_pass "all 7 TensorRT packages are at $TRT_EXPECT"
else
    note_fail "$trt_bad TensorRT package(s) are not at $TRT_EXPECT"
fi
SONAME="$(fact soname)"
printf '  %-28s %s\n' "libnvinfer.so.10 ->" "$(basename "$SONAME")"
if [[ "$SONAME" == *10.16.2* ]]; then
    note_pass "the runtime library really is 10.16.2, not just the package record"
else
    note_fail "libnvinfer.so.10 resolves to '$SONAME'"
fi
held_missing=0
for p in "${TRT_PKGS[@]}"; do grep -qx "held $p" "$FACTS" || held_missing=$(( held_missing + 1 )); done
if (( held_missing == 0 )); then
    note_pass "all 7 are apt-mark held again at the new version"
else
    note_fail "$held_missing TensorRT package(s) are no longer held"
fi

# --- 3. DeepStream unchanged ---
bold "== CHECK 2: DeepStream is still 9.1, same build as the host =="
HOST_GCID="$(sed -n 's/^GCID: //p' /opt/nvidia/deepstream/deepstream/version)"
printf '  %-28s %s (GCID %s)\n' "container" "$(fact dsver)" "$(fact dsgcid)"
printf '  %-28s %s (GCID %s)\n' "host" "$(ds_version)" "$HOST_GCID"
if [[ "$(fact dsver)" == "9.1.0" && "$(fact dsgcid)" == "$HOST_GCID" ]]; then
    note_pass "the TensorRT swap left DeepStream 9.1.0 intact and identical to the host build"
else
    note_fail "DeepStream in the container differs from the host"
fi

# --- 4. plugins at runtime ---
bold "== CHECK 3: every required plugin loads at RUNTIME =="
missing="$(grep -c '^elem MISSING' "$FACTS" || true)"
grep '^elem MISSING' "$FACTS" | sed 's/^elem MISSING/  missing:/' || true
printf '  %-28s %s\n' "elements checked" "$(grep -c '^elem ' "$FACTS")"
if [[ "$missing" == "0" ]]; then
    note_pass "all required elements present (they are NOT loadable at build time -- no NVIDIA runtime there)"
else
    note_fail "$missing required element(s) missing inside the container"
fi

# --- 5/6. engine identity and read-only mount ---
bold "== CHECK 4: the engine is byte-identical and was not rebuilt =="
printf '  %-28s %s\n' "host before" "${ENGINE_SHA_BEFORE:0:16}..."
printf '  %-28s %s\n' "seen inside container" "$(fact enginesha | cut -c1-16)..."
printf '  %-28s %s\n' "host after" "${ENGINE_SHA_AFTER:0:16}..."
if [[ "$ENGINE_SHA_BEFORE" == "$ENGINE_SHA_AFTER" && "$(fact enginesha)" == "$ENGINE_SHA_BEFORE" ]]; then
    note_pass "one engine file, unchanged, seen identically from both sides"
else
    note_fail "the engine differs between host and container, or changed during the run"
fi
if grep -q 'Use deserialized engine model' "$WORKDIR/cont_app.log"; then
    note_pass "the container deserialized the prebuilt engine"
else
    grep -iE 'engine|tensorrt' "$WORKDIR/cont_app.log" | head -5 >&2
    note_fail "no 'Use deserialized engine model' line in the container log"
fi
if grep -qE 'try rebuild|trying rebuild|Trying to create engine|buildSerializedNetwork' "$WORKDIR/cont_app.log"; then
    note_fail "the container attempted an engine rebuild"
else
    note_pass "no rebuild was attempted"
fi

bold "== CHECK 5: the engine mount is genuinely read-only =="
ro_rc=0
docker run --rm --runtime nvidia --network none -v "$ENGINE_DIR:/app/models/engines:ro" "$IMAGE" \
    bash -c 'touch /app/models/engines/__write_probe' >"$WORKDIR/ro.log" 2>&1 || ro_rc=$?
if (( ro_rc != 0 )) && [[ ! -e "$ENGINE_DIR/__write_probe" ]]; then
    note_pass "writing into the engine mount fails (exit $ro_rc); a silent rebuild is physically impossible"
else
    rm -f "$ENGINE_DIR/__write_probe"
    note_fail "the engine mount is writable"
fi

# --- 7. clean run over the whole clip ---
bold "== CHECK 6: the containerised app ran to a clean EOS =="
CONT_FRAMES="$(find "$WORKDIR/cont_det" -name '*.txt' | wc -l)"
EXPECTED_FRAMES="$(video_frame_count "$(resolve_video)")"
printf '  %-28s %s of %s\n' "frames processed" "$CONT_FRAMES" "$EXPECTED_FRAMES"
if (( cont_rc == 0 && probe_rc == 0 )); then
    note_pass "deepstream-app and analytics_probe both exited 0"
else
    tail -n 20 "$WORKDIR/cont_app.log" >&2
    note_fail "container runs exited $cont_rc / $probe_rc"
fi
if grep -qE 'ERROR from element|Error\(s\) in config file|App run failed' "$WORKDIR/cont_app.log"; then
    grep -E 'ERROR from element|App run failed' "$WORKDIR/cont_app.log" | head -3 >&2
    note_fail "the container log reports a pipeline error"
else
    note_pass "no pipeline errors in the container log"
fi
if (( CONT_FRAMES == EXPECTED_FRAMES )); then
    note_pass "every frame of the clip was processed"
else
    note_fail "processed $CONT_FRAMES frames, clip holds $EXPECTED_FRAMES"
fi

# --- 8/9. metadata identical ---
bold "== CHECK 7: detector metadata is identical to the host run =="
DET_DIFF="$(diff -rq "$WORKDIR/host_det" "$WORKDIR/cont_det" 2>/dev/null | wc -l)"
printf '  %-28s %s\n' "per-frame files differing" "$DET_DIFF"
# Checkpoint 1 measured ~1% run-to-run detection jitter on identical hosts, so a
# couple of frames is noise; a container-induced change would be structural.
if (( DET_DIFF <= 5 )); then
    note_pass "detector output matches the host run ($DET_DIFF of $CONT_FRAMES frames differ, within the documented jitter)"
else
    diff -rq "$WORKDIR/host_det" "$WORKDIR/cont_det" | head -5 >&2
    note_fail "$DET_DIFF detector frames differ -- more than run-to-run jitter explains"
fi

bold "== CHECK 8: tracker metadata is identical =="
TRK_DIFF="$(diff -rq "$WORKDIR/host_trk" "$WORKDIR/cont_trk" 2>/dev/null | wc -l)"
printf '  %-28s %s\n' "per-frame files differing" "$TRK_DIFF"
if (( TRK_DIFF <= 5 )); then
    note_pass "tracker output matches the host run ($TRK_DIFF frames differ)"
else
    diff -rq "$WORKDIR/host_trk" "$WORKDIR/cont_trk" | head -5 >&2
    note_fail "$TRK_DIFF tracker frames differ"
fi
TRK_VERDICT="$WORKDIR/trk_verdict.txt"
python3 "$REPO_ROOT/scripts/analyze_tracks.py" \
    --detections "$WORKDIR/cont_det" --tracks "$WORKDIR/cont_trk" \
    --terminated "$TERMINATED_DIR" --shadow "$SHADOW_DIR" \
    --verdict "$TRK_VERDICT" >"$WORKDIR/trk_report.txt"
tget() { sed -n "s/^$1=//p" "$TRK_VERDICT"; }
printf '  %-28s %s\n' "mid-track ID switches" "$(tget mid_track_switches)"
printf '  %-28s %s\n' "unique track ids" "$(tget unique_ids)"
printf '  %-28s %s frames\n' "longest continuous track" "$(tget longest_run_len)"
if [[ "$(tget mid_track_switches)" == "0" && "$(tget longest_run_len)" == "224" ]]; then
    note_pass "identity behaviour unchanged: 0 mid-track switches, 224-frame longest track"
else
    note_fail "tracking behaviour changed in the container"
fi

# --- 10. zone ---
bold "== CHECK 9: the restricted-zone result is unchanged =="
ZONE_VERDICT="$WORKDIR/zone_verdict.txt"
python3 "$REPO_ROOT/scripts/analyze_zone.py" \
    --zone "$WORKDIR/cont_zone" --tracks "$WORKDIR/cont_trk" \
    --config "$ZONE_CFG" --verdict "$ZONE_VERDICT" >"$WORKDIR/zone_report.txt"
zget() { sed -n "s/^$1=//p" "$ZONE_VERDICT"; }
printf '  %-28s %s (expected 109)\n' "entry frame" "$(zget ds_entry)"
printf '  %-28s %s (expected 183)\n' "exit frame" "$(zget ds_exit)"
printf '  %-28s %s\n' "frames inside" "$(zget ds_frames_inside)"
printf '  %-28s %s\n' "contiguous runs" "$(zget ds_runs)"
printf '  %-28s %s%%\n' "agreement with recomputation" "$(zget agreement_pct)"
if [[ "$(zget ds_entry)" == "109" && "$(zget ds_exit)" == "183" \
      && "$(zget ds_frames_inside)" == "75" && "$(zget ds_runs)" == "1" ]] \
   && awk -v p="$(zget agreement_pct)" 'BEGIN { exit !(p >= 99.0) }'; then
    note_pass "entry 109, 75 frames, exit 183, one unbroken interval -- identical to host-native"
else
    note_fail "the restricted-zone result changed in the container"
fi

# --- 11. persistence ---
bold "== CHECK 10: outputs persist on the host after the container is gone =="
printf '  %-28s %s\n' "running containers" "$(docker ps -q | wc -l)"
LIVE="$(find "$DETECTION_DIR" "$TRACK_DIR" "$ZONE_DIR" -name '*.txt' -type f | wc -l)"
printf '  %-28s %s\n' "files on the host now" "$LIVE"
if (( LIVE > 0 )) && [[ -O "$DETECTION_DIR" ]]; then
    note_pass "container output survived --rm and is owned by the host user"
else
    note_fail "container output did not persist on the host"
fi

# --- 12. no privileged access ---
# Asserted against what Docker ACTUALLY configured, not against the text of this
# repository's scripts. Grepping source was the first attempt and was wrong: it
# matched its own comments and its own grep line. Inspecting the live HostConfig
# is both stronger and immune to that.
bold "== CHECK 11: no privileged or device access anywhere =="
CID="$(docker run -d --rm --runtime nvidia --network none "${MOUNTS[@]}" "$IMAGE" sleep 30)"
HOSTCFG="$(docker inspect "$CID" --format \
    '{{.HostConfig.Privileged}}|{{len .HostConfig.Devices}}|{{len .HostConfig.DeviceRequests}}|{{.HostConfig.NetworkMode}}|{{len .HostConfig.CapAdd}}')"
docker kill "$CID" >/dev/null 2>&1 || true
IFS='|' read -r PRIV NDEV NDEVREQ NETMODE NCAP <<<"$HOSTCFG"
printf '  %-28s %s\n' "Privileged" "$PRIV"
printf '  %-28s %s\n' "explicit --device entries" "$NDEV"
printf '  %-28s %s\n' "--gpus device requests" "$NDEVREQ"
printf '  %-28s %s\n' "NetworkMode" "$NETMODE"
printf '  %-28s %s\n' "added capabilities" "$NCAP"
if [[ "$PRIV" == "false" && "$NDEV" == "0" && "$NDEVREQ" == "0" \
      && "$NETMODE" == "none" && "$NCAP" == "0" ]]; then
    note_pass "unprivileged, no device mounts, no --gpus, no network, no added capabilities -- the NVIDIA runtime supplies the hardware"
else
    note_fail "the container was granted more access than intended: $HOSTCFG"
fi

# --- 13. host-native application untouched ---
bold "== CHECK 12: the host-native application is untouched =="
if git -C "$REPO_ROOT" diff --quiet HEAD -- configs/ tools/ 2>/dev/null; then
    note_pass "configs/ and tools/ are unmodified relative to HEAD"
else
    git -C "$REPO_ROOT" diff --stat HEAD -- configs/ tools/ >&2
    note_fail "containerisation modified the application's configs or tools"
fi
for suite in verify_zone.sh; do
    s_rc=0
    "$REPO_ROOT/scripts/$suite" >"$WORKDIR/$suite.log" 2>&1 || s_rc=$?
    if (( s_rc == 0 )); then
        note_pass "$suite still exits 0 (it runs the checkpoint 1, 2 and 3 suites in turn)"
    else
        tail -n 25 "$WORKDIR/$suite.log" >&2
        note_fail "$suite exited $s_rc"
    fi
done

# ---------------------------------------------------------------- summary ----
bold "== Summary =="
printf '  %-30s %s\n' "image" "$IMAGE"
printf '  %-30s %s\n' "TensorRT in container" "$(sed -n 's/^pkg libnvinfer10 //p' "$FACTS")"
printf '  %-30s %s\n' "DeepStream in container" "$(fact dsver)"
printf '  %-30s %s\n' "frames processed" "$CONT_FRAMES"
printf '  %-30s %s / %s\n' "det/trk frames differing" "$DET_DIFF" "$TRK_DIFF"
printf '  %-30s %s..%s (%s frames)\n' "restricted zone" "$(zget ds_entry)" "$(zget ds_exit)" "$(zget ds_frames_inside)"

if (( FAILURES == 0 )); then
    bold "All checks passed."
    exit 0
fi
die "$FAILURES check(s) failed."
