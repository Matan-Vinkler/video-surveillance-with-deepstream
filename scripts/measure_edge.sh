#!/usr/bin/env bash
# measure_edge.sh - Milestone 8.2: bounded, instrumented run of the DEPLOYED
# pipeline, with host-side telemetry collected alongside it.
#
# This script NEVER builds, pulls or prunes anything. It reuses the Milestone 7
# image exactly as it is and bind-mounts the soak config into it, so the
# deployment artifact under measurement is the one that was certified.
#
# Modes (exactly one):
#   --pilot          ~60 s validation run of the measurement machinery
#   --soak           ~600 s bounded characterisation run
#   --seconds N      override the duration of whichever mode was chosen
#
# Telemetry, written to models/edge/ (git-ignored):
#   <mode>_app.log         deepstream-app stdout+stderr, each line host-stamped
#   <mode>_tegrastats.txt  tegrastats --interval 1000, running around the run
#   <mode>_sampler.tsv     1 Hz: VmRSS, MemAvailable, GPU clock, cooling states
#   <mode>_summary.txt     run metadata, epoch marks and collection counts
#
# The run is UNPACED (sink sync=0). It is a maximum-throughput stress test and
# must never be described as real-time playback. The real-time reading is:
# sustained throughput above 29.97 fps means the board has processing headroom
# for a 29.97 fps input stream.
#
# Exit codes:
#   0  completed the bounded duration
#   1  a criterion failed
#   2  aborted by the RAM guard or the disk floor (telemetry retained)
#   3  the application crashed or exited early
#   4  telemetry collection failed
#   5  preflight failed
#
# Usage:
#   ./scripts/measure_edge.sh --soak && ./scripts/analyze_edge.py --soak

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

IMAGE_NAME="${IMAGE_NAME:-video-surveillance-deepstream}"
IMAGE_TAG="${IMAGE_TAG:-m7-triton}"
IMAGE="$IMAGE_NAME:$IMAGE_TAG"

EDGE_DIR="${EDGE_DIR:-$REPO_ROOT/models/edge}"
SOAK_CONFIG_NAME="deepstream_app_walk_soak.txt"
SOAK_CONFIG="$CONFIG_DIR/$SOAK_CONFIG_NAME"

# The Milestone 4 FP16 engine, frozen since Milestone 6 and re-verified by
# Milestone 7. If this hash moves, the thing being measured is not the thing
# that was certified, and the run is meaningless.
EXPECTED_ENGINE_SHA="35677da6a31aa3724b1d7d93f6b8925a64a7a64b6790a55c18413562725270a6"
EXPECTED_POWER_MODE="MAXN_SUPER"

# 600 MiB is OUR conservative safety threshold, chosen because this board has no
# swap and the kernel's only recourse under pressure is reclaim then the OOM
# killer. It is NOT a kernel limit and NOT a claimed OOM threshold. Three
# consecutive samples, so a transient dip during a buffer-pool reallocation
# cannot destroy a valid run.
RAM_FLOOR_KB=$(( 600 * 1024 ))
RAM_STRIKES_MAX=3
DISK_FLOOR_GB=5
GPU_BUSY_LIMIT=40          # same contention gate benchmark_engines.sh uses
STOP_GRACE_S=15            # how long SIGINT gets before escalating
BASELINE_S="${BASELINE_S:-30}"   # idle telemetry before load; tegrastats is
                                 # system-wide, so loaded figures are only
                                 # meaningful against a measured idle reference

MODE=""
DURATION=0
while (( $# > 0 )); do
    case "$1" in
        --pilot) [[ -z "$MODE" ]] || die "Pick one mode."; MODE="pilot"; DURATION=60 ;;
        --soak)  [[ -z "$MODE" ]] || die "Pick one mode."; MODE="soak";  DURATION=600 ;;
        --seconds)
            shift
            [[ "${1:-}" =~ ^[0-9]+$ ]] || die "--seconds needs an integer."
            DURATION="$1" ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
    shift
done
[[ -n "$MODE" ]] || die "No mode given. Try --help."
(( DURATION > 0 )) || die "Duration must be positive."

