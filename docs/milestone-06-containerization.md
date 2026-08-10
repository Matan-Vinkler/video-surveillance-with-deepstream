# Milestone 06 — Containerising the application

**Goal.** Run the finished Milestone 5 application inside a Docker container on
this Jetson, and prove that containerisation changed nothing about what it does.

**Status: complete.** `./scripts/verify_container.sh` exits 0 with all checks
passing. Detector and tracker metadata are **identical on 0 of 288 frames
differing** between the host-native and containerised runs, and the
restricted-zone result is unchanged: entry 109, 75 frames inside, exit 183.

Containerisation is a **deployment** change. No config, threshold, model,
tracker setting or analytics geometry was altered, and the FP16 engine was
reused rather than rebuilt — `configs/` and `tools/` are byte-identical to
`HEAD`, which is itself a check.

---

## 1. What was added

```
Dockerfile               # derived image: TensorRT pin + the application
.dockerignore            # keeps models/, build/, docs/ out of the context
scripts/
├── run_container.sh     # build / headless / zone / display / shell
└── verify_container.sh  # 12 machine checks, host-vs-container diff
```

Nothing else changed. The container runs the same `deepstream-app` with the same
`.txt` configs.

## 2. The base image

`nvcr.io/nvidia/deepstream:9.1-samples-multiarch`, digest
`sha256:4f80b374e4a5086552825fe0f5bdd015c8cfd3dbe430cdde5ce9572e80e01583`,
`arm64/linux`, 6.39 GB.

Verified before relying on it: DeepStream **9.1.0 GCID 46117240** — the same
build as the host; all twelve required GStreamer elements; the NvSORT YAML and
`libnvds_nvmultiobjecttracker.so` at the exact absolute paths our configs
already hard-code; `Primary_Detector/{labels.txt, resnet18_trafficcamnet_pruned.onnx}`;
and `sample_walk.mov` **sha256-identical** to the host copy (`07410bd6…`), so no
video needs mounting.

`-triton-multiarch` was rejected: far larger, and it drags in Triton, which is
out of scope here and is Milestone 7's own (currently blocked) problem.

**One documented claim turned out to be wrong.** NVIDIA's docs state *"The
Jetson Docker containers are for deployment only. They do not support DeepStream
software development within a container."* This image ships `g++`, `gcc`, `make`,
`pkg-config`, the `gstreamer-1.0` `.pc` and the DeepStream headers — including
`sources/includes/nvds_analytics_meta.h`. `tools/analytics_probe.cpp` is
therefore compiled **inside** the image, with no multi-stage build, no host-built
binary and no `apt-get`.

## 3. The one deliberate deviation: TensorRT 10.16.1 → 10.16.2

The shipped image carries TensorRT **10.16.1.11** from the generic arm64/SBSA
CUDA repo. This Jetson runs JetPack 7.2 / L4T R39.2, whose TensorRT is
**10.16.2.10**, and every engine in this project was built with it. TensorRT plan
files are version-locked, so the host engine cannot deserialize under 10.16.1.

That left two designs:

| | **A — keep 10.16.1, build a second engine** | **B — upgrade to 10.16.2, reuse the engine** |
|---|---|---|
| Feasible? | **No, as stated.** The samples image has no `trtexec`, no `/usr/src/tensorrt` and no TensorRT Python binding, so it cannot build an engine without installing packages anyway. And the host cannot build a 10.16.1 engine — it only has 10.16.2 | Yes |
| Inference stack | Two engines, two TensorRT versions | One of each |
| Behavioural risk | **Higher** — a different TensorRT builds a different engine, and numerical equivalence has never been validated ([milestone-04](milestone-04-tensorrt-optimization.md) §8) | Lower |
| Provability | A difference in output could never be attributed | Byte-identical comparison is possible |

**B was chosen**, and the reason is the milestone's own claim: *containerisation
did not change application behaviour*. That is only provable if the inference
library and the engine file are the same on both sides. Option A would
deliberately introduce a second engine built by a different TensorRT — precisely
a change to the inference stack, and exactly the kind whose detection-quality
impact this project has never validated.

### The evidence gathered before doing it

- The 10.16.2 packages come from the **same repository the host installed from**:
  `repo.download.nvidia.com/jetson/common r39.2/main arm64`. Identical version
  string, identical architecture — not a lookalike rebuild. That repo is already
  configured in the image; it simply sits at apt priority 500 against SBSA's 600,
  which is why 10.16.1 wins by default.
