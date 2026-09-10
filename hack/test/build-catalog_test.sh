#!/usr/bin/env bash
# Tests for hack/build-catalog.sh.
#
# A fake `docker` on PATH serves the two crane calls the script makes:
#   docker run --rm <crane> export ghcr.io/siderolabs/extensions:<ver> -
#     -> tar with the fixture image-digests and descriptions.yaml
#   docker run --rm <crane> export <extension-ref> -
#     -> tar with a fixture manifest.yaml
#   docker run --rm <crane> digest <ref>
#     -> sha256 of the ref (deterministic, no registry needed)
#
# Regression coverage (review of custom-imager PR):
#   * --rebuilt with one name and with several names: names must reach the
#     catalog lookup without extra quote characters (the committed
#     "${REBUILT[@]+'${REBUILT[@]}'}" expansion produced 'i915' / 'i915 / zfs').
#   * rebuilt-only mode (no --extension) must produce the --out artifacts;
#     previously the empty EXTENSIONS array tripped nounset on bash 3.2 and
#     the script died with no output files.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/../build-catalog.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The script's sanity step needs python3+yaml.
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: python3+yaml not available"; exit 0; }

# --- fixture catalog ---------------------------------------------------------
# Mirror the real v1.14.0 catalog shape: one line per official extension.
mkdir -p "$tmp/catalog"
cat > "$tmp/catalog/image-digests" <<'EOF'
ghcr.io/siderolabs/etcd:v3.6.10@sha256:0000000000000000000000000000000000000000000000000000000000000000
ghcr.io/siderolabs/i915:20260810-v1.14.0@sha256:1111111111111111111111111111111111111111111111111111111111111111
ghcr.io/siderolabs/zfs:2.4.4-v1.14.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
ghcr.io/siderolabs/kangaroo:latest@sha256:3333333333333333333333333333333333333333333333333333333333333333
EOF
cat > "$tmp/catalog/descriptions.yaml" <<'EOF'
ghcr.io/siderolabs/etcd:v3.6.10@sha256:0000000000000000000000000000000000000000000000000000000000000000:
  author: Sidero Labs
  description: |
    etcd
ghcr.io/siderolabs/i915:20260810-v1.14.0@sha256:1111111111111111111111111111111111111111111111111111111111111111:
  author: Sidero Labs
  description: |
    i915 kernel module
ghcr.io/siderolabs/zfs:2.4.4-v1.14.0@sha256:2222222222222222222222222222222222222222222222222222222222222222:
  author: Sidero Labs
  description: |
    zfs kernel module
ghcr.io/siderolabs/kangaroo:latest@sha256:3333333333333333333333333333333333333333333333333333333333333333:
  author: Sidero Labs
  description: |
    kangaroo
EOF
tar -C "$tmp/catalog" -cf "$tmp/catalog.tar" image-digests descriptions.yaml

# fixture manifest for the --extension path
mkdir -p "$tmp/ext"
cat > "$tmp/ext/manifest.yaml" <<'EOF'
metadata:
  author: Example
  description: |
    A test extension.
EOF
tar -C "$tmp/ext" -cf "$tmp/ext.tar" manifest.yaml

# --- fake docker -------------------------------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
# Fake docker for build-catalog tests.
[ "\$1" = "run" ] || exit 97
[ "\$2" = "--rm" ] || exit 98
[ "\$4" = "export" ] || [ "\$4" = "digest" ] || exit 99
if [ "\$4" = "export" ]; then
  if [ "\$5" = "ghcr.io/siderolabs/extensions:v1.14.0" ]; then
    cat "${tmp}/catalog.tar"
  else
    cat "${tmp}/ext.tar"
  fi
  exit 0
fi
# digest: deterministic per ref
printf '%s' "\$5" | openssl dgst -sha256 | awk '{print \$NF}' | sed 's/^/sha256:/'
EOF
chmod +x "$tmp/bin/docker"

