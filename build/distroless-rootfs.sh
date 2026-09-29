#!/bin/sh
# Assemble the files a distroless instance image adds on top of its base.
#
# Runs in the Debian stage of Dockerfile.instance, after the pinned packages
# are installed and trimmed. It starts from the seed packages given on the
# command line, follows every ELF file they ship through ldd to the shared
# libraries it loads, and repeats with the packages owning those libraries
# until nothing new turns up. Packages the distroless base already ships
# (listed in its status.d) are left out; everything else is copied to <out>
# file by file, as the Debian stage has it after trimming.
#
# Each copied package is also recorded in <out>/var/lib/dpkg/status.d/, the
# layout distroless images use, so SBOM generators and scanners see the same
# packages they see in the Debian image.
#
# Following Depends instead of ldd would pull in perl, debconf and a shell:
# package dependencies describe installing and configuring the package, not
# running its binaries.
#
# Usage:
#   distroless-rootfs.sh <out> <base-status.d> <package>...
set -eu

out="$1"
base_status="$2"
shift 2

work="$(mktemp -d)"
: >"${work}/done"
printf '%s\n' "$@" >"${work}/todo"

# owner <path>: the package that ships path. ldd prints RPATH-relative paths
# unnormalized (plugin/../private/lib.so), and may print a path through the
# /lib -> /usr/lib symlink while dpkg recorded the other spelling.
owner() {
  path="$(realpath -s "$1")"
  for p in "${path}" "${path#/usr}" "/usr${path}"; do
    if pkg="$(dpkg-query -S "$p" 2>/dev/null)"; then
      echo "${pkg%%: *}" | cut -d, -f1 | cut -d: -f1
      return 0
    fi
  done
  echo "!! no package ships $1" >&2
  return 1
}

is_elf() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -c 4 "$1" | od -An -c | tr -d ' \n')" = "177ELF" ]
}

while [ -s "${work}/todo" ]; do
  sort -u "${work}/todo" | comm -23 - "${work}/done" >"${work}/next"
  : >"${work}/todo"
  while read -r pkg; do
    [ -n "${pkg}" ] || continue
    echo "${pkg}" >>"${work}/done"
    if [ -e "${base_status}/${pkg}" ]; then
      echo "   base     ${pkg}"
      continue
    fi
    echo "   copy     ${pkg}"
    echo "${pkg}" >>"${work}/copy"
    dpkg-query -L "${pkg}" | while read -r f; do
      # Directories are created as needed; a directory entry that is a
      # symlink in this stage (/lib) must not replace the base's own.
      if [ -d "${f}" ] || { [ ! -e "${f}" ] && [ ! -L "${f}" ]; }; then
        continue
      fi
      echo "${f#/}" >>"${work}/files"
      is_elf "${f}" || continue
      ldd "${f}" 2>/dev/null | while read -r line; do
        case "${line}" in
          *"not found"*) echo "!! ${f}: ${line}" >&2; exit 1 ;;
          *"=> /"*) lib="${line#*=> }"; owner "${lib%% (*}" >>"${work}/todo" ;;
        esac
      done
    done
  done <"${work}/next"
  sort -u "${work}/done" -o "${work}/done"
done

mkdir -p "${out}/var/lib/dpkg/status.d"
sort -u "${work}/files" | tar -C / -cf - --no-recursion -T - | tar -C "${out}" -xpf -
while read -r pkg; do
  dpkg-query -s "${pkg}" >"${out}/var/lib/dpkg/status.d/${pkg}"
  for md5 in "/var/lib/dpkg/info/${pkg}.md5sums" /var/lib/dpkg/info/"${pkg}":*.md5sums; do
    [ -f "${md5}" ] && cp "${md5}" "${out}/var/lib/dpkg/status.d/${pkg}.md5sums"
  done
done <"${work}/copy"

rm -rf "${work}"
