# Inspection report — monitoring and logging milestone

Read-only inspection of what the deployed application already exposes, and of
what DeepStream's messaging stack can actually carry, carried out before any
Milestone 9 work. Every claim is backed by command output. No file was created
or modified to produce it, no image was built, pulled or removed, and no package
was installed.

Dated record of the inspection phase: **2026-08-13**, branch `main`, HEAD
`5c1b708`, working tree clean. Corrections discovered during implementation are
appended as an addendum; the body is not rewritten.

The capstone requirement for this milestone is *"DeepStream analytics metadata,
logging to file or Kafka/MQTT sink, optionally Prometheus and Grafana."* The
purpose of this inspection was to establish the **smallest useful** M9, and in
particular whether it could be done by configuration alone.

---

## 1. What the pipeline already exposes

The distinction that matters is not "does DeepStream have this metadata" but
"can this project export it".

| Information | In DeepStream | **Exportable today** |
|---|---|---|
| Detector objects (class, bbox, confidence) | Yes | **Yes** — `gie-kitti-output-dir` |
| Tracker `object_id`, tracker bbox | Yes | **Yes** — `kitti-track-output-dir` |
| Pipeline FPS | Yes | **Yes** — `**PERF` on stdout, captured by M8.2 |
| Terminated / shadow tracks | Yes | Yes (dirs configured; empty on this clip) |
| **ROI occupancy** (`NvDsAnalyticsFrameMeta`) | Yes | **Only via `analytics_probe`** |
| **Per-object ROI status** (`NvDsAnalyticsObjInfo`) | Yes | **Only via `analytics_probe`** |
| Wall-clock timestamp | Available | **No — nothing captured it** |
| Zone entry/exit *events* | Not a DeepStream concept | Derived offline by `analyze_zone.py` |

This restates the Milestone 5 finding rather than discovering a new one:
**`deepstream-app` can run `nvdsanalytics` but cannot report it.** Every export
path it owns carries detections and tracks and never the ROI verdict.

## 2. DeepStream messaging support

Present and dependency-resolved on the host **and inside the M7 image**, with no
rebuild required:

```
nvmsgconv      PRESENT        nvmsgbroker    PRESENT
libnvds_mqtt_proto.so    all dependencies resolved   (links libmosquitto.so.1)
libnvds_kafka_proto.so   all dependencies resolved   (links librdkafka.so.1)
libnvds_amqp_proto.so / azure / azure_edge           resolved
libnvds_redis_proto.so   libhiredis.so.1.1.0 => not found     [UNRESOLVED]
libmosquitto.so.1, librdkafka.so.1   present in the container
```

`deepstream-app` supports `[sink] type=6` (`NV_DS_SINK_MSG_CONV_BROKER`), which
builds `nvmsgconv → nvmsgbroker` from configuration alone
(`deepstream_app.c:1576`, `deepstream_sink_bin.c:208`).

### The blocker, and it is decisive

`nvmsgconv` serialises `NvDsEventMsgMeta`, which the **application** must attach.
`deepstream-app` never attaches it — the canonical example that does is
`deepstream-test4` (`deepstream_test4_app.c:323`). More importantly:

```
$ grep -rn "NVDS_USER_OBJ_META_NVDSANALYTICS|NvDsAnalyticsObjInfo|NvDsAnalyticsFrameMeta" \
       /opt/nvidia/deepstream/deepstream/sources/libs/nvmsgconv/
  (no matches)

$ strings libnvds_msgconv.so.1.0.0 | grep -iE 'roiStatus|objInROI'
  (none)
```

The schema's `NvDsAnalyticsObject` is a false friend: it is a static descriptive
block read from the msgconv **config file** — `"analyticsModule": {id,
description, source, version}` (`dsmeta_payload.cpp:190-225`) — describing which
module produced the data. It is not the ROI verdict.

> **`nvmsgconv` cannot carry `nvdsanalytics` ROI state.** A configuration-only
> Milestone 9 could publish detections and track IDs but not whether the person
> is in the restricted zone — that is, everything except the thing this system
> exists to detect.

The textbook data flow is therefore **not applicable** here:

```
textbook:    NvDs metadata → nvmsgconv → payload → nvmsgbroker → MQTT   [ROI lost]
applicable:  analytics meta → analytics_probe → event → JSONL / MQTT    [ROI kept]
```

## 3. MQTT state

A broker is **already installed, enabled and running**, so Milestone 9 need not
install anything:

```
mosquitto 2.0.18-1build3     active (running) since 2026-08-13 16:02:56
mosquitto-clients            mosquitto_pub, mosquitto_sub in PATH
LISTEN  127.0.0.1:1883  and  [::1]:1883          <-- loopback only
round trip: mosquitto_pub -> mosquitto_sub delivered the test payload
```

