# Inspection report — edge deployment milestone

Read-only inspection of the Jetson deployment environment and of the existing
Milestone 7 artifact, carried out before any Milestone 8 work. Every claim is
backed by command output. No file was created or modified to produce it, no
image was built, pulled or removed, no package was installed, no container was
started, and neither the power mode nor the clocks were changed.

Dated record of the inspection phase: **2026-08-12**, branch `main`, HEAD
`b79a7da`, working tree clean. Corrections discovered during implementation are
appended as an addendum; the body is not rewritten.

The capstone requirement for this milestone is *"Edge: run on Jetson
Orin/Xavier with `deepstream-app`."* That literal requirement is **already
satisfied** by Milestones 6 and 7 — the application has only ever run on this
Jetson. The purpose of this inspection is therefore to establish what edge
deployment has *not* yet proven, so that Milestone 8 measures something real
rather than re-running Milestone 7.

---

## 1. Environment findings

| Item | Value | Evidence |
|---|---|---|
| Board | NVIDIA Jetson Orin Nano Engineering Reference Developer Kit **Super** | `/proc/device-tree/model` |
| L4T | **R39 rev 2.0**, GCID 45755727, dated 2026-06-01 | `/etc/nv_tegra_release` |
| JetPack | **7.2-b187** | `dpkg -l nvidia-jetpack` |
| OS | Ubuntu 24.04.4 LTS | `/etc/os-release` |
| Kernel | `6.8.12-1021-tegra` aarch64, SMP PREEMPT | `uname -a` |
| DeepStream (host) | **9.1.0**, GCID 46117240 | `/opt/nvidia/deepstream/deepstream/version` |
| CUDA | 13.2.1 (`cuda-toolkit-13-2`) | `dpkg -l` |
| TensorRT | **10.16.2.10-1+cuda13.2** | `dpkg -l` |
| Docker | Engine **29.7.2** client and server, containerd v2.3.3 | `docker version` |
| Storage driver | **`overlayfs`**, Docker root `/var/lib/docker` | `docker info` |
| Container runtimes | `io.containerd.runc.v2`, **`nvidia`**, `runc` — default is **`nvidia`** | `docker info` |
| NVIDIA container stack | `nvidia-container-toolkit 1.19.1-1`, `libnvidia-container1 1.19.1-1` | `dpkg -l` |
| CPU | 6 × Cortex-A78AE, 115.2–1728.0 MHz | `lscpu`, `nproc` |
| RAM | 7.3 GiB unified (7486 MB per `tegrastats`), 4.8 GiB available | `free -h` |
| Swap | **none configured (0 B)** | `swapon --show` |
| Power mode | `MAXN_SUPER` (mode 2) — **not changed** | `nvpmodel -q` |
| GPU | `17000000.gpu`, devfreq 306–1020 MHz, governor `nvhost_podgov`, idling at 306 MHz | devfreq sysfs |
| Idle thermals | `tj` 47 °C, `gpu` 47 °C, `cpu` 46 °C, `soc0-2` 45–46 °C | thermal-zone sysfs |
| Idle power | `VDD_IN` ≈ 3.85 W, `VDD_CPU_GPU_CV` ≈ 0.6 W, `VDD_SOC` ≈ 1.17 W | `tegrastats` |
| Sample clip | `sample_walk.mov`, 51,436,729 B, read from the DeepStream install path | `ls -l` |

Four findings shape the plan, three of them carried forward unchanged from
[`milestone-04-inspection.md`](milestone-04-inspection.md):

- **The GPU clock still cannot be locked.** `jetson_clocks` requires root and no
  `sudo` is available here. DVFS will move both CPU and GPU across their full
  range during any measurement. This cannot be eliminated — only measured and
  accounted for, exactly as Milestone 4 did.
- **There is still no swap.** A memory leak during a long run ends in a hard OOM
  kill, not a slowdown. Any sustained run must be bounded and must watch RAM.
- **`nvidia-smi` remains useless on Jetson** (`Not Supported` / `N/A`), and GPU
  memory is unified with system RAM. `tegrastats` is the only usable instrument,
  and it runs as a normal user.
- **Free disk has fallen from 70 GB to 29 GB** since Milestone 4. Storage is now
  the binding constraint on this milestone; §2 treats it as a first-class
  engineering fact rather than a footnote.

## 2. Disk and Docker state

This is the constraint that governs the whole milestone, so it is recorded as
captured output rather than summarised.

