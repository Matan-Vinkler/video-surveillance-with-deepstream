#!/usr/bin/env bash
# verify_mqtt.sh - Milestone 9.3: prove that the verified surveillance events are
#                  actually delivered to an external MQTT subscriber.
#
# SEPARATE FROM verify_events.sh ON PURPOSE. Milestone 9.2's claim is "the events
# are correct" and it must stay independently verifiable with no broker and no
# network at all. This script's claim is narrower and different: "those same
# bytes reach a consumer outside the container."
#
# THE STRONGEST CHECK IS A BYTE COMPARISON
# ----------------------------------------
# The probe serializes each event EXACTLY ONCE and hands the same string to both
# sinks (analytics_probe.cpp, serialize_event). So the subscriber's payloads and
# the JSONL lines must be byte-identical. Comparing them is what proves MQTT is a
# TRANSPORT of the verified event rather than a second serialization that merely
# looks similar. Nothing here reconstructs an expected JSON string by hand.
#
# ORDERING MATTERS
# ----------------
# mosquitto_sub is started FIRST and confirmed subscribed before the pipeline
# runs. MQTT has no history for a non-retained topic: a subscriber that attaches
# late simply misses the messages, and the test would fail for a reason that has
# nothing to do with the code. The subscriber is bounded by `timeout` so this
# script cannot hang.
#
# Runs:
#   RUN 1  success path   fresh --events-mqtt container, live subscriber
#   RUN 2  negative path  the same, pointed at a closed port
#
# What it proves:
#   1  a subscriber outside the container receives exactly the expected events
#   2  the received payloads are byte-identical to the JSONL lines
#   3  the semantics are still 109 / 183 / 75
#   4  the broker ACKNOWLEDGED every message (QoS 1 PUBACK count)
#   5  an unreachable broker fails loudly, non-zero, without hanging, and
#      without destroying the local JSONL record
#   6  hygiene: no container, no orphan subscriber or probe
#
# Usage:  ./scripts/verify_mqtt.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

IMAGE_NAME="${IMAGE_NAME:-video-surveillance-deepstream}"
IMAGE_TAG="${IMAGE_TAG:-m7-triton}"
IMAGE="$IMAGE_NAME:$IMAGE_TAG"

EXPECT_EVENTS=2
EXPECT_ENTER_FRAME=109
EXPECT_EXIT_FRAME=183
EXPECT_FRAMES_INSIDE=75
# A port nothing is listening on. Chosen high and odd to avoid colliding with a
# service; asserted closed before use rather than assumed.
DEAD_PORT="${DEAD_PORT:-18831}"
SUB_TIMEOUT_S=180

while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
done

require_tools; require_analytics_config; require_triton_repo
command -v docker >/dev/null 2>&1 || die "'docker' is not in PATH."
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon."
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "Image '$IMAGE' not found. This script never builds it."
command -v mosquitto_sub >/dev/null 2>&1 \
    || die "mosquitto_sub is not installed. Milestone 9.1 recorded it as present."
command -v python3 >/dev/null 2>&1 || die "python3 is required to validate JSON."

WORKDIR="$(mktemp -d)"
FAILURES=0
SUB_PID=""

cleanup() {
    local rc=$?
    set +e
    # Never leave a subscriber behind, on any exit path.
    if [[ -n "$SUB_PID" ]] && kill -0 "$SUB_PID" 2>/dev/null; then
        kill "$SUB_PID" 2>/dev/null
        wait "$SUB_PID" 2>/dev/null
    fi
    if (( rc == 0 && ${FAILURES:-0} == 0 )); then
        rm -rf "$WORKDIR"
    else
        printf '\n  evidence retained: %s\n' "$WORKDIR" >&2
        printf '  %s\n' "sub.out  run.log  neg_run.log  events_success.jsonl" >&2
    fi
    set -e
}
trap cleanup EXIT
note_pass() { printf '  PASS  %s\n' "$*"; }
note_fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

bold "== Environment =="
printf '  %-32s %s\n' "image" "$IMAGE"
printf '  %-32s %s\n' "broker" "$MQTT_HOST:$MQTT_PORT"
printf '  %-32s %s\n' "topic" "$MQTT_TOPIC"
printf '  %-32s %s\n' "event file" "$EVENTS_FILE"

# The broker must be up before anything else is attempted, otherwise a broker
# outage would present as a code failure.
if timeout 5 mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -t "$MQTT_TOPIC/selftest" -m 'verify_mqtt preflight'; then
    note_pass "broker reachable from the host"
else
    die "No MQTT broker at $MQTT_HOST:$MQTT_PORT. Milestone 9.1 recorded mosquitto
       as installed and running; start it before running this verification."
