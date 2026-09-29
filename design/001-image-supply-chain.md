# 001 — Instance image supply chain

Status: accepted (2026-09-29)

How the cnmsql instance images get from upstream packages to a running
cluster: what pins them, how new upstream releases arrive, how an image is
tested, published, signed and handed to the operator, and how users verify
it.

## Problems with the previous pipeline

- **Nothing was pinned.** The Dockerfile installed whatever
  `percona-server-server` Percona had published last, from repos bootstrapped
  with an unpinned `percona-release_latest` deb (MariaDB: `curl | bash` of
  `mariadb_repo_setup`), on an undigested `debian:bookworm-slim`. The
  `serverVersion` field in `versions.json` was never passed to the build. A
  rebuild could silently move `8.4.6` to `8.4.7`, and nothing recorded which
  one an image carried.
- **Tags counted builds, not server versions.** `8.4-5` was the fifth build of
  the series; the counter came from querying the registry (racy, needs a
  token). Neither users nor the operator could tell the server version from
  the tag.
- **New upstream releases went unnoticed** until someone rebuilt by hand, and
  base-image CVE fixes only arrived with that rebuild.
- **No SBOM, provenance or signature**, and only amd64.

## Decisions

| # | Decision | Why |
|---|---|---|
| S1 | `docker-bake.hcl` is the single source of truth: base image by digest, exact package versions, platforms, tags, labels | One file to review; bake is the standard buildx front end, so local builds and CI run the same definition |
| S2 | Renovate bumps every pin (Debian packages via its `deb` datasource, base digests, action SHAs) and opens one PR per series | Existing tooling instead of a bespoke watcher; its PRs trigger CI normally |
| S3 | Vendor signing keyrings are committed in `keys/`; apt sources are written directly, no `percona-release` / `mariadb_repo_setup` | Nothing is fetched and trusted at build time; a key change shows up in review |
| S4 | Immutable tag `<server>-<YYYYMMDDhhmm>-<distro>`, plus moving `<server>-<distro>`, `<series>-<distro>`, and for the default distro `<server>`, `<series>` | The server version is in every tag; a timestamp build id needs no registry lookup; the distro suffix leaves room for trixie |
| S5 | Every image is built on a native runner per platform (amd64, arm64) and must pass the tools, version and smoke checks before it is pushed | arm64 is tested, not emulated; a broken server/backup pairing never reaches the registry |
| S6 | Only images whose **inputs** changed are republished | Republishing an equivalent image moves the tags and rolls every cluster that tracks them, for nothing |
| S7 | BuildKit SBOM + max-mode provenance on every image; keyless cosign signature over the index and every manifest | Standard, verifiable with stock tools, no key to manage |
| S8 | CI regenerates `catalogs/catalog-<flavor>-<distro>.yaml` (ClusterImageCatalog, immutable tag + digest) after every publish | The operator's native way to pick images; applying a catalog is as reproducible as pulling by digest |

## Pins (S1, S3)

`docker-bake.hcl` holds, per image:

- the base image, e.g. `debian:bookworm-slim@sha256:…`, shared by every image
  of a distro;
- for Percona Server: the apt repos (`ps-84-lts`, `pxb-84-lts`), the apt
  component (`main`, or `testing` for pre-GA lines), and the exact package
  versions of `percona-server-server` and the XtraBackup package.
  `percona-server-server` depends on its matching `client` and `common`
  packages with `=`, so pinning it pins the whole server;
- for MariaDB: the exact `mariadb-server` package version. Renovate watches
  MariaDB's per-series repo (`…/mariadb-server/11.4/…`), which only carries
  the newest release; the image installs from the per-release repo
  (`…/mariadb-server/11.4.13/…`), so the pinned release stays installable
  after the next one ships. An apt preference makes MariaDB's packages win
  over Debian's own `mariadb-*`;
- the platforms it is built for.

