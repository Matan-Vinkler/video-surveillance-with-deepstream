# Milestone 09.3 — MQTT delivery to an external consumer

**Goal.** Get the events Milestone 9.2 verified off the box, and prove a
subscriber outside the container received exactly those bytes.

**Status: complete. M9.3 PASSES.** `./scripts/verify_mqtt.sh` exits 0 with all
twenty checks passing. A `mosquitto_sub` started before the pipeline received
**exactly two messages**, byte-identical to the JSONL lines written by the same
run, both acknowledged by the broker at QoS 1. A second, deliberately
unreachable broker made the run exit non-zero in 8 seconds without hanging and
without costing the local record.

```
  messages received                2
  PASS  subscriber payloads == JSONL lines, byte for byte
  zone_enter frame                 109 (expected 109)
  zone_exit frame                  183 (expected 183)
  frames_inside                    75 (expected 75)
  published / acked                2 / 2 (failures 0)
```

The surveillance result is unchanged: `verify_events.sh`, `verify_zone.sh` and
`verify_triton.sh` all still exit 0.

---

## 1. Purpose

Milestone 9.2 proved the events are *correct*. It proved nothing about whether
they leave the machine — the JSONL file sits on the same disk as the pipeline
that wrote it. M9.3 answers the remaining question:

> Do those exact events reach a consumer outside the container?

Nothing else. No new event types, no `pipeline_health`, no operational
telemetry, no second broker technology.

## 2. Why MQTT

The capstone allows *"logging to file or Kafka/MQTT sink, optionally Prometheus
and Grafana."* The inspection compared the realistic options on this machine
([`milestone-09-inspection.md`](milestone-09-inspection.md) §2–§5):

| Option | Verdict |
|---|---|
| **MQTT (Mosquitto)** | **Chosen.** Broker already installed, enabled, running and round-trip verified. `libnvds_mqtt_proto.so` resolves, `libmosquitto` present in host and image. Zero new infrastructure |
| Kafka | Adapter present and `librdkafka.so.1` resolves, but no broker runs and one would need Zookeeper/KRaft. Strictly more infrastructure for the same result |
| Redis | `libnvds_redis_proto.so` needs `libhiredis.so.1.1.0`, which is **not installed**. Rules itself out |
| Prometheus / Grafana | An exporter, a TSDB with retention, a provisioned dashboard — on 25 GB free with no `sudo` for services. Explicitly optional in the capstone |

MQTT is also the right *shape*: this is event-driven intrusion notification, not
a metrics time series. A zone entry is a discrete thing that happened, which is
what a pub/sub topic carries well and what a scrape endpoint carries badly.

## 3. Why not `nvmsgconv`

The textbook DeepStream route is `nvmsgconv → nvmsgbroker`, configured by
`[sink] type=6`, with no application code at all. Both plugins load in the M7
image and the MQTT adapter resolves there. It still cannot be used, for a reason
established by reading the shipped source rather than assumed:

```
$ grep -rn "NVDS_USER_OBJ_META_NVDSANALYTICS|NvDsAnalyticsObjInfo|NvDsAnalyticsFrameMeta" \
       /opt/nvidia/deepstream/deepstream/sources/libs/nvmsgconv/
  (no matches)

$ strings libnvds_msgconv.so.1.0.0 | grep -iE 'roiStatus|objInROI'
  (none)
```

`nvmsgconv` serialises `NvDsEventMsgMeta`, which the application must attach and
which `deepstream-app` never attaches; and it never reads the `nvdsanalytics`
user meta at all. Its `NvDsAnalyticsObject` is a static descriptive block from
the msgconv config file — *which module produced this* — not the ROI verdict.

> A configuration-only path could have published detections and track IDs, but
> not whether the person was inside the restricted zone.

So the transport is attached where the ROI verdict actually exists: in the probe
that has been reading it since Milestone 5.

## 4. Architecture

```
        nvdsanalytics metadata  (NvDsAnalyticsFrameMeta + NvDsAnalyticsObjInfo)
                    |
        analytics_probe pad probe on the nvdsanalytics src pad
                    |
        per-(object_id, roi_label) transition detection          [M9.2]
                    |
        serialize_event()  ->  ONE JSON string                   [M9.2]
                    |
        +-----------+-----------+
        |                       |
   JSONL line              MQTT publish                          [M9.3]
   events.jsonl            topic surveillance/zone, QoS 1
                                   |
                           Mosquitto 127.0.0.1:1883
                                   |
                            external subscriber
```

## 5. The relationship between JSONL and MQTT

**One serialization, two sinks.** This is the load-bearing design decision.

`serialize_event()` builds the JSON string once. `emit_event()` then hands that
same `std::string` to the file and to `mosquitto_publish`. There is no second
formatter, no MQTT-only wrapper, and no field reordering on either path.

