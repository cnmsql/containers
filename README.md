# cnmsql / containers

Container images for [cnmsql](https://github.com/cnmsql),
a Kubernetes operator for running Percona Server for MySQL.

This repository builds the **instance image**, which is the MySQL pod the
operator runs. It is a slim, multi-version Percona Server image built from a
minimal Debian base. Rather than layering on top of the large upstream
`percona/percona-server` image, it installs only what the instance manager needs
to run: `mysqld`, XtraBackup, and a few client tools used for debugging,
replication and logical backups. Docs, man pages, locales, the `mysql-test` suite, debug builds, and
the telemetry agent are removed.

## Layout

| Path | Purpose |
| --- | --- |
| [`docker-bake.hcl`](docker-bake.hcl) | The build definition and single source of truth: base image digests, exact server and backup package versions, platforms, tags and labels for every image. |
| [`Dockerfile.instance`](Dockerfile.instance) | The Percona Server instance image. |
| [`Dockerfile.mariadb-instance`](Dockerfile.mariadb-instance) | The MariaDB instance image. |
| [`keys/`](keys) | The Percona and MariaDB apt signing keyrings. Package sources are verified against these; nothing is downloaded and trusted at build time. |
| [`images/build.sh`](images/build.sh) | Builds images for one platform and runs the tools, version and smoke checks; with `--push`, pushes them by digest with an SBOM and provenance. |
| [`images/smoke.sh`](images/smoke.sh) | Initializes a data dir, takes a physical backup, prepares and restores it, and checks the data survived. |
| [`images/check-tools.sh`](images/check-tools.sh) | Fails if a binary from a tools list is missing or broken. |
| [`images/required-tools.txt`](images/required-tools.txt), [`images/mariadb-required-tools.txt`](images/mariadb-required-tools.txt) | The binaries the instance manager runs in each image. |
| [`images/plan.sh`](images/plan.sh) | Works out which images need building: those whose inputs changed since they were published. |
| [`images/publish.sh`](images/publish.sh) | Tags the multi-platform image and signs it with cosign. |
| [`images/catalog.sh`](images/catalog.sh) | Regenerates the `ClusterImageCatalog` manifests in [`catalogs/`](catalogs). |
| [`renovate.json`](renovate.json) | Renovate configuration: bumps every pin in `docker-bake.hcl` and the workflow actions. |
| [`.github/workflows/build.yml`](.github/workflows/build.yml) | CI: build and check on pull requests; build, publish, sign and update the catalogs on `main`. |
| [`design/001-image-supply-chain.md`](design/001-image-supply-chain.md) | Design of the whole supply chain. |

## Image design

The image stays small because it starts from `debian:bookworm-slim`, installs
only the runtime packages, and deletes everything non-essential in the same
layer.

It runs unprivileged, as uid `1001` in group `mysql` with gid `0` (the root
group). The data directories are group-writable, so the image also works on
platforms that assign an arbitrary uid, such as OpenShift, without granting real
privilege. `mysqld` never needs root and binds only ports above 1024.

The build keeps `mysql` and `mysqladmin` (for operator debugging, liveness
pings, PITR replay and loading dumps), `mysqlbinlog` (for binlog streaming and
PITR), `mysqldump` (for logical backups), and the XtraBackup suite. Everything
else is dropped, including `mysqlpump`, which is deprecated in 8.0 and removed
in 8.4.

### Required tools

The instance manager runs some binaries from the image directly: the server,
the backup and stream tools, the binlog client, the SQL client and the dump
tool. They are listed in [`images/required-tools.txt`](images/required-tools.txt)
and [`images/mariadb-required-tools.txt`](images/mariadb-required-tools.txt).
After each build, [`images/check-tools.sh`](images/check-tools.sh) runs the new
image and checks that every listed binary is on `PATH` and starts (most with
`--version`). If one fails, the build stops before the image is tagged or
pushed.

When you remove a binary from an image, check the list first. When the operator
starts running a new binary, add it to the list in the same change that adds it
to the image.

Images published before logical backup support strip the dump tool, so
`cnmsql` logical backups fail on them with `LogicalToolUnavailable`. Use a
newer patch tag of the same series.

The image has no `percona-release`: the build writes the Percona apt sources
itself, signed by the committed keyring. `percona-server-server` still pulls in
`percona-telemetry-agent`, whose binary is deleted during the build.

## MariaDB image

[`Dockerfile.mariadb-instance`](Dockerfile.mariadb-instance) builds the MariaDB
counterpart to the Percona image, following the same principles: a
`debian:bookworm-slim` base, only the runtime packages (`mariadb-server` and
`mariadb-backup`, the latter providing `mariabackup`), the same unprivileged
uid `1001` / gid `0` identity, and the same aggressive stripping of docs, man
pages, locales and static libraries. MariaDB has no telemetry agent to remove.
It keeps `mariadb-dump` for logical backups. The legacy `mysqldump` alias is
removed, since the operator calls `mariadb-dump`.

The instance manager is shared with the Percona image and drives the server by
its MySQL names (`mysqld`, `mysqladmin`, `mysqlbinlog`, `mysql_install_db`).
Older MariaDB series (10.x) ship those names directly; newer ones (11.x/12.x)
ship them only in the `mariadb-server-compat` / `mariadb-client-compat`
packages, which the build installs when the enabled repo provides them. MariaDB
also has no `mysqld --initialize`, so `mysql_install_db` / `mariadb-install-db`
(and the `resolveip` helper it needs) are kept for data-dir bootstrap.

## Versions

Every image is pinned in [`docker-bake.hcl`](docker-bake.hcl) to exact package
versions. [Renovate](renovate.json) opens a PR when Percona or MariaDB ships a
new release, or when the Debian base image is refreshed.

| Flavor | Series | Notes |
| --- | --- | --- |
| Percona Server | `8.0` | `ps-80` / `pxb-80` |
| Percona Server | `8.4` | LTS, `ps-84-lts` / `pxb-84-lts` |
| Percona Server | `9.7` | LTS, `ps-97-lts` / `pxb-97-lts` (XtraBackup 9.7 is still a release candidate upstream) |
| MariaDB | `10.11`, `11.4`, `11.8`, `12.3` | LTS; 11.x and 12.x ship the `mysql*` names in `mariadb-*-compat` |

Every image is built for `linux/amd64` and `linux/arm64`.

To bump a version by hand, edit its pin in `docker-bake.hcl`. To add a series,
add an entry to the `MYSQL` or `MARIADB` list, with its `# renovate:` comments.

## Tags

For Percona Server 8.4.11 built at 2026-10-01 12:00 UTC on Debian bookworm:

| Tag | Moves? | Points to |
| --- | --- | --- |
| `8.4.11-202610011200-bookworm` | never | this build |
| `8.4.11-bookworm`, `8.4.11` | yes | newest build of 8.4.11 |
| `8.4-bookworm`, `8.4` | yes | newest build of the newest 8.4 patch |

An image is rebuilt when its inputs change: a new package version, a new base
image digest, or a Dockerfile change. Rebuilding an image whose inputs did not
change is skipped, so the moving tags only move for a real change.

Older tags (`8.4-5`, `8.4-<sha>`) stay published but are no longer produced.

## Catalogs

[`catalogs/`](catalogs) holds a `ClusterImageCatalog` per flavor and distro,
regenerated after every publish. Each entry pins the newest image of a series by
immutable tag and digest:

```bash
kubectl apply -f https://raw.githubusercontent.com/cnmsql/containers/main/catalogs/catalog-mysql-bookworm.yaml
```

## Verifying images

Images are signed with [cosign](https://github.com/sigstore/cosign), keyless,
by this repository's build workflow, and carry an SPDX SBOM and SLSA provenance:

```bash
cosign verify ghcr.io/cnmsql/cnmsql-instance:8.4 \
  --certificate-identity-regexp '^https://github.com/cnmsql/containers/\.github/workflows/build\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect ghcr.io/cnmsql/cnmsql-instance:8.4 --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/cnmsql/cnmsql-instance:8.4 --format '{{ json .Provenance }}'
```

## Building locally

Needs Docker with buildx, `jq` and `skopeo`.

```bash
docker buildx bake --print                 # every image, fully resolved
images/build.sh mysql-8-4-bookworm         # build + check + smoke test one image
images/build.sh mariadb                    # every MariaDB image
images/build.sh --platform linux/arm64 mysql-8-4-bookworm   # needs arm64 or QEMU
```

Target names are `<flavor>-<series with dashes>-<distro>`. Locally built images
are tagged `cnmsql-build/<target>:<os>-<arch>`.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml):

- **Pull requests and branches** build every image on native amd64 and arm64
  runners, run the tools, version and smoke checks and a Trivy scan, and push
  nothing.
- **`main`** rebuilds only the images whose inputs changed, pushes them to
  `ghcr.io/<owner>/cnmsql-instance` and `ghcr.io/<owner>/cnmsql-mariadb-instance`,
  signs them, and commits the regenerated catalogs.
- **`workflow_dispatch`** with `force` rebuilds and republishes everything.

See [the design](design/001-image-supply-chain.md) for the details.

## License

Apache License 2.0. See [LICENSE](LICENSE).
