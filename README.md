# pipesutils

[![build](https://github.com/OpSourced/pipesutils/actions/workflows/build.yml/badge.svg)](https://github.com/OpSourced/pipesutils/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Multi-arch (`linux/amd64` + `linux/arm64`) image with the Turbot Pipes CLIs,
ready to run in Kubernetes or anywhere else a container runs:

| CLI | Version pin | Purpose |
| --- | --- | --- |
| [steampipe](https://steampipe.io) | `STEAMPIPE_VERSION` (v2.4.5) | live SQL over cloud APIs |
| [tailpipe](https://tailpipe.io) | `TAILPIPE_VERSION` (v0.7.4) | log collection into a local parquet lake |
| [powerpipe](https://powerpipe.io) | `POWERPIPE_VERSION` (v1.5.3) | benchmarks + dashboards |

Each build also carries the plugins and vendor CLI for the clouds it targets —
AWS by default, `--build-arg CLOUDS="aws azure gcp"` for everything. Nothing
downloads on first run.

```bash
docker pull ghcr.io/opsourced/pipesutils:latest
docker run --rm ghcr.io/opsourced/pipesutils steampipe query "select 1"
```

Three images are published, one per cloud — pull whichever you need:

```bash
ghcr.io/opsourced/pipesutils:latest          # AWS  (alias: latest-aws)
ghcr.io/opsourced/pipesutils:latest-azure    # Azure
ghcr.io/opsourced/pipesutils:latest-gcp      # GCP
```

Each carries that cloud's steampipe and tailpipe plugins plus its vendor CLI.

Free to use, no registration and no login needed to pull.

## What's in it

* `debian:bookworm-slim` base (steampipe v2's FDW needs glibc >= 2.34, so
  alpine/musl is out and the embedded postgres binaries need glibc).
* Runs as uid/gid **10001** (`pipes`). Not optional: steampipe refuses to run as
  root, and the embedded `initdb` needs the uid to resolve to a real passwd
  entry — so `runAsUser` must be `10001`.
* Baked at build time so pods have no cold-start downloads:
  * steampipe **and** tailpipe plugins for each selected cloud
  * that cloud's vendor CLI
  * embedded postgres 14.19 binaries (the initialised cluster and generated
    password are removed, so every pod gets its own)
* Runtime packages otherwise kept to `ca-certificates`, `git` (powerpipe mod
  install), `less`, `libstdc++6` (DuckDB in tailpipe/powerpipe), `procps`,
  `tzdata`.
* Telemetry and update checks off by default.

### Why this base

`debian:bookworm-slim`, and **not alpine** — I tested rather than assumed:

| Base | Size | Verdict |
| --- | --- | --- |
| `alpine:3.22` | 8.3 MB | **Does not work.** musl, not glibc |
| `gcr.io/distroless/base-debian12` | 20.8 MB | **Rejected.** No shell and no git |
| `cgr.dev/chainguard/wolfi-base` | 16.3 MB | **Rejected.** No `azure-cli` package |
| `debian:trixie-slim` | 78.6 MB | **Rejected.** Bigger, and no vendor repo |
| `ubuntu:24.04` | 78.2 MB | Bigger, no benefit |
| **`debian:bookworm-slim`** | **74.8 MB** | glibc 2.36, vendor repos support it |

What actually happens on alpine:

```console
$ docker run --rm -v ./bin:/t alpine:3.22 /t/tailpipe --version
exec /t/tailpipe: no such file or directory     # wants /lib64/ld-linux-x86-64.so.2

$ docker run --rm -v ./bin:/t alpine:3.22 /t/steampipe service start
Error: Initializing database... FAILED!         # embedded postgres is glibc-linked
```

`steampipe` itself is a static Go binary and does start on alpine, which makes
this failure mode worse than a clean one — it breaks at the first query, not at
startup. `tailpipe` and `powerpipe` are cgo builds (DuckDB) and are dynamically
linked, so they do not run at all. Steampipe v2.0.0 raised the floor explicitly:

> Increased the minimum required `glibc` version to `2.34` for the FDW […]
> Steampipe no longer supports older Linux distributions such as Ubuntu 20.04
> and Amazon Linux 2.

A musl base would need `gcompat` shims under the embedded PostgreSQL, the FDW
and DuckDB. That is not a supported configuration by anyone involved.

Wolfi was the near miss: glibc 2.41, 16 MB, and it packages `google-cloud-sdk`,
`aws-cli-2`, `git` and `bash`. But it has no `azure-cli`, and `az` has no
install path that is not apt or pip — so the `-all` variant could not be built.
Saving 58 MB on a 1.4 GB image was not worth splitting bases over.

Which is the honest framing: **the base is ~5% of the image**. The plugins and
vendor CLIs are the other 95%, and `CLOUDS` is the knob that moves them.

### Picking clouds

One build arg decides the contents:

```bash
docker build -t pipesutils:aws .                                   # default
docker build --build-arg CLOUDS="aws azure" -t pipesutils:aws-azure .
docker build --build-arg CLOUDS="aws azure gcp" -t pipesutils:all .
```

| `CLOUDS` | Plugins | Vendor CLI | Size | Published as |
| --- | --- | --- | --- | --- |
| `aws` (default) | steampipe + tailpipe `aws` | `aws` v2 | 1.44 GB | `latest`, `latest-aws` |
| `azure` | steampipe + tailpipe `azure` | `az` | 1.52 GB | `latest-azure` |
| `gcp` | steampipe + tailpipe `gcp` | `gcloud` | 1.66 GB | `latest-gcp` |
| `aws azure gcp` | all six | all three | 3.18 GB | not published — build it yourself |

Sizes are measured, uncompressed, amd64.

Need two clouds in one container? Either build it (`--build-arg CLOUDS="aws
azure"`) or add the second cloud's plugins at startup with
`EXTRA_STEAMPIPE_PLUGINS` — the vendor CLI is the only part that cannot be
added at run time.

The plugin and the vendor CLI ship together because for two of the three
clouds they are not independent:

* The **Azure** plugin's credential chain ends at
  `azidentity.NewAzureCLICredential` — it executes `az` unless you hand it a
  client secret or certificate. It has no workload-identity credential, so
  `az login --federated-token` is the only secretless path on EKS.
* The **GCP** plugin reads Application Default Credentials, which is what
  `gcloud auth application-default login` writes.
* **AWS** needs no CLI for IRSA, but `aws sso login`, `aws logs tail` and
  `sts get-caller-identity` are what you reach for when a role is misbehaving.

Unselected clouds are decided in the build's fetch stage, so nothing is
downloaded and nothing lands in a lower layer to be deleted later — an
AWS-only image genuinely does not contain `az`.

### Build args

| Arg | Default | Notes |
| --- | --- | --- |
| `CLOUDS` | `aws` | space separated: `aws`, `azure`, `gcp`. A typo fails the build immediately |
| `STEAMPIPE_VERSION` / `TAILPIPE_VERSION` / `POWERPIPE_VERSION` | pinned tags | release tags on the turbot repos |
| `STEAMPIPE_PLUGINS` | follows `CLOUDS` | override to add plugins outside the cloud list, e.g. `"aws azuread"` |
| `TAILPIPE_PLUGINS` | follows `CLOUDS` | same |
| `INSTALL_AWS_CLI` | `auto` | `auto` follows `CLOUDS`; `true`/`false` force it |
| `INSTALL_AZURE_CLI` | `auto` | same |
| `INSTALL_GCLOUD` | `auto` | same |
| `PRELOAD_STEAMPIPE_DB` | `true` | pre-pull the embedded postgres |
| `INCLUDE_POWERPIPE` | `true` | set `false` to drop 132 MB |
| `PIPES_UID` / `PIPES_GID` | `10001` | must match `runAsUser` in your manifests |

The selected clouds are recorded on the image, so a running container can tell
what it is:

```bash
docker inspect -f '{{ index .Config.Labels "io.pipesutils.clouds" }}' <image>
echo "$PIPES_CLOUDS"   # same value, inside the container
```

Turbot release assets are checksum-verified against the release
`checksums.txt`; the AWS CLI installer is GPG-verified
([hack/fetch-release.sh](hack/fetch-release.sh),
[hack/fetch-cloud-clis.sh](hack/fetch-cloud-clis.sh)).

Plugins not baked in still install at run time as usual —
`steampipe plugin install azuread`.

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
| `EXTRA_STEAMPIPE_PLUGINS` | — | plugins to install at startup, space separated |
| `EXTRA_TAILPIPE_PLUGINS` | — | same, for tailpipe |
| `EXTRA_CLI` | — | vendor CLIs to install at startup. `aws` only — see below |

### Adding things at startup

Without rebuilding, for when you need something the image was not built with:

```bash
docker run --rm \
  -e EXTRA_STEAMPIPE_PLUGINS="azuread kubernetes" \
  -e EXTRA_TAILPIPE_PLUGINS="gcp" \
  ghcr.io/opsourced/pipesutils steampipe query "select 1"
```

In Kubernetes, set them on the container and the pod picks them up on restart:

```yaml
env:
  - name: EXTRA_STEAMPIPE_PLUGINS
    value: "azuread kubernetes"
```

Anything already present is detected and skipped, so this is safe to leave set.

Two caveats worth knowing before you rely on it:

* **It is not persistent.** Installs land in `$HOME`, which is an image layer,
  so they are re-downloaded on every container start — a few seconds and a few
  hundred MB each time. Mount a volume over `~/.steampipe/plugins` to keep
  them, or bake them in with `CLOUDS` / `STEAMPIPE_PLUGINS` once you know what
  you need.
* **`EXTRA_CLI` only supports `aws`.** The AWS CLI has a self-contained
  installer that works in a user directory. `az` and `gcloud` come from vendor
  apt repos and need root, which this container does not have — asking for
  them fails with a message pointing at `latest-azure` / `latest-gcp` rather
  than half-installing something. The AWS startup install is also HTTPS-only, with
  none of the GPG verification the build-time install does, so prefer a baked
  image where it matters.

## CI

[.github/workflows/build.yml](.github/workflows/build.yml) builds each arch
**natively** — `ubuntu-24.04` and `ubuntu-24.04-arm` — because the build runs
`steampipe plugin install` and `steampipe service start`, which under QEMU is
slow and flaky. Each arch is pushed by digest, then a `merge` job joins them
into one manifest list, and cosign keyless-signs it.

Three variants are published from the same Dockerfile, each as its own
manifest list covering both architectures:

| Cloud | Tags |
| --- | --- |
| AWS | `latest`, `latest-aws`, `v1.2.3`, `1.2`, `sha-<sha>` |
| Azure | `latest-azure`, `v1.2.3-azure`, `1.2-azure`, `sha-<sha>-azure` |
| GCP | `latest-gcp`, `v1.2.3-gcp`, `1.2-gcp`, `sha-<sha>-gcp` |

* PRs: all three clouds, **amd64 only**, build + smoke test, nothing pushed.
  Arch-specific breakage is rare and caught on `main`; a cloud-specific
  regression would not be.
* `main` and tags: all three clouds on both architectures, signed and scanned
  per variant.
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

### First publish: make the package public

GHCR packages are **private by default**, even when the repository is public.
Until someone flips this, `docker pull` prompts anonymous users for
credentials. All three cloud variants are tags on a single `pipesutils`
package, so this is one switch, done once:

1. Push to `main` so the workflow creates the package.
2. Go to the package page — either from the repo's right-hand sidebar under
   **Packages**, or directly:
   `https://github.com/orgs/OpSourced/packages/container/package/pipesutils`
3. **Package settings** (right-hand side) → scroll to **Danger Zone** →
   **Change visibility** → **Public**, then type the package name to confirm.

While in package settings, check **Manage Actions access** lists this
repository with at least `Write` — that is what lets the workflow push new
tags. The image sets `org.opencontainers.image.source`, so GitHub links the
package to this repo automatically and the repo README shows on the package
page.

Repository visibility is separate: **repo Settings → General → Danger Zone →
Change repository visibility**.

The Trivy scan authenticates with `GITHUB_TOKEN` rather than relying on the
package being public, so scanning works before and after this switch.

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
the plugins and the Postgres FDW are Apache-2.0; the AWS and Google Cloud CLIs
are Apache-2.0 (with some Google SDK components under Google's SDK terms) and
the Azure CLI is MIT. That combination is fine to
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
