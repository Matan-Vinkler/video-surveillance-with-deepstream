# Milestone 09.2 — Structured surveillance events

**Goal.** Turn the restricted-zone metadata the pipeline already computes into
events an external consumer can act on, without flooding that consumer with the
same fact once per frame.

**Status: complete. M9.2 PASSES.** `./scripts/verify_events.sh` exits 0 with all
twenty checks passing. One fresh container run of the existing M7 image produced
**exactly two events** for 288 frames:

```
{"event":"zone_enter","event_time_utc":"2026-08-13T16:12:11.783Z","frame_number":109,
 "stream_time_seconds":3.637,"zone":"RF","track_id":1,"class":"person","occupancy":1}
{"event":"zone_exit","event_time_utc":"2026-08-13T16:12:12.215Z","frame_number":183,
 "stream_time_seconds":6.106,"zone":"RF","track_id":1,"class":"person","occupancy":0,
 "frames_inside":75,"duration_seconds":2.502,"exit_reason":"left_zone"}
```

Those two lines are the whole Milestone 5 restricted-zone result — entry 109, 75
frames inside, exit 183 — expressed as events rather than as 288 per-frame dump
files, and cross-checked against an independent recomputation.

**MQTT is not implemented.** Delivery to an external broker is Milestone 9.3.

> *Pointer added 2026-08-15 (M10.2): Milestone 9.3 has since delivered it —
> [`milestone-09-mqtt.md`](milestone-09-mqtt.md). The statement above is
> retained as the state at the close of 9.2, and remains true of this document's
> scope: nothing verified here needs a broker or a network.*

---

## 1. Why not configuration alone

The obvious route is `nvmsgconv → nvmsgbroker`, driven by `[sink] type=6` in a
`deepstream-app` config. Both plugins are installed and load in the M7 image, and
the MQTT and Kafka protocol adapters resolve all their dependencies there. The
inspection tested that route and found it cannot carry what this project needs
([`milestone-09-inspection.md`](milestone-09-inspection.md) §2):

```
$ grep -rn "NVDS_USER_OBJ_META_NVDSANALYTICS|NvDsAnalyticsObjInfo|NvDsAnalyticsFrameMeta" \
       /opt/nvidia/deepstream/deepstream/sources/libs/nvmsgconv/
  (no matches)
```

`nvmsgconv` serialises `NvDsEventMsgMeta`, which the application must attach and
which `deepstream-app` never attaches. And the converter never reads
`nvdsanalytics` metadata at all — its `NvDsAnalyticsObject` is a static
descriptive block from the msgconv config file, naming which module produced the
data, not the ROI verdict.

> A configuration-only Milestone 9 could publish detections and track IDs, but
> not whether the person is inside the restricted zone — everything except the
> thing this system exists to detect.

## 2. Why `analytics_probe` is the event source

Because it is already the project's only route to that metadata. Since Milestone
5, `tools/analytics_probe.cpp` has been the one component that reads
`NVDS_USER_FRAME_META_NVDSANALYTICS` and `NVDS_USER_OBJ_META_NVDSANALYTICS`
(`analytics_probe.cpp:179-209`), for exactly the reason above.

A second component would have had to rebuild the same pipeline, read the same
metadata, and earn its own cross-check against `deepstream-app`. Extending the
existing reader adds one output to a component that is already trusted.

The honest caveat: **the probe was introduced as test equipment**, and Milestone
9 gives it a production-shaped role. It is still built from the same
configuration files as the application and still cross-checked; but that change
of role is recorded rather than glossed over.

## 3. Event model

Two event types. The choice is not stylistic — it is three orders of magnitude:

| Model | Volume for this clip | At 30 fps for 24 h |
|---|---|---|
| Per-frame inside-state | 75 messages | **~353 MB/day** |
| **Transitions only** | **2 messages** | a handful |

| Event | Emitted when |
|---|---|
| `zone_enter` | a `(track, roi)` pair that was outside is now inside |
| `zone_exit` | that pair is no longer inside — either it left, or the track ended |

Deliberately **not** implemented: `zone_inside` per frame and `person_detected`
per frame. Both restate a fact the consumer already knows, once per frame.

`pipeline_health` was considered and left out. It would have needed a timer
source and a second data path through the probe for a number (`**PERF`) that
`deepstream-app` already prints and that Milestone 8.2 already characterised.
The zone transition path is what M9.2 is accepted on, and keeping it the only
new path kept it verifiable.

### State is keyed by `(object_id, roi_label)`

Not by "the person" and not by a single ROI. Several tracked people and several
ROIs work without anything being hard-coded — an object inside two ROIs opens two
independent intervals. On `sample_walk.mov` this reduces to one pair, but the
structure does not assume that.

