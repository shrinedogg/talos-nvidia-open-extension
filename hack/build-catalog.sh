#!/usr/bin/env bash
# Build (and optionally push) a Talos extensions catalog image for a
# self-hosted Image Factory, containing the official siderolabs catalog plus
# this repo's custom extensions.
#
# Catalog format (verified against ghcr.io/siderolabs/extensions:v1.13.5):
#   image-digests     one fully-qualified ref per line: <repo>:<tag>@sha256:<d>
#   descriptions.yaml mapping keyed by that same ref: {author, description}
#
# The descriptions for the custom extensions are read from each image's own
# /manifest.yaml, mirroring how the upstream catalog is generated.
#
# Usage:
#   build-catalog.sh --talos-version v1.13.5 \
#     --extension docker.io/shrinedogg/nvidia-open-modules:610.43.02-v1.13.5 \
#     --extension docker.io/shrinedogg/nvidia-open-firmware:610.43.02-v1.13.5 \
#     --rebuilt i915 --rebuilt zfs \
#     --rebuilt-namespace docker.io/shrinedogg \
#     --tag docker.io/shrinedogg/extensions:v1.13.5 \
#     [--mirror-namespace registry.internal:5000/siderolabs] [--push] [--out DIR]
#
# --rebuilt NAME (repeatable) requires --rebuilt-namespace NS: the official
# catalog line for ghcr.io/siderolabs/NAME keeps its name and tag but gets the
# digest of NS/NAME:<same tag>, the copy rebuilt against our kernel. The
# replacement pairs are written to mirror-overrides.txt as "<src> <dest-path>"
# lines so the factory mirror step can copy our image under the official path.
#
# --mirror-namespace rewrites the official ghcr.io/siderolabs/ refs to your
# mirror (digests are preserved, so images copied with `crane copy` still
# match). Use it for air-gapped/self-signed factories where ALL images are
# mirrored and cosign-signed with your key (see docs/self-hosted-factory.md).
#
# Requires: docker (crane + buildx are run via containers/daemon), python3+yaml.
set -euo pipefail

CRANE_IMAGE="gcr.io/go-containerregistry/crane:latest"

TALOS_VERSION=""
TAG=""
MIRROR_NS=""
REBUILT_NS=""
PUSH=0
OUT=""
EXTENSIONS=()
REBUILT=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --talos-version) TALOS_VERSION="$2"; shift 2 ;;
    --extension) EXTENSIONS+=("$2"); shift 2 ;;
    --rebuilt) REBUILT+=("$2"); shift 2 ;;
    --rebuilt-namespace) REBUILT_NS="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --mirror-namespace) MIRROR_NS="$2"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${TALOS_VERSION}" ]] || { echo "error: --talos-version required" >&2; exit 2; }
