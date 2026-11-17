#!/usr/bin/env bash
# Tests for hack/build-catalog.sh.
#
# Two fakes on PATH serve the crane calls the script makes, sharing one
# fixture helper ($tmp/bin/.crane-fixture):
#   fake `crane` binary:  crane export <ref> - / crane digest <ref>
#     -> the binary path, as CI gets it from imjasonh/setup-crane
#   fake `docker`:        docker run --rm <crane> export <ref> - / digest <ref>
#     -> the container fallback path
#   export ghcr.io/siderolabs/extensions:<ver> -
#     -> tar with the fixture image-digests and descriptions.yaml
#   export <extension-ref> -
#     -> tar with a fixture manifest.yaml
#   digest <ref>
#     -> sha256 of the ref (deterministic, no registry needed)
#
# The assertions run twice: once with the fake crane binary on PATH (the
# script prefers the binary) and once with the fake docker only (the script
# falls back to the CRANE_IMAGE container), so both paths are proven.
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

# --- fakes -------------------------------------------------------------------
# Shared fixture logic for the crane calls. The fake docker (container path)
# and the fake crane binary (PATH path) both exec it; the fixture tars live
# in $CRANE_FIXTURE_DIR:
#   .crane-fixture export ghcr.io/siderolabs/extensions:<ver> - -> catalog tar
#   .crane-fixture export <extension-ref> -                    -> manifest tar
#   .crane-fixture digest <ref>                                -> sha256:<hash>
mkdir -p "$tmp/bin"
cat > "$tmp/bin/.crane-fixture" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "export" ]; then
  if [ "$2" = "ghcr.io/siderolabs/extensions:v1.14.0" ]; then
    cat "$CRANE_FIXTURE_DIR/catalog.tar"
  else
    cat "$CRANE_FIXTURE_DIR/ext.tar"
  fi
  exit 0
fi
# digest: deterministic per ref
printf '%s' "$2" | openssl dgst -sha256 | awk '{print $NF}' | sed 's/^/sha256:/'
EOF

# Fake docker: the container fallback (docker run --rm <crane-image> ...).
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
# Fake docker for build-catalog tests.
[ "\$1" = "run" ] || exit 97
[ "\$2" = "--rm" ] || exit 98
[ "\$4" = "export" ] || [ "\$4" = "digest" ] || exit 99
CRANE_FIXTURE_DIR="${tmp}" exec bash "$tmp/bin/.crane-fixture" "\$4" "\$5"
EOF
chmod +x "$tmp/bin/docker"

# Fake crane binary: what imjasonh/setup-crane puts on PATH in CI.
cat > "$tmp/bin/crane" <<EOF
#!/usr/bin/env bash
# Fake crane for build-catalog tests.
[ "\$1" = "export" ] || [ "\$1" = "digest" ] || exit 99
CRANE_FIXTURE_DIR="${tmp}" exec bash "$tmp/bin/.crane-fixture" "\$1" "\$2"
EOF
chmod +x "$tmp/bin/crane"

# Fallback dir: fake docker only (no crane), to prove the container path.
mkdir -p "$tmp/bin-container"
cp "$tmp/bin/docker" "$tmp/bin-container/docker"

i915_ours_digest="sha256:$(printf '%s' 'docker.io/example/i915:20260810-v1.14.0' | openssl dgst -sha256 | awk '{print $NF}')"
zfs_ours_digest="sha256:$(printf '%s' 'docker.io/example/zfs:2.4.4-v1.14.0' | openssl dgst -sha256 | awk '{print $NF}')"
custom_digest="sha256:$(printf '%s' 'docker.io/example/custom:v1' | openssl dgst -sha256 | awk '{print $NF}')"

run_binary() { PATH="$tmp/bin:$PATH" "$script" "$@"; }
run_container() { PATH="$tmp/bin-container:$PATH" "$script" "$@"; }

