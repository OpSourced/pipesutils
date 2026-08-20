# pipesutils

[![build](https://github.com/OpSourced/pipesutils/actions/workflows/build.yml/badge.svg)](https://github.com/OpSourced/pipesutils/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Multi-arch (`linux/amd64` + `linux/arm64`) container image for
[Tailpipe](https://tailpipe.io) — collecting cloud logs into a local parquet
lake — with the plugin and vendor CLI for one cloud preinstalled.

```bash
docker pull ghcr.io/opsourced/pipesutils:latest
docker run --rm ghcr.io/opsourced/pipesutils tailpipe --version
```

Three images, one per cloud. Free to use, no login needed to pull.

| Tag | Contains | Size |
| --- | --- | --- |
| `latest`, `latest-aws` | tailpipe + `aws` plugin + AWS CLI v2 | 623 MB |
| `latest-azure` | tailpipe + `azure` plugin + Azure CLI | ~700 MB |
| `latest-gcp` | tailpipe + `gcp` plugin + gcloud | ~850 MB |

Versioned tags follow the same pattern: `v1.2.3`, `1.2`, `sha-<commit>`, each
with the `-azure` / `-gcp` suffix.

## What's in it

* `debian:bookworm-slim`, running as uid/gid **10001** (`pipes`).
* Tailpipe, checksum-verified against the release `checksums.txt`.
* The selected cloud's tailpipe plugin, baked in — no download on first run.
* That cloud's vendor CLI: `aws` (GPG-verified installer), `az` or `gcloud`
  (vendor apt repos).
* Runtime packages kept to `ca-certificates`, `libstdc++6` (embedded DuckDB),
  `tzdata`, and `curl`/`unzip` for the startup installs below.
* Telemetry and update checks off.

### Why this base

`debian:bookworm-slim`, **not alpine** — tested, not assumed:

```console
$ docker run --rm -v ./bin:/t alpine:3.22 /t/tailpipe --version
exec /t/tailpipe: no such file or directory     # wants /lib64/ld-linux-x86-64.so.2
```

Tailpipe embeds DuckDB, so it is a cgo build, dynamically linked against
glibc. musl bases would need `gcompat` shims under DuckDB, which nobody
supports.

| Base | Size | Verdict |
| --- | --- | --- |
| `alpine:3.22` | 8.3 MB | musl — the binary does not exec |
| `cgr.dev/chainguard/wolfi-base` | 16.3 MB | glibc, but no `azure-cli` package |
| `gcr.io/distroless/base-debian12` | 20.8 MB | no shell — breaks `kubectl exec` |
| **`debian:bookworm-slim`** | **74.8 MB** | glibc 2.36, vendor apt repos support it |

Wolfi is the near miss: glibc 2.41 and 58 MB smaller, with `aws-cli-2` and
`google-cloud-sdk` packaged — but no `azure-cli`, and `az` has no install path
that is not apt or pip. Worth revisiting if the Azure variant is ever dropped;
at 623 MB the base is now 12% of the image rather than a rounding error.

## Build args

| Arg | Default | Notes |
| --- | --- | --- |
| `CLOUDS` | `aws` | `aws`, `azure`, `gcp`. A typo fails the build immediately |
| `TAILPIPE_VERSION` | pinned tag | release tag on `turbot/tailpipe` |
| `TAILPIPE_PLUGINS` | follows `CLOUDS` | override to bake something else, e.g. `"aws kubernetes"` |
| `INSTALL_AWS_CLI` | `auto` | `auto` follows `CLOUDS`; `true`/`false` force it |
| `INSTALL_AZURE_CLI` | `auto` | same |
| `INSTALL_GCLOUD` | `auto` | same |
| `PIPES_UID` / `PIPES_GID` | `10001` | must match `runAsUser` in your manifests |

```bash
docker build --build-arg CLOUDS=azure -t pipesutils:azure .
```

Unselected clouds are decided in the build's fetch stage, so nothing is
downloaded and nothing lands in a lower layer to be deleted later — an AWS
image genuinely does not contain `az`.

Which cloud an image speaks is recorded on it:

```bash
docker inspect -f '{{ index .Config.Labels "io.pipesutils.clouds" }}' <image>
echo "$PIPES_CLOUDS"   # same value, inside the container
```

## Running it

```bash
# collect, with credentials from the environment
docker run --rm -v tailpipe-data:/home/pipes/.tailpipe/data \
  ghcr.io/opsourced/pipesutils tailpipe collect --progress=false

# query the lake
docker run --rm -v tailpipe-data:/home/pipes/.tailpipe/data \
  ghcr.io/opsourced/pipesutils tailpipe query "select count(*) from aws_cloudtrail_log"
```

| Path | Contents |
| --- | --- |
| `/home/pipes/.tailpipe/config` | partition definitions (`.tpc`) |
| `/home/pipes/.tailpipe/data` | the parquet lake — mount persistent storage here |

Plugins live in `/home/pipes/.tailpipe/plugins` inside the image layer, so
mounting the two paths above does not shadow them.

### Adding things at startup

| Var | Effect |
| --- | --- |
| `EXTRA_TAILPIPE_PLUGINS` | plugins to install at startup, space separated |
| `EXTRA_CLI` | vendor CLIs to install at startup — `aws` only |

```bash
docker run -e EXTRA_TAILPIPE_PLUGINS="kubernetes nginx" ghcr.io/opsourced/pipesutils
```

Anything already present is skipped, so this is safe to leave set. Two
caveats: installs land in `$HOME`, an image layer, so they are re-downloaded
on every start unless you mount a volume over `~/.tailpipe/plugins`; and
`EXTRA_CLI` only supports `aws`, because `az` and `gcloud` come from apt repos
needing root. Asking for those fails pointing at `latest-azure`/`latest-gcp`
rather than half-installing something.

## CI

[build.yml](.github/workflows/build.yml) builds each cloud on each
architecture **natively** — `ubuntu-24.04` and `ubuntu-24.04-arm` — because
the build runs `tailpipe plugin install`, which under QEMU is slow and flaky.
Each arch is pushed by digest, a `merge` job joins them into one manifest list
per cloud, cosign keyless-signs it, and Trivy scans the result into code
scanning.

* PRs: all three clouds, **amd64 only**, build + smoke test, nothing pushed.
* `main` and tags: all three clouds on both architectures.
* Weekly rebuild for base-image CVE patches.
* [cli-updates.yml](.github/workflows/cli-updates.yml) opens a PR when
  tailpipe releases — Dependabot covers the base image but cannot see that
  build arg.
* [lint.yml](.github/workflows/lint.yml) runs actionlint, hadolint and
  shellcheck on every PR.

### First publish: make the package public

GHCR packages are **private by default**, even when the repository is public.
All three variants are tags on a single `pipesutils` package, so this is one
switch, done once:

1. Push to `main` so the workflow creates the package.
2. Package page — repo sidebar under **Packages**, or
   `https://github.com/orgs/OpSourced/packages/container/package/pipesutils`
3. **Package settings** → **Danger Zone** → **Change visibility** → **Public**.

While there, check **Manage Actions access** lists this repository with at
least `Write`. Repository visibility is separate: **Settings → General →
Danger Zone**.

The Trivy scan authenticates with `GITHUB_TOKEN` rather than relying on the
package being public, so scanning works before and after this switch.

## Verifying what you pulled

```bash
cosign verify ghcr.io/opsourced/pipesutils:latest \
  --certificate-identity-regexp '^https://github\.com/OpSourced/pipesutils/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect ghcr.io/opsourced/pipesutils:latest \
  --format '{{ json .SBOM }}'
```

Tailpipe is checksum-verified against the publisher's `checksums.txt` and the
AWS CLI installer is GPG-verified at build time, so a tampered release fails
the build instead of shipping.

## License

This repository — Dockerfile, entrypoint, build scripts, CI — is
[Apache-2.0](LICENSE).

The **image** redistributes third-party binaries under their own licenses:
Tailpipe is **AGPL-3.0**, shipped unmodified; its plugins are Apache-2.0; the
AWS and Google Cloud CLIs are Apache-2.0 (with some Google SDK components
under Google's SDK terms) and the Azure CLI is MIT. Using tailpipe to collect
your own logs carries no obligation; AGPL-3.0 section 13 only applies if you
modify tailpipe itself and offer it to users over a network.

Full breakdown with source links: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md),
also shipped inside the image at `/usr/share/doc/pipesutils/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go through
[SECURITY.md](SECURITY.md), not public issues.