```
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/mmcblk0p1  116G   81G   29G  74% /

$ docker system df
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          2         0         42.51GB   14.08GB (33%)
Containers      0         0         0B        0B
Local Volumes   0         0         0B        0B
Build Cache     81        0         24.49GB   397.3kB

$ docker system df -v            (images section)
REPOSITORY                     TAG                   IMAGE ID      SIZE     SHARED    UNIQUE    CONTAINERS
video-surveillance-deepstream  m7-triton             6e53ea730fc6  42.5GB   28.44GB   14.08GB   0
nvcr.io/nvidia/deepstream      9.1-triton-multiarch  fd31f5b44aba  28.4GB   28.44GB   78.23kB   0

$ docker ps -a
CONTAINER ID   IMAGE     STATUS    SIZE      NAMES
                                                        (no rows)

$ docker volume ls
DRIVER    VOLUME NAME
                                                        (no rows)
```

Read out of that:

- **No containers exist at all**, running or stopped. Writable-layer usage is
  measured at **0 B** — so no stopped container is consuming space, and none can
  be reclaimed because none exists.
- **No volumes.** There is no persistent Docker state of any kind.
- The build cache is 24.49 GB but only **397.3 kB of it is reclaimable**: the
  rest is shared with the two live images. Pruning it would free essentially
  nothing while risking a future rebuild.
- The 14.08 GB reported as reclaimable under *Images* is the **M7 image's unique
  layers**, counted as reclaimable only because no container currently
  references it. **`docker system prune -a` would therefore delete this
  project's deployment artifact.** Prune is treated as forbidden for the
  remainder of the project.

### Can Milestone 8 reuse the existing image?

> **Yes.** Milestone 8 can be completed by reusing
> `video-surveillance-deepstream:m7-triton` without building or pulling
> anything.

The image is present and is the only application image on disk. Every mode of
[`../scripts/run_container.sh`](../scripts/run_container.sh) already drives it
via `--triton`, and both `verify_container.sh` and `verify_triton.sh` establish
the precedent of issuing `docker run` directly against the same image with the
same mounts. Nothing this milestone needs — throughput, telemetry, a sustained
run, redeployment — requires a different image, a different base, or a rebuild.

**The one step that would demand a new multi-GB artifact is
`run_container.sh --build --triton`, and Milestone 8 must never invoke it.** For
context, the single M7 rebuild drove free space to a measured low of 14.48 GB
([`milestone-07-triton.md`](milestone-07-triton.md) §4) while starting from more
headroom than exists now. If a Milestone 8 step ever appears to need something
new inside the container, the answer is a **bind mount** at run time — exactly
how the FP16 engine and the Triton model repository are already supplied. That
costs zero image space.

## 3. What Milestones 6 and 7 already proved

| Claim | Status | Evidence |
|---|---|---|
| Runs on Jetson Orin with `deepstream-app` | **Proven** | The literal capstone requirement, met by M6 §9 and M7 §10 |
| Reproducible launch from the repository | **Proven** | One script, one flag; preflights daemon, runtime, image, engine and output dirs, then prints the full `docker run` before executing it (`run_container.sh:143-148`) |
| Fresh invocation leaves no residue | **Proven** | `--rm` is unconditional in `COMMON_ARGS` (`run_container.sh:120-129`); `docker ps -a` is empty |
| GPU / NVDEC / VIC access without privilege | **Proven** | No `--privileged`, no `--device`, no `--gpus`; CSV-mode injection by the NVIDIA runtime; asserted by `verify_container.sh` CHECK 11 |
| Functional correctness inside the container | **Proven** | 288/288 frames, 230 detecting frames, 0 mid-track ID switches, 224-frame track over frames 50..273, zone entry 109 / 75 frames / exit 183, 100.00% analytics agreement, exit 0, clean EOS |
| The FP16 engine is reused byte for byte | **Proven** | sha256 `35677da6a31aa3724b1d7d93f6b8925a64a7a64b6790a55c18413562725270a6`, with the model repository and `1/model.plan` both mounted read-only |
| Visible playback is correct | **Proven (M7 path)** | Human-confirmed on the physical display: RF transitions 0 → 1 → 0, no OSD ghosting (M7 §10) |
| Storage cost of the artifact | **Measured** | 16.03 GB derived image, 10.41 GB base (M7 §4) |

## 4. What remains genuinely unproven

### Partially proven — to be narrowed rather than repeated