- **DeepStream links TensorRT by major soname only.** `deepstream-app`,
  `libnvdsgst_infer.so` and `libnvds_infer.so` all require `libnvinfer.so.10`,
  `libnvinfer_plugin.so.10`, `libnvonnxparser.so.10`. 10.16.1 → 10.16.2 keeps
  the soname, so nothing relinks.
- `apt-get install -s` reports **`7 upgraded, 0 newly installed, 0 to remove`**,
  with no `Remv` lines.
- **DeepStream is not dpkg-managed in this image at all** (`dpkg -l | grep
  deepstream` is empty; it is unpacked under `/opt`). No packaging relationship
  could remove it.
- Both builds carry the same builder-resource set (`ptx, sm75, sm80, sm86, sm89,
  sm90, sm100, sm110, sm120`). *(A hypothesis that the SBSA build lacked `sm87`
  for Orin was checked and disproved — neither build ships it.)*

### What it costs, stated plainly

NVIDIA `apt-mark hold`ed all seven packages. Upgrading requires
`--allow-change-held-packages`, which is an explicit override of a vendor pin,
and **the resulting image is custom, not the shipped artifact.**

The direction matters, though: on a *native* JetPack 7.2 Jetson — this device —
DeepStream 9.1 runs against TensorRT 10.16.2. That is NVIDIA's supported native
combination and what the host has run since Milestone 3. The multiarch container
is the outlier, carrying the SBSA build so one image can serve x86, arm64 servers
and Jetson. So this **moves the container toward the supported native
combination while deviating from the shipped image's pin.**

The seven are **re-held at the new version** — preserving NVIDIA's intent that
they not drift, rather than abandoning it.

```
libnvinfer10 libnvinfer-plugin10 libnvinfer-vc-plugin10 libnvinfer-lean10
libnvinfer-dispatch10 libnvonnxparsers10 tensorrt-libs   -> 10.16.2.10-1+cuda13.2
```

All seven must move together: `tensorrt-libs` is a metapackage with
exact-version dependencies, so a partial upgrade cannot resolve.

> **Trap.** The TensorRT **dev** and **Python** packages in the same repos are
> not held, and their unpinned candidate is `11.2.1.2` — a different major. Any
> future addition must be pinned explicitly.

## 4. Nothing extra was installed

No Python TensorRT bindings, no dev packages, no `trtexec`. That is possible
because **the container never resolves the engine's name.** The nvinfer config
references the stable symlink `../models/engines/trafficcamnet_fp16.engine`,
which the host maintains; `deepstream-app` only has to follow it.
`ensure_engine_link()` — the sole consumer of `trt_version()` and
`model_contract()` — stays on the host, where TensorRT's Python binding exists.

## 5. What is copied, what is mounted

| Artifact | Strategy | Why |
|---|---|---|
| `configs/`, `scripts/`, `tools/` | **COPY** | Small, versioned; they define the verified behaviour, so the image is the deliverable rather than a shell around host files |
| `analytics_probe` | **built in-image** | Self-contained; no host toolchain dependency |
| **FP16 engine** | **bind-mount, read-only** | Machine-specific, git-ignored. Baking it in would pin the image to one TensorRT build and contradict the rule that engines are regenerated, never shipped. Read-only also makes a rebuild *physically impossible* |
| labels, NvSORT YAML, tracker `.so`, `sample_walk.mov` | **container-native** | All at absolute `/opt/...` paths the configs already use; the video is sha256-identical to the host's |
| detector / tracker / zone dumps | **bind-mount, read-write** | Evidence must survive `--rm` |
| `docs/`, `media/`, `models/`, `build/` | **excluded** via `.dockerignore` | Not needed to run anything; keeps machine-specific artifacts out |

The in-image layout mirrors the repository (`/app/configs`, `/app/models`), so
the configs' relative paths resolve unchanged. **Not one config was rewritten
for Docker** — CHECK 12 asserts it.

## 6. A build-time limitation worth knowing

The first build failed here:

```
gst-inspect-1.0 nvinfer
  Failed to load plugin '.../libnvdsgst_dsexample.so':
      libnvbufsurface.so.1.0.0: cannot open shared object file
  No such element or plugin 'nvinfer'
```