No `conf.d` overrides, so this is the mosquitto 2.x default: local listener,
anonymous accepted locally (established empirically — the round trip used no
credentials).

Container reachability, **tested rather than assumed**:

| Network mode | `127.0.0.1:1883` | `172.17.0.1:1883` |
|---|---|---|
| default bridge | unreachable | **unreachable** |
| `--network host` | **REACHABLE** | — |
| `--network none` | unreachable (by design) | — |

Bridge fails even via the docker0 gateway, because the broker binds loopback
only. Widening the listener would need `sudo`, which this project does not have.
**`--network host` is the only option that needs neither `sudo` nor a change to
the broker.**

### Not weakening the Milestone 7 isolation claim

M7 used `--network none` as **evidence**, not caution: it is what proves Triton
runs in-process with no socket. That claim must survive. The resolution is that
these are different **modes of the same artifact** — the existing modes keep
`--network none` untouched, and any MQTT publishing mode opts into
`--network host` explicitly. The isolation claim stays true of the mode that
asserts it, and the network access is scoped and documented rather than quietly
relaxed.

## 4. File logging

`analytics_probe` already holds every field an event needs: frame number,
`object_id`, class label, ROI label, per-object `roiStatus`, per-ROI occupancy.
The only thing missing is a **timestamp**.

Transition logic already exists and is already proven: `analyze_zone.py:150`
`runs()` computes maximal consecutive inside-stretches, which is what produced
the verified `entry 109 / 75 frames / exit 183`.

| | JSONL file | MQTT |
|---|---|---|
| Infrastructure | none | broker (already running) |
| Network | none — works under `--network none` | needs `--network host` |
| Verification | diff the file, deterministic | needs a live subscriber |
| Proves | events are correct | events leave the box |

They answer different questions, which is why they became different checkpoints.

## 5. Operational telemetry

M8.2 already measured FPS, `tegrastats`, RSS, thermals and power. Re-plumbing
that as a continuous service would be building an observability product and
would duplicate documented work. FPS alone is nearly free (already on stdout)
and is the one number that says the pipeline is alive.

**Prometheus/Grafana are not recommended**: an exporter, a Prometheus server with
scrape config and retention, and a provisioned Grafana, on a board with 25 GB
free and no `sudo` for services. The capstone marks them optional.

## 6. Event model

Per-frame state versus transitions is not a style question, it is three orders
of magnitude:

```
per-frame inside-state at 30 fps   ~353 MB/day of messages
transition events, same clip       2 events (~409 bytes)
```

Proposed: `zone_enter`, `zone_exit`, and optionally `pipeline_health`.
Rejected: `zone_inside` and `person_detected` per frame.

## 7. Decisions taken before implementation

| Decision | Rationale |
|---|---|
| Extend `analytics_probe`, do not write a second component | It is already the project's only reader of ROI metadata, already builds on the host, already cross-checked against `deepstream-app` |
| Configuration-only `nvmsgconv` rejected | §2 — it cannot carry the ROI verdict |
| Transition events, never per-frame state | §6 |
| File first, MQTT second, as separate checkpoints | Separates "are the events right" from "does delivery work", so an MQTT fault cannot masquerade as an event-model fault |
| MQTT over Kafka | The broker is already installed, running and round-trip verified; Kafka would need a broker plus Zookeeper/KRaft |
| Redis rejected | `libhiredis.so.1.1.0` is missing, so the adapter would not load |
| Host-built probe bind-mounted into the M7 image | Host and container both run DeepStream 9.1.0 GCID 46117240, and the binary's `RUNPATH` already points at `/opt/nvidia/deepstream/deepstream/lib`. Zero image space, no rebuild |
| Prometheus/Grafana deferred | §5 |

## 8. Proposed checkpoints

| # | Checkpoint | Question it answers |
|---|---|---|
| 9.1 | Observability and messaging inspection | What exists, and can configuration alone do it? |
| 9.2 | Structured surveillance events to file | Can we emit correct, non-spammy zone events? |
| 9.3 | MQTT delivery to an external consumer | Do the events actually leave the box? |

## 9. Risks identified before starting

1. **Breaking a completed milestone.** `verify_zone.sh` and `verify_triton.sh`
   both depend on the probe's existing per-frame output. Mitigated by making the
   event stream strictly additive and off by default.
2. **`--network host` weakening the M7 claim.** Mitigated by §3: a separate mode,
   never a change to the existing ones.
3. **Timestamp semantics.** `nvstreammux attach-sys-ts` defaults to TRUE, so on a
   file source `ntp_timestamp` is processing time, not capture time. Reporting it
   as a capture timestamp would be false.
4. **Unbounded log growth.** A per-frame model would produce hundreds of MB per
   day. Mitigated by the transition model and by truncating per run.
5. **The probe is test equipment, not the application.** Milestone 9 gives it a
   production-shaped role. Worth stating rather than quietly reclassifying.
