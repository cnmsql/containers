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
# the Dockerfile and its target stage, the files it copies in (keys/, build/),
# and the resolved build args (base digests and pinned package versions) and
# platforms. Labels, tags and the build id are left out on purpose: they change
# on every build.
inputs() {
  local t="$1" json dockerfile
  json="$(target_json "$t")"
  dockerfile="$(jq -r .dockerfile <<<"$json")"
  {
    jq -S -c '{dockerfile, target, args, platforms}' <<<"$json"
    cd "${repo_root}" && sha256sum "${dockerfile}" keys/* build/*
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

# Static BusyBox the checks mount into the image under test. The distroless
# images ship no shell, so every image is tested with the same one; nothing
# from it ends up in an image.
# renovate: datasource=docker
TEST_SHELL_IMAGE="busybox:1.38.0-musl@sha256:ea2b9914a16a4ac1981994af97b318f7c7d4db76b580c56177f08bf76f4a0be8"
test_shell_mount=/.cnmsql-test

# test_shell_dir <platform>: a directory holding BusyBox for platform and a link
# per applet, extracted once.
test_shell_dir() {
  local dir="${TMPDIR:-/tmp}/cnmsql-test-shell-${1//\//-}-${TEST_SHELL_IMAGE##*:}"
  if [ ! -x "${dir}/sh" ]; then
    local id
    rm -rf "${dir}" && mkdir -p "${dir}"
    id="$(${CONTAINER_TOOL:-docker} create --platform "$1" "${TEST_SHELL_IMAGE}" true)" || return 1
    ${CONTAINER_TOOL:-docker} cp "${id}:/bin/busybox" "${dir}/busybox" || return 1
    ${CONTAINER_TOOL:-docker} rm "${id}" >/dev/null
    ${CONTAINER_TOOL:-docker} run --rm --platform "$1" --network none "${TEST_SHELL_IMAGE}" busybox --list |
      while read -r applet; do ln -sf busybox "${dir}/${applet}"; done
  fi
  echo "${dir}"
}

# run_with_shell <image> <arg>...: run BusyBox sh in a throwaway container of
# image, as the image's user and with no network. The image's own PATH comes
# first, so its binaries win over the BusyBox applets.
run_with_shell() {
  local image="$1" platform path dir
  shift
  platform="$(${CONTAINER_TOOL:-docker} image inspect --format '{{.Os}}/{{.Architecture}}' "${image}")" || return 1
  path="$(${CONTAINER_TOOL:-docker} image inspect "${image}" |
    jq -r '.[0].Config.Env // [] | map(select(startswith("PATH=")))[0] // "PATH=/usr/sbin:/usr/bin:/sbin:/bin" | sub("^PATH="; "")')"
  dir="$(test_shell_dir "${platform}")" || return 1
  ${CONTAINER_TOOL:-docker} run --rm -i --network none \
    -v "${dir}:${test_shell_mount}:ro" -e "PATH=${path}:${test_shell_mount}" \
    --entrypoint "${test_shell_mount}/sh" "${image}" "$@"
}