**This is not a TensorRT problem** — the version, soname, hold and
`deepstream-app` assertions had already passed. `docker build` runs **without the
NVIDIA container runtime**, so the host driver libraries it injects through CSV
mode (`libnvbufsurface`, `libnvbufsurftransform`, `libnvdsbufferpool`, …) do not
exist during a build. Any DeepStream plugin linking them cannot load there, and
loads perfectly at run time.

So the Dockerfile asserts only what a build can actually see — package versions,
the resolved soname, the holds, DeepStream's on-disk integrity and its GCID — and
**element availability is asserted by `verify_container.sh`, where the runtime
exists.** The Dockerfile says so in a comment, so it is not "fixed" back later.

## 7. Hardware access without privilege

Jetson's NVIDIA runtime uses **CSV mode**
(`/etc/nvidia-container-runtime/host-files-for-container.d/`), whose
`devices.csv` injects 43 device entries:

| Need | Provided by the runtime |
|---|---|
| GPU | `/dev/nvhost-*`, `/dev/nvgpu/igpu0/*`, `/dev/nvidia0`, `/dev/nvidiactl` |
| **NVDEC** | `/dev/v4l2-nvdec` |
| VIC / surface allocation | `/dev/nvmap`, `/dev/host1x-fence`, `/dev/nvsciipc` |
| Display | `/dev/dri/card*`, `/dev/dri/renderD*`, `/dev/fb0` |

`drivers.csv` injects driver libraries but **zero DeepStream and zero TensorRT**
— confirming both must come from the image, which is why §3 matters at all.

Measured on the live container:

```
Privileged                   false
explicit --device entries    0
--gpus device requests       0
NetworkMode                  none
added capabilities           0
```

No `--privileged`, no `--device`, no `--gpus`, no networking. This is asserted
against the container's actual `HostConfig` via `docker inspect`, not by grepping
our own scripts — the first attempt did grep the scripts and failed on its own
comments, which is a good illustration of why source text is not evidence.

## 8. Verification results

`./scripts/verify_container.sh` — a host-native baseline run, two container runs,
a read-only facts pass and a negative control. **Exit 0, all checks passed.**

```
== CHECK 1: TensorRT inside the image is exactly 10.16.2.10-1+cuda13.2 ==
  libnvinfer10 … tensorrt-libs   all 10.16.2.10-1+cuda13.2
  libnvinfer.so.10 ->            libnvinfer.so.10.16.2
  PASS  all 7 TensorRT packages are at 10.16.2.10-1+cuda13.2
  PASS  the runtime library really is 10.16.2, not just the package record
  PASS  all 7 are apt-mark held again at the new version
== CHECK 2: DeepStream is still 9.1, same build as the host ==
  container  9.1.0 (GCID 46117240)      host  9.1.0 (GCID 46117240)
  PASS  the TensorRT swap left DeepStream 9.1.0 intact and identical to the host build
== CHECK 3: every required plugin loads at RUNTIME ==
  PASS  all required elements present
== CHECK 4: the engine is byte-identical and was not rebuilt ==
  host before / inside container / host after   35677da6a31aa372…  (all three)
  PASS  one engine file, unchanged, seen identically from both sides
  PASS  the container deserialized the prebuilt engine
  PASS  no rebuild was attempted
== CHECK 5: the engine mount is genuinely read-only ==
  PASS  writing into the engine mount fails (exit 1)
== CHECK 6: the containerised app ran to a clean EOS ==
  frames processed             288 of 288
  PASS  deepstream-app and analytics_probe both exited 0
== CHECK 7: detector metadata is identical to the host run ==
  per-frame files differing    0
== CHECK 8: tracker metadata is identical ==
  per-frame files differing    0
  mid-track ID switches        0
  longest continuous track     224 frames
== CHECK 9: the restricted-zone result is unchanged ==
  entry 109, exit 183, 75 frames, 1 run, 100.00% agreement
== CHECK 10: outputs persist on the host after the container is gone ==
  PASS  container output survived --rm and is owned by the host user
== CHECK 11: no privileged or device access anywhere ==
  PASS  unprivileged, no device mounts, no --gpus, no network, no added capabilities
== CHECK 12: the host-native application is untouched ==
  PASS  configs/ and tools/ are unmodified relative to HEAD
  PASS  verify_zone.sh still exits 0
```

**The headline is CHECK 7 and 8: 0 of 288 per-frame files differ.** Not
"equivalent within tolerance" — byte-identical detector and tracker metadata,
host versus container. The comparison is against a **fresh host-native baseline
captured in the same script run**, not against numbers copied from the Milestone
5 documents.

