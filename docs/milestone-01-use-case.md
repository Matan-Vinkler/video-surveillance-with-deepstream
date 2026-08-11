# Milestone 01 — Defining the use case

**Goal.** Choose the surveillance scenario the whole project will be built
around, state the behaviour expected of it, and establish which AI task that
behaviour requires. No video source, no model, no pipeline — those are
Milestones 2, 3 and 5.

**Status: complete.** Selected use case: **person detection in a restricted
zone**. Required AI task: **object detection**, because the decision the system
has to make is spatial.

> **Written retrospectively, from a conversation rather than from artifacts.**
> Milestone 1 predates this repository. It produced no code and no command
> output, and it was worked through in a ChatGPT session before any of this was
> committed. This document was reconstructed on **12 August 2026** from that
> session's record, so its evidentiary basis is recall of a discussion rather
> than captured output — weaker than every other document in `docs/`.

**Approximate date of the original work:** 4–5 August 2026.

---

## 1. What the milestone had to decide

The capstone brief states Milestone 1 in full as:

> "Step 1: Define Use Case"

offering a choice between:

> "Person detection in restricted zones"
> "Vehicle counting in traffic lanes"
> "Face detection for entry access"

and requiring only:

> "Document the use case and its expected outcome."

That is the entire explicit requirement. The milestone was kept deliberately
close to that wording rather than expanded into requirements engineering the
brief did not ask for — a scoping preference established the day before the work
itself.

Everything else was assigned elsewhere by the brief's own structure: video
source to Milestone 2, model choice to Milestone 3, TensorRT to Milestone 4,
the DeepStream pipeline and tracker to Milestone 5, containerisation to
Milestone 6, Triton to Milestone 7.

## 2. The use case as chosen

> **Person detection in a restricted zone.**

The system's purpose is to detect a person and determine whether that person is
within a spatial region designated as restricted. The class of interest is
therefore `person`, and the event of interest is *not* "a person is somewhere in
the frame" but "a detected person is associated with the restricted area".

That distinction is the whole milestone. It is what makes the frame-level
question insufficient and forces a spatial one, and §5 follows directly from it.

## 3. Alternatives considered

The brief supplied the three candidates quoted in §1. Pose estimation came up
separately, through a "dance tutor" style example, while discussing how
different AI tasks map onto different applications (see §5).

The argument for the choice was that the restricted-zone scenario maps cleanly
onto object detection, onto the `person` class, and onto the tracking and
region-of-interest logic the later milestones would introduce anyway. It was
chosen because it fits the rest of the capstone.

## 4. Expected system behaviour

The expected outcome, as stated at the time:

A video stream is processed, people in it are detected, bounding boxes are
produced and displayed, and the detection metadata is available to the
application.

The conceptual flow:

```
video input → detect `person` objects → obtain their locations
            → use those locations for restricted-zone logic
```

Two requirements come out of this, and both matter:

1. **Identify** the relevant class — `person`.
2. **Localise** that person within the image.

## 5. Why object detection, and not image classification

This was the milestone's central learning point.

Image classification answers a question about the frame as a whole:

```
frame → "person"
```

That is enough to assert *that* a person is present. It is not enough here,
because the application's actual question is about **where** the person is. A
classifier cannot answer "is this person inside the restricted region?", and no
amount of confidence in its output changes that — the information required is
simply not in the output.

Object detection returns both parts:

```
frame → "person" + bounding box
```

The bounding box is what makes the zone test possible at all. The requirement
was recorded as needing both the person *class* and the person's *location*,
which classification does not provide. The spatial nature of the decision is the
reason for the task choice — everything else about detection is secondary.

Pose estimation was discussed, via the dance-tutor example, as an illustration of
how a different question demands a different task — joint and body-pose analysis
rather than object localisation. It was not selected because this application
needs to locate people, not analyse their posture.

### The ordering principle

Underneath the specific choice sat a methodological point that outlasted the
milestone:

> use case → AI task → model → pipeline → application logic

The use case is defined **first**, and the technique follows from it — rather
than starting from an interesting model and inventing a problem it happens to
solve. For this project that ordering runs:

restricted-zone surveillance → spatial localisation is required → object
detection is the appropriate task → later, choose a detector supporting
`person` → later still, add tracking and zone logic.

This was not a deliverable in the brief, but it is the reason Milestones 3 and 5
had a criterion to be judged against when they arrived.

## 6. Requirements inherited from the brief

Two project-level constraints were in force from the start:

- **Real-time operation.** The capstone objective calls for "an AI-powered
  real-time video analytics pipeline".
- **Target hardware.** The brief permits "Jetson or GPU-enabled VM"; the work
  proceeded on a Jetson Orin Nano.

## 7. What the use case implies downstream

The chain established here:

```
restricted-zone person surveillance
  → requires object detection
  → model must support the `person` class
  → detections carry spatial coordinates
  → tracking can preserve identity across frames
  → zone/ROI analytics can decide whether a tracked person is inside the region
```

The discussion connected the scenario to object detection, the `person` class,
later tracking, and ROI logic. It also lined up with the later DeepStream
milestone, whose brief named `nvinfer`, `nvtracker` and an OSD/video sink
directly.

**What this does *not* license.** TrafficCamNet, NvSORT, `nvdsanalytics`, the FP16
engine, in-process Triton, and the specific zone coordinates were **not**
Milestone 1 decisions and must not be read back into it. Milestone 1 established
only that the use case creates a need for person detection with localisation,
followed later by tracking and zone logic. Which components satisfy that need was
decided, with evidence, in Milestones 3 through 7.

## 8. What Milestone 1 deferred

Design questions knowingly left to the milestone that owned them:

| Question | Settled in |
|---|---|
| Video or camera source | Milestone 2 |
| Model architecture | Milestone 3 |
| Confidence threshold | Milestone 5 |
| Tracking algorithm | Milestone 5 |
| Restricted-zone geometry | Milestone 5, checkpoint 3 |
| ROI implementation | Milestone 5, checkpoint 3 |

## 9. Completion criteria

| Criterion | Status |
|---|---|
| Surveillance use case selected | Done — person detection in a restricted zone |
| Expected outcome stated | Done — §4 |
| Required AI task established | Done — object detection, §5 |
| Classification vs. detection understood | Done — §5, on the grounds that the decision is spatial |
| Use case documented | Done, but **retrospectively** — this file, written 12 August 2026 |
| No implementation work | Done — the brief required no artifact beyond the documented use case |

The brief's requirement — document the use case and its expected outcome — was
met.
