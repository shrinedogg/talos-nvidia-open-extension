#!/usr/bin/env bash
# Redirect the pkgs checkout's kernel source download to an alternate URL.
#
# Motivation: kernel.org's tarball distribution (cdn.kernel.org and the whole
# rsync mirror network) can drop releases or go down — as observed 2026-07-03,
# when every /pub/linux/kernel/v6.x/ tarball 404'd everywhere. The cgit
# snapshot service on git.kernel.org is separate infrastructure and generates
# tarballs straight from the stable tree's release tags.
#
# The snapshot is .tar.gz (not .xz) with different checksums than the release
# tarball, so this script patches three things in the pkgs checkout:
#   1. the source URL in kernel/prepare/pkg.yaml
#   2. the extract command (tar -xJf -> tar -xf, which auto-detects)
#   3. linux_sha256 / linux_sha512 in the Pkgfile
#
# Usage: patch-kernel-source.sh <pkgs-dir> <url> <sha256> <sha512>
set -euo pipefail

PKGS_DIR="${1:?pkgs checkout dir}"
URL="${2:?kernel source url}"
SHA256="${3:?sha256}"
SHA512="${4:?sha512}"

PREPARE="${PKGS_DIR}/kernel/prepare/pkg.yaml"
PKGFILE="${PKGS_DIR}/Pkgfile"

[[ -f "${PREPARE}" && -f "${PKGFILE}" ]] || {
  echo "error: ${PKGS_DIR} doesn't look like a pkgs checkout" >&2
  exit 1
}

# 1. swap the kernel tarball URL (matches the templated cdn.kernel.org line)
sed -i.bak "s|url: https://cdn.kernel.org/pub/linux/kernel/.*linux-.*\.tar\.xz$|url: ${URL}|" "${PREPARE}"

# 2. auto-detect compression on extract (snapshot is gz, release is xz)
sed -i.bak 's|tar -xJf linux.tar.xz|tar -xf linux.tar.xz|' "${PREPARE}"
rm -f "${PREPARE}.bak"

# 3. re-pin the checksums for the alternate tarball
sed -i.bak \
  -e "s|^  linux_sha256:.*|  linux_sha256: ${SHA256}|" \
  -e "s|^  linux_sha512:.*|  linux_sha512: ${SHA512}|" \
  "${PKGFILE}"
rm -f "${PKGFILE}.bak"

grep -q "${SHA256}" "${PKGFILE}" || { echo "error: checksum patch failed" >&2; exit 1; }
grep -q "url: ${URL}" "${PREPARE}" || { echo "error: URL patch failed" >&2; exit 1; }

echo "==> kernel source redirected to ${URL}"