fi

# --- 1 ------------------------------------------------- subscriber first ---
bold "== CHECK 1: an external subscriber receives the events =="
# -C: exit after N messages, so the subscriber ends on its own in the success
# case. timeout: so it ends even when it does not.
timeout "$SUB_TIMEOUT_S" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -t "$MQTT_TOPIC" -C "$EXPECT_EVENTS" >"$WORKDIR/sub.out" 2>"$WORKDIR/sub.err" &
SUB_PID=$!

# Confirm the subscription is LIVE before publishing anything. Polling the
# process is not enough -- mosquitto_sub exists before it has subscribed. A
# round trip through the broker on a scratch topic proves the connection is up.
subscribed=0
for _ in $(seq 1 30); do
    if timeout 3 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
            -t "$MQTT_TOPIC/ready" -C 1 >/dev/null 2>&1 &
    then
        probe_pid=$!
        sleep 0.3
        timeout 3 mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
            -t "$MQTT_TOPIC/ready" -m ready 2>/dev/null
        if wait "$probe_pid" 2>/dev/null; then
            subscribed=1
            break
        fi
    fi
    sleep 0.5
done
(( subscribed == 1 )) && note_pass "broker round trip confirmed before the run" \
    || note_fail "could not confirm broker round trip; the run may race the subscriber"
kill -0 "$SUB_PID" 2>/dev/null && note_pass "subscriber is listening on '$MQTT_TOPIC'" \
    || note_fail "the subscriber exited before the pipeline started"

run_rc=0
./scripts/run_container.sh --events-mqtt --triton >"$WORKDIR/run.log" 2>&1 || run_rc=$?
printf '  %-32s %s\n' "container exit status" "$run_rc"
(( run_rc == 0 )) && note_pass "the MQTT-enabled run exited 0" \
    || { tail -n 20 "$WORKDIR/run.log" >&2; note_fail "the run exited $run_rc"; }

# The subscriber should now have its two messages and exited by itself.
sub_rc=0
wait "$SUB_PID" || sub_rc=$?
SUB_PID=""
SUB_LINES="$(wc -l <"$WORKDIR/sub.out")"
printf '  %-32s %s\n' "subscriber exit status" "$sub_rc"
printf '  %-32s %s\n' "messages received" "$SUB_LINES"
(( sub_rc == 0 )) \
    && note_pass "subscriber exited 0 after receiving $EXPECT_EVENTS message(s)" \
    || note_fail "subscriber exited $sub_rc (124 = timed out waiting for messages)"
(( SUB_LINES == EXPECT_EVENTS )) \
    && note_pass "exactly $EXPECT_EVENTS messages received -- no per-frame spam" \
    || note_fail "received $SUB_LINES messages, expected $EXPECT_EVENTS"

cp "$EVENTS_FILE" "$WORKDIR/events_success.jsonl"

# --- 2 --------------------------------------------- byte-identical check ---
bold "== CHECK 2: MQTT payloads are byte-identical to the JSONL lines =="
# Both come from one serialize_event() call. If these ever differ, the single
# serialization property has been broken.
if diff -u "$WORKDIR/events_success.jsonl" "$WORKDIR/sub.out" >"$WORKDIR/payload.diff"; then
    note_pass "subscriber payloads == JSONL lines, byte for byte"
else
    head -20 "$WORKDIR/payload.diff" >&2
    note_fail "the MQTT payloads differ from the JSONL lines"
fi

if python3 -c '
import json, sys
bad = 0
for i, line in enumerate(open(sys.argv[1]), 1):
    if not line.strip():
        continue
    try:
        json.loads(line)
    except Exception as e:
        print("received message %d is not valid JSON: %s" % (i, e)); bad += 1
sys.exit(1 if bad else 0)' "$WORKDIR/sub.out"; then
    note_pass "every received message parses as JSON"
else
    note_fail "a received message is not valid JSON"
fi

# --- 3 ------------------------------------------------------- semantics ---
bold "== CHECK 3: the delivered events still mean what M9.2 verified =="
python3 - "$WORKDIR/sub.out" >"$WORKDIR/sub.txt" <<'PY'
import json, sys
from collections import Counter
msgs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("total=%d" % len(msgs))
k = Counter(m["event"] for m in msgs)
for name in sorted(k):
    print("count_%s=%d" % (name, k[name]))