That is what makes the verification meaningful:

> Because both sinks receive identical bytes, the subscriber's output and the
> JSONL file can be compared with `diff`. Any difference is a transport fault,
> not two serializers that drifted apart.

Had the payload been rebuilt for the wire, a passing byte comparison would have
proved only that two pieces of code agreed today.

MQTT is therefore a **transport of an already-verified event**, and Milestone
9.2's evidence carries forward intact rather than needing to be re-established
in a different format.

## 6. Network-mode decision

The broker listens on **loopback only**:

```
LISTEN  127.0.0.1:1883   and   [::1]:1883
```

Milestone 9.1 tested every container network mode rather than assuming one:

| Mode | `127.0.0.1:1883` | `172.17.0.1:1883` |
|---|---|---|
| `--network none` | unreachable | — |
| default bridge | unreachable | **unreachable** |
| `--network host` | **REACHABLE** | — |

Bridge fails even via the docker0 gateway, because nothing is bound on the
bridge address. The alternatives to host networking were: widen the broker's
listener (needs `sudo`, changes system state), or run a second broker (new
infrastructure for no benefit). **`--network host` is the only option needing
neither `sudo` nor a change to the broker.**

## 7. Why `--network host` is scoped to one mode

Milestone 7's central claim is that Triton runs **in-process** — no daemon, no
socket, no HTTP, no gRPC — and `--network none` is a large part of the evidence
for it. `verify_triton.sh` asserts it in four places. Quietly adding networking
to the existing modes would have retired that evidence without saying so.

So M9.3 adds a **new mode** rather than relaxing the old ones:

| Mode | Network | Milestone |
|---|---|---|
| `--headless`, `--zone`, `--display`, `--shell` | `--network none` | M6/M7 |
| `--events` | `--network none` | M9.2 — file output needs no network |
| **`--events-mqtt`** | **`--network host`** | M9.3 — publishing requires the broker |

Three properties follow, and all three are verified rather than asserted:

1. `verify_triton.sh` still passes unchanged, so the isolation claim still holds
   for the modes that make it.
2. `verify_events.sh` still passes under `--network none`, so **event generation
   never depends on a broker or a network**.
3. The security-relevant difference is visible in the mode name at the command
   line, not buried in a script.

`run_container.sh`'s header comment previously read *"Deliberately NOT used:
… host networking"*. That statement became false and was corrected rather than
left standing.

## 8. Topic

```
surveillance/zone
```

One stable application topic, configurable through `MQTT_TOPIC` and passed
explicitly on the command line — nothing is hard-coded in the C++.

**Not** a topic per track or per frame. The payload already carries `event`,
`zone`, `track_id` and `class`, so encoding those in the topic tree would
duplicate the message in its own address and force subscribers into wildcard
patterns to see one zone's activity.

## 9. QoS and retain

| Setting | Value | Why |
|---|---|---|
| QoS | **1** | The broker returns a PUBACK per message, so the run can count acknowledgements and report *delivery* rather than *attempted delivery*. QoS 0 would be fire-and-forget with nothing to verify |
| Retain | **false** | A retained intrusion alert is redelivered to every future subscriber as though it had just happened. A stale "person in the restricted zone" is worse than no message |

> **QoS 1 is at-least-once.** It can duplicate a message if a PUBACK is lost and
> the client republishes. This document reports what was observed in a bounded
> run — 2 published, 2 acknowledged, 0 duplicates — and makes **no claim of
> exactly-once delivery**. Exactly-once would be QoS 2, which was not used and
> not tested.

The probe reports the three numbers separately, so the distinction survives into
the logs:

```
mqtt published: 2      handed to the client library
mqtt acked: 2          PUBACKs the broker actually returned
mqtt failures: 0
```

## 10. Connection lifecycle

Bounded and matched to the run. No background service, no daemon.

```
connect (once, no retry loop)   mosquitto_connect
   |                            fails fast -- "Connection refused" in ~0 s
start network thread            mosquitto_loop_start
   |                            so PUBACKs arrive while the pipeline runs
run the DeepStream pipeline
   |                            on each transition: serialize once,
   |                            write JSONL, publish the same bytes
EOS
   |
drain (bounded, <= 5 s)         wait for outstanding PUBACKs only
disconnect / loop_stop / destroy / lib_cleanup
```

**No retry loop, deliberately.** A broker that is not there is a fact to report,
not a thing to wait for; an unbounded retry inside a bounded verification is how
a test hangs. The negative test below confirms the run ends in 8 s.

## 11. Success-path verification

`scripts/verify_mqtt.sh`, kept separate from `verify_events.sh` so Milestone
9.2 stays independently verifiable with no broker at all.

