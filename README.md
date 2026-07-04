# cnmsql / containers

Container images for [cnmsql](https://github.com/cnmsql),
a Kubernetes operator for running Percona Server for MySQL.

This repository builds the **instance image**, which is the MySQL pod the
operator runs. It is a slim, multi-version Percona Server image built from a
minimal Debian base. Rather than layering on top of the large upstream
`percona/percona-server` image, it installs only what the instance manager needs
to run: `mysqld`, XtraBackup, and a few utilities used for debugging and
replication. Docs, man pages, locales, the `mysql-test` suite, debug builds, and
the telemetry agent are removed.

## Layout

| Path | Purpose |
| --- | --- |
| [`Dockerfile.instance`](Dockerfile.instance) | The Percona Server instance image. Build args let one Dockerfile cover every supported MySQL version. |
| [`Dockerfile.mariadb-instance`](Dockerfile.mariadb-instance) | The MariaDB instance image. Same slim/rootless design, built from MariaDB's official apt repo (`mariadb-server` + `mariadb-backup`). |
| [`images/versions.json`](images/versions.json) | The Percona version matrix: base image, Percona Server / XtraBackup repos, package names, and release component per MySQL version. |
| [`images/mariadb-versions.json`](images/mariadb-versions.json) | The MariaDB version matrix: base image and MariaDB series per version. |
| [`images/build.sh`](images/build.sh) | Percona build driver. Reads `versions.json`, works out patch numbers, builds and optionally pushes the images. |
| [`images/build-mariadb.sh`](images/build-mariadb.sh) | MariaDB build driver. Same behaviour as `build.sh`, reads `mariadb-versions.json`. |
| [`images/lib.sh`](images/lib.sh) | Shared helpers (patch-version auto-detection) sourced by both build drivers. |
| [`.github/workflows/build.yml`](.github/workflows/build.yml) | CI. Builds each version of both flavours in the matrix and pushes to GHCR on pushes to `main` and `v*` tags. |

## Image design

The image stays small because it starts from `debian:bookworm-slim`, installs
only the runtime packages, and deletes everything non-essential in the same
layer.

It runs unprivileged, as uid `1001` in group `mysql` with gid `0` (the root
group). The data directories are group-writable, so the image also works on
platforms that assign an arbitrary uid, such as OpenShift, without granting real
privilege. `mysqld` never needs root and binds only ports above 1024.

The build keeps `mysql` and `mysqladmin` (for operator debugging and liveness
pings), `mysqlbinlog` (for binlog streaming and PITR), and the XtraBackup suite.
Everything else is dropped.

`percona-release` is left installed on purpose. `percona-server-server` depends
on it through `percona-telemetry-agent`, so removing it would also remove
`mysqld`. It does nothing at runtime, since `manager` is PID 1 and the telemetry
agent binary is deleted during the build.

## MariaDB image

[`Dockerfile.mariadb-instance`](Dockerfile.mariadb-instance) builds the MariaDB
counterpart to the Percona image, following the same principles: a
`debian:bookworm-slim` base, only the runtime packages (`mariadb-server` and
`mariadb-backup`, the latter providing `mariabackup`), the same unprivileged
uid `1001` / gid `0` identity, and the same aggressive stripping of docs, man
pages, locales and static libraries. MariaDB has no telemetry agent to remove.

The instance manager is shared with the Percona image and drives the server by
its MySQL names (`mysqld`, `mysqladmin`, `mysqlbinlog`, `mysql_install_db`).
Older MariaDB series (10.x) ship those names directly; newer ones (11.x/12.x)
ship them only in the `mariadb-server-compat` / `mariadb-client-compat`
packages, which the build installs when the enabled repo provides them. MariaDB
also has no `mysqld --initialize`, so `mysql_install_db` / `mariadb-install-db`
(and the `resolveip` helper it needs) are kept for data-dir bootstrap.

## Versions

### Percona Server

The supported matrix lives in [`images/versions.json`](images/versions.json).
Each entry maps a short `version` to the Percona apt repos and package names used
to install it:

| `version` | Server | Percona component |
| --- | --- | --- |
| `8.0` | 8.0.x | release (GA) |
| `8.4` | 8.4.x LTS | release (GA) |
| `9.x` | 9.x innovation | testing (pre-GA) |

### MariaDB

The supported matrix lives in
[`images/mariadb-versions.json`](images/mariadb-versions.json). Each entry maps a
short `version` to the MariaDB series enabled via the official
`mariadb_repo_setup` script:

| `version` | Server | Notes |
| --- | --- | --- |
| `10.11` | 10.11.x LTS | ships `mysql*` names directly |
| `11.4` | 11.4.x LTS | uses `mariadb-*-compat` for `mysql*` names |
| `11.8` | 11.8.x LTS | uses `mariadb-*-compat` for `mysql*` names |
| `12.3` | 12.3.x LTS | uses `mariadb-*-compat` for `mysql*` names |

To add or bump a version, edit the relevant matrix file. Both the build drivers
and the CI matrix read from them.

## Building locally

Build every version in the matrix:

```bash
images/build.sh
```

Build only specific versions:

```bash
images/build.sh 8.0 8.4
```

The MariaDB images build the same way through `images/build-mariadb.sh`:

```bash
images/build-mariadb.sh          # every MariaDB version
images/build-mariadb.sh 11.4     # only 11.4
```

### Tagging

Each image is tagged `<MYSQL_VERSION>-<PATCH_VERSION>` (for example `8.0-1`,
`8.4-3`). Each one also gets a bare `<MYSQL_VERSION>` tag (for example `8.0`)
that moves to point at the latest patch.

The patch number is detected by querying the target registry for existing tags,
trying these in order:

1. **GitHub Packages API**, when `GH_TOKEN` is set (this is the CI path).
2. **crane**, which runs the `go-containerregistry/crane` image to list tags from
   a generic OCI registry.
3. **Fallback**, which starts at `1`.

You can skip detection with `PATCH_VERSION=N` or `--patch=N`. The override
applies to every version built in that run.

### Configuration

The build reads these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `REGISTRY` | `cnmsql-instance` (Percona) / `cnmsql-mariadb-instance` (MariaDB) | Image name prefix and target repository. |
| `PUSH` | _(unset)_ | Set to `1` to push after building. |
| `PATCH_VERSION` | _(auto)_ | Manual patch override for all built versions. |
| `GH_TOKEN` | _(unset)_ | GitHub token for GHCR tag lookup (CI). |
| `CONTAINER_TOOL` | `docker` | Container CLI to use, for example `podman`. |

Build and push `8.0` to GHCR:

```bash
REGISTRY=ghcr.io/cnmsql/cnmsql-instance \
GH_TOKEN="$(gh auth token)" \
PUSH=1 \
images/build.sh 8.0
```

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) reads the version
lists from `versions.json` and `mariadb-versions.json`, builds each version of
both flavours in parallel, and pushes the images to
`ghcr.io/<owner>/cnmsql-instance` and `ghcr.io/<owner>/cnmsql-mariadb-instance`.
It runs on pushes to `main` and on `v*` tags, and you can also start it by hand
with `workflow_dispatch`.

## License

Apache License 2.0. See [LICENSE](LICENSE).