- **Repeated operation.** `verify_triton.sh` already issues five separate
  `docker run` invocations in a single pass, so "the image can be launched many
  times" is true in practice. What was never *asserted* is agreement between two
  independent fresh invocations. Note the caveat already recorded in
  [`../PLAN.md`](../PLAN.md) §11: *detection counts vary ~1% between identical
  runs*. Any redeployment check must therefore rest on the stable invariants —
  frame count, exit code, zone entry/exit/duration, ID-switch count — and state
  a tolerance on raw detection counts. A strict equality claim would fail for a
  reason that has nothing to do with deployment.
- **Reproducibility from a clean machine.** Blocked by existing debt:
  `verify_triton.sh` depends on `/home/matan/m6-baseline` (4.1 MB, outside the
  repository). Milestone 8 will not close this and should not imply that it has.

### Not measured at all

| Metric | Status |
|---|---|
| End-to-end pipeline FPS | **Never measured.** Open since M5; disclaimed in M6 §11.4 and M7 §11; recorded in `PLAN.md` §10 |
| Real-time sustainability (≥ 29.97 fps) | Never measured |
| CPU utilisation under pipeline load | Never measured |
| GPU utilisation under pipeline load | Measured for `trtexec` in M4 only |
| RAM consumption of the pipeline | Never measured |
| Temperature under pipeline load | Measured for `trtexec` in M4 only |
| Board power under pipeline load | Measured for `trtexec` in M4 only |
| Thermal throttling / clock behaviour | Never measured for the pipeline |
| Memory growth over time | **Never measured** |
| Longer-duration stability | Never attempted |
| Failure-free repeated operation | Incidental, never asserted |

The single most important observation behind this table: **every run this
project has ever made processed 288 frames and stopped.** No run has exceeded
9.61 s of video. There is therefore no evidence at all about steady-state
behaviour — thermal, memory, or throughput.

## 5. Instrumentation already available

Everything needed for telemetry already exists in
[`../scripts/trt_common.sh`](../scripts/trt_common.sh), and `ds_common.sh`
sources it transitively. Any new Milestone 8 script that does
`source ds_common.sh` gets all of it with **no new plumbing**:

| Helper | Location | Provides |
|---|---|---|
| `tegrastats_sample <s> <out>` | `trt_common.sh:184` | `timeout`-bounded capture; treats exit 124/143 as the expected end, dies on anything else, and requires a non-empty log |
| `gpu_busy_percent` | `trt_common.sh:196` | Peak `GR3D_FREQ` over a 4 s sample — a contention gate before measuring |
| `power_mode` | `trt_common.sh:206` | `nvpmodel -q`, read-only |
| `tj_temp_c` | `trt_common.sh:208` | Junction temperature from sysfs |
| `gpu_cur_freq_mhz` | `trt_common.sh:220` | GPU devfreq `cur_freq` |
| `disk_free_gb` | `trt_common.sh:230` | Free GB on the repository filesystem |

`benchmark_engines.sh` is the **methodological template** — to be read and
copied from, not modified: a GPU-idle gate before measuring, a discarded
pre-heat, `tegrastats` running for the whole measurement, `tj` and clock
recorded before and after each run, results as TSV, and an explicit
INCONCLUSIVE verdict when spread swamps the signal.

### `tegrastats` covers every required metric except FPS

Confirmed this session with a 4 s bounded sample, printed to stdout with no file
written. One line, verbatim:

```
08-12-2026 15:28:04 RAM 2390/7486MB (lfb 4x4MB) CPU [6%@729,4%@729,1%@729,13%@883,3%@729,5%@729] GR3D_FREQ 0% cpu@45.687C/45.687C soc2@45.156C/45.156C soc0@45.468C/45.468C gpu@46.843C/46.843C tj@46.843C/46.843C soc1@46.156C/46.156C VDD_IN 3848mW/3848mW/3848mW VDD_CPU_GPU_CV 606mW/606mW/606mW VDD_SOC 1174mW/1174mW/1174mW
```

| Requirement | Field | Adequate? |
|---|---|---|
| RAM | `RAM used/total`, `lfb` | Yes — and unified memory means this covers GPU memory too |
| CPU utilisation | per-core `%@MHz`, all six cores | Yes — utilisation *and* clock in one field |
| GPU utilisation | `GR3D_FREQ n%` | Yes — load percentage, **not** clock in MHz, the distinction M4 recorded |
| Temperature | `tj@`, `gpu@`, `cpu@`, `soc0-2@` | Yes |
| Power | `VDD_IN`, `VDD_CPU_GPU_CV`, `VDD_SOC`, each current/average/max | Yes |
| Clock behaviour | CPU MHz per core; GPU MHz from devfreq sysfs | Yes |
| Throttling | **no direct flag** | **Partial** — can only be *inferred* from clocks falling while `tj` rises. To be reported as an inference, never as a measurement |
| FPS | absent | **No** — must come from `deepstream-app` |

