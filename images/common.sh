#!/usr/bin/env bash
# Shared helpers for the image scripts. Everything is read from the resolved
# bake definition (docker-bake.hcl), so the scripts never keep their own copy of
# versions, tags or labels.
#
# Needs: docker buildx, jq. Sourced, not executed.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# bake_print <target|group>...: the resolved bake definition as JSON.
bake_print() {
  docker buildx bake -f "${repo_root}/docker-bake.hcl" --print "$@" 2>/dev/null
}

# bake_targets [group]: the target names in a group (default: every image).
bake_targets() {
  bake_print "${1:-default}" | jq -r '.target | keys[]'
}

# target_json <target>: one resolved target.
target_json() {
  bake_print "$1" | jq --arg t "$1" '.target[$t]'
}

# label <target-json> <key>
label() {
  jq -r --arg k "$2" '.labels[$k]' <<<"$1"
}

# inputs <target>: fingerprint of everything that decides the image contents:
# the Dockerfile, the files it copies in (keys/), and the resolved build args
# (base digest and pinned package versions) and platforms. Labels, tags and the
# build id are left out on purpose: they change on every build.
inputs() {
  local t="$1" json dockerfile
  json="$(target_json "$t")"
  dockerfile="$(jq -r .dockerfile <<<"$json")"
  {
    jq -S -c '{dockerfile, args, platforms}' <<<"$json"
    cd "${repo_root}" && sha256sum "${dockerfile}" keys/*
  } | sha256sum | awk '{print "sha256:" $1}'
}

# tools_file <flavor>
tools_file() {
  case "$1" in
    mysql) echo "${repo_root}/images/required-tools.txt" ;;
    mariadb) echo "${repo_root}/images/mariadb-required-tools.txt" ;;
    *) echo "unknown flavor $1" >&2; return 1 ;;
  esac
}

# server_binary <flavor>
server_binary() {
  case "$1" in
    mysql) echo mysqld ;;
    mariadb) echo mariadbd ;;
    *) echo "unknown flavor $1" >&2; return 1 ;;
  esac
}

# Extra skopeo flags, e.g. SKOPEO_OPTS=--tls-verify=false for a local registry.
read -r -a skopeo_opts <<<"${SKOPEO_OPTS:-}"

# published_labels <image-ref>: config labels of a published image as JSON, or
# nothing when the reference does not exist (or the registry is unreachable).
published_labels() {
  skopeo inspect "${skopeo_opts[@]}" --no-tags "docker://$1" 2>/dev/null | jq -c '.Labels // {}' || true
}

# published_digest <image-ref>: digest of the manifest (or index) at ref.
published_digest() {
  echo "sha256:$(skopeo inspect "${skopeo_opts[@]}" --raw "docker://$1" | sha256sum | cut -d' ' -f1)"
}