**Ordering is part of the test.** MQTT keeps no history for a non-retained
topic: a subscriber that attaches after the publish simply misses it, and the
test would fail for a reason unrelated to the code. So the script:

1. asserts the broker is reachable at all (otherwise a broker outage would
   present as a code failure),
2. starts `mosquitto_sub -C 2` **before** the pipeline, bounded by `timeout`,
3. confirms a live round trip through the broker on a scratch topic — merely
   checking the process exists is not enough, because `mosquitto_sub` exists
   before it has subscribed,
4. only then runs the container,
5. `wait`s for the subscriber and captures its exit status.

The subscriber is killed on every exit path by the cleanup trap, so no orphan
can survive a failure.

## 12. Observed subscriber messages

Received by `mosquitto_sub` on `surveillance/zone`, outside the container:

```json
{"event":"zone_enter","event_time_utc":"2026-08-13T16:51:00.088Z","frame_number":109,"stream_time_seconds":3.637,"zone":"RF","track_id":1,"class":"person","occupancy":1}
{"event":"zone_exit","event_time_utc":"2026-08-13T16:51:00.761Z","frame_number":183,"stream_time_seconds":6.106,"zone":"RF","track_id":1,"class":"person","occupancy":0,"frames_inside":75,"duration_seconds":2.502,"exit_reason":"left_zone"}
```

Two messages for 288 frames. No `zone_inside`, no `person_detected`, no
`pipeline_health` — asserted explicitly, not merely absent by luck.

## 13. Byte comparison with JSONL

The strongest check in the milestone:

```
diff -u models/events/events.jsonl <subscriber output>   ->  no differences
PASS  subscriber payloads == JSONL lines, byte for byte
```

Nothing in the verification reconstructs an expected JSON string by hand. The
file produced by the run is compared directly against what came off the wire.

The semantics are then confirmed independently by parsing the *received*
messages — not the file — with Python's `json`: `zone_enter` 109, `zone_exit`
183, `frames_inside` 75, one of each event.

## 14. Negative test — broker unreachable

Required, bounded, and non-destructive. The host Mosquitto service was **not**
stopped or reconfigured: that would need privilege and would change system
state. Instead the run was pointed at a closed port on the same host.

**The port is asserted closed before use**, rather than assumed — a negative
test against a port that happened to be open would prove nothing.

```
  PASS  port 18831 is closed, so it is a genuine unreachable endpoint
  exit status                      1
  elapsed                          8 s
  PASS  the run exited non-zero (1) -- delivery failure is visible
  PASS  the error names MQTT as the cause:
        mqtt: cannot connect to 127.0.0.1:18831 -- Connection refused
  JSONL still written              2 lines
  PASS  local JSONL evidence was preserved despite the outage
  PASS  no hang: finished in 8s, no retry loop
```

## 15. Failure semantics

The reliability hierarchy, decided before implementation:

```
surveillance analytics          the pipeline result
        |
JSONL event generation          PRIMARY local record
        |
MQTT delivery                   transport
```

A broker outage is a **transport** failure. It must not stop the surveillance
system recording locally, and it must not be mistaken for a detection failure.
So when MQTT is requested and the broker is unreachable:

- the error is printed immediately, naming MQTT and the endpoint,
- **the pipeline still runs and still writes the JSONL record** — confirmed
  above: 2 lines written with the broker down,
- the process exits **non-zero**, so the failure cannot be read as success,
- there is no retry loop, so the run stays bounded.

Publish failures and missing PUBACKs are treated the same way: counted, printed,
and reflected in a non-zero exit.

The JSONL-only mode (`--events`) is unaffected by any of this — it never
contacts a broker and still runs under `--network none`.

## 16. Existing pipeline preservation

Re-run after the change, not assumed:

| Verification | Result |
|---|---|
| `./scripts/verify_events.sh` (M9.2) | **exit 0** — 2 events, 109/183/75, cross-checked against `analyze_zone.py` |
| `./scripts/verify_zone.sh` (M5) | **exit 0** — 288 frames, 109/183, 75 frames, 1 run, 100.00% agreement |
| `./scripts/verify_triton.sh` (M7) | **exit 0** — 33 PASS, 0 FAIL, detection structure identical, zone 109..183 |

The invariants are untouched: 288 frames; `mid_track_switches=0`,
`unique_ids=2`, longest run 224 (50..273); zone entry 109, exit 183, 75 frames,
1 run, 100.00% agreement.

**Two separate binaries is what makes that safe.** `build/analytics_probe` is
built on the host by the unchanged default `make` target and has never linked
`libmosquitto`; `build/analytics_probe_mqtt` is built with `-DHAVE_MOSQUITTO`.
The M5/M7/M9.2 paths use the first, so whichever build ran most recently cannot
change an earlier milestone's result.

