#!/usr/bin/env bash
# Check that a built instance image ships every binary the cnmsql instance
# manager executes.
#
# Usage:
#   images/check-tools.sh <image> <tools-file>
#   images/check-tools.sh cnmsql-instance:8.0-1 images/required-tools.txt
#
# The tools file lists one binary per line, optionally followed by the probe
# arguments (see images/required-tools.txt for the format). The check runs in a
# throwaway container as the image's own user, with no network, and exits
# non-zero when any binary is missing or its probe fails.
#
# Environment:
#   CONTAINER_TOOL      container CLI (default: docker)
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <image> <tools-file>" >&2
  exit 2
fi
image="$1"
tools_file="$2"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"

echo ">> checking required tools in ${image} (${tools_file})"

# Strip comments and blank lines, then feed the list to a shell in the image.
# Each probe reads from /dev/null so it can't swallow the rest of the list.
# shellcheck disable=SC2016 # the script expands inside the container
grep -vE '^[[:space:]]*(#|$)' "${tools_file}" |
  "${CONTAINER_TOOL}" run --rm -i --network none --entrypoint sh "${image}" -c '
    rc=0
    while read -r bin probe; do
      if ! path="$(command -v "$bin")"; then
        echo "   MISSING  $bin"
        rc=1
        continue
      fi
      if [ "$probe" = "-" ]; then
        if [ -x "$path" ]; then
          echo "   ok       $bin ($path)"
        else
          echo "   NOT EXEC $bin ($path)"
          rc=1
        fi
        continue
      fi
      # Unquoted on purpose: a probe can be several arguments.
      if out="$("$bin" ${probe:---version} 2>&1 </dev/null)"; then
        # Show the first line that carries a version, else the first line.
        line="$(printf "%s\n" "$out" | grep -m 1 -iE "(ver|version|distrib|from|server) v?[0-9]+\.[0-9]+" || printf "%s\n" "$out" | head -n 1)"
        echo "   ok       $bin: $line"
      else
        status=$?
        echo "   FAILED   $bin ${probe:---version} (exit $status)"
        printf "%s\n" "$out" | head -n 5 | sed "s/^/            /"
        rc=1
      fi
    done
    exit "$rc"
  '
