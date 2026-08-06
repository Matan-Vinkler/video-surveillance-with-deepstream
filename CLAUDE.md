# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 1. Purpose and document map

This is an **operating agreement**, not a project specification. It describes
*how* to work in this repository. It does not describe what the project builds,
which milestone is active, or how any pipeline works.

It is a stable engineering contract. Update it only when the repository-wide
development process changes — workflow, verification policy, coding
conventions, repository conventions. **Do not update it because a milestone was
completed.**

Each document has exactly one responsibility. Do not duplicate between them:

| Document | Owns |
|---|---|
| `README.md` | Project overview, requirements, quick start, usage |
| `PLAN.md` | Roadmap, milestone status, engineering decisions, learning progress, future work |
| `CLAUDE.md` | AI working agreement, workflow, repository conventions, verification requirements |
| `docs/` | Architecture, milestone documentation, design notes, reports |

If information belongs in two places, put it in one and link to it.

## 2. Project context

A staged capstone project on an NVIDIA Jetson. Work proceeds one milestone at a
time, and each milestone is deliberately narrow. **`PLAN.md` is the source of
truth for what is done, what is active, and what is out of scope.** Read it
before proposing work.

The user is building this to understand the system, not only to get working
code. Explanation is part of the deliverable, not an optional extra.

## 3. Workflow

Follow this loop:

1. **Inspect** — gather evidence from the actual environment first
2. **Explain** — report what was found, with command output
3. **Propose** — a minimal plan, with alternatives and trade-offs
4. **Wait for approval** — do not modify anything before this
5. **Implement** — the approved scope, nothing more
6. **Verify** — run it, capture real output
7. **Explain the verification** — show the evidence, state what remains unproven

The full loop is for substantive work. A typo fix, a one-line doc correction, or
a read-only question does not need a formal proposal — use judgement, and when
in doubt, propose. Never skip steps 6 and 7.

## 4. What requires approval

**Ask first:**

- Creating, modifying, or deleting any file
- Installing, upgrading, or downloading anything
- Any use of `sudo`, or changes to system software or configuration
- Long-lived or unbounded pipelines
- Anything that opens a window on the user's physical display
- `git commit`, `git push`, or any history rewrite
- Work beyond the current milestone's scope
- Changing anything in a completed milestone

**Proceed freely:**

- Read-only inspection: reading files, `gst-inspect`, `gst-discoverer`, `ps`, `ls`
- Running the repository's own bounded verification scripts
- Writing scratch files to the session scratchpad (never into the project)

## 5. Engineering principles

- **Incremental development.** One milestone at a time; small, reviewable changes.
- **Evidence before conclusions.** Measure it; do not reason from what "should" happen.
- **Explicit over automatic.** Where a construct exists to be understood, spell it
  out — an explicit GStreamer pipeline over `playbin`, named elements over
  auto-plugging.
- **Minimal implementations.** Solve the stated problem. Do not add configuration,
  layers, or generality that was not requested.
- **No silent assumptions.** State assumptions explicitly, or verify them.
- **No claiming success without verification.** Show the output or do not make the claim.
- **Preserve reproducibility.** Anything demonstrated must be re-runnable from the
  repository by someone else.
- **Avoid unnecessary abstraction.** Prefer duplication you can read over indirection
  you must trace. Factor out only what is genuinely shared.
- **Never modify system software without explicit approval.**

## 6. Verification standard

A change is verified when:

- It was actually executed and **real captured output** is shown — not described,
  not predicted
- **Exit codes are checked**, including through pipes (`PIPESTATUS`)
- **Negative cases** are exercised: bad input, missing resources, conflicting options
- It **re-runs from a clean environment**, not just the current shell
- Failures are **reported as failures**, with the output that shows them

Never use `|| true`, or any construct that hides a non-zero exit. If something
could not be verified, say so explicitly and say why — an honest gap is worth
more than an unearned claim.

## 7. Documentation rules

- Update documentation **in the same change** as the behaviour it describes.
- Documentation quotes **real captured output**. If behaviour changes, re-run and
  repaste — never hand-edit recorded output.
- Route each change to the owning document (§1). Link rather than duplicate.
- **All milestone documentation lives in `docs/`**, named `milestone-NN-<topic>.md`
  with a zero-padded number. A milestone typically produces two files:
  `milestone-NN-inspection.md` (the dated inspection-phase record) and
  `milestone-NN-<subject>.md` (the implementation and verification record).
  Never place milestone documents at the repository root — only `README.md`,
  `PLAN.md` and `CLAUDE.md` belong there.
- When moving a document, use `git mv` to preserve history, and fix relative links
  both **to** it and **inside** it.
- Record **why**, not just what. A decision without its rationale is not documented.
- When a limitation is discovered, document it as a limitation. Do not quietly
  work around it.

## 8. Completed milestones are frozen

Treat completed milestones as finished work:

- Do not refactor, restructure, or "improve" them unprompted
- Do not retro-fit patterns introduced by later milestones
- Do not re-run or re-verify them unless asked, or unless a change affects them
- Changing one requires explicit approval **and** an update to its documentation

Their inspection reports are dated records of what was true at the time. Do not
rewrite history in them; append corrections instead.

## 9. Avoid

- Scope creep into future milestones — especially adding AI inference, tracking, or
  deployment machinery before its milestone is open
- Frameworks, dependencies, or abstractions the user did not ask for
- `playbin` or auto-plugging where an explicit pipeline is the teaching point
- Hiding, smoothing over, or narrating around a failure
- Committing large binaries; prefer referencing files already on the target machine
- Hard-coding versions or paths that can be discovered at run time

## 10. Standing environment facts

- Development happens directly on the Jetson. No `sudo` is available or permitted.
- Shells here run on a tty with no `DISPLAY`. Visible playback opens a window on the
  user's physically attached monitor — **ask before running anything that does**.
  Headless equivalents exist for verification.
- Git identity is not configured globally; commits pass it inline via `git -c`.
- Large media is never committed. Sample video is read from its install path on
  the target machine.