APP_LOG="$EDGE_DIR/${MODE}_app.log"
TEGRA_LOG="$EDGE_DIR/${MODE}_tegrastats.txt"
SAMPLER_TSV="$EDGE_DIR/${MODE}_sampler.tsv"
SUMMARY="$EDGE_DIR/${MODE}_summary.txt"
CIDFILE="$EDGE_DIR/.${MODE}.cid"
RC_FILE="$EDGE_DIR/.${MODE}.rc"

STATUS="UNKNOWN"
ABORT_REASON=""
STOP_RUNG="none"
CID=""
CID_RECORD=""
APP_PID=""
APP_COMM="?"
TEGRA_PID=""
RUNNER_PID=""
SAMPLES=0
MEMAVAIL_MIN=999999999
LAST_MEM=0
BASELINE_START=""
LOAD_START=""
LOAD_END=""

# --------------------------------------------------------------- cleanup ----
# One idempotent path, registered before anything is started, so no route out of
# this script can leave a container, a tegrastats, a reader loop or a scratch
# file behind. `set +e` is deliberate and scoped: kill/wait on an already-dead
# pid returns non-zero, and that is the expected case here, not a hidden failure.
cleanup() {
    set +e
    if [[ -n "$CID" && -n "$APP_PID" && -d "/proc/$APP_PID" ]]; then
        docker kill --signal=SIGINT "$CID" >/dev/null 2>&1
        local waited=0
        while [[ -d "/proc/$APP_PID" ]] && (( waited < 10 )); do sleep 1; waited=$(( waited + 1 )); done
        if [[ -d "/proc/$APP_PID" ]]; then docker kill "$CID" >/dev/null 2>&1; fi
    fi
    if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
        wait "$RUNNER_PID"
    fi
    if [[ -n "$TEGRA_PID" ]] && kill -0 "$TEGRA_PID" 2>/dev/null; then
        kill "$TEGRA_PID" 2>/dev/null
        wait "$TEGRA_PID"
    fi
    rm -f "$CIDFILE" "$RC_FILE"
    set -e
}
trap cleanup EXIT
trap 'STATUS="INTERRUPTED"; exit 130' INT TERM

# -------------------------------------------------------------- preflight ---
bold "== Preflight =="
command -v docker >/dev/null 2>&1 || { warn "docker is not in PATH."; exit 5; }
docker info >/dev/null 2>&1 || { warn "Cannot talk to the Docker daemon."; exit 5; }
docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"' \
    || { warn "The 'nvidia' container runtime is not registered."; exit 5; }
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { warn "Image '$IMAGE' not found. This script never builds it."; exit 5; }
[[ -f "$SOAK_CONFIG" ]] || { warn "Missing $SOAK_CONFIG"; exit 5; }
require_triton_repo
ENGINE_TARGET="$(ensure_engine_link)"
[[ -s "$STABLE_ENGINE" ]] || { warn "Stable engine link does not resolve."; exit 5; }

# A failing preflight STOPS. It never tidies the machine up: an orphan process
# or a running container is evidence about the machine's state, and killing it
# would both destroy that evidence and risk interfering with something the user
# is doing deliberately.
ENGINE_SHA="$(sha256sum "$(readlink -f "$STABLE_ENGINE")" | cut -d' ' -f1)"
[[ "$ENGINE_SHA" == "$EXPECTED_ENGINE_SHA" ]] \
    || { warn "Engine sha256 is $ENGINE_SHA, expected $EXPECTED_ENGINE_SHA."; exit 5; }

POWER_MODE_NOW="$(power_mode)"
[[ "$POWER_MODE_NOW" == "$EXPECTED_POWER_MODE" ]] \
    || { warn "Power mode is '$POWER_MODE_NOW', expected $EXPECTED_POWER_MODE. Not changing it."; exit 5; }

if docker ps --format '{{.Image}}' | grep -q "^$IMAGE_NAME"; then
    warn "A container from this project is already running. Refusing to measure alongside it."
    docker ps --format '  {{.ID}} {{.Image}} {{.Status}}' >&2
    exit 5
fi
if pgrep -x tegrastats >/dev/null 2>&1; then
    warn "An orphan tegrastats is already running; its logfile would collide with ours."
    pgrep -a tegrastats >&2
    exit 5