Two FPS sources already exist and cost nothing:

1. **`enable-perf-measurement=1` and `perf-measurement-interval-sec=5` are
   already set in all four application configs**, so `deepstream-app` has been
   printing `**PERF: <fps> (<avg>)` lines all along. No script has ever captured
   or asserted them; the only such figure recorded anywhere in the project is a
   hand-transcribed line in M7 §10, immediately disclaimed in §11 because it was
   paced by `sync=1`. Capturing stdout is the entire job.
2. **Wall clock ÷ 288 frames** for the existing bounded run — an honest
   end-to-end throughput figure that needs no configuration change at all, and
   an independent cross-check on `deepstream-app`'s own accounting.

Per-process memory can be read from `/proc` on the host for the containerised
`deepstream-app`, which is stronger leak evidence than system-wide RAM. That
needs `ps`, already installed. `jtop` is not installed and will not be.

## 6. Feasibility of a bounded stability test

**Mechanism.** `[tests] file-loop=1` is a real, parser-supported key in
DeepStream 9.1 — present in the `deepstream-app` binary and in ten shipped
sample configs. All four of this project's configs set `file-loop=0`, with the
comment *"Never loop: verification must terminate on its own."* There is no CLI
override (`deepstream-app` accepts only `-c` and `-i`), so a looping run needs
**one new config file**, which can be bind-mounted into the existing image.

**Termination.** A looping `deepstream-app` never ends by itself. It must be
bounded externally with `timeout` sending `SIGINT`, which `deepstream-app`
handles as a quit request rather than being killed outright. The resulting exit
status must be handled the way `tegrastats_sample` already handles its own — the
expected signal exit declared acceptable explicitly, never with `|| true`.

**Estimates for a ~10-minute unpaced run** (`sync=0`):

