#!/usr/bin/env bash
# Smoke test a built instance image end to end: initialize a data dir, start
# the server, write a row, take a physical backup with the image's own backup
# tool, prepare it, start a server on the prepared backup and read the row back.
#
# check-tools.sh only proves each binary starts; this proves the pinned server
# and backup tool actually work together (e.g. an XtraBackup too old for the
# server it is paired with fails here).
#
# Usage:
#   images/smoke.sh <image> <mysql|mariadb>
#
# Runs in a throwaway container as the image's own user, with no network and a
# mounted BusyBox shell (the image may have none), so the script inside is
# plain POSIX sh.
#
# Environment:
#   CONTAINER_TOOL      container CLI (default: docker)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=images/common.sh
. "${here}/common.sh"

if [ $# -ne 2 ]; then
  echo "usage: $0 <image> <mysql|mariadb>" >&2
  exit 2
fi
image="$1"
flavor="$2"

echo ">> smoke testing ${image} (${flavor})"

# shellcheck disable=SC2016 # the script expands inside the container
run_with_shell "${image}" -s -- "${flavor}" <<'EOF'
set -eu
set -o pipefail
flavor="$1"
work="$(mktemp -d)"
sock="${work}/server.sock"

if [ "${flavor}" = mysql ]; then
  server=mysqld client=mysql admin=mysqladmin backup=xtrabackup
  extra="--mysqlx=OFF --secure-file-priv="
else
  server=mariadbd client=mariadb admin=mariadb-admin backup=mariabackup
  extra=""
fi

fail() {
  echo "!! $*"
  for f in "${work}"/*.log; do echo "--- ${f}"; tail -n 30 "${f}"; done
  exit 1
}

start() {
  "${server}" --no-defaults --datadir="$1" --socket="${sock}" --skip-networking \
    --pid-file="${work}/server.pid" --log-error="${work}/server.log" ${extra} &
  for _ in $(seq 120); do
    "${admin}" --no-defaults -uroot -S "${sock}" ping >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "${server} did not start on $1"
}

stop() {
  "${admin}" --no-defaults -uroot -S "${sock}" shutdown
  wait
}

sql() {
  "${client}" --no-defaults -uroot -S "${sock}" -N -e "$1"
}

echo "   initializing a data dir"
if [ "${flavor}" = mysql ]; then
  "${server}" --no-defaults --initialize-insecure --datadir="${work}/data" \
    --log-error="${work}/init.log" || fail "initialize failed"
else
  mariadb-install-db --no-defaults --datadir="${work}/data" --skip-test-db \
    --auth-root-authentication-method=normal >"${work}/init.log" 2>&1 || fail "mariadb-install-db failed"
fi

start "${work}/data"
echo "   server $(sql 'SELECT VERSION()') is up; writing a row"
sql "CREATE DATABASE smoke; CREATE TABLE smoke.t (id INT PRIMARY KEY); INSERT INTO smoke.t VALUES (42);"

echo "   taking a physical backup with ${backup}"
"${backup}" --no-defaults --backup --target-dir="${work}/backup" --user=root --socket="${sock}" \
  >"${work}/backup.log" 2>&1 || fail "backup failed"
stop

echo "   preparing the backup"
"${backup}" --no-defaults --prepare --target-dir="${work}/backup" \
  >"${work}/prepare.log" 2>&1 || fail "prepare failed"

echo "   starting a server on the prepared backup"
start "${work}/backup"
got="$(sql 'SELECT id FROM smoke.t')"
stop
[ "${got}" = 42 ] || fail "restored row is '${got}', want 42"
echo "   ok: the row survived backup, prepare and restore"
EOF