## 4. Transition semantics — which frame an event carries

This is the detail most likely to be got wrong later, so it is stated exactly.

```
frame 108   outside
frame 109   inside     <-- zone_enter.frame_number = 109
...
frame 183   inside     <-- zone_exit.frame_number  = 183
frame 184   outside        (this is where the transition is DETECTED)
```

**`zone_exit.frame_number` is the last frame of the completed interval, not the
first frame outside it.** The exit is *detected* at frame 184, but attributing
the event to 184 would make the interval arithmetic wrong:

```
183 - 109 + 1 = 75      correct, and the project's existing convention
184 - 109     = 75      right answer, wrong reason -- and breaks on a
                        single-frame interval, where it would give 1 instead
                        of the correct 1 only by luck
```

Every earlier milestone records this interval as **109 / 75 / 183**
([`milestone-05-restricted-zone.md`](milestone-05-restricted-zone.md),
[`milestone-07-triton.md`](milestone-07-triton.md),
[`milestone-08-redeployment.md`](milestone-08-redeployment.md)). The event stream
uses the same numbers, so the two descriptions of one fact cannot drift.

The implementation achieves this by refreshing `last_inside_frame` on every frame
an interval remains open, and closing the interval at that remembered frame
rather than at the frame where the change was noticed.

`occupancy` is the ROI's occupancy **at the moment the transition was detected** —
1 when the person entered, 0 once they had left. It therefore describes the state
after the transition, while `frame_number` describes the interval boundary. The
two fields deliberately answer different questions.

## 5. Timestamp semantics

The inspection required this be got right rather than assumed. Measured on the
first frame of the verified run:

```
events: first frame buf_pts=0 ns  ntp_timestamp=1786637462613026000
events: frame interval 0.033367 s (29.97 fps), derived from PTS
```

`ntp_timestamp` **is** populated — but `nvstreammux`'s `attach-sys-ts` defaults to
`true`, so on a file source it is the system time at which the buffer reached the
mux. `1786637462` seconds is 2026-08-13 16:11:02 UTC: the moment of *processing*,
not of capture. For a recorded clip replayed unpaced there is no true capture
wall-clock at all.

Calling that a capture timestamp would be false, so the schema separates the two
things it actually knows:

| Field | Meaning |
|---|---|
| `event_time_utc` | Host wall clock when **this system observed** the event. ISO 8601 UTC, milliseconds. |
| `stream_time_seconds` | Position **within the source stream**, from `buf_pts`. 0.000 is the first frame. |

For a live camera the two would nearly coincide; for a replayed file they do not,
and the schema says so rather than hiding it behind one ambiguous `timestamp`.

`duration_seconds` uses a frame interval **derived from the first two buffers'
PTS** — 0.033367 s, i.e. 29.97 fps — so no frame rate is hard-coded. It follows
the project's existing convention, `frames_inside / fps`
(`analyze_zone.py:218`), giving 75 × 0.033367 = **2.502 s**. If fewer than two
frames are seen the field is omitted rather than guessed.

## 6. JSONL schema

One event per line, flushed per event so a consumer tailing the file — or a run
that is interrupted — loses nothing.

| Field | Type | Present on | Meaning |
|---|---|---|---|
| `event` | string | all | `zone_enter` or `zone_exit` |
| `event_time_utc` | string | all | Host observation time, ISO 8601 UTC ms |
| `frame_number` | int | all | Interval boundary frame (§4) |
| `stream_time_seconds` | float | all | Position in the source stream |
| `zone` | string | all | ROI label from the analytics config |
| `track_id` | int | all | Tracker `object_id` |
| `class` | string | all | Detector label, e.g. `person` |
| `occupancy` | int | all | ROI occupancy after the transition |
| `frames_inside` | int | `zone_exit` | Inclusive interval length |
| `duration_seconds` | float | `zone_exit` | `frames_inside` × PTS-derived frame interval |
| `exit_reason` | string | `zone_exit` | `left_zone`, `track_ended` or `stream_ended` |

**`zone` is the real ROI label, `RF`**, taken from `roi-RF=` in
`configs/config_nvdsanalytics_restricted_zone.txt`. A friendlier
`"restricted_zone"` was considered and rejected: it would have been a second name
for a thing that already has one, and it would not generalise to a config with
several ROIs.

## 7. Container integration

A new `--events` mode in `run_container.sh`, kept separate from `--zone` because
`--zone` is a completed-milestone path that `verify_zone.sh` and
`verify_triton.sh` assert against.

