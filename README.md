# cloudnative-mysql / containers

Container images for [CloudNative-MySQL](https://github.com/CloudNative-MySQL),
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
| [`Dockerfile.instance`](Dockerfile.instance) | The instance image. Build args let one Dockerfile cover every supported MySQL version. |
| [`images/versions.json`](images/versions.json) | The version matrix: base image, Percona Server / XtraBackup repos, package names, and release component per MySQL version. |
| [`images/build.sh`](images/build.sh) | Build driver. Reads `versions.json`, works out patch numbers, builds and optionally pushes the images. |
| [`.github/workflows/build.yml`](.github/workflows/build.yml) | CI. Builds each version in the matrix and pushes to GHCR on pushes to `main` and `v*` tags. |

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

## Versions

The supported matrix lives in [`images/versions.json`](images/versions.json).
Each entry maps a short `version` to the Percona apt repos and package names used
to install it:

| `version` | Server | Percona component |
| --- | --- | --- |
| `8.0` | 8.0.x | release (GA) |
| `8.4` | 8.4.x LTS | release (GA) |
| `9.x` | 9.x innovation | testing (pre-GA) |

To add or bump a version, edit `versions.json`. Both `build.sh` and the CI matrix
read from it.

## Building locally

Build every version in the matrix:

```bash
images/build.sh
```

Build only specific versions:

```bash
images/build.sh 8.0 8.4
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
| `REGISTRY` | `cloudnative-mysql-instance` | Image name prefix and target repository. |
| `PUSH` | _(unset)_ | Set to `1` to push after building. |
| `PATCH_VERSION` | _(auto)_ | Manual patch override for all built versions. |
| `GH_TOKEN` | _(unset)_ | GitHub token for GHCR tag lookup (CI). |
| `CONTAINER_TOOL` | `docker` | Container CLI to use, for example `podman`. |

Build and push `8.0` to GHCR:

```bash
REGISTRY=ghcr.io/cloudnative-mysql/cloudnative-mysql-instance \
GH_TOKEN="$(gh auth token)" \
PUSH=1 \
images/build.sh 8.0
```

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) reads the version
list from `versions.json`, builds each version in parallel, and pushes the images
to `ghcr.io/<owner>/cloudnative-mysql-instance`. It runs on pushes to `main` and
on `v*` tags, and you can also start it by hand with `workflow_dispatch`.

## License

Apache License 2.0. See [LICENSE](LICENSE).
