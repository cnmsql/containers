#!/usr/bin/env bash
# Build the cnmsql slim MariaDB instance image(s) from images/mariadb-versions.json.
#
# The MariaDB counterpart to build.sh. Tagging, patch auto-increment and the
# moving <version> tag all behave identically (see build.sh for the details);
# the only differences are the versions file, the Dockerfile, and the default
# image name.
#
# Usage:
#   images/build-mariadb.sh                  # build every version, auto-detect patch
#   images/build-mariadb.sh 11.4             # build only the named versions
#   images/build-mariadb.sh 11.4 --patch=5   # force patch version 5 for 11.4
#
# Environment:
#   REGISTRY            image name prefix   (default: cnmsql-mariadb-instance)
#   PUSH                set to 1 to push
#   PATCH_VERSION       manual patch override (applies to all versions being built)
#   COMMIT_TAG          if set, tag as <VERSION>-<COMMIT_TAG> (e.g. a commit hash)
#                       instead of the auto-incremented patch, and skip the moving
#                       <VERSION> tag. Used for non-release builds.
#   GH_TOKEN            GitHub token for registry tag lookup (CI)
#   CONTAINER_TOOL                          (default: docker)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/.." && pwd)"
versions_json="${here}/mariadb-versions.json"

REGISTRY="${REGISTRY:-cnmsql-mariadb-instance}"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"
PATCH_VERSION="${PATCH_VERSION:-}"

# Shared patch-version auto-detection (resolve_patch and friends).
# shellcheck source=images/lib.sh
. "${here}/lib.sh"

# Print "version base mariadbVersion" for each requested version.
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
    print(r["version"], r["base"], r.get("mariadbVersion", r["version"]))
PY
}

build_one() {
  local version="$1" base="$2" mariadb_version="$3"

  # Release builds use an auto-incremented patch plus a moving <version> tag.
  # Non-release builds (COMMIT_TAG set) use <version>-<commit-hash> only.
  local versioned_tag latest_tag=""
  if [ -n "${COMMIT_TAG:-}" ]; then
    versioned_tag="${REGISTRY}:${version}-${COMMIT_TAG}"
    echo ">> building ${versioned_tag} (base=${base} mariadb=${mariadb_version})"
  else
    local patch
    patch="$(resolve_patch "${REGISTRY}" "${version}")"
    versioned_tag="${REGISTRY}:${version}-${patch}"
    latest_tag="${REGISTRY}:${version}"
    echo ">> building ${versioned_tag} (base=${base} mariadb=${mariadb_version} patch=${patch})"
  fi

  "${CONTAINER_TOOL}" build \
    -f "${repo_root}/Dockerfile.mariadb-instance" \
    --build-arg "BASE_IMAGE=${base}" \
    --build-arg "MARIADB_VERSION=${mariadb_version}" \
    -t "${versioned_tag}" \
    "${repo_root}"

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
# select_versions.
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
while read -r version base mariadb_version; do
  [ -z "${version}" ] && continue
  build_one "${version}" "${base}" "${mariadb_version}" || rc=1
done < <(select_versions "${versions[@]}")
exit "${rc}"
