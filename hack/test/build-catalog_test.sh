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
# Path provenance: the two fakes emit byte-identical stdout (the fixture
# stream the script pipes on), so the suite tells which path served a call
# via a marker: each fake records its path word in $tmp/crane-path ("binary"
# for the fake crane, "container" for the fake docker), through the shared
# fixture helper, which takes the marker as its last argument. run_cases
# removes the marker before each case and asserts the expected value after,
# so "both paths are proven" is literal: the binary case must leave "binary"
# and the container-fallback case must leave "container"; a mutant that
# drops the binary preference (crane() always container) fails the binary
# case's marker assertion.
#
# Hermetic fallback: the container-fallback case runs the script with a
# constructed minimal PATH (hermetic_container_path): the fake-docker dir
# first, then a private toolbin with exec wrappers for the tools the
# script + fakes need. The caller's PATH is excluded entirely, and no
# directory of any required tool is on the fallback PATH, so a crane
# co-located with
# those tools (the norm: /usr/local/bin alongside python3, Homebrew
# prefixes) is invisible too. The wrappers exec the caller-side resolved
# paths, so an interpreter prefix (a venv, a pyenv shim) survives the
# hermetic PATH. On a machine with a real crane (the dev
# workflow's make target needs a bare `crane` on PATH, Makefile:259) the
# script's `command -v crane` finds nothing and the container fallback is
# actually taken, without hitting any registry.
#
# Mutation proof: the suite honors BUILD_CATALOG_SCRIPT (default
# ${here}/../build-catalog.sh); point it at a sed-mutated copy of the
# script (crane() always container) and the binary case must FAIL.
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
# BUILD_CATALOG_SCRIPT override (mutation proof): point the suite at a
# mutated copy of the script (e.g. crane() always container); default is the
# real one.
script="${BUILD_CATALOG_SCRIPT:-${here}/../build-catalog.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The script's sanity step needs python3+yaml. The check is representative
# of the container-fallback case as well: that case's toolbin python3 is
# an exec wrapper around this same caller-side interpreter, so both see
# the same interpreter and prefix (a venv stays a venv).
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
#   .crane-fixture export ghcr.io/siderolabs/extensions:<ver> <marker> -> catalog tar
#   .crane-fixture export <extension-ref> <marker>                     -> manifest tar
#   .crane-fixture digest <ref> <marker>                               -> sha256:<hash>
# The trailing <marker> ("binary" / "container") is written to
# $CRANE_PATH_MARKER so the suite can assert which path actually served the
# call; stdout stays the clean fixture stream.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/.crane-fixture" <<'EOF'
#!/usr/bin/env bash
# $1 subcommand, $2 ref, $3 path marker.
printf '%s\n' "$3" > "${CRANE_PATH_MARKER:?}"
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
# Records the "container" path marker for the suite; stdout stays the
# fixture stream.
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
# Fake docker for build-catalog tests.
[ "\$1" = "run" ] || exit 97
[ "\$2" = "--rm" ] || exit 98
[ "\$4" = "export" ] || [ "\$4" = "digest" ] || exit 99
CRANE_FIXTURE_DIR="${tmp}" CRANE_PATH_MARKER="${tmp}/crane-path" exec bash "$tmp/bin/.crane-fixture" "\$4" "\$5" container
EOF
chmod +x "$tmp/bin/docker"

# Fake crane binary: what imjasonh/setup-crane puts on PATH in CI.
# Records the "binary" path marker for the suite; stdout stays the
# fixture stream.
cat > "$tmp/bin/crane" <<EOF
#!/usr/bin/env bash
# Fake crane for build-catalog tests.
[ "\$1" = "export" ] || [ "\$1" = "digest" ] || exit 99
CRANE_FIXTURE_DIR="${tmp}" CRANE_PATH_MARKER="${tmp}/crane-path" exec bash "$tmp/bin/.crane-fixture" "\$1" "\$2" binary
EOF
chmod +x "$tmp/bin/crane"

# Fallback dir: the fake docker, run FIRST on the constructed minimal PATH
# (hermetic_container_path) — NOT on the caller's PATH: carrying the
# caller's PATH would keep an outer crane (real or fake) visible to the
# script's `command -v crane`, and the "fallback" case would silently take
# the binary path against a live registry.
mkdir -p "$tmp/bin-container"
cp "$tmp/bin/docker" "$tmp/bin-container/docker"

# Constructed minimal PATH for the container-fallback case: the fake-docker
# dir first, then a private toolbin holding an exec wrapper for each tool
# the script + fakes invoke. Each wrapper execs the caller-side resolved
# absolute path, so argv[0] carries the real path: an interpreter prefix
# (a venv's bin, a pyenv shim dir) survives — a symlink in the toolbin
# would drop it, because CPython resolves the venv from the argv[0]
# directory and would fall back to the base prefix. The caller's PATH is
# deliberately excluded, and no required-tool directory is on this PATH,
# so a crane co-located with any of those tools is invisible to the
# script's `command -v crane` and it must take the container fallback.
# The tool list covers every external command the script or fakes run:
# python3 tar grep sed awk openssl bash env cat mktemp rm sh (shebangs,
# the sanity and digest pipeline, --out) plus wc tr cp mkdir (line
# counts, artifact copy).
hermetic_container_path() {
  local tool d
  mkdir -p "$tmp/toolbin"
  for tool in python3 tar grep sed awk openssl bash env cat mktemp rm sh wc tr cp mkdir; do
    d="$(command -v "$tool" 2>/dev/null)" || { fail "hermetic PATH: required tool ${tool} not on caller PATH"; }
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$d" > "$tmp/toolbin/$tool"
    chmod +x "$tmp/toolbin/$tool"
  done
  printf '%s' "$tmp/bin-container:$tmp/toolbin"
}