for m in msgs:
    if m["event"] == "zone_enter":
        print("enter_frame=%d" % m["frame_number"])
        print("enter_zone=%s" % m["zone"])
        print("enter_track=%d" % m["track_id"])
    if m["event"] == "zone_exit":
        print("exit_frame=%d" % m["frame_number"])
        print("exit_frames_inside=%d" % m["frames_inside"])
        print("exit_reason=%s" % m.get("exit_reason", "none"))
PY
sget() { sed -n "s/^$1=//p" "$WORKDIR/sub.txt"; }
printf '  %-32s %s (expected %s)\n' "zone_enter frame" "$(sget enter_frame)" "$EXPECT_ENTER_FRAME"
printf '  %-32s %s (expected %s)\n' "zone_exit frame" "$(sget exit_frame)" "$EXPECT_EXIT_FRAME"
printf '  %-32s %s (expected %s)\n' "frames_inside" "$(sget exit_frames_inside)" "$EXPECT_FRAMES_INSIDE"
printf '  %-32s %s\n' "zone / track" "$(sget enter_zone) / $(sget enter_track)"

[[ "$(sget count_zone_enter)" == "1" && "$(sget count_zone_exit)" == "1" ]] \
    && note_pass "one zone_enter and one zone_exit delivered" \
    || note_fail "expected one of each, got $(sget count_zone_enter)/$(sget count_zone_exit)"
[[ "$(sget enter_frame)" == "$EXPECT_ENTER_FRAME" ]] \
    && note_pass "zone_enter at frame $EXPECT_ENTER_FRAME" \
    || note_fail "zone_enter at $(sget enter_frame)"
[[ "$(sget exit_frame)" == "$EXPECT_EXIT_FRAME" ]] \
    && note_pass "zone_exit at frame $EXPECT_EXIT_FRAME" \
    || note_fail "zone_exit at $(sget exit_frame)"
[[ "$(sget exit_frames_inside)" == "$EXPECT_FRAMES_INSIDE" ]] \
    && note_pass "frames_inside $EXPECT_FRAMES_INSIDE" \
    || note_fail "frames_inside $(sget exit_frames_inside)"
if grep -qE '"event":"zone_inside"|"event":"person_detected"|"event":"pipeline_health"' \
        "$WORKDIR/sub.out"; then
    note_fail "unexpected event types were published"
else
    note_pass "no zone_inside, person_detected or pipeline_health messages"
fi

# --- 4 ------------------------------------------------------ broker ACKs ---
bold "== CHECK 4: the broker acknowledged every message (QoS 1) =="
PUBLISHED="$(sed -n 's/^mqtt published: //p' "$WORKDIR/run.log")"; PUBLISHED="${PUBLISHED:-0}"
ACKED="$(sed -n 's/^mqtt acked: //p' "$WORKDIR/run.log")"; ACKED="${ACKED:-0}"
MFAIL="$(sed -n 's/^mqtt failures: //p' "$WORKDIR/run.log")"; MFAIL="${MFAIL:-0}"
printf '  %-32s %s / %s (failures %s)\n' "published / acked" "$PUBLISHED" "$ACKED" "$MFAIL"
[[ "$PUBLISHED" == "$EXPECT_EVENTS" && "$ACKED" == "$EXPECT_EVENTS" && "$MFAIL" == "0" ]] \
    && note_pass "$EXPECT_EVENTS published, $EXPECT_EVENTS PUBACKed, 0 failures" \
    || note_fail "publish/ack accounting is $PUBLISHED/$ACKED with $MFAIL failures"
info "  QoS 1 is AT LEAST ONCE. This states the broker took delivery of every"
info "  message in this run; it is not a claim of exactly-once semantics."

# --- 5 --------------------------------------------------- negative test ----
bold "== CHECK 5: an unreachable broker fails loudly and does not hang =="
# Assert the port really is closed rather than assuming it. A negative test
# against a port that happens to be open would prove nothing.
if timeout 3 bash -c "echo > /dev/tcp/$MQTT_HOST/$DEAD_PORT" 2>/dev/null; then
    note_fail "port $DEAD_PORT is OPEN, so this would not be a negative test"
