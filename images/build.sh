#!/usr/bin/env bash
# Build the cnmsql slim instance image(s) from images/versions.json.
#
# Tagging: <MYSQL_VERSION>-<PATCH_VERSION> (e.g., 8.0-1, 8.0-2, 8.4-1)
# The patch version is auto-incremented by querying the target registry for
# existing tags. Additionally, a bare <MYSQL_VERSION> moving tag (e.g., 8.0)
# points to the latest-patch image.
#
# Usage:
#   images/build.sh                         # build every version, auto-detect patch
#   images/build.sh 8.0 8.4                 # build only the named versions
#   images/build.sh 8.0 --patch=5           # force patch version 5 for 8.0
#
# Environment:
#   REGISTRY            image name prefix   (default: cnmsql-instance)
#   PUSH                set to 1 to push
#   PATCH_VERSION       manual patch override (applies to all versions being built)
#   COMMIT_TAG          if set, tag as <MYSQL_VERSION>-<COMMIT_TAG> (e.g. a commit
#                       hash) instead of the auto-incremented patch, and skip the
#                       moving <MYSQL_VERSION> tag. Used for non-release builds.
#   GH_TOKEN            GitHub token for registry tag lookup (CI)
#   CONTAINER_TOOL                          (default: docker)
#
# Auto-detection strategies (tried in order):
#   1. GitHub Packages API   — if GH_TOKEN is set, queries GHCR tags
#   2. crane                 — if the go-containerregistry/crane image is reachable
#   3. Manual override       — PATCH_VERSION env var or --patch=N flag required
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/.." && pwd)"
versions_json="${here}/versions.json"

REGISTRY="${REGISTRY:-cnmsql-instance}"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"
PATCH_VERSION="${PATCH_VERSION:-}"

# Shared patch-version auto-detection (resolve_patch and friends).
# shellcheck source=images/lib.sh
. "${here}/lib.sh"

# Print "version base ps pxb pxbPackage component" for each requested version.
select_versions() {
  python3 - "$versions_json" "$@" <<'PY'
import json, sys
path, *want = sys.argv[1], *sys.argv[2:]
with open(path) as fh:
    rows = json.load(fh)
want = set(want)
for r in rows:
    if want and r["version"] not in want:
        continue
    print(r["version"], r["base"], r["ps"], r["pxb"], r["pxbPackage"], r.get("component", "release"))
PY
}

build_one() {
  local version="$1" base="$2" ps="$3" pxb="$4" pxbPkg="$5" component="$6"

  # Release builds use an auto-incremented patch plus a moving <version> tag.
  # Non-release builds (COMMIT_TAG set) use <version>-<commit-hash> only.
  local versioned_tag latest_tag=""
  if [ -n "${COMMIT_TAG:-}" ]; then
    versioned_tag="${REGISTRY}:${version}-${COMMIT_TAG}"
    echo ">> building ${versioned_tag} (base=${base} ps=${ps} pxb=${pxb} component=${component})"
  else
    local patch
    patch="$(resolve_patch "${REGISTRY}" "${version}")"
    versioned_tag="${REGISTRY}:${version}-${patch}"
    latest_tag="${REGISTRY}:${version}"
    echo ">> building ${versioned_tag} (base=${base} ps=${ps} pxb=${pxb} patch=${patch} component=${component})"
  fi

  "${CONTAINER_TOOL}" build \
    -f "${repo_root}/Dockerfile.instance" \
    --build-arg "BASE_IMAGE=${base}" \
    --build-arg "PS_REPO=${ps}" \
    --build-arg "PXB_REPO=${pxb}" \
    --build-arg "PXB_PACKAGE=${pxbPkg}" \
    --build-arg "REPO_COMPONENT=${component}" \
    -t "${versioned_tag}" \
    "${repo_root}"

  # Fail before tagging or pushing if a tool the instance manager runs is gone.
  # Explicit return: build_one runs under `|| rc=1`, which disables set -e.
  "${here}/check-tools.sh" "${versioned_tag}" "${here}/required-tools.txt" || return 1

  # Also tag with the bare version (moving tag pointing to latest patch).
  if [ -n "${latest_tag}" ]; then
    "${CONTAINER_TOOL}" tag "${versioned_tag}" "${latest_tag}"
  fi

  if [ "${PUSH:-}" = "1" ]; then
    echo ">> pushing ${versioned_tag}"
    "${CONTAINER_TOOL}" push "${versioned_tag}"
    if [ -n "${latest_tag}" ]; then
      echo ">> pushing ${latest_tag}"
      "${CONTAINER_TOOL}" push "${latest_tag}"
    fi
  fi
}

# Parse --patch=N arguments out of the positional args before feeding them to
# select_versions. Multiple --patch flags apply counter-intuitively to the NEXT
# version, so reposition them: --patch=N should precede the version it belongs to.
declare -a versions=()
while [ $# -gt 0 ]; do
  case "$1" in
    --patch=*)
      PATCH_VERSION="${1#*=}"
      shift
      ;;
    --patch)
      PATCH_VERSION="$2"
      shift 2
      ;;
    *)
      versions+=("$1")
      shift
      ;;
  esac
done

rc=0
while read -r version base ps pxb pxbPkg component; do
  [ -z "${version}" ] && continue
  build_one "${version}" "${base}" "${ps}" "${pxb}" "${pxbPkg}" "${component}" || rc=1
done < <(select_versions "${versions[@]}")
exit "${rc}"
