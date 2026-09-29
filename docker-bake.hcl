# Build definition for the cnmsql instance images.
#
# This file is the single source of truth for what goes into every image: the
# base image digest and the exact server/backup package versions are pinned
# here, and Renovate (renovate.json) bumps each pin from upstream through the
# "# renovate:" comment above it. See design/001-image-supply-chain.md.
#
#   docker buildx bake --print                    # every target, resolved
#   docker buildx bake mysql-8-4-bookworm --load  # build one image locally
#   images/build.sh mysql-8-4-bookworm            # build + check + smoke test
#
# Target names are <flavor>-<series with dots as dashes>-<distro>.

# Registry and owner prefix for the image names, e.g. "ghcr.io/cnmsql". Empty
# for local builds.
variable "IMAGE_PREFIX" {
  default = ""
}

# Build id, the middle part of the immutable tag. CI computes it once per run so
# every platform of an image carries the same one.
variable "BUILD_ID" {
  default = formatdate("YYYYMMDDhhmm", timestamp())
}

# Commit the image is built from (org.opencontainers.image.revision).
variable "REVISION" {
  default = ""
}

# Distro whose images also get the distro-less tags (<server>, <series>).
variable "DEFAULT_DISTRO" {
  default = "bookworm"
}

variable "SOURCE" {
  default = "https://github.com/cnmsql/containers"
}

# --------------------------------------------------------------------------
# Base images
# --------------------------------------------------------------------------

variable "BASE_BOOKWORM" {
  # renovate: datasource=docker
  default = "debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251"
}

# Distroless base for the MySQL images built from a Debian release's packages.
# It must be the same release: the libraries it already ships (glibc,
# libstdc++, OpenSSL) are the ones the packages were built against.
variable "DISTROLESS_BOOKWORM" {
  # renovate: datasource=docker
  default = "gcr.io/distroless/cc-debian12:latest@sha256:e5d81ddde149641e2a9ba55be4545bc125c67de07508b03ba4c22e6eb0ded5aa"
}

variable "BASES" {
  default = {
    bookworm = BASE_BOOKWORM
  }
}

variable "DISTROLESS_BASES" {
  default = {
    bookworm = DISTROLESS_BOOKWORM
  }
}

# --------------------------------------------------------------------------
# Percona Server for MySQL
#
# ps_version / pxb_version are exact Debian package versions from Percona's
# apt repos. The server version in the tags is the upstream part of ps_version
# (8.4.11-11-1.bookworm -> 8.4.11). component is the apt component: "main" for
# GA releases, "testing" for pre-GA ones.
# --------------------------------------------------------------------------

variable "MYSQL" {
  default = [
    {
      series      = "8.0"
      distro      = "bookworm"
      component   = "main"
      ps_repo     = "ps-80"
      pxb_repo    = "pxb-80"
      pxb_package = "percona-xtrabackup-80"
      # renovate: datasource=deb depName=mysql-8.0-server packageName=percona-server-server registryUrl=https://repo.percona.com/ps-80/apt?suite=bookworm&components=main&binaryArch=amd64
      ps_version = "8.0.46-37-1.bookworm"
      # renovate: datasource=deb depName=mysql-8.0-xtrabackup packageName=percona-xtrabackup-80 registryUrl=https://repo.percona.com/pxb-80/apt?suite=bookworm&components=main&binaryArch=amd64
      pxb_version = "8.0.35-36-1.bookworm"
      platforms   = ["linux/amd64", "linux/arm64"]
    },
    {
      series      = "8.4"
      distro      = "bookworm"
      component   = "main"
      ps_repo     = "ps-84-lts"
      pxb_repo    = "pxb-84-lts"
      pxb_package = "percona-xtrabackup-84"
      # renovate: datasource=deb depName=mysql-8.4-server packageName=percona-server-server registryUrl=https://repo.percona.com/ps-84-lts/apt?suite=bookworm&components=main&binaryArch=amd64
      ps_version = "8.4.11-11-1.bookworm"
      # renovate: datasource=deb depName=mysql-8.4-xtrabackup packageName=percona-xtrabackup-84 registryUrl=https://repo.percona.com/pxb-84-lts/apt?suite=bookworm&components=main&binaryArch=amd64
      pxb_version = "8.4.0-7-1.bookworm"
      platforms   = ["linux/amd64", "linux/arm64"]
    },
    {
      series      = "9.7"
      distro      = "bookworm"
      component   = "main"
      ps_repo     = "ps-97-lts"
      pxb_repo    = "pxb-97-lts"
      pxb_package = "percona-xtrabackup-97"
      # renovate: datasource=deb depName=mysql-9.7-server packageName=percona-server-server registryUrl=https://repo.percona.com/ps-97-lts/apt?suite=bookworm&components=main&binaryArch=amd64
      ps_version = "9.7.2-2-1.bookworm"
      # renovate: datasource=deb depName=mysql-9.7-xtrabackup packageName=percona-xtrabackup-97 registryUrl=https://repo.percona.com/pxb-97-lts/apt?suite=bookworm&components=main&binaryArch=amd64
      pxb_version = "9.7.1~rc1-1.bookworm"
      platforms   = ["linux/amd64", "linux/arm64"]
    },
  ]
}

