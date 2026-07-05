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
#     --tag docker.io/shrinedogg/extensions:v1.13.5 \
#     [--mirror-namespace registry.internal:5000/siderolabs] [--push] [--out DIR]
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
PUSH=0
OUT=""
EXTENSIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --talos-version) TALOS_VERSION="$2"; shift 2 ;;
    --extension) EXTENSIONS+=("$2"); shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --mirror-namespace) MIRROR_NS="$2"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${TALOS_VERSION}" ]] || { echo "error: --talos-version required" >&2; exit 2; }
[[ ${#EXTENSIONS[@]} -gt 0 ]] || { echo "error: at least one --extension required" >&2; exit 2; }

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
  cp "${work}/image-digests" "${work}/descriptions.yaml" "${OUT}/"
  echo "==> wrote ${OUT}/image-digests and ${OUT}/descriptions.yaml"
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