fi
if pgrep -x deepstream-app >/dev/null 2>&1; then
    warn "A deepstream-app is already running on this host."
    pgrep -a deepstream-app >&2
    exit 5
fi

DISK_BEFORE_GB="$(disk_free_gb)"
(( DISK_BEFORE_GB >= DISK_FLOOR_GB )) \
    || { warn "Only ${DISK_BEFORE_GB} GB free; floor is ${DISK_FLOOR_GB} GB."; exit 5; }

GPU_IDLE="$(gpu_busy_percent)"
(( GPU_IDLE <= GPU_BUSY_LIMIT )) \
    || { warn "GPU already ${GPU_IDLE}% busy; refusing to measure under contention."; exit 5; }

printf '  %-24s %s\n' "image"        "$IMAGE"
printf '  %-24s %s\n' "config"       "$SOAK_CONFIG_NAME (bind-mounted, image unchanged)"
printf '  %-24s %s\n' "engine"       "$(basename "$ENGINE_TARGET")"
printf '  %-24s %s\n' "engine sha256" "$ENGINE_SHA"
printf '  %-24s %s\n' "duration"     "${DURATION} s load, ${BASELINE_S} s idle baseline (${MODE})"
printf '  %-24s %s\n' "power mode"   "$POWER_MODE_NOW"
printf '  %-24s %s GB free\n' "disk" "$DISK_BEFORE_GB"
printf '  %-24s %s%%\n' "gpu at rest" "$GPU_IDLE"
printf '  %-24s %s\n' "no stale state" "no project container, no orphan tegrastats/deepstream-app"

mkdir -p "$EDGE_DIR"
rm -f "$APP_LOG" "$TEGRA_LOG" "$SAMPLER_TSV" "$SUMMARY" "$CIDFILE" "$RC_FILE"

# ------------------------------------------------- cooling device inventory --
# Two classes, and they are NOT equivalent. Class A devices impose frequency
# caps: a non-zero state is the thermal framework throttling the hardware.
# Class B are alert and fan devices: the fan spinning up is thermal management
# working, and reporting it as throttling would be wrong.
COOL_PATH=(); COOL_TYPE=(); COOL_MAX=(); COOL_CLASS=(); COOL_START=()
for c in /sys/class/thermal/cooling_device*; do
    [[ -r "$c/type" ]] || continue
    t="$(cat "$c/type")"
    case "$t" in
        cpufreq-*|devfreq-*) k="CAP" ;;
        *)                   k="ALERT" ;;
    esac
    COOL_PATH+=("$c"); COOL_TYPE+=("$t"); COOL_CLASS+=("$k")
    COOL_MAX+=("$(cat "$c/max_state" 2>/dev/null || echo '?')")
    COOL_START+=("$(cat "$c/cur_state" 2>/dev/null || echo '?')")