i915_ours_digest="sha256:$(printf '%s' 'docker.io/example/i915:20260810-v1.14.0' | openssl dgst -sha256 | awk '{print $NF}')"
zfs_ours_digest="sha256:$(printf '%s' 'docker.io/example/zfs:2.4.4-v1.14.0' | openssl dgst -sha256 | awk '{print $NF}')"
custom_digest="sha256:$(printf '%s' 'docker.io/example/custom:v1' | openssl dgst -sha256 | awk '{print $NF}')"

run() { PATH="$tmp/bin:$PATH" "$script" "$@"; }

# --- case 1: rebuilt-only, single name (was: 'i915' with quotes) -------------
out1="$tmp/out1"
run --talos-version v1.14.0 \
    --rebuilt i915 --rebuilt-namespace docker.io/example \
    --out "$out1" > /dev/null || fail "rebuilt-only single: nonzero exit"
[[ -f "$out1/image-digests" ]] || fail "rebuilt-only single: image-digests not written"
[[ -f "$out1/descriptions.yaml" ]] || fail "rebuilt-only single: descriptions.yaml not written"
[[ -f "$out1/mirror-overrides.txt" ]] || fail "rebuilt-only single: mirror-overrides.txt not written"
grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out1/image-digests" \
  || fail "rebuilt-only single: i915 line not replaced (got: $(grep i915 "$out1/image-digests" || true))"
grep -qF "ghcr.io/siderolabs/zfs:2.4.4-v1.14.0@sha256:2222222222222222222222222222222222222222222222222222222222222222" "$out1/image-digests" \
  || fail "rebuilt-only single: zfs line must be untouched"
grep -qF "docker.io/example/i915:20260810-v1.14.0@${i915_ours_digest} siderolabs/i915:20260810-v1.14.0" "$out1/mirror-overrides.txt" \
  || fail "rebuilt-only single: mirror-overrides.txt wrong"
grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}:" "$out1/descriptions.yaml" \
  || fail "rebuilt-only single: descriptions.yaml key not rewritten"

# --- case 2: rebuilt-only, several names (was: 'i915 / zfs') ------------------
out2="$tmp/out2"
run --talos-version v1.14.0 \
    --rebuilt i915 --rebuilt zfs --rebuilt-namespace docker.io/example \
    --out "$out2" > /dev/null || fail "rebuilt-only multi: nonzero exit"
grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out2/image-digests" \
  || fail "rebuilt-only multi: i915 line not replaced (got: $(grep i915 "$out2/image-digests" || true))"
grep -qF "ghcr.io/siderolabs/zfs:2.4.4-v1.14.0@${zfs_ours_digest}" "$out2/image-digests" \
  || fail "rebuilt-only multi: zfs line not replaced (got: $(grep zfs "$out2/image-digests" || true))"
[[ "$(wc -l < "$out2/mirror-overrides.txt" | tr -d ' ')" == "2" ]] \
  || fail "rebuilt-only multi: expected 2 override lines, got: $(cat "$out2/mirror-overrides.txt")"

# --- case 3: unknown rebuilt name still fails cleanly -------------------------
if run --talos-version v1.14.0 --rebuilt nosuchext --rebuilt-namespace docker.io/example --out "$tmp/out3" > /dev/null 2> "$tmp/err3"; then
  fail "unknown rebuilt name: expected failure"
fi
grep -qF "error: nosuchext is not in the official v1.14.0 catalog" "$tmp/err3" \
  || fail "unknown rebuilt name: wrong error: $(cat "$tmp/err3")"

# --- case 4: --extension path (non-empty EXTENSIONS loop) ----------------------
out4="$tmp/out4"
run --talos-version v1.14.0 \
    --extension docker.io/example/custom:v1 \
    --rebuilt i915 --rebuilt-namespace docker.io/example \
    --out "$out4" > /dev/null || fail "extension+rebuilt: nonzero exit"
grep -qF "docker.io/example/custom:v1@${custom_digest}" "$out4/image-digests" \
  || fail "extension+rebuilt: custom extension line missing"
grep -qF "author: Example" "$out4/descriptions.yaml" \
  || fail "extension+rebuilt: custom extension description missing"
grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out4/image-digests" \
  || fail "extension+rebuilt: i915 line not replaced"

echo "PASS: build-catalog"
