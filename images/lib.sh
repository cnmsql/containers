#!/usr/bin/env bash
# Shared helpers for the cnmsql image build scripts (build.sh, build-mariadb.sh).
#
# The only non-trivial thing worth sharing is patch-version auto-detection:
# given a target registry repo and a base version (e.g. "8.0" or "11.4"), figure
# out the next <version>-<N> patch number by inspecting the tags already present
# in the registry.
#
# Consumers are expected to have set (or left unset) these globals before
# sourcing:
#   CONTAINER_TOOL   container CLI          (default: docker)
#   PATCH_VERSION    manual patch override  (optional)
#   GH_TOKEN         GitHub token for GHCR tag lookup (optional)

CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"

# ---------------------------------------------------------------------------
# Patch auto-detection: query the registry for existing <version>-<N> tags
# and return N+1.
# ---------------------------------------------------------------------------

next_patch_via_ghcr_api() {
  local repo="$1" base_version="$2"
  # repo example: ghcr.io/cnmsql/cnmsql-instance
  local registry="${repo%%/*}"
  local rest="${repo#*/}"  # owner/package
  local owner="${rest%%/*}"
  local package="${rest#*/}"

  local url="https://api.${registry}/orgs/${owner}/packages/container/${package}/versions?package_type=container&per_page=100"
  local tags
  tags="$(curl -fsSL -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                -H "Authorization: Bearer ${GH_TOKEN}" \
                "${url}" 2>/dev/null || true)"

  if [ -z "${tags}" ]; then
    echo ""
    return
  fi

  # Extract metadata.container.tags[] arrays and filter for <version>-<N>
  local max=0
  local pattern="${base_version}-"
  while IFS= read -r tag; do
    tag="${tag//\"/}"
    if [[ "${tag}" == "${pattern}"* ]]; then
      local num="${tag#${pattern}}"
      if [[ "${num}" =~ ^[0-9]+$ ]] && [ "${num}" -gt "${max}" ]; then
        max="${num}"
      fi
    fi
  done < <(echo "${tags}" | jq -r '.[].metadata.container.tags[]?' 2>/dev/null || true)

  echo "$((max + 1))"
}

next_patch_via_crane() {
  local repo="$1" base_version="$2"
  local tags
  tags="$("${CONTAINER_TOOL}" run --rm gcr.io/go-containerregistry/crane:latest \
           ls "${repo}" 2>/dev/null || true)"

  if [ -z "${tags}" ]; then
    echo ""
    return
  fi

  local max=0
  local pattern="${base_version}-"
  while IFS= read -r tag; do
    if [[ "${tag}" == "${pattern}"* ]]; then
      local num="${tag#${pattern}}"
      if [[ "${num}" =~ ^[0-9]+$ ]] && [ "${num}" -gt "${max}" ]; then
        max="${num}"
      fi
    fi
  done <<< "${tags}"

  echo "$((max + 1))"
}

# resolve_patch <repo> <base_version>
# Strategies, in order: explicit override, GHCR API, crane, fallback to 1.
resolve_patch() {
  local repo="$1" base_version="$2"

  # 1. Explicit --patch flag or PATCH_VERSION env var
  if [ -n "${PATCH_VERSION:-}" ]; then
    echo "${PATCH_VERSION}"
    return
  fi

  # 2. GitHub Packages API (for GHCR repos)
  if [ -n "${GH_TOKEN:-}" ]; then
    local patch
    patch="$(next_patch_via_ghcr_api "${repo}" "${base_version}")"
    if [ -n "${patch}" ] && [ "${patch}" -gt 0 ] 2>/dev/null; then
      echo "${patch}"
      return
    fi
  fi

  # 3. crane (generic OCI registry)
  local patch
  patch="$(next_patch_via_crane "${repo}" "${base_version}")"
  if [ -n "${patch}" ] && [ "${patch}" -gt 0 ] 2>/dev/null; then
    echo "${patch}"
    return
  fi

  # 4. Fallback: start at 1
  echo "1"
}
