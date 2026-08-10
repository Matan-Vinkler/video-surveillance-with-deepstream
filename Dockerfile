# Milestone 6 - containerise the restricted-zone surveillance application.
#
# Base: NVIDIA's DeepStream 9.1 Jetson image. Containerisation is a DEPLOYMENT
# change, not an application change: no config, threshold, model, tracker or
# analytics geometry is altered, and the FP16 engine is reused rather than
# rebuilt.
#
# ---------------------------------------------------------------------------
# THE ONE DELIBERATE DEVIATION: TensorRT 10.16.1 -> 10.16.2
# ---------------------------------------------------------------------------
# The shipped multiarch image carries TensorRT 10.16.1.11 from the generic
# arm64/SBSA CUDA repo. This Jetson runs JetPack 7.2 / L4T R39.2, whose
# TensorRT is 10.16.2.10, and every engine in this project was built with it.
# TensorRT plan files are version-locked, so the host engine cannot deserialize
# under 10.16.1.
#
# We upgrade the container to match the host rather than build a second engine,
# because the whole claim of this milestone is "containerisation did not change
# application behaviour" -- and that is only provable if the inference library
# and the engine file are identical on both sides. Building a second engine with
# a different TensorRT would change the inference stack, and its numerical
# equivalence has never been validated (see milestone-04 s8).
#
# Evidence this is safe, all measured before doing it:
#   - The 10.16.2 packages come from the SAME repo the host installed from:
#     repo.download.nvidia.com/jetson/common r39.2/main arm64. Identical version
#     string, identical architecture -- not a lookalike rebuild.
#   - DeepStream links TensorRT by MAJOR soname only (libnvinfer.so.10,
#     libnvinfer_plugin.so.10, libnvonnxparser.so.10), so 10.16.1 -> 10.16.2 is
#     ABI-compatible and requires no relinking.
#   - `apt-get install -s` reports "7 upgraded, 0 to remove". Nothing is removed.
#   - DeepStream is not dpkg-managed in this image at all, so no packaging
#     relationship could remove it.
#   - Both builds carry the same builder-resource set (ptx, sm75..sm120).
#
# What this costs: NVIDIA apt-mark held these packages, so this is an explicit
# override of a vendor pin, and the resulting image is CUSTOM rather than the
# shipped artifact. It is, however, the combination NVIDIA supports natively on
# this device -- DeepStream 9.1 on JetPack 7.2 runs against TensorRT 10.16.2.
# Full record: docs/milestone-06-containerization.md
# ---------------------------------------------------------------------------

ARG BASE_IMAGE=nvcr.io/nvidia/deepstream:9.1-samples-multiarch
FROM ${BASE_IMAGE}

# Pinned exactly. Never install these unpinned: the unheld TensorRT dev and
# Python packages in the same repos resolve to 11.2.1.2, a different major.
ARG TRT_VERSION=10.16.2.10-1+cuda13.2

# All seven move together -- tensorrt-libs is a metapackage whose dependencies
# are exact-version, so a partial upgrade cannot resolve.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends --allow-change-held-packages \
        libnvinfer10="${TRT_VERSION}" \
        libnvinfer-plugin10="${TRT_VERSION}" \
        libnvinfer-vc-plugin10="${TRT_VERSION}" \
        libnvinfer-lean10="${TRT_VERSION}" \
        libnvinfer-dispatch10="${TRT_VERSION}" \
        libnvonnxparsers10="${TRT_VERSION}" \
        tensorrt-libs="${TRT_VERSION}"; \
    # Re-pin at the NEW version. The point is to preserve NVIDIA's intent that
    # these do not drift, not to abandon it.
    apt-mark hold \
        libnvinfer10 libnvinfer-plugin10 libnvinfer-vc-plugin10 \
        libnvinfer-lean10 libnvinfer-dispatch10 libnvonnxparsers10 tensorrt-libs; \
    rm -rf /var/lib/apt/lists/*

# Fail the BUILD, not a later run, if the upgrade did not take effect.
#
# These are package- and filesystem-level assertions only, and that limit is
# deliberate: `docker build` runs WITHOUT the NVIDIA container runtime, so the
# host driver libraries it injects (libnvbufsurface, libnvbufsurftransform,
# libnvdsbufferpool, ...) do not exist during a build. Any DeepStream GStreamer
# plugin that links them therefore cannot be loaded here -- `gst-inspect-1.0
# nvinfer` reports "No such element or plugin" at build time and works perfectly
# at run time. Element availability is asserted by scripts/verify_container.sh,
# where the runtime is actually present.
RUN set -eux; \
    got="$(dpkg-query -W -f='${Version}' libnvinfer10)"; \
    test "$got" = "${TRT_VERSION}" || { echo "libnvinfer10 is $got, expected ${TRT_VERSION}"; exit 1; }; \
    for p in libnvinfer-plugin10 libnvinfer-vc-plugin10 libnvinfer-lean10 \
             libnvinfer-dispatch10 libnvonnxparsers10 tensorrt-libs; do \
        v="$(dpkg-query -W -f='${Version}' "$p")"; \
        test "$v" = "${TRT_VERSION}" || { echo "$p is $v, expected ${TRT_VERSION}"; exit 1; }; \
    done; \
    readlink -f /usr/lib/aarch64-linux-gnu/libnvinfer.so.10 | grep -q '10\.16\.2' \
        || { echo "libnvinfer.so.10 does not resolve to 10.16.2"; exit 1; }; \
    for p in libnvinfer10 libnvinfer-plugin10 libnvinfer-vc-plugin10 libnvinfer-lean10 \
             libnvinfer-dispatch10 libnvonnxparsers10 tensorrt-libs; do \
        apt-mark showhold | grep -qx "$p" || { echo "$p was not re-held"; exit 1; }; \
    done; \
    # DeepStream itself must still be intact on disk after the swap.
    test -x /usr/bin/deepstream-app; \
    test -e /opt/nvidia/deepstream/deepstream/lib/gst-plugins/libnvdsgst_infer.so; \
    test -e /opt/nvidia/deepstream/deepstream/lib/libnvds_nvmultiobjecttracker.so; \
    grep -q '^Version: 9\.1\.0' /opt/nvidia/deepstream/deepstream/version

WORKDIR /app

# The application itself. Layout mirrors the repository so the configs' relative
# paths (../models/engines, ../models/detections) resolve unchanged -- not one
# config is rewritten for Docker.
COPY configs/ /app/configs/
COPY scripts/ /app/scripts/
COPY tools/   /app/tools/

# Build the analytics probe IN the image. Contrary to NVIDIA's "no development
# in Jetson containers" note, this image ships g++, make, pkg-config, the
# gstreamer-1.0 .pc and the DeepStream headers -- verified before relying on it.
# Building here rather than copying a host binary keeps the image self-contained
# and removes any host-toolchain dependency.
RUN set -eux; \
    make -C /app/tools DS_ROOT=/opt/nvidia/deepstream/deepstream; \
    test -x /app/build/analytics_probe

# Mount points. Created so a missing bind-mount fails as "empty", never as a
# silent write into the image layer.
RUN mkdir -p /app/models/engines /app/models/detections /app/models/tracks \
             /app/models/tracks_terminated /app/models/tracks_shadow /app/models/zone

# The base image's entrypoint word-splits its arguments ("$@" unquoted), which
# mangles any command passed to `docker run`. Cleared deliberately.
ENTRYPOINT []
CMD ["/bin/bash"]