```
docker run --rm --runtime nvidia --network none \
    -v .../models/engines:/app/models/engines:ro \
    -v .../models/triton_model_repo:/app/models/triton_model_repo:ro \
    -v .../<fp16 engine>:/app/models/triton_model_repo/trafficcamnet/1/model.plan:ro \
    -v .../build/analytics_probe:/app/build/analytics_probe:ro     <-- host build
    -v .../models/events:/app/models/events \
    video-surveillance-deepstream:m7-triton \
    /app/build/analytics_probe ... --events-output /app/models/events/events.jsonl
```

Two properties worth stating:

- **`--network none` is retained.** File event generation needs no network, so
  the Milestone 7 isolation claim is not weakened by M9.2 at all. Milestone 9.3
  will need network access and will have to justify it in its own mode.
- **No image was rebuilt.** The extended probe is compiled on the host by
  `make -C tools` and bind-mounted over the copy baked into the image — the same
  tactic that supplies the FP16 engine. Host and container both run DeepStream
  9.1.0 GCID 46117240, and the binary's `RUNPATH` already points at
  `/opt/nvidia/deepstream/deepstream/lib`, which exists in both. Rebuilding the
  42.5 GB image to change one binary would have been absurd on 25 GB of free
  disk.

## 8. Verification method

`scripts/verify_events.sh`, twenty checks in six groups, failing closed — no
`|| true` anywhere.

| Check | Asserts |
|---|---|
| 1 | Fresh `docker run --rm` exits 0, all 288 frames reach `nvdsanalytics`, no element error |
| 2 | Event file exists, is non-empty, and **every line parses with Python's `json`** — not a regex |
| 3 | Schema: required keys present with correct types; `event_time_utc` is really ISO 8601 UTC ms; booleans rejected where ints are required |
| 4 | Exactly one `zone_enter` and one `zone_exit`; total event count is O(transitions); no `zone_inside`/`person_detected`; frames, zone, class, track id, exit reason and duration all correct |
| 5 | **Independent cross-check** against `analyze_zone.py` |
| 6 | Hygiene: no container, no orphan process, bounded event file, no output video |

### Why check 5 is the important one

The event stream and `analyze_zone.py` derive the same interval by two
independent routes, and **neither parses the other's output**:

| | Route |
|---|---|
| Event stream | C++ edge detection on `(object_id, roi_label)`, live, during the run |
| `analyze_zone.py` | Python, offline, reading the per-frame dump files afterwards |

If the C++ transition logic were wrong — off by one frame, mishandling the close
frame, missing a re-entry — the Python recomputation would disagree and the check
fails. Without it, "the file says 109" would only prove the file says 109.

## 9. Observed result

```
== CHECK 1: a fresh container run completes ==
  exit status                      0
  PASS  analytics_probe exited 0
  PASS  all 288 frames reached nvdsanalytics
  PASS  no element errors in the run log
== CHECK 2: the event file exists and is valid JSON Lines ==
  event file                       409 bytes, 2 lines
  PASS  every line parses as JSON
== CHECK 4: exactly the expected transitions, and no per-frame spam ==
  total events                     2
  PASS  exactly one zone_enter and one zone_exit
  PASS  event count 2 is O(transitions), not O(frames) -- no per-frame spam
  enter frame                      109 (expected 109)
  exit frame                       183 (expected 183)
  frames inside                    75 (expected 75)
  zone / class                     RF / person
  exit reason                      left_zone
  PASS  enter and exit carry the same track_id (1)
  PASS  duration_seconds 2.5020 within ±0.05 of 2.5025
== CHECK 5: independent cross-check against analyze_zone.py ==
  analyze_zone entry               109
  analyze_zone exit                183
  analyze_zone frames inside       75
  analyze_zone runs                1
  PASS  the event stream and analyze_zone.py agree exactly on entry, exit and duration
```

Two events, 409 bytes, for 288 frames.

## 10. Existing pipeline behaviour is unchanged

The event stream is **additive and off by default**: without `--events-output`,
not one byte of the probe's previous behaviour changes. That is what keeps the
completed milestones valid, and it was verified rather than asserted — both
statements of record were re-run against the extended probe:

| Verification | Result |
|---|---|
| `./scripts/verify_zone.sh` (M5) | **exit 0** — 288 frames, entry 109, exit 183, 75 frames, 1 run, 100.00% agreement |
| `./scripts/verify_triton.sh` (M7) | **exit 0** — 33 PASS, 0 FAIL, detection structure identical, zone 109..183 |

`verify_zone.sh` executes the probe natively on the host, so it ran the *new*
binary — which is the strongest available evidence that the extension is
backward compatible.

## 11. Disk and resource impact

| | |
|---|---|
| Event file | **409 bytes** for a 288-frame run |
| Docker images | unchanged — none built, pulled or pruned |
| Containers after the run | 0 |
| Output video | none |
| New per-frame trees | none — the probe's existing zone dumps are rewritten in place |