The server version in the tags and labels is derived from the package version
(`8.4.11-11-1.bookworm` → `8.4.11`, `1:11.4.13+maria~deb12` → `11.4.13`), so it
cannot drift from what is installed; the build also checks the server binary
reports it.

Not pinned, on purpose:

- `percona-telemetry-agent` (a hard dependency of `percona-server-server`,
  deleted from the image during the build). Pinning it would roll every
  Percona cluster whenever Percona bumps a binary the image does not ship.
- Debian's own dependency packages (`libssl3`, …). They come from the Debian
  archive at build time; the base digest bump is what refreshes them.

Keys: `keys/percona-keyring.gpg` (Percona packaging key
`4D1BB29D63D98E422B2113B19334A25F8507EFA5`) and
`keys/mariadb-keyring-2025.gpg` (MariaDB signing key
`177F4010FE56CA3336300305F1656F24C74CD1D8` and its enterprise/maxscale
siblings; sha256 matches `supplychain.mariadb.com`'s published checksum).
Rotating a key is a reviewed PR that replaces the file.

## Upstream updates (S2)

Renovate (the Mend GitHub App) reads `renovate.json`:

- a regex manager over `docker-bake.hcl` finds each `# renovate:
  datasource=deb depName=<flavor>-<series>-<server|xtrabackup>
  packageName=<package> registryUrl=<repo>?suite=…&components=…&binaryArch=amd64`
  comment and the value below it, and looks the package up in that apt index
  with Debian versioning. The per-series `depName` gives one PR per series and
  tool (`renovate/mysql-8.4-server-8.x`);
- a second regex manager keeps the base images' digests current; all base
  digest bumps are grouped into one PR (`renovate/base-images`), since they
  rebuild every image of the distro anyway;
- `helpers:pinGitHubActionDigests` keeps the workflow's actions pinned by SHA
  and current.

Nothing automerges: the PR's build is the gate and merging publishes.

A Percona repo only ever carries one series (`ps-84-lts` is 8.4 only), so a
series can never jump to the next one through a bump; moving to a new series is
a new entry in `docker-bake.hcl`.

## Build and test (S5)

`.github/workflows/build.yml`, job `build`, one job per image and platform on
`ubuntu-24.04` / `ubuntu-24.04-arm`, runs `images/build.sh`:

1. `docker buildx bake <target> --load` for that platform;
2. `images/check-tools.sh`: every binary the instance manager runs is present
   and starts;
3. version check: `mysqld --version` / `mariadbd --version` reports the pinned
   server version;
4. `images/smoke.sh`: initialize a data dir, start the server, write a row,
   take a physical backup with the image's own XtraBackup / mariabackup,
   prepare it, start a server on the prepared backup, read the row back. This
   is what catches a backup tool that cannot handle the server it is paired
   with;
5. an informational Trivy scan (fixable HIGH/CRITICAL) into the job summary.

On a publishing run the job then rebuilds the same target (every layer comes
from the cache of the build it just tested) and pushes it **by digest, with no
tag**, with `--attest type=sbom` and `--attest type=provenance,mode=max`. The
digest is handed to the publish job as an artifact.

Pull requests and non-main branches run the whole matrix and publish nothing.
The same script runs locally: `images/build.sh mysql-8-4-bookworm`.

## Skipping unchanged images (S6)

`images/plan.sh` fingerprints each target: sha256 over the resolved build args
(base digest, repos, package versions), the platforms, the Dockerfile and
`keys/`. Tags, labels and the build id are excluded. The fingerprint is stored
on the image as the `co.cnmsql.image.inputs` label.

On main, a target is built only when its published `<server>-<distro>` image
carries a different fingerprint (or does not exist). A README change or a
bump of one series therefore republishes nothing else. `workflow_dispatch`
with `force: true` rebuilds everything, e.g. to pick up a Debian security fix
before the next base digest bump.

## Publish and sign (S4, S7)

Job `publish`, one per image, runs `images/publish.sh`:

1. `docker buildx imagetools create` assembles the per-platform digests into
   one index and applies every tag from `docker-bake.hcl`. The platforms' SBOM
   and provenance attestation manifests are carried into the index. An image
   with a missing platform is refused.
2. `cosign sign --recursive` signs the index and every manifest in it,
   keyless, with the workflow's GitHub OIDC identity
   (`https://github.com/cnmsql/containers/.github/workflows/build.yml@refs/heads/main`),
   recorded in the public Rekor log.
3. `cosign verify` checks the signature against that identity before the job
   succeeds.

Tags, for Percona Server 8.4.11 built at 2026-10-01 12:00 UTC on bookworm:

| Tag | Moves? | Points to |
|---|---|---|
| `8.4.11-202610011200-bookworm` | never | this build |
| `8.4.11-bookworm`, `8.4.11` | yes | newest build of 8.4.11 |
| `8.4-bookworm`, `8.4` | yes | newest build of the newest 8.4 patch |

The legacy `<series>-<N>` tags (`8.4-5`) and `<series>-<sha>` tags are no
longer produced; the published ones stay in GHCR untouched.

Every image carries OCI labels (`org.opencontainers.image.version`, `.revision`,
`.source`, `.base.name`, `.base.digest`, …) and cnmsql labels:

| Label | Example |
|---|---|
| `co.cnmsql.image.flavor` | `mysql` |
| `co.cnmsql.image.series` | `8.4` |
| `co.cnmsql.image.catalog-series` | `8.4` (`9.0` for the legacy `9.x` line) |
| `co.cnmsql.image.server-version` | `8.4.11` |
| `co.cnmsql.image.distro` | `bookworm` |
| `co.cnmsql.image.build` | `202610011200` |
| `co.cnmsql.image.inputs` | `sha256:…` |

## Catalogs (S8)

After the publish jobs, job `catalogs` runs `images/catalog.sh` and commits
`catalogs/catalog-<flavor>-<distro>.yaml` to main (paths-ignored by the build
workflow). Each is a `ClusterImageCatalog` named `cnmsql-<flavor>-<distro>`
whose entries point at the newest build of each series by immutable tag and
digest:

```yaml
- series: "8.4"
  image: ghcr.io/cnmsql/cnmsql-instance:8.4.11-202610011200-bookworm@sha256:…
```

Users (or their GitOps tooling) apply the catalog from the repo; a patch
upgrade is a new catalog revision, which the operator rolls like any image
change. Clusters pinned to an older catalog revision or an immutable tag never
move on their own.

## Verifying an image

```bash
cosign verify ghcr.io/cnmsql/cnmsql-instance:8.4 \
  --certificate-identity-regexp '^https://github.com/cnmsql/containers/\.github/workflows/build\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect ghcr.io/cnmsql/cnmsql-instance:8.4 \
  --format '{{ json .SBOM }}'        # SPDX SBOM per platform
docker buildx imagetools inspect ghcr.io/cnmsql/cnmsql-instance:8.4 \
  --format '{{ json .Provenance }}'  # SLSA provenance per platform
```

## Contract with the operator

The operator should not have to trust a tag for anything beyond a first
guess:

- the series is explicit in the catalog (`series`) and in the
  `co.cnmsql.image.series` / `catalog-series` labels;
- the exact server version is in the tag, the labels, and above all in the
  server binary itself (`mysqld --version`), which is authoritative.

How the operator uses this is designed on the operator side
(cnmsql `design/033-image-version-discovery.md`).

## Non-goals

- Pinning Debian's own dependency packages (snapshot.debian.org). The base
  digest plus the rebuild on its bump is the refresh mechanism.
- Blocking on Trivy findings: the fixes come from upstream bumps, which this
  pipeline already turns into PRs.
- Deleting old tags. Users may have pinned them.