i915_ours_digest="sha256:$(printf '%s' 'docker.io/example/i915:20260810-v1.14.0' | openssl dgst -sha256 | awk '{print $NF}')"
zfs_ours_digest="sha256:$(printf '%s' 'docker.io/example/zfs:2.4.4-v1.14.0' | openssl dgst -sha256 | awk '{print $NF}')"
custom_digest="sha256:$(printf '%s' 'docker.io/example/custom:v1' | openssl dgst -sha256 | awk '{print $NF}')"

run_binary() { PATH="$tmp/bin:$PATH" "$script" "$@"; }
# The fallback case runs on the hermetic PATH only: the caller's PATH — and
# any crane on it — must be invisible, or this case silently exercises the
# binary path.
run_container() { PATH="$(hermetic_container_path)" "$script" "$@"; }

# Assert the path marker: the fake that served the case's crane calls
# recorded its path word ("binary" / "container") in $tmp/crane-path.
check_marker() {
  local want="$1" label="$2" desc="$3"
  local got="<none>"
  if [[ -f "$tmp/crane-path" ]]; then got="$(<"$tmp/crane-path")"; fi
  [[ "$got" == "$want" ]] || fail "${label}: ${desc}: path marker expected ${want}, got ${got}"
}

run_cases() {
  local label="$1"
  local run="$2"
  local expect_marker="$3"

  # --- case 1: rebuilt-only, single name (was: 'i915' with quotes) -----------
  rm -f "$tmp/crane-path"
  out1="$tmp/out1-${label}"
  "$run" --talos-version v1.14.0 \
      --rebuilt i915 --rebuilt-namespace docker.io/example \
      --out "$out1" > /dev/null || fail "${label}: rebuilt-only single: nonzero exit"
  check_marker "$expect_marker" "$label" "rebuilt-only single"
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
  rm -f "$tmp/crane-path"
  out2="$tmp/out2-${label}"
  "$run" --talos-version v1.14.0 \
      --rebuilt i915 --rebuilt zfs --rebuilt-namespace docker.io/example \
      --out "$out2" > /dev/null || fail "${label}: rebuilt-only multi: nonzero exit"
  check_marker "$expect_marker" "$label" "rebuilt-only multi"
  grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out2/image-digests" \
    || fail "${label}: rebuilt-only multi: i915 line not replaced (got: $(grep i915 "$out2/image-digests" || true))"
  grep -qF "ghcr.io/siderolabs/zfs:2.4.4-v1.14.0@${zfs_ours_digest}" "$out2/image-digests" \
    || fail "${label}: rebuilt-only multi: zfs line not replaced (got: $(grep zfs "$out2/image-digests" || true))"
  [[ "$(wc -l < "$out2/mirror-overrides.txt" | tr -d ' ')" == "2" ]] \
    || fail "${label}: rebuilt-only multi: expected 2 override lines, got: $(cat "$out2/mirror-overrides.txt")"

  # --- case 3: unknown rebuilt name still fails cleanly -----------------------
  rm -f "$tmp/crane-path"
  if "$run" --talos-version v1.14.0 --rebuilt nosuchext --rebuilt-namespace docker.io/example --out "$tmp/out3-${label}" > /dev/null 2> "$tmp/err3-${label}"; then
    fail "${label}: unknown rebuilt name: expected failure"
  fi
  grep -qF "error: nosuchext is not in the official v1.14.0 catalog" "$tmp/err3-${label}" \
    || fail "${label}: unknown rebuilt name: wrong error: $(cat "$tmp/err3-${label}")"
  check_marker "$expect_marker" "$label" "unknown rebuilt name"

  # --- case 4: --extension path (non-empty EXTENSIONS loop) -------------------
  rm -f "$tmp/crane-path"
  out4="$tmp/out4-${label}"
  "$run" --talos-version v1.14.0 \
      --extension docker.io/example/custom:v1 \
      --rebuilt i915 --rebuilt-namespace docker.io/example \
      --out "$out4" > /dev/null || fail "${label}: extension+rebuilt: nonzero exit"
  check_marker "$expect_marker" "$label" "extension+rebuilt"
  grep -qF "docker.io/example/custom:v1@${custom_digest}" "$out4/image-digests" \
    || fail "${label}: extension+rebuilt: custom extension line missing"
  grep -qF "author: Example" "$out4/descriptions.yaml" \
    || fail "${label}: extension+rebuilt: custom extension description missing"
  grep -qF "ghcr.io/siderolabs/i915:20260810-v1.14.0@${i915_ours_digest}" "$out4/image-digests" \
    || fail "${label}: extension+rebuilt: i915 line not replaced"
}

# The script prefers a PATH crane binary, so run the binary path first (fake
# crane on PATH, first on it, so it wins over any outer crane), then the
# container fallback (fake docker first on the hermetic PATH, caller's PATH
# excluded). The expected marker per label proves the path actually taken.
run_cases binary run_binary binary
run_cases container-fallback run_container container

echo "PASS: build-catalog (binary + container fallback)"