**The file is truncated per invocation, not appended.** Each run produces the
events of that run and nothing else. Appending would blend runs into a file whose
contents depend on how many times it had been run before — unverifiable, and
unbounded. That is bounding by design, which is preferable to a rotation
subsystem nobody asked for. `models/events/` is git-ignored; the representative
lines quoted at the top of this document are the committed record.

## 12. The termination-while-inside path

Implemented, and **NOT EXERCISED** by this clip.

If a track disappears while an interval is open, the interval is closed at its
last inside frame with `exit_reason: "track_ended"`. If the stream ends with an
interval still open, it is closed with `exit_reason: "stream_ended"`. Without
this, a person who left the frame while inside the zone would never have their
interval closed at all.

On `sample_walk.mov` neither path runs: the walker leaves the ROI at frame 183
and stays tracked for 90 more frames, so the observed exit is
`exit_reason: "left_zone"` — which the verification asserts explicitly, precisely
so that a future change silently taking a different path would be caught.

> No verification claim is made for `track_ended` or `stream_ended`. They are
> implemented and unexercised, in the same sense Milestone 5 recorded gap
> bridging and occlusion recovery as NOT EXERCISED.

## 13. Limitations

1. **A one-frame tracker dropout inside the ROI would read as a termination.**
   Absence from `obj_meta_list` is treated as the track ending immediately, so a
   momentary drop would produce `track_ended` followed by a fresh `zone_enter`.
   A grace period would fix it, at the cost of a tunable this clip cannot
   justify. Not observed here — the known probation-window drops (frames 44-48,
   50-54) fall far outside the ROI interval.
2. **`event_time_utc` is observation time, not capture time** (§5). On a replayed
   file, and especially an unpaced one, it reflects when the pipeline processed
   the frame.
3. **One clip, one ROI, one person.** The implementation is keyed to support
   several of each, but only the single-person single-ROI case has been run.
4. **No delivery guarantee.** The file is flushed per event, but nothing
   acknowledges receipt. That is the point of Milestone 9.3.
5. **The probe is test equipment doing a production job** (§2).
6. **No `pipeline_health` event**, so a silent stream is still ambiguous between
   "nothing happened" and "the pipeline stopped" (§3).

## 14. M9.2 verdict

| Criterion | Result |
|---|---|
| Fresh `docker run --rm`, existing image, nothing built or pulled | **PASS** |
| Events as JSON Lines with the required fields | **PASS** |
| Exactly `zone_enter` 109 and `zone_exit` 183, one interval of 75 | **PASS** |
| Transitions only, no per-frame spam | **PASS** — 2 events for 288 frames |
| Cross-checked against an independent recomputation | **PASS** |
| Existing pipeline behaviour unchanged | **PASS** — `verify_zone.sh` and `verify_triton.sh` both exit 0 |
| Clean shutdown, no container, no orphan | **PASS** |
| Bounded disk | **PASS** — 409 bytes |
| `--network none` retained | **PASS** |

> **M9.2: PASS.** Milestone 9 remains open.

> **Amendment — 2026-08-15, Milestone 10.3.** One line of
> `scripts/verify_events.sh` was changed, and it is recorded here because this
> document is the script's statement of record. Its *"no output video produced"*
> hygiene check searched the whole repository except `media/`, which at the time
> was the only legitimate home for a video file. Milestone 10.2 added `demo/` for
> the capstone demo capture, so the check began failing on the deliverable it was
> never meant to police — `verify_events.sh` exited **1** with all twenty checks
> otherwise green. `demo/` is now excluded alongside `media/`.
>
> **No criterion was loosened.** The property under test — that the *event
> pipeline* writes no video — is unchanged and still enforced over `models/`,
> which is where `deepstream-app` and `analytics_probe` write; a control test
> confirmed a file planted under `models/zone/` is still caught. The M9.2 result
> above stands: re-run after the amendment, `verify_events.sh` exits **0** with
> zone_enter 109, zone_exit 183, 75 frames inside, 2 events for 288 frames.

## 15. What remains for M9.3

Deliver these events to an external consumer over MQTT, and prove receipt.

The inspection established the ground: `libnvds_mqtt_proto.so` resolves in the
container, `libmosquitto.so.1` is present in both host and image, and a Mosquitto
broker is already installed, enabled and running — but on **loopback only**, so a
bridged container cannot reach it and `--network host` is the only option that
needs neither `sudo` nor a broker configuration change
([`milestone-09-inspection.md`](milestone-09-inspection.md) §3).

That means M9.3 must introduce network access to a container in a project whose
Milestone 7 evidence rests on `--network none`. The approach already agreed: a
**separate mode**, so every existing mode keeps its isolation and the new access
is explicit, scoped and justified — never a silent relaxation of a completed
milestone's claim.