## 17. Build and resource hygiene

**No image was rebuilt.** `libmosquitto`'s headers are present in the M7 image
but **not** on the Jetson host, so `make -C tools mqtt` runs *inside* a throwaway
`--rm` container and writes the binary into the bind-mounted `build/`
directory — the same tactic that supplies the engine. The host `make mqtt`
target fails loudly with an explanation rather than producing a binary whose
`--mqtt-host` silently does nothing.

Runtime resolution, checked on both sides:

```
NEEDED  libmosquitto.so.1        RUNPATH  /opt/nvidia/deepstream/deepstream/lib
host:       all resolved         (libmosquitto.so.1 runtime lib is installed)
container:  all resolved
build/analytics_probe:  still does NOT link libmosquitto
```

| | |
|---|---|
| Docker images | unchanged — none built, pulled or pruned |
| Containers after the run | 0 |
| Event file | 409 bytes |
| Subscriber output | 409 bytes, in a temp dir removed on success |
| Output video / engine copies | none |
| `build/`, `models/events/` | git-ignored |

## 18. Limitations

1. **QoS 1 is at-least-once.** No exactly-once claim; duplicates are possible in
   principle and simply did not occur in this bounded run.
2. **One local broker, one run.** Mosquitto 2.0.18 on loopback. No remote broker,
   no broker restart mid-run, no network partition, no message-volume testing.
3. **No authentication and no TLS.** The broker accepts anonymous local
   connections and the client uses none. That is acceptable for a loopback
   broker on a single board and would **not** be acceptable for a real
   deployment, where the transport would need TLS and credentials.
4. **No retained messages**, by choice (§9). A subscriber that attaches after an
   event has been published will never see it — MQTT keeps no history here.
5. **No delivery guarantee beyond the broker.** A PUBACK proves the *broker*
   took the message. It says nothing about whether any subscriber consumed it;
   with no subscriber attached, a non-retained message is simply discarded.
6. **`--network host` gives the container the host's whole network namespace.**
   That is a broader grant than "may reach 127.0.0.1:1883", and it is the
   coarsest part of this design. It is scoped to one mode, but within that mode
   it is not a narrow permission.
7. **`track_ended` and `stream_ended` remain NOT EXERCISED**, exactly as in
   Milestone 9.2. The walker leaves the ROI at frame 183 and stays tracked, so
   only `left_zone` has ever been produced.
8. **A one-frame tracker dropout inside the ROI would still read as a
   termination** (M9.2 §13), producing a spurious exit/enter pair — and now
   publishing it.
9. **No `pipeline_health`**, so a silent topic remains ambiguous between "nothing
   happened" and "the pipeline stopped".
10. **`event_time_utc` is observation time, not capture time** (M9.2 §5).

## 19. M9.3 verdict

| Criterion | Result |
|---|---|
| External subscriber receives the events | **PASS** — 2 messages on `surveillance/zone` |
| Payloads byte-identical to the JSONL from the same run | **PASS** |
| Semantics preserved (109 / 183 / 75) | **PASS**, checked on the *received* messages |
| No per-frame or unexpected event types | **PASS** |
| Broker acknowledged every message (QoS 1) | **PASS** — 2/2, 0 failures |
| Unreachable broker fails loudly, non-zero, no hang | **PASS** — exit 1 in 8 s |
| Local JSONL preserved during the outage | **PASS** — 2 lines |
| Existing verifications unchanged | **PASS** — three suites, all exit 0 |
| `--network none` retained for every other mode | **PASS** |
| No image built, bounded disk, no orphans | **PASS** |

> **M9.3: PASS.**

## 20. Milestone 9 verdict

> **Milestone 9 — Monitoring and Logging: COMPLETE.**

| # | Checkpoint | Status |
|---|---|---|
| 9.1 | Observability and messaging inspection | Complete — [`milestone-09-inspection.md`](milestone-09-inspection.md) |
| 9.2 | Structured surveillance events to file | Complete — [`milestone-09-events.md`](milestone-09-events.md) |
| 9.3 | MQTT delivery to an external consumer | Complete — this document |

The capstone asked for *"DeepStream analytics metadata, logging to file or
Kafka/MQTT sink."* Both halves are delivered from the analytics metadata itself:
a bounded local JSON Lines record, and MQTT delivery of the same bytes to an
external consumer, each independently verified.

What Milestone 9 deliberately did **not** build: Prometheus, Grafana, Kafka,
Redis, operational telemetry export, or `pipeline_health`. The inspection
recorded why for each, and §18 records what the delivered system still cannot
claim.

Next: **Milestone 10 — Final Report and Deliverables.**