[[ ${#EXTENSIONS[@]} -gt 0 || ${#REBUILT[@]} -gt 0 ]] || { echo "error: at least one --extension or --rebuilt required" >&2; exit 2; }
[[ ${#REBUILT[@]} -eq 0 || -n "${REBUILT_NS}" ]] || { echo "error: --rebuilt requires --rebuilt-namespace" >&2; exit 2; }

crane() { docker run --rm "${CRANE_IMAGE}" "$@"; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "==> fetching official catalog ghcr.io/siderolabs/extensions:${TALOS_VERSION}"
docker run --rm "${CRANE_IMAGE}" export "ghcr.io/siderolabs/extensions:${TALOS_VERSION}" - \
  > "${work}/catalog.tar"
tar -xf "${work}/catalog.tar" -C "${work}" image-digests descriptions.yaml

for ext in "${EXTENSIONS[@]}"; do
  echo "==> resolving ${ext}"
  digest="$(crane digest "${ext}")"
  ref="${ext}@${digest}"

  if grep -qF "${ext}@" "${work}/image-digests"; then
    echo "    already present, skipping"
    continue
  fi

  echo "    manifest metadata"
  docker run --rm "${CRANE_IMAGE}" export "${ext}" - \
    | tar -xO manifest.yaml > "${work}/ext-manifest.yaml"

  author="$(python3 -c "
import sys, yaml
m = yaml.safe_load(open('${work}/ext-manifest.yaml'))
print(m['metadata']['author'])
")"
  # indent the (possibly multi-line) description as a YAML block scalar
  description="$(python3 -c "
import sys, yaml
m = yaml.safe_load(open('${work}/ext-manifest.yaml'))
for line in m['metadata']['description'].strip().splitlines():
    print('    ' + line)
")"

  echo "${ref}" >> "${work}/image-digests"
  {
    echo "${ref}:"
    echo "  author: ${author}"
    echo "  description: |"
    echo "${description}"
  } >> "${work}/descriptions.yaml"
  echo "    added ${ref}"
done

# --rebuilt NAME: the official catalog line for ghcr.io/siderolabs/NAME:<tag>
# keeps its name and tag but gets the digest of ${REBUILT_NS}/NAME:<tag>, the
# copy rebuilt against our kernel. mirror-overrides.txt records "<src> <dest>"
# pairs so the mirror step can copy our image under the official path.
: > "${work}/mirror-overrides.txt"
for name in "${REBUILT[@]+'${REBUILT[@]}'}"; do
  official_line="$(grep -E "^ghcr.io/siderolabs/${name}:[^@]+@sha256:[0-9a-f]{64}$" "${work}/image-digests" || true)"
  [[ -n "${official_line}" ]] || { echo "error: ${name} is not in the official ${TALOS_VERSION} catalog" >&2; exit 1; }
  [[ "$(printf '%s\n' "${official_line}" | wc -l | tr -d ' ')" == 1 ]] || { echo "error: ${name} matches more than one catalog line" >&2; exit 1; }
  official_ref="${official_line%%@*}"
  ext_tag="${official_ref##*:}"
  ours="${REBUILT_NS}/${name}:${ext_tag}"
  echo "==> rebuilt ${name}: ${official_ref} -> digest of ${ours}"
  digest="$(crane digest "${ours}")"
  new_line="${official_ref}@${digest}"
  sed -i.bak "s|^${official_line}$|${new_line}|" "${work}/image-digests"
  sed -i.bak "s|^${official_line}:|${new_line}:|" "${work}/descriptions.yaml"
  rm -f "${work}"/*.bak
  grep -qF "${new_line}" "${work}/image-digests" || { echo "error: replacement failed for ${name}" >&2; exit 1; }
  echo "${ours}@${digest} siderolabs/${name}:${ext_tag}" >> "${work}/mirror-overrides.txt"
done

if [[ -n "${MIRROR_NS}" ]]; then
  echo "==> rewriting ghcr.io/siderolabs/ -> ${MIRROR_NS}/ (digests preserved)"
  sed -i.bak "s|ghcr.io/siderolabs/|${MIRROR_NS}/|g" "${work}/image-digests" "${work}/descriptions.yaml"
  rm -f "${work}"/*.bak
fi

# sanity: every line in image-digests is a valid pinned ref
bad="$(grep -cvE '^[a-z0-9.:/_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' "${work}/image-digests" || true)"
[[ "${bad}" == "0" ]] || { echo "error: malformed entries in image-digests" >&2; exit 1; }
python3 -c "import yaml; yaml.safe_load(open('${work}/descriptions.yaml'))" \
  || { echo "error: merged descriptions.yaml is not valid YAML" >&2; exit 1; }

if [[ -n "${OUT}" ]]; then
  mkdir -p "${OUT}"
  cp "${work}/image-digests" "${work}/descriptions.yaml" "${work}/mirror-overrides.txt" "${OUT}/"
  echo "==> wrote ${OUT}/{image-digests,descriptions.yaml,mirror-overrides.txt}"
fi

if [[ -n "${TAG}" ]]; then
  cat > "${work}/Dockerfile" <<'EOF'
FROM scratch
COPY image-digests /image-digests
COPY descriptions.yaml /descriptions.yaml
EOF
  echo "==> building catalog image ${TAG} (push=${PUSH})"
  if [[ "${PUSH}" == "1" ]]; then
    docker buildx build --provenance=false --push -t "${TAG}" "${work}"
  else
    docker buildx build --provenance=false --load -t "${TAG}" "${work}"
  fi
fi

echo "==> catalog contains $(wc -l < "${work}/image-digests" | tr -d ' ') extensions"
