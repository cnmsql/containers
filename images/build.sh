#!/usr/bin/env bash
# Build, check and (optionally) push instance images for one platform.
#
# Every target is built for a single platform, loaded into the local image
# store and checked before anything is pushed:
#
#   1. check-tools.sh   every binary the instance manager runs is present;
#   2. version check    the server reports the version pinned in docker-bake.hcl;
#   3. smoke.sh         init, write, physical backup, prepare, restore, read.
#
# With --push the same target is then pushed by digest (no tags) with an SBOM
# and max-mode provenance attached, and the digest is written to
# $DIGESTS_DIR/<target>/. images/publish.sh later assembles the per-platform
# digests into the tagged multi-platform image and signs it.
#
# Usage:
#   images/build.sh [--platform linux/arm64] [--push] <target|group>...
#   images/build.sh mysql-8-4-bookworm        # one image, native platform
#   images/build.sh mariadb                   # every MariaDB image
#
# Environment:
#   IMAGE_PREFIX   registry/owner prefix, e.g. ghcr.io/cnmsql (required to push)
#   BUILD_ID       build id for the immutable tag (default: now, UTC)
#   DIGESTS_DIR    where --push records digests (default: ./digests)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=images/common.sh
. "${here}/common.sh"

platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"
push=0
declare -a selected=()
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    --platform=*) platform="${1#*=}"; shift ;;
    --push) push=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) selected+=("$1"); shift ;;
  esac
done
[ ${#selected[@]} -gt 0 ] || selected=(default)
if [ "${push}" = 1 ] && [ -z "${IMAGE_PREFIX:-}" ]; then
  echo "IMAGE_PREFIX must be set to push" >&2
  exit 2
fi
DIGESTS_DIR="${DIGESTS_DIR:-${PWD}/digests}"
# Pin the build id for the whole run so both builds of a target agree.
export BUILD_ID="${BUILD_ID:-$(date -u +%Y%m%d%H%M)}"

# Runs under `|| rc=1`, which disables set -e: every step returns explicitly.
build_one() {
  local t="$1" json flavor server platforms fp local_ref
  json="$(target_json "$t")"
  flavor="$(label "$json" co.cnmsql.image.flavor)"
  server="$(label "$json" co.cnmsql.image.server-version)"
  platforms="$(jq -r '.platforms | join(" ")' <<<"$json")"
  if [[ " ${platforms} " != *" ${platform} "* ]]; then
    echo ">> skipping ${t}: not built for ${platform} (${platforms})"
    return 0
  fi
  fp="$(inputs "$t")"
  local_ref="cnmsql-build/${t}:${platform//\//-}"

  echo ">> building ${t} ${server} for ${platform} (inputs ${fp})"
  docker buildx bake -f "${repo_root}/docker-bake.hcl" "$t" --load \
    --set "${t}.platform=${platform}" \
    --set "${t}.tags=${local_ref}" \
    --set "${t}.labels.co.cnmsql.image.inputs=${fp}" || return 1

  "${here}/check-tools.sh" "${local_ref}" "$(tools_file "${flavor}")" || return 1

  local bin reported
  bin="$(server_binary "${flavor}")"
  reported="$(docker run --rm --network none --entrypoint "${bin}" "${local_ref}" --version)" || return 1
  echo ">> ${reported}"
  if ! grep -qE "Ver ${server//./\\.}[-_ ]" <<<"${reported}"; then
    echo "!! ${bin} does not report the pinned version ${server}" >&2
    return 1
  fi

  "${here}/smoke.sh" "${local_ref}" "${flavor}" || return 1

  if [ "${push}" = 1 ]; then
    local repo meta digest
    repo="$(jq -r '.tags[0] | sub(":[^:/]+$"; "")' <<<"$json")"
    meta="$(mktemp)"
    echo ">> pushing ${t} for ${platform} to ${repo} by digest"
    # Same builder, same inputs: every layer comes from the build just tested.
    docker buildx bake -f "${repo_root}/docker-bake.hcl" "$t" \
      --metadata-file "${meta}" \
      --set "${t}.platform=${platform}" \
      --set "${t}.tags=${repo}" \
      --set "${t}.labels.co.cnmsql.image.inputs=${fp}" \
      --set "${t}.attest=type=provenance,mode=max" \
      --set "${t}.attest=type=sbom" \
      --set "${t}.output=type=image,push-by-digest=true,name-canonical=true,push=true" || return 1
    digest="$(jq -r --arg t "$t" '.[$t]["containerimage.digest"]' "${meta}")"
    rm -f "${meta}"
    mkdir -p "${DIGESTS_DIR}/${t}"
    touch "${DIGESTS_DIR}/${t}/${digest#sha256:}"
    echo ">> pushed ${repo}@${digest}"
  fi
}

rc=0
for sel in "${selected[@]}"; do
  for t in $(bake_targets "${sel}"); do
    build_one "$t" || { echo "!! ${t} failed" >&2; rc=1; }
  done
done
exit "${rc}"