done
(( ${#COOL_PATH[@]} > 0 )) || { warn "No thermal cooling devices found."; exit 4; }

GPU_DEVFREQ="$(ls -d /sys/devices/platform/bus@0/*.gpu/devfreq/*/ 2>/dev/null | head -n1)"
[[ -r "${GPU_DEVFREQ}cur_freq" ]] || { warn "GPU devfreq cur_freq unreadable."; exit 4; }

{
    printf '# epoch\trss_kb\tmemavail_kb\tgpu_hz'
    for t in "${COOL_TYPE[@]}"; do printf '\t%s' "$t"; done
    printf '\n'
} > "$SAMPLER_TSV"

# One sampler row. rss is passed in because during the idle baseline there is no
# process to read it from, and inventing a zero there would be a lie in the data.
sample_row() {
    local rss="$1" ts mem ghz st row c
    ts="$EPOCHREALTIME"
    mem="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
    ghz="$(cat "${GPU_DEVFREQ}cur_freq" 2>/dev/null)" || ghz=0
    row="$ts\t$rss\t$mem\t$ghz"
    for c in "${COOL_PATH[@]}"; do
        st="$(cat "$c/cur_state" 2>/dev/null)" || st="NA"
        row="$row\t$st"
    done
    printf '%b\n' "$row" >> "$SAMPLER_TSV"
    LAST_MEM="$mem"
    SAMPLES=$(( SAMPLES + 1 ))
    if (( mem < MEMAVAIL_MIN )); then MEMAVAIL_MIN="$mem"; fi
}

# ------------------------------------------------------------- telemetry ----
bold "== Telemetry =="
tegrastats --interval 1000 --logfile "$TEGRA_LOG" >/dev/null 2>&1 &
TEGRA_PID=$!
sleep 3
[[ -s "$TEGRA_LOG" ]] || { warn "tegrastats produced no output in 3 s."; exit 4; }
info "  tegrastats running (pid $TEGRA_PID)"

bold "== Idle baseline (${BASELINE_S} s) =="
BASELINE_START="$EPOCHREALTIME"
for _ in $(seq 1 "$BASELINE_S"); do
    sample_row "NA"
    sleep 1
done
info "  $SAMPLES idle samples, MemAvailable now $(( LAST_MEM / 1024 )) MB"

MOUNTS=(
    -v "$ENGINE_DIR:/app/models/engines:ro"
    -v "$TRITON_REPO_DIR:/app/models/triton_model_repo:ro"
    -v "$(readlink -f "$STABLE_ENGINE"):/app/models/triton_model_repo/trafficcamnet/1/model.plan:ro"
    -v "$SOAK_CONFIG:/app/configs/$SOAK_CONFIG_NAME:ro"
)

# stdbuf -oL INSIDE the container: deepstream-app's stdout is a pipe here, so
# libc would block-buffer it and the PERF lines would arrive in bursts with
# meaningless timestamps. stdbuf execs the program, so PID 1 in the container
# is still deepstream-app itself -- verified in the pilot via /proc/<pid>/comm.
run_app() {
    local rc
    set +e
    docker run --rm --runtime nvidia --network none \
        --cidfile "$CIDFILE" "${MOUNTS[@]}" "$IMAGE" \
        stdbuf -oL -eL deepstream-app -c "/app/configs/$SOAK_CONFIG_NAME" 2>&1 \
      | while IFS= read -r line; do printf '%s %s\n' "$EPOCHREALTIME" "$line"; done > "$APP_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    printf '%s\n' "$rc" > "$RC_FILE"
}

bold "== docker run =="
printf '  docker run --rm --runtime nvidia --network none --cidfile <file> \\\n'
for m in "${MOUNTS[@]}"; do
    [[ "$m" == "-v" ]] && continue
    printf '    -v %s \\\n' "$m"
done
printf '    %s stdbuf -oL -eL deepstream-app -c /app/configs/%s\n\n' "$IMAGE" "$SOAK_CONFIG_NAME"

LOAD_START="$EPOCHREALTIME"
RUN_START="$EPOCHSECONDS"
run_app &
RUNNER_PID=$!

# ------------------------------------------------------- identify the app ---
# --cidfile gives the container id without needing --name; .State.Pid is the
# host pid of the container's PID 1, which IS deepstream-app because the image
# has an empty ENTRYPOINT and stdbuf execs rather than forks.
for _ in $(seq 1 60); do
    [[ -s "$CIDFILE" ]] && break
    sleep 0.5
done
[[ -s "$CIDFILE" ]] || { warn "No container id appeared within 30 s."; STATUS="FAILED"; exit 3; }
CID="$(cat "$CIDFILE")"
CID_RECORD="${CID:0:12}"

for _ in $(seq 1 60); do
    APP_PID="$(docker inspect --format '{{.State.Pid}}' "$CID" 2>/dev/null)" || APP_PID=""
    [[ -n "$APP_PID" && "$APP_PID" != "0" && -d "/proc/$APP_PID" ]] && break
    APP_PID=""
    sleep 0.5
done
[[ -n "$APP_PID" ]] || { warn "Could not resolve the container's host pid."; STATUS="FAILED"; exit 3; }

APP_COMM="$(cat "/proc/$APP_PID/comm" 2>/dev/null)"       || APP_COMM="?"
APP_CMD="$(tr '\0' ' ' < "/proc/$APP_PID/cmdline")"       || APP_CMD="?"
APP_CGROUP="$(grep -o "${CID_RECORD}[0-9a-f]*" "/proc/$APP_PID/cgroup" | head -n1)" || APP_CGROUP=""

bold "== Process identity =="
printf '  %-24s %s\n' "container id" "$CID_RECORD"
printf '  %-24s %s\n' "host pid"     "$APP_PID"
printf '  %-24s %s\n' "/proc comm"   "$APP_COMM"
printf '  %-24s %s\n' "cmdline"      "$APP_CMD"
printf '  %-24s %s\n' "cgroup match" "${APP_CGROUP:-<none>}"
[[ "$APP_COMM" == "deepstream-app" ]] \
    || warn "Host pid $APP_PID is '$APP_COMM', not deepstream-app. RSS would be wrong."

# --------------------------------------------------------- supervisor loop --
bold "== Running for ${DURATION} s =="
DEADLINE=$(( RUN_START + DURATION ))
STRIKES=0
NEXT_TICK=$(( RUN_START + 60 ))

while :; do
    if [[ ! -d "/proc/$APP_PID" ]]; then
        STATUS="SHORT"; ABORT_REASON="application exited before the deadline"
        break
    fi

    rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/$APP_PID/status" 2>/dev/null)" || rss=""
    sample_row "${rss:-NA}"

    if (( LAST_MEM < RAM_FLOOR_KB )); then
        STRIKES=$(( STRIKES + 1 ))
        warn "MemAvailable ${LAST_MEM} kB below floor ${RAM_FLOOR_KB} kB (strike ${STRIKES}/${RAM_STRIKES_MAX})"
        if (( STRIKES >= RAM_STRIKES_MAX )); then
            STATUS="ABORTED"
            ABORT_REASON="ram-guard: MemAvailable below ${RAM_FLOOR_KB} kB for ${RAM_STRIKES_MAX} consecutive samples"
            break
        fi
    else
        STRIKES=0
    fi

    if (( $(disk_free_gb) < DISK_FLOOR_GB )); then
        STATUS="ABORTED"; ABORT_REASON="disk-floor: free space below ${DISK_FLOOR_GB} GB"
        break
    fi

    if (( EPOCHSECONDS >= NEXT_TICK )); then
        info "  t+$(( EPOCHSECONDS - RUN_START ))s  rss=$(( ${rss:-0} / 1024 ))MB  memavail=$(( LAST_MEM / 1024 ))MB"
        NEXT_TICK=$(( NEXT_TICK + 60 ))
    fi

    if (( EPOCHSECONDS >= DEADLINE )); then
        STATUS="COMPLETED"
        break
    fi
    sleep 1
done

# ------------------------------------------------------------- shutdown -----
bold "== Shutdown =="
waited=0
if [[ -d "/proc/$APP_PID" ]]; then
    info "  rung 1: docker kill --signal=SIGINT"
    docker kill --signal=SIGINT "$CID" >/dev/null
    STOP_RUNG="SIGINT"
    while [[ -d "/proc/$APP_PID" ]] && (( waited < STOP_GRACE_S )); do sleep 1; waited=$(( waited + 1 )); done
    if [[ -d "/proc/$APP_PID" ]]; then
        info "  rung 2: docker stop -t 10"
        docker stop -t 10 "$CID" >/dev/null
        STOP_RUNG="docker stop"
        while [[ -d "/proc/$APP_PID" ]] && (( waited < 40 )); do sleep 1; waited=$(( waited + 1 )); done
    fi
    if [[ -d "/proc/$APP_PID" ]]; then
        info "  rung 3: docker kill (SIGKILL)"
        docker kill "$CID" >/dev/null
        STOP_RUNG="SIGKILL"
    fi
    info "  stopped after ${waited} s at rung: $STOP_RUNG"
else
    STOP_RUNG="exited on its own"
fi
LOAD_END="$EPOCHREALTIME"

# The runner's own exit status is not the application's: it is the status of a
# subshell whose job was to write the exit code to a file. The real one is in
# RC_FILE, which is read before cleanup removes it.
set +e; wait "$RUNNER_PID"; set -e
RUNNER_PID=""
APP_RC="$(cat "$RC_FILE" 2>/dev/null)" || APP_RC="?"

if [[ -n "$TEGRA_PID" ]] && kill -0 "$TEGRA_PID" 2>/dev/null; then
    kill "$TEGRA_PID"
    set +e; wait "$TEGRA_PID"; set -e
fi
TEGRA_PID=""
CID=""

DISK_AFTER_GB="$(disk_free_gb)"

# -------------------------------------------------------------- summary -----
# PERF header lines are reprinted every 20 samples and are NOT data. The loop
# marker is GStreamer's own per-seek warning, proven one-per-loop in the pilot;
# it is counted, never suppressed. Empty lines are kept in the log as evidence
# and counted here so they cannot be mistaken for missing data.
PERF_SAMPLES="$(grep -cE '\*\*PERF:[[:space:]]+[0-9]+\.[0-9]+' "$APP_LOG")" || PERF_SAMPLES=0
PERF_HEADERS="$(grep -c 'FPS 0 (Avg)' "$APP_LOG")"                          || PERF_HEADERS=0
LOOP_MARKS="$(grep -c 'Got data flow before segment event' "$APP_LOG")"     || LOOP_MARKS=0
EMPTY_LINES="$(awk 'NF==1 { n++ } END { print n+0 }' "$APP_LOG")"
TEGRA_LINES="$(wc -l < "$TEGRA_LOG")"
RUN_ELAPSED=$(( EPOCHSECONDS - RUN_START ))

{
    printf 'mode                %s\n' "$MODE"
    printf 'status              %s\n' "$STATUS"
    printf 'abort_reason        %s\n' "${ABORT_REASON:-none}"
    printf 'requested_seconds   %s\n' "$DURATION"
    printf 'elapsed_seconds     %s\n' "$RUN_ELAPSED"
    printf 'baseline_seconds    %s\n' "$BASELINE_S"
    printf 'baseline_start      %s\n' "$BASELINE_START"
    printf 'load_start          %s\n' "$LOAD_START"
    printf 'load_end            %s\n' "$LOAD_END"
    printf 'image               %s\n' "$IMAGE"
    printf 'engine_sha256       %s\n' "$ENGINE_SHA"
    printf 'container_id        %s\n' "$CID_RECORD"
    printf 'app_host_pid        %s\n' "$APP_PID"
    printf 'app_comm            %s\n' "$APP_COMM"
    printf 'app_exit_code       %s\n' "$APP_RC"
    printf 'stop_rung           %s\n' "$STOP_RUNG"
    printf 'stop_seconds        %s\n' "$waited"
    printf 'perf_samples        %s\n' "$PERF_SAMPLES"
    printf 'perf_header_lines   %s\n' "$PERF_HEADERS"
    printf 'loop_markers        %s\n' "$LOOP_MARKS"
    printf 'empty_log_lines     %s\n' "$EMPTY_LINES"
    printf 'tegrastats_samples  %s\n' "$TEGRA_LINES"
    printf 'sampler_samples     %s\n' "$SAMPLES"
    printf 'memavail_min_kb     %s\n' "$MEMAVAIL_MIN"
    printf 'ram_floor_kb        %s\n' "$RAM_FLOOR_KB"
    printf 'disk_before_gb      %s\n' "$DISK_BEFORE_GB"
    printf 'disk_after_gb       %s\n' "$DISK_AFTER_GB"
    printf 'power_mode          %s\n' "$POWER_MODE_NOW"
    printf '\ncooling devices (class type max start)\n'
    for i in "${!COOL_PATH[@]}"; do
        printf '  %-6s %-26s max=%-3s start=%s\n' \
            "${COOL_CLASS[$i]}" "${COOL_TYPE[$i]}" "${COOL_MAX[$i]}" "${COOL_START[$i]}"
    done
} > "$SUMMARY"

bold "== Summary =="
cat "$SUMMARY"
info ""
info "Evidence: $EDGE_DIR"
info "Analyse:  ./scripts/analyze_edge.py --$MODE"

case "$STATUS" in
    COMPLETED)   exit 0 ;;
    ABORTED)     exit 2 ;;
    SHORT)       exit 3 ;;
    INTERRUPTED) exit 130 ;;
    *)           exit 1 ;;
esac