# --------------------------------------------------------------------------
# MariaDB
#
# package_version is the exact mariadb-server package version, watched on the
# per-series repo (which only carries the newest release). The image installs
# from the per-release repo instead, which keeps the pinned release installable
# after MariaDB ships the next one.
# --------------------------------------------------------------------------

variable "MARIADB" {
  default = [
    {
      series = "10.11"
      distro = "bookworm"
      # renovate: datasource=deb depName=mariadb-10.11-server packageName=mariadb-server registryUrl=https://dlm.mariadb.com/repo/mariadb-server/10.11/repo/debian?suite=bookworm&components=main&binaryArch=amd64
      package_version = "1:10.11.19+maria~deb12"
      platforms       = ["linux/amd64", "linux/arm64"]
    },
    {
      series = "11.4"
      distro = "bookworm"
      # renovate: datasource=deb depName=mariadb-11.4-server packageName=mariadb-server registryUrl=https://dlm.mariadb.com/repo/mariadb-server/11.4/repo/debian?suite=bookworm&components=main&binaryArch=amd64
      package_version = "1:11.4.13+maria~deb12"
      platforms       = ["linux/amd64", "linux/arm64"]
    },
    {
      series = "11.8"
      distro = "bookworm"
      # renovate: datasource=deb depName=mariadb-11.8-server packageName=mariadb-server registryUrl=https://dlm.mariadb.com/repo/mariadb-server/11.8/repo/debian?suite=bookworm&components=main&binaryArch=amd64
      package_version = "1:11.8.9+maria~deb12"
      platforms       = ["linux/amd64", "linux/arm64"]
    },
    {
      series = "12.3"
      distro = "bookworm"
      # renovate: datasource=deb depName=mariadb-12.3-server packageName=mariadb-server registryUrl=https://dlm.mariadb.com/repo/mariadb-server/12.3/repo/debian?suite=bookworm&components=main&binaryArch=amd64
      package_version = "1:12.3.3+maria~deb12"
      platforms       = ["linux/amd64", "linux/arm64"]
    },
  ]
}

# --------------------------------------------------------------------------
# Tags and labels
# --------------------------------------------------------------------------

# <server>-<build>-<distro> is immutable. <server>-<distro> and <series>-<distro>
# move to the newest build; the default distro also gets <server> and <series>.
function "tags" {
  params = [image, series, server, distro]
  result = concat(
    [
      "${ref(image)}:${server}-${BUILD_ID}-${distro}",
      "${ref(image)}:${server}-${distro}",
      "${ref(image)}:${series}-${distro}",
    ],
    distro == DEFAULT_DISTRO ? ["${ref(image)}:${server}", "${ref(image)}:${series}"] : [],
  )
}