else
    note_pass "port $DEAD_PORT is closed, so it is a genuine unreachable endpoint"

    NEG_EVENTS="$WORKDIR/neg_events.jsonl"
    neg_start="$EPOCHSECONDS"
    neg_rc=0
    # Invoked directly rather than through run_container.sh so the broker port
    # can be pointed somewhere closed without adding a flag to the wrapper.
    docker run --rm --runtime nvidia --network host \
        -v "$ENGINE_DIR:/app/models/engines:ro" \
        -v "$TRITON_REPO_DIR:/app/models/triton_model_repo:ro" \
        -v "$(readlink -f "$STABLE_ENGINE"):/app/models/triton_model_repo/trafficcamnet/1/model.plan:ro" \
        -v "$ZONE_DIR:/app/models/zone" \
        -v "$PROBE_MQTT_BIN:/app/build/analytics_probe_mqtt:ro" \
        -v "$WORKDIR:/app/neg" \
        "$IMAGE" \
        /app/build/analytics_probe_mqtt \
          --video /opt/nvidia/deepstream/deepstream/samples/streams/sample_walk.mov \
          --infer-config /app/configs/config_inferserver_trafficcamnet.txt \
          --inference-element nvinferserver \
          --tracker-lib /opt/nvidia/deepstream/deepstream/lib/libnvds_nvmultiobjecttracker.so \
          --tracker-config /opt/nvidia/deepstream/deepstream/samples/configs/deepstream-app/config_tracker_NvSORT.yml \
          --analytics-config /app/configs/config_nvdsanalytics_restricted_zone.txt \
          --out-dir /app/models/zone \
          --events-output /app/neg/neg_events.jsonl \
          --mqtt-host "$MQTT_HOST" --mqtt-port "$DEAD_PORT" \
          --mqtt-topic "$MQTT_TOPIC" >"$WORKDIR/neg_run.log" 2>&1 || neg_rc=$?
    neg_elapsed=$(( EPOCHSECONDS - neg_start ))

    printf '  %-32s %s\n' "exit status" "$neg_rc"
    printf '  %-32s %s s\n' "elapsed" "$neg_elapsed"
    (( neg_rc != 0 )) \
        && note_pass "the run exited non-zero ($neg_rc) -- delivery failure is visible" \
        || note_fail "the run exited 0 despite the broker being unreachable"

    if grep -qE 'mqtt: cannot connect' "$WORKDIR/neg_run.log"; then
        note_pass "the error names MQTT as the cause: $(grep -m1 'cannot connect' "$WORKDIR/neg_run.log" | sed 's/^ERROR: //')"
    else
        note_fail "no clear MQTT connection error in the log"
    fi

    # The reliability hierarchy: analytics -> JSONL (primary record) -> MQTT
    # (transport). A transport failure must not cost the local record.
    if [[ -s "$NEG_EVENTS" ]]; then
        NEG_LINES="$(wc -l <"$NEG_EVENTS")"
        printf '  %-32s %s lines\n' "JSONL still written" "$NEG_LINES"
        (( NEG_LINES == EXPECT_EVENTS )) \
            && note_pass "local JSONL evidence was preserved despite the outage" \
            || note_fail "JSONL has $NEG_LINES lines, expected $EXPECT_EVENTS"
    else
        note_fail "no local JSONL was written during the outage"
    fi

    # 60 s is generous for a 9.61 s clip and would still catch a retry loop.
    (( neg_elapsed < 60 )) && note_pass "no hang: finished in ${neg_elapsed}s, no retry loop" \
        || note_fail "took ${neg_elapsed}s -- looks like it retried"
fi

# --- 6 --------------------------------------------------------- hygiene ----
bold "== CHECK 6: hygiene =="
LEFTOVER="$(docker ps -aq | wc -l)"
(( LEFTOVER == 0 )) && note_pass "no container left behind" \
    || note_fail "$LEFTOVER container(s) still exist"

ORPHANS="$(ps -eo comm= | sort -u \
    | grep -cE '^(deepstream-app|analytics_probe|analytics_probe_mqtt|mosquitto_sub)$')" || ORPHANS=0
(( ORPHANS == 0 )) && note_pass "no orphan probe, deepstream-app or mosquitto_sub" \
    || note_fail "$ORPHANS orphan process(es)"

if (( $(wc -c <"$EVENTS_FILE") < 65536 )); then
    note_pass "event file is small ($(wc -c <"$EVENTS_FILE") bytes)"
else
    note_fail "event file is unexpectedly large"
fi

# --- verdict ----------------------------------------------------------------
printf '\n'
if (( FAILURES == 0 )); then
    bold "== Milestone 9.3 MQTT delivery VERIFIED =="
    printf '  %s\n' \
        "$SUB_LINES messages received by an external subscriber on '$MQTT_TOPIC'" \
        "payloads byte-identical to the JSONL lines from the same run" \
        "zone_enter $(sget enter_frame), zone_exit $(sget exit_frame), $(sget exit_frames_inside) frames inside" \
        "$ACKED of $PUBLISHED acknowledged by the broker at QoS 1 (at-least-once)" \
        "an unreachable broker exits non-zero without hanging, and keeps the local record"
    exit 0
else
    bold "== $FAILURES CHECK(S) FAILED =="
    exit 1
fi