run_cases() {
  local label="$1"
  local run="$2"

  # --- case 1: rebuilt-only, single name (was: 'i915' with quotes) -----------
  out1="$tmp/out1-${label}"
  "$run" --talos-version v1.14.0 \
      --rebuilt i915 --rebuilt-namespace docker.io/example \
      --out "$out1" > /dev/null || fail "${label}: rebuilt-only single: nonzero exit"
  [[ -f "$out1/image-digests" ]] || fail "${label}: rebuilt-only single: image-digests not written"
  [[ -f "$out1/descriptions.yaml" ]] || fail "${label}: rebuilt-only single: descriptions.yaml not written"
  [[ -f "$out1/mirror-overrides.txt" ]] || fail "${label}: rebuilt-only single: mirror-overrides.txt not written"
  grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out1/image-digests" \
    || fail "${label}: rebuilt-only single: i915 line not replaced (got: $(grep i915 "$out1/image-digests" || true))"
  grep -qF "ghcr.io/siderolabs/zfs:2.4.4-v1.14.0@sha256:2222222222222222222222222222222222222222222222222222222222222222" "$out1/image-digests" \
    || fail "${label}: rebuilt-only single: zfs line must be untouched"
  grep -qF "docker.io/example/i915:20260810-v1.14.0@${i915_ours_digest} siderolabs/i915:20260810-v1.14.0" "$out1/mirror-overrides.txt" \
    || fail "${label}: rebuilt-only single: mirror-overrides.txt wrong"
  grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}:" "$out1/descriptions.yaml" \
    || fail "${label}: rebuilt-only single: descriptions.yaml key not rewritten"

  # --- case 2: rebuilt-only, several names (was: 'i915 / zfs') ----------------
  out2="$tmp/out2-${label}"
  "$run" --talos-version v1.14.0 \
      --rebuilt i915 --rebuilt zfs --rebuilt-namespace docker.io/example \
      --out "$out2" > /dev/null || fail "${label}: rebuilt-only multi: nonzero exit"
  grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out2/image-digests" \
    || fail "${label}: rebuilt-only multi: i915 line not replaced (got: $(grep i915 "$out2/image-digests" || true))"
  grep -qF "ghcr.io/siderolabs/zfs:2.4.4-v1.14.0@${zfs_ours_digest}" "$out2/image-digests" \
    || fail "${label}: rebuilt-only multi: zfs line not replaced (got: $(grep zfs "$out2/image-digests" || true))"
  [[ "$(wc -l < "$out2/mirror-overrides.txt" | tr -d ' ')" == "2" ]] \
    || fail "${label}: rebuilt-only multi: expected 2 override lines, got: $(cat "$out2/mirror-overrides.txt")"

  # --- case 3: unknown rebuilt name still fails cleanly -----------------------
  if "$run" --talos-version v1.14.0 --rebuilt nosuchext --rebuilt-namespace docker.io/example --out "$tmp/out3-${label}" > /dev/null 2> "$tmp/err3-${label}"; then
    fail "${label}: unknown rebuilt name: expected failure"
  fi
  grep -qF "error: nosuchext is not in the official v1.14.0 catalog" "$tmp/err3-${label}" \
    || fail "${label}: unknown rebuilt name: wrong error: $(cat "$tmp/err3-${label}")"

  # --- case 4: --extension path (non-empty EXTENSIONS loop) -------------------
  out4="$tmp/out4-${label}"
  "$run" --talos-version v1.14.0 \
      --extension docker.io/example/custom:v1 \
      --rebuilt i915 --rebuilt-namespace docker.io/example \
      --out "$out4" > /dev/null || fail "${label}: extension+rebuilt: nonzero exit"
  grep -qF "docker.io/example/custom:v1@${custom_digest}" "$out4/image-digests" \
    || fail "${label}: extension+rebuilt: custom extension line missing"
  grep -qF "author: Example" "$out4/descriptions.yaml" \
    || fail "${label}: extension+rebuilt: custom extension description missing"
  grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out4/image-digests" \
    || fail "${label}: extension+rebuilt: i915 line not replaced"
}

# The script prefers a PATH crane binary, so run the binary path first (fake
# crane on PATH), then the container fallback (fake docker only on PATH).
run_cases binary run_binary
run_cases container-fallback run_container

echo "PASS: build-catalog (binary + container fallback)"