# base_name <image@digest>: the fully qualified name of a pinned base image.
function "base_name" {
  params = [base]
  result = (length(regexall("^[^/]+[.:][^/]*/", base)) > 0
    ? split("@", base)[0]
    : "docker.io/library/${split("@", base)[0]}")
}

function "ref" {
  params = [image]
  result = IMAGE_PREFIX == "" ? image : "${IMAGE_PREFIX}/${image}"
}

function "labels" {
  params = [flavor, image, description, series, server, distro, base]
  result = {
    "org.opencontainers.image.title"          = image
    "org.opencontainers.image.description"    = description
    "org.opencontainers.image.source"         = SOURCE
    "org.opencontainers.image.licenses"       = "Apache-2.0"
    "org.opencontainers.image.vendor"         = "cnmsql"
    "org.opencontainers.image.version"        = server
    "org.opencontainers.image.revision"       = REVISION
    "org.opencontainers.image.created"        = timestamp()
    "org.opencontainers.image.base.name"      = base_name(base)
    "org.opencontainers.image.base.digest"    = split("@", base)[1]
    "co.cnmsql.image.flavor"                  = flavor
    "co.cnmsql.image.series"                  = series
    "co.cnmsql.image.server-version"          = server
    "co.cnmsql.image.distro"                  = distro
    "co.cnmsql.image.build"                   = BUILD_ID
  }
}

function "target_name" {
  params = [flavor, series, distro]
  result = "${flavor}-${replace(series, ".", "-")}-${distro}"
}

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------

group "default" {
  targets = ["mysql", "mariadb"]
}

# Every MySQL entry is built twice: on its Debian base (tags *-<distro>) and on
# the matching distroless base (tags *-distroless), from the same packages.
target "mysql" {
  name       = target_name("mysql", e.series, variant == "distroless" ? "distroless" : e.distro)
  matrix     = { e = MYSQL, variant = ["debian", "distroless"] }
  context    = "."
  dockerfile = "Dockerfile.instance"
  target     = variant
  platforms  = e.platforms
  args = {
    BASE_IMAGE        = BASES[e.distro]
    DISTROLESS_IMAGE  = DISTROLESS_BASES[e.distro]
    PERCONA_COMPONENT = e.component
    PS_REPO           = e.ps_repo
    PS_VERSION        = e.ps_version
    PXB_REPO          = e.pxb_repo
    PXB_PACKAGE       = e.pxb_package
    PXB_VERSION       = e.pxb_version
  }
  tags = tags("cnmsql-instance", e.series, split("-", e.ps_version)[0], variant == "distroless" ? "distroless" : e.distro)
  labels = labels(
    "mysql", "cnmsql-instance", "Slim Percona Server for MySQL instance image for the cnmsql operator",
    e.series, split("-", e.ps_version)[0], variant == "distroless" ? "distroless" : e.distro,
    variant == "distroless" ? DISTROLESS_BASES[e.distro] : BASES[e.distro],
  )
}

target "mariadb" {
  name       = target_name("mariadb", e.series, e.distro)
  matrix     = { e = MARIADB }
  context    = "."
  dockerfile = "Dockerfile.mariadb-instance"
  platforms  = e.platforms
  args = {
    BASE_IMAGE              = BASES[e.distro]
    MARIADB_VERSION         = regex_replace(e.package_version, "^([0-9]+:)?([0-9.]+).*$", "$2")
    MARIADB_PACKAGE_VERSION = e.package_version
  }
  tags = tags("cnmsql-mariadb-instance", e.series, regex_replace(e.package_version, "^([0-9]+:)?([0-9.]+).*$", "$2"), e.distro)
  labels = labels(
    "mariadb", "cnmsql-mariadb-instance", "Slim MariaDB instance image for the cnmsql operator",
    e.series, regex_replace(e.package_version, "^([0-9]+:)?([0-9.]+).*$", "$2"), e.distro, BASES[e.distro],
  )
}
