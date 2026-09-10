#!/usr/bin/env bash
# Contract tests for the `imager` Makefile target, via `make -n` (no build):
#
#   * publication: the imager is output to the caller's REGISTRY/USERNAME
#     (this repo's convention), whatever the source of that value
#     (command line or environment);
#   * embedded gendata: Talos bakes REGISTRY/USERNAME into the imager
#     (Dockerfile gendata step), and its default installer profile uses them
#     to locate installer-base. They must stay Sidero's published values
#     (ghcr.io/siderolabs), whatever the caller supplies;
#   * TOOLS_PREFIX: this repo uses it as a namespace (ghcr.io/siderolabs),
#     Talos v1.14.0 uses it as the full tools repository
#     (ghcr.io/siderolabs/tools) and builds FROM ${TOOLS_PREFIX}:${TOOLS}.
#     The target must translate it, both when the default applies and when
#     the caller passes the namespace explicitly.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

talos_version="$(awk '/^TALOS_VERSION \?=/ {print $3}' "${root}/Makefile")"
[[ -n "${talos_version}" ]] || fail "could not read TALOS_VERSION from Makefile"

# Reuse a blobless shallow clone across runs (CI: BUILD_DIR, local: /tmp).
cache_dir="${BUILD_DIR:-/tmp/tnoe-test-caches}"
talos_dir="${cache_dir}/talos-${talos_version}"
if [ ! -d "${talos_dir}/.git" ]; then
  mkdir -p "${cache_dir}"
  git clone --quiet --filter=blob:none --depth 1 --branch "${talos_version}" \
    https://github.com/siderolabs/talos "${talos_dir}" || fail "cloning talos ${talos_version}"
fi
git -C "${talos_dir}" fetch --quiet --depth 1 origin tag "${talos_version}"
git -C "${talos_dir}" -c advice.detachedHead=false checkout -q "${talos_version}"

# make -n imager, with the caller's registry/username where noted.
out() { make -C "${root}" -n imager TALOS_DIR="${talos_dir}" KERNEL_IMAGE=example.test/kern:1 REGISTRY=docker.io USERNAME=shrinedogg "$@" 2>&1; }
out_env() { env REGISTRY="${1}" USERNAME="${2}" make -C "${root}" -n imager TALOS_DIR="${talos_dir}" KERNEL_IMAGE=example.test/kern:1 2>&1; }

want_arg() { # <label> <expected substring> <make output on stdin>
  { cat | grep -qF -- "$2" ; } || fail "$1: missing [$2]"
}

# Case A: default caller values -> published under docker.io/shrinedogg,
# gendata embedded as Sidero's, tools image is the full repository.
a="$(out)"
echo "${a}" | want_arg "A: output name" "--output type=image,name=docker.io/shrinedogg/imager:${talos_version},"
echo "${a}" | want_arg "A: embedded REGISTRY" "--build-arg=REGISTRY=ghcr.io "
echo "${a}" | want_arg "A: embedded USERNAME" "--build-arg=USERNAME=siderolabs "
echo "${a}" | want_arg "A: PKG_KERNEL" "--build-arg=PKG_KERNEL=example.test/kern:1 "
bad="$(grep -oE -- '--build-arg=TOOLS_PREFIX=[^ ]*' <<< "${a}" | grep -vF -- "--build-arg=TOOLS_PREFIX=ghcr.io/siderolabs/tools" || true)"
[[ -z "${bad}" ]] || fail "A: TOOLS_PREFIX not the full tools repository: ${bad}"

# Case B: caller passes this repo's own namespace default explicitly.
b="$(out TOOLS_PREFIX=ghcr.io/siderolabs)"
bad="$(grep -oE -- '--build-arg=TOOLS_PREFIX=[^ ]*' <<< "${b}" | grep -vF -- "--build-arg=TOOLS_PREFIX=ghcr.io/siderolabs/tools" || true)"
[[ -z "${bad}" ]] || fail "B: TOOLS_PREFIX not the full tools repository: ${bad}"
echo "${b}" | want_arg "B: output name" "--output type=image,name=docker.io/shrinedogg/imager:${talos_version},"

# Case C: caller publishes elsewhere -> output follows the caller, gendata
# still Sidero's.
c="$(out REGISTRY=example.com/ns USERNAME=me)"
echo "${c}" | want_arg "C: output name follows caller" "--output type=image,name=example.com/ns/me/imager:${talos_version},"
echo "${c}" | want_arg "C: embedded REGISTRY" "--build-arg=REGISTRY=ghcr.io "
echo "${c}" | want_arg "C: embedded USERNAME" "--build-arg=USERNAME=siderolabs "

# Case D: values only in the environment (CI job-level env) must not leak
# into the embedded gendata.
d="$(out_env env-leak env-leak)"
echo "${d}" | want_arg "D: output name follows env" "--output type=image,name=env-leak/env-leak/imager:${talos_version},"
echo "${d}" | want_arg "D: embedded REGISTRY" "--build-arg=REGISTRY=ghcr.io "
echo "${d}" | want_arg "D: embedded USERNAME" "--build-arg=USERNAME=siderolabs "

echo "PASS: imager-args"
