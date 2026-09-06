#!/usr/bin/env bash
# Refresh checksums in vars.yaml for the pinned NVIDIA_DRIVER_VERSION and
# CONTAINER_TOOLKIT_VERSION.
#
# NVIDIA publishes no checksums for GitHub source tarballs or .run installers,
# so all eight digests are computed locally. Downloads ~850 MB total (source
# tarball + amd64/arm64 .run installers + the nvidia-container-toolkit
# source tarball).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(awk '/^NVIDIA_DRIVER_VERSION:/ {print $2}' vars.yaml)"
TOOLKIT_VERSION="$(awk '/^CONTAINER_TOOLKIT_VERSION:/ {print $2}' vars.yaml)"
echo "==> NVIDIA_DRIVER_VERSION: ${VERSION}"
echo "==> CONTAINER_TOOLKIT_VERSION: ${TOOLKIT_VERSION}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# bash 3.2 compatible (macOS /bin/bash): no associative arrays.
url_for() {
  case "$1" in
    SRC)       echo "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VERSION}.tar.gz" ;;
    RUN_AMD64) echo "https://download.nvidia.com/XFree86/Linux-x86_64/${VERSION}/NVIDIA-Linux-x86_64-${VERSION}.run" ;;
    RUN_ARM64) echo "https://download.nvidia.com/XFree86/Linux-aarch64/${VERSION}/NVIDIA-Linux-aarch64-${VERSION}.run" ;;
    TOOLKIT)   echo "https://github.com/NVIDIA/nvidia-container-toolkit/archive/refs/tags/${TOOLKIT_VERSION}.tar.gz" ;;
    *) echo "unknown key: $1" >&2; exit 1 ;;
  esac
}

for key in SRC RUN_AMD64 RUN_ARM64 TOOLKIT; do
  url="$(url_for "${key}")"
  echo "==> downloading ${url}"
  curl -fL --retry 3 -o "${tmp}/${key}" "${url}"

  sha256="$(shasum -a 256 "${tmp}/${key}" | awk '{print $1}')"
  sha512="$(shasum -a 512 "${tmp}/${key}" | awk '{print $1}')"

  case "${key}" in
    SRC)       s256_var=NVIDIA_DRIVER_SRC_SHA256; s512_var=NVIDIA_DRIVER_SRC_SHA512 ;;
    RUN_AMD64) s256_var=NVIDIA_RUN_AMD64_SHA256;  s512_var=NVIDIA_RUN_AMD64_SHA512 ;;
    RUN_ARM64) s256_var=NVIDIA_RUN_ARM64_SHA256;  s512_var=NVIDIA_RUN_ARM64_SHA512 ;;
    TOOLKIT)   s256_var=CONTAINER_TOOLKIT_SHA256;   s512_var=CONTAINER_TOOLKIT_SHA512 ;;
  esac

  sed -i.bak \
    -e "s|^${s256_var}:.*|${s256_var}: ${sha256}|" \
    -e "s|^${s512_var}:.*|${s512_var}: ${sha512}|" \
    vars.yaml && rm vars.yaml.bak

  rm -f "${tmp}/${key}"
  echo "==> ${key}: sha256=${sha256}"
done

echo "==> vars.yaml updated for ${VERSION}"