| Quantity | Estimate |
|---|---|
| Throughput | **Unknown — this is the thing being measured.** Bracketed between 30 fps (real-time bound) and ~150 fps; M4 measured the engine alone at 310 qps FP16, and decode, tracker, tiler, OSD and Triton tensor copies will dominate |
| Frames processed | ~18,000 to ~90,000 |
| Clip iterations (288 frames each) | ~62 to ~310 |
| `tegrastats` at 1 Hz | ~600 lines × ~330 B ≈ **200 KB** (M4's comparable log was 282 KB) |
| `**PERF` lines at 5 s | ~120 lines, under 10 KB |
| Total telemetry | **under 500 KB** |
| Video written | **none** — `type=1` fakesink; there is no `[sink1]`, no `output-file` and no encoder key anywhere in `configs/` |
| Docker writable-layer growth | **0 B** — `--rm`, and every output path is a bind mount |

**The four KITTI dumps must be disabled in the soak config.** Measured density
from the existing 288-frame output is 3.3 KB/frame for detections, 3.3 KB/frame
for tracks and 7.4 KB/frame for the zone probe. At 90,000 frames that is roughly
600 MB across ~360,000 files — and, worse, it places synchronous per-frame disk
I/O inside the thing being measured. Removing the four `*-output-dir` keys
removes both problems. Correctness is not under test here; M7 proved it.

**Verdict: a 10-minute bounded soak is reasonable.** It is far below any disk
risk, long enough for the thermal ramp to reach steady state (M4 saw 51.3 →
66.0 °C under `trtexec`), and long enough for a memory trend to separate from
noise.

**One caveat to record before measuring, not after:** `file-loop` restarts the
source rather than seeking seamlessly — `PLAN.md` §9 already lists gapless
looping as unimplemented. Each loop boundary may inject a stall that depresses
the average. The result must therefore report the **distribution** of
per-interval `**PERF` samples and identify loop-boundary dips, rather than a
single averaged number.

## 7. Redeployment semantics

- **Every invocation uses `docker run --rm`**, set once in `COMMON_ARGS`
  (`run_container.sh:120-129`) and inherited by all four modes.
  `verify_container.sh` and `verify_triton.sh` pass `--rm` on their own
  `docker run` lines too. Nothing is left behind, which the empty `docker ps -a`
  in §2 confirms independently.
- **No `--name` anywhere in the repository.** When a handle is needed,
  `verify_container.sh:345` captures a CID from `docker run -d --rm`. Any
  Milestone 8 telemetry that must attach to a running container would have to do
  the same — but the need is avoidable entirely, because `tegrastats` is
  system-wide.
- **No `-d`, no restart policy, no `--cpus`/`--memory` limits, no healthcheck,
  no systemd unit.** `ENTRYPOINT` is empty and `CMD` is `/bin/bash`: the command
  always comes from the caller.
- **Removing and recreating containers costs no meaningful disk.** Writable-layer
  usage is measured at 0 B, and containers do not survive the run.
- **No persistent state is required between runs.** The engine is mounted
  read-only, the Triton repository is mounted read-only, configs are baked into
  the image, and every output path is a host bind mount. The one cross-run
  coupling is that the four dump directories are **overwritten in place**, so a
  redeployment comparison must snapshot the first run's output before the second
  run starts.
- **Deployment reproducibility can therefore be demonstrated by launching the
  existing image twice**, subject to the ~1% detection-count tolerance in §4.

## 8. Decisions taken before implementation

| Decision | Rationale |
|---|---|
| Reuse `m7-triton`; never build or pull | 29 GB free, and the M7 rebuild once fell to 14.48 GB from more headroom. Anything new goes in by bind mount |
| Never run any `docker prune` | Docker reports the M7 image's 14.08 GB as "reclaimable" purely because no container references it |
| Three checkpoints, not four | The proposed "reproducible edge launch" checkpoint duplicates M6 §9 and M7; the only unproven part of it is two fresh invocations agreeing, which belongs after the sustained run |
| Sustained run is **unpaced** (`sync=0`) | It yields the throughput figure and the harshest thermal and power condition in one run. Sustaining well above 29.97 fps proves real-time capability a fortiori; a paced run would prove less and stress less |
| Sustained run is **~10 minutes** | Long enough for thermal steady state and for a memory trend to separate from noise; short enough to stay bounded with no swap |
| KITTI dumps disabled in the soak config | Keeps ~600 MB and ~360,000 files off the disk, and keeps per-frame synchronous I/O out of the measurement |
| New script issues its own `docker run` | The precedent set by `verify_container.sh` and `verify_triton.sh`, and it means no completed-milestone file is modified |
| Telemetry is small text only | No video, no per-frame dumps, no metadata dumps; under 500 KB per run |
| Report spread, never a single number | Clocks cannot be locked. The M4 method applies unchanged |
| Redeployment asserted on stable invariants plus a stated tolerance | Detection counts already vary ~1% run to run for reasons unrelated to deployment |
| Monitoring stacks deferred to M9 | `PLAN.md` §2 assigns output, metrics and observability to Milestone 9 explicitly |
| No systemd, autostart or reboot persistence | No `sudo` is available for a system unit, the capstone wording does not ask for one, and "standalone operation" is satisfied by a self-contained repeatable launch from the repository |

## 9. Risks identified before starting

1. **Accidental image work is the only real disk risk.** A rebuild costs 15–30 GB
   of the 29 GB free, and `docker system prune -a` would delete the deployment
   artifact. Mitigated by never building, pulling or pruning, and by enforcing a
   free-space floor with `disk_free_gb` before starting — the watchdog M7
   described in prose but never implemented.
2. **Zero swap.** A leak during a sustained run ends in an OOM kill. Mitigated by
   bounded runtime, RAM sampled at 1 Hz, and an abort threshold.
3. **Clocks cannot be locked.** DVFS will move CPU and GPU across their range
   during measurement. Mitigated the M4 way: report spread, record `tj` and
   clocks beside every figure, declare INCONCLUSIVE rather than dress up noise.
4. **`file-loop` is not gapless.** Loop-boundary stalls may bias the average
   downward. Mitigated by reporting the per-interval distribution and naming the
   dips.
5. **The ~1% run-to-run detection variance is known and unexplained.** A
   redeployment check built on strict equality would fail for the wrong reason.
6. **`tegrastats` is system-wide, not per-container.** Mitigated by capturing an
   idle baseline, running nothing else, reporting deltas, and using `/proc` RSS
   for the per-process memory trend.
7. **Throttling cannot be read directly** without root. It can only be inferred
   from clocks falling while `tj` rises, and must be documented as an inference.
8. **The `**PERF` figure is self-reported.** It is `deepstream-app`'s own
   accounting, not an independent measurement. Mitigated by cross-checking it
   against frames ÷ wall clock.
9. **Clean-machine reproducibility stays broken.** `verify_triton.sh` needs
   `/home/matan/m6-baseline`. Milestone 8 restates this as open debt rather than
   fixing it.

A run that fails, throttles or leaks is a **result** to be documented as such —
not a reason to retune the pipeline.

---

## Addendum — 2026-08-13, after Milestone 8.2 implementation

Appended, not merged. Everything above is the dated record of what was known on
2026-08-12, before any Milestone 8 code was written, and it is left exactly as
it was written. This addendum records what implementation discovered.

### Throttling can be read directly after all

Two places above state that thermal throttling cannot be measured on this board,
and are the strongest claims in the document that implementation superseded:

- §5, the `tegrastats` coverage table, row *Throttling*: *"**no direct flag** …
  **Partial** — can only be *inferred* from clocks falling while `tj` rises. To
  be reported as an inference, never as a measurement."*
- §9, risk 7: *"**Throttling cannot be read directly** without root. It can only
  be inferred from clocks falling while `tj` rises, and must be documented as an
  inference."*

Both statements were about `tegrastats`, and about `tegrastats` they remain
true: it exposes no throttling flag. The error was in generalising from that one
instrument to the platform.

**The Linux thermal framework exposes its cooling devices at
`/sys/class/thermal/cooling_device*/`, world-readable, no root required.** Each
device has a `type`, a `max_state` and a live `cur_state`. Thirteen exist on this
board. Three of them are the frequency-capping mechanisms themselves:

| Device | `max_state` | What a non-zero state means |
|---|---|---|
| `cpufreq-cpu0` | 21 | The thermal framework is capping the CPU cluster's frequency |
| `cpufreq-cpu4` | 21 | The same, for the second cluster |
| `devfreq-17000000.gpu` | 7 | The thermal framework is capping the GPU's frequency |

Reading `cur_state` therefore answers the question directly: **a non-zero state
on one of those three devices *is* throttling**, not evidence from which
throttling might be inferred. `scripts/measure_edge.sh` samples all thirteen at
1 Hz for this reason, and classifies them so the distinction cannot be lost.

The remaining ten — the `*-throttle-alert` devices, `hot-surface-alert` and
`pwm-fan` — are alert and fan devices. **They are not equivalent to the first
three, and must not be reported as though they were.** A fan stepping up is
thermal management working correctly.

### What the soak measured

Over the 604 s Milestone 8.2 run, **all three frequency-capping devices remained
at `cur_state` 0 for every one of the 601 samples**. `pwm-fan` moved 0 → 1 at
t+46 s and stayed there; no other device left 0.

> **No CPU or GPU thermal frequency capping occurred during the soak.** That is
> a statement about measured cooling-device state, not an inference from clock
> stability. Junction temperature peaked at 64.97 °C, roughly 5 °C below the
> 70 °C passive trip carried by the `cpu-thermal` and `gpu-thermal` zones.

Consequently the phrase *"throttling is reported as an inference"*, used in the
acceptance criteria above and in `PLAN.md`, no longer describes what was done.
Throttling was **measured**. Full record:
[`milestone-08-edge-deployment.md`](milestone-08-edge-deployment.md) §10.

### Two smaller supersessions

- **§5 concluded that no independent frame count was cheaply available**, leaving
  wall-clock ÷ 288 on a single pass as the only cross-check on `deepstream-app`'s
  self-reported `**PERF`. Implementation found a better one: GStreamer emits
  `Got data flow before segment event` exactly **once per file-loop seek**, which
  yields completed-loops × 288 frames over host wall-clock time, owing nothing to
  DeepStream's own accounting. The two methods agreed to 0.06%
  ([detail](milestone-08-edge-deployment.md) §7).
- **§6 warned that loop-boundary stalls "may inject a stall that depresses the
  average"**, and the plan allowed for excluding boundary samples. Measured, the
  effect is **~0.30 fps out of 178** — about 0.17% — so no sample was excluded
  from any statistic ([detail](milestone-08-edge-deployment.md) §8). The caveat
  was correct to raise and turned out not to matter.

### What did not change

The inspection's disk analysis, its reuse decision, its scope boundaries and its
remaining seven risks all held. In particular §2's answer — that Milestone 8 can
be completed by reusing `video-surveillance-deepstream:m7-triton` without
building or pulling anything — was borne out: checkpoints 8.1 and 8.2 are
complete, nothing was built, pulled or pruned, and free disk was 29 GB before the
soak and 29 GB after.
