# pipesutils

[![build](https://github.com/OpSourced/pipesutils/actions/workflows/build.yml/badge.svg)](https://github.com/OpSourced/pipesutils/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Minimal multi-arch (`linux/amd64` + `linux/arm64`) image with the Turbot Pipes
CLIs, ready to run in Kubernetes or anywhere else a container runs:

| CLI | Version pin | Purpose |
| --- | --- | --- |
| [steampipe](https://steampipe.io) | `STEAMPIPE_VERSION` (v2.4.5) | live SQL over cloud APIs |
| [tailpipe](https://tailpipe.io) | `TAILPIPE_VERSION` (v0.7.4) | log collection into a local parquet lake |
| [powerpipe](https://powerpipe.io) | `POWERPIPE_VERSION` (v1.5.3) | benchmarks + dashboards |

```bash
docker pull ghcr.io/opsourced/pipesutils:latest
docker run --rm ghcr.io/opsourced/pipesutils steampipe query "select 1"
```

Free to use, no registration and no login needed to pull. Tags: `latest`,
`sha-<commit>`, and `vX.Y.Z` / `X.Y` on releases.

## What's in it

* `debian:bookworm-slim` base (steampipe v2's FDW needs glibc >= 2.34, so
  alpine/musl is out and the embedded postgres binaries need glibc).
* Runs as uid/gid **10001** (`pipes`). Not optional: steampipe refuses to run as
  root, and the embedded `initdb` needs the uid to resolve to a real passwd
  entry — so `runAsUser` must be `10001`.
* Baked at build time so pods have no cold-start downloads:
  * steampipe + tailpipe `aws` plugins
  * embedded postgres 14.19 binaries (the initialised cluster and generated
    password are removed, so every pod gets its own)
* Runtime packages kept to `ca-certificates`, `git` (powerpipe mod install),
  `less`, `libstdc++6` (DuckDB in tailpipe/powerpipe), `procps`, `tzdata`.
* Telemetry and update checks off by default.

~1.2 GB uncompressed, and most of that is the CLIs and the AWS plugins
themselves (aws steampipe plugin 362 MB, aws tailpipe plugin 161 MB, embedded
postgres 148 MB, three CLI binaries 308 MB).

### Build args

| Arg | Default | Notes |
| --- | --- | --- |
| `STEAMPIPE_VERSION` / `TAILPIPE_VERSION` / `POWERPIPE_VERSION` | pinned tags | release tags on the turbot repos |
| `STEAMPIPE_PLUGINS` | `aws` | space separated, baked in |
| `TAILPIPE_PLUGINS` | `aws` | space separated, baked in |
| `PRELOAD_STEAMPIPE_DB` | `true` | pre-pull the embedded postgres |
| `INCLUDE_POWERPIPE` | `true` | set `false` to drop 127 MB |
| `PIPES_UID` / `PIPES_GID` | `10001` | must match `runAsUser` in the manifests |

Every release asset is checksum-verified against the release `checksums.txt`
([hack/fetch-release.sh](hack/fetch-release.sh)).

Slim variant:

```bash
docker build \
  --build-arg INCLUDE_POWERPIPE=false \
  --build-arg STEAMPIPE_PLUGINS= \
  --build-arg TAILPIPE_PLUGINS= \
  --build-arg PRELOAD_STEAMPIPE_DB=false \
  -t pipesutils:slim .
```

## Running it

```bash
# one-shot query (embedded postgres starts on demand)
docker run --rm pipesutils steampipe query "select 1"

# long-lived, with the database service already up
docker run -d -e STEAMPIPE_START_SERVICE=true pipesutils sleep infinity
```

Entrypoint env:

| Var | Default | Effect |
| --- | --- | --- |
| `STEAMPIPE_START_SERVICE` | `false` | start the embedded postgres before `CMD`, stop it on SIGTERM |
| `STEAMPIPE_DATABASE_LISTEN` | `local` | `network` exposes 9193 to other pods |

## CI

[.github/workflows/build.yml](.github/workflows/build.yml) builds each arch
**natively** — `ubuntu-24.04` and `ubuntu-24.04-arm` — because the build runs
`steampipe plugin install` and `steampipe service start`, which under QEMU is
slow and flaky. Each arch is pushed by digest, then a `merge` job joins them
into one manifest list, and cosign keyless-signs it.

* PRs: build + smoke test only, nothing is pushed.
* `main`: `latest`, `sha-<sha>`.
* tags `v*`: `v1.2.3`, `1.2`, plus `latest`.
* weekly cron rebuild for base-image CVE patches, then a Trivy scan uploaded to
  code scanning.
* `workflow_dispatch` takes optional `steampipe_version` / `tailpipe_version` /
  `powerpipe_version` inputs to build against a specific CLI release.

[cli-updates.yml](.github/workflows/cli-updates.yml) checks the turbot releases
weekly and opens a PR when a CLI pin falls behind — Dependabot covers the base
image but cannot see those build args.

If `ubuntu-24.04-arm` runners are not available on the org plan, swap that
matrix entry to `ubuntu-24.04`, add `docker/setup-qemu-action`, and expect the
arm64 leg to take considerably longer.

### First publish

GHCR packages start **private** even when the repository is public. After the
first successful push to `main`, open the package settings once and set
visibility to public — otherwise `docker pull` asks anonymous users for
credentials. The image carries `org.opencontainers.image.source`, so GHCR links
the package to this repository and inherits its README automatically.

## Running it in Kubernetes

The image is deliberately unopinionated — no manifests ship here. What it does
impose on any deployment:

| Constraint | Why |
| --- | --- |
| `runAsUser: 10001` | steampipe refuses uid 0; embedded `initdb` needs a real passwd entry |
| writable rootfs | steampipe writes its postgres data dir, logs and connection state under `$STEAMPIPE_INSTALL_DIR` |
| `/home/pipes/.steampipe/config` | steampipe connections (`.spc`) |
| `/home/pipes/.tailpipe/config` | tailpipe partitions (`.tpc`) |
| `/home/pipes/.tailpipe/data` | the parquet lake — mount persistent storage here |
| `/workspace` | mods, exports, generated reports |

Plugins live in `/home/pipes/.{steampipe,tailpipe}/plugins` in the image layer,
so mounting the config and data paths above does not shadow them.

A shape that works well: a single-replica StatefulSet running
`sleep infinity` with `STEAMPIPE_START_SERVICE=true` to `kubectl exec` into,
plus CronJobs using the same image and volumes for `tailpipe collect` and for
scheduled `steampipe query` runs. On EKS, give the pod's ServiceAccount an
IRSA role and set no credentials at all.

If your storage is `ReadWriteOnce` (EBS gp3), pin the Jobs to the StatefulSet's
node with a `podAffinity` on `topologyKey: kubernetes.io/hostname` — RWO allows
many pods per node, just not many nodes.

## Verifying what you pulled

Manifest lists are cosign-signed with keyless OIDC and carry SBOM and
max-mode provenance attestations:

```bash
cosign verify ghcr.io/opsourced/pipesutils:latest \
  --certificate-identity-regexp '^https://github\.com/OpSourced/pipesutils/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect ghcr.io/opsourced/pipesutils:latest \
  --format '{{ json .SBOM }}'
```

Every CLI is checksum-verified against the publisher's `checksums.txt` at build
time, so a tampered or truncated release fails the build instead of shipping.

## License

This repository — the Dockerfile, entrypoint, build scripts and CI — is
[Apache-2.0](LICENSE).

The **image** redistributes third-party binaries under their own licenses. The
Steampipe, Tailpipe and Powerpipe CLIs are **AGPL-3.0**, shipped unmodified;
the plugins and the Postgres FDW are Apache-2.0. That combination is fine to
run and to redistribute, and using the CLIs to query your own infrastructure
carries no obligation. If you modify those CLIs and offer them to users over a
network, AGPL-3.0 section 13 applies to your modified version.

Full breakdown, including where to get each component's source:
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). The same notices ship
inside the image at `/usr/share/doc/pipesutils/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go through
[SECURITY.md](SECURITY.md), not public issues.

## Roadmap

Powerpipe ships in the image but nothing serves it yet. The intended shape is a
powerpipe container on `:9033` reading a mod from `/workspace`, with generated
dashboards written to a ConfigMap so views can change without a rebuild.
