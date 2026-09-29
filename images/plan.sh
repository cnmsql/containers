#!/usr/bin/env bash
# Print the CI matrix: which targets to build, on which runners.
#
# A target is skipped when its published <server>-<distro> image already
# carries the same inputs fingerprint (see inputs in common.sh): rebuilding it
# would only move the tags to an equivalent image and roll every cluster that
# tracks them. --all keeps every target (pull requests, forced rebuilds).
#
# Usage:
#   IMAGE_PREFIX=ghcr.io/cnmsql images/plan.sh [--all]
#
# Output (one line of JSON):
#   {"build":   [{"target", "platform", "arch", "runner", "name"}, ...],
#    "publish": [{"target", "name"}, ...]}
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=images/common.sh
. "${here}/common.sh"

all=0
[ "${1:-}" = "--all" ] && all=1

builds='[]'
publishes='[]'
for t in $(bake_targets); do
  json="$(target_json "$t")"
  fp="$(inputs "$t")"
  if [ "${all}" = 0 ]; then
    # tags[1] is <prefix>/<image>:<server>-<distro>, the newest build of this
    # exact server version.
    current="$(jq -r '.tags[1]' <<<"$json")"
    published="$(published_labels "${current}" | jq -r '.["co.cnmsql.image.inputs"] // empty' 2>/dev/null || true)"
    if [ "${published}" = "${fp}" ]; then
      echo "skip ${t}: ${current} already has inputs ${fp}" >&2
      continue
    fi
    echo "build ${t}: ${current} has inputs '${published:-none}', want ${fp}" >&2
  fi
  builds="$(jq -c --arg t "$t" --argjson j "$json" '. + [$j.platforms[] | {
      target: $t,
      platform: .,
      arch: (split("/")[1]),
      runner: (if . == "linux/arm64" then "ubuntu-24.04-arm" else "ubuntu-24.04" end),
      name: "\($t) \(split("/")[1])"}]' <<<"$builds")"
  publishes="$(jq -c --arg t "$t" '. + [{target: $t, name: $t}]' <<<"$publishes")"
done

jq -cn --argjson b "$builds" --argjson p "$publishes" '{build: $b, publish: $p}'
