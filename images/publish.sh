#!/usr/bin/env bash
# Assemble, tag and sign one multi-platform image from the per-platform
# digests images/build.sh --push recorded.
#
# 1. docker buildx imagetools create: one image index over the platform
#    digests (their SBOM and provenance attestations come along), tagged with
#    every tag docker-bake.hcl gives the target;
# 2. cosign sign --recursive: keyless, with the workflow's GitHub OIDC identity,
#    over the index and every manifest in it;
# 3. cosign verify: the signature is checked against that same identity before
#    the job succeeds.
#
# Usage:
#   images/publish.sh <target>
#
# Environment:
#   IMAGE_PREFIX        registry/owner prefix, e.g. ghcr.io/cnmsql (required)
#   BUILD_ID            the build id the platforms were built with (required)
#   DIGESTS_DIR         where build.sh recorded digests (default: ./digests)
#   SIGNER_IDENTITY     regexp for the signing certificate identity
#                       (default: this repo's build workflow)
#   SIGN                set to 0 to skip signing, e.g. when trying the pipeline
#                       against a local registry (default: 1)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=images/common.sh
. "${here}/common.sh"

t="${1:?usage: $0 <target>}"
: "${IMAGE_PREFIX:?IMAGE_PREFIX must be set}"
: "${BUILD_ID:?BUILD_ID must be the id the platforms were built with}"
DIGESTS_DIR="${DIGESTS_DIR:-${PWD}/digests}"
SIGNER_IDENTITY="${SIGNER_IDENTITY:-^https://github.com/${GITHUB_REPOSITORY:-cnmsql/containers}/\.github/workflows/build\.yml@}"
ISSUER="https://token.actions.githubusercontent.com"

json="$(target_json "$t")"
mapfile -t tags < <(jq -r '.tags[]' <<<"$json")
repo="${tags[0]%:*}"

declare -a sources=()
for f in "${DIGESTS_DIR}/${t}"/*; do
  [ -e "$f" ] || { echo "no digests for ${t} in ${DIGESTS_DIR}" >&2; exit 1; }
  sources+=("${repo}@sha256:$(basename "$f")")
done
want="$(jq -r '.platforms | length' <<<"$json")"
if [ "${#sources[@]}" -ne "${want}" ]; then
  echo "${t}: ${#sources[@]} platform digests, want ${want}" >&2
  exit 1
fi

echo ">> creating ${repo} index from ${sources[*]}"
declare -a tag_args=()
for tag in "${tags[@]}"; do tag_args+=(--tag "${tag}"); done
docker buildx imagetools create "${tag_args[@]}" "${sources[@]}"

digest="$(docker buildx imagetools inspect "${tags[0]}" --format '{{json .Manifest}}' | jq -r .digest)"
if [ "${SIGN:-1}" = 0 ]; then
  echo ">> not signing ${repo}@${digest} (SIGN=0)"
else
  echo ">> signing ${repo}@${digest}"
  cosign sign --yes --recursive "${repo}@${digest}"

  echo ">> verifying ${repo}@${digest}"
  cosign verify "${repo}@${digest}" \
    --certificate-identity-regexp "${SIGNER_IDENTITY}" \
    --certificate-oidc-issuer "${ISSUER}" >/dev/null
fi

echo ">> published ${t}:"
printf '   %s\n' "${tags[@]}"
echo "   ${repo}@${digest}"