That result is only obtainable because of the TensorRT decision in §3. With a
second engine built by a different TensorRT, any difference here would have been
unattributable.

## 9. Runtime interface

```
./scripts/run_container.sh --build       # build; fails if the TensorRT pin did not take
./scripts/run_container.sh --headless    # deepstream-app -> fakesink
./scripts/run_container.sh --zone        # analytics_probe -> restricted-zone verdict
./scripts/run_container.sh --display     # visible playback on the physical monitor
./scripts/run_container.sh --shell       # interactive, same mounts
```

The wrapper preflight-checks the daemon, the `nvidia` runtime, the image, the
engine and the output directories before launching, and **prints the full
`docker run` it is about to execute** — the mounts and flags stay visible rather
than hidden in a script.

### The visible path, and why it needs no `xhost`

Measured on this host:

```
$ DISPLAY=:1 xhost   ->  access control enabled … SI:localuser:matan
$ xauth list         ->  cookies for :0, :1001, localhost:0 — NONE for :1
```

Display `:1` authorises by **local uid**, not by cookie — so mounting
`~/.Xauthority` would achieve nothing and `xhost +` would be a large,
unnecessary weakening. The wrapper instead runs the container **as uid 1000**
with `--group-add video --group-add render`. Docker has no `userns-remap`, so the
container's uid *is* uid 1000 to the kernel and matches `SI:localuser:matan`,
with **no host X11 change at all**. If that ever fails, the wrapper prints the
narrow fallback (`xhost +SI:localuser:<user>` for that display only) rather than
performing it.

## 10. Image policy

| Question | Decision |
|---|---|
| Base tag | **Pinned** to `9.1-samples-multiarch`, and the digest is recorded in §2. Never `latest` |
| Our tag | `video-surveillance-deepstream:m6`; overridable via `IMAGE_NAME`/`IMAGE_TAG` |
| Committed | `Dockerfile`, `.dockerignore`, both scripts |
| Ignored | `models/` (engine + all dumps), `build/`, `docs/`, `media/`, `.git/` |
| Engine in `.dockerignore`? | **Yes** — `models/` is excluded outright. The engine must never enter the image |

## 11. Known limitations

1. **The image is a custom artifact**, not NVIDIA's shipped one (§3). Supported
   as a *software combination* on this device; unsupported as an *image*.
2. **A TensorRT upgrade must be repeated deliberately.** If the base image later
   ships 10.16.2, the pin becomes a no-op — harmless, but the Dockerfile should
   then be simplified rather than left as archaeology.
3. **Element availability cannot be asserted at build time** (§6).
4. **No performance claim.** End-to-end throughput was never measured natively
   either, so nothing is said about container overhead.
5. **One clip, one source.** The crowded source is untested here, as everywhere.
6. **Visible playback in the container is unverified** — the headless path is
   fully machine-checked; the on-screen path needs a human, as in Milestone 5.
7. **Image size** grew from 6.39 GB to 8.99 GB (`docker image inspect .Size`),
   partly because both TensorRT versions transit the layers.

## 12. Completion criteria

| Criterion | Status |
|---|---|
| Image builds | Done — exit 0, build-time assertions pass |
| Container starts | Done |
| NVIDIA runtime active, GPU reachable | Done — engine deserializes and inference runs |
| `deepstream-app` present | Done |
| All required plugins present | Done — at runtime (§6) |
| TensorRT is exactly 10.16.2 and re-held | Done — all 7 packages + resolved soname |
| DeepStream still 9.1 | Done — same GCID as host |
| FP16 engine deserialized, not rebuilt | Done — identical sha256 on both sides; mount proven read-only |
| All 288 frames processed | Done |
| Detection unchanged | Done — **0 of 288 frames differ** |
| Tracking unchanged | Done — **0 differ**, 0 mid-track switches, 224-frame track |
| Restricted zone unchanged | Done — 109 / 75 / 183, 100% agreement |
| Headless container exits cleanly | Done |
| Outputs persist on the host | Done — survived `--rm` |
| Host-native suites still pass | Done — `verify_zone.sh` exit 0 |
| No config silently changed for Docker | Done — `configs/` and `tools/` clean vs `HEAD` |
| Visible container playback confirmed | **Not done** — needs a manual run |
