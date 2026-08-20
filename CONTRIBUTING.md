# Contributing

Thanks for taking a look. This repo is small on purpose: it builds one image
containing [Tailpipe](https://tailpipe.io), its plugin for one cloud, and that
cloud's vendor CLI. Nothing else.

## What belongs here

* the `Dockerfile` and its build args
* the entrypoint and the release-fetch script
* the GitHub Actions build

Deployment manifests, dashboards and query libraries do **not** live here — the
image is meant to be dropped into whatever you already run.

## Building locally

```bash
docker build -t pipesutils:dev .
docker run --rm pipesutils:dev tailpipe query "select 1"
```

The default build is AWS-only. CI publishes one image per cloud, and you can
build any of them locally — or a combined one, which CI does not publish:

```bash
docker build --build-arg CLOUDS=azure -t pipesutils:azure .
docker build --build-arg CLOUDS=gcp   -t pipesutils:gcp .
docker build --build-arg CLOUDS="aws azure gcp" -t pipesutils:all .
```

If you touch anything cloud-specific, build the affected variant before
opening the PR. CI builds all three on every PR, but amd64 only.

For fast iteration on the Dockerfile itself, skip the slow parts:

```bash
docker build \
  --build-arg TAILPIPE_PLUGINS=" " \
  --build-arg INSTALL_AWS_CLI=false \
  -t pipesutils:dev .
```

## Bumping the tailpipe version

Change the `TAILPIPE_VERSION` default in the `Dockerfile`. Releases are
checksum-verified against the publisher's `checksums.txt`, so a bad tag fails
the build rather than shipping.

To test a version without committing:

```bash
docker build --build-arg TAILPIPE_VERSION=v0.7.3 -t pipesutils:test .
```

The same inputs exist on the `workflow_dispatch` trigger.

## Linting

CI runs these on every PR, and they take seconds - run them before pushing
rather than waiting on a 15-minute build:

```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest
docker run --rm -v "$PWD":/mnt -w /mnt ghcr.io/hadolint/hadolint:v2.15.0-debian \
  hadolint --config .hadolint.yaml Dockerfile
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:stable \
  hack/*.sh docker/entrypoint.sh
```

Use the **pinned** hadolint tag above, not `hadolint/hadolint:latest`. CI runs
whatever `hadolint-action` pins (2.15.0 today), and the two versions disagree:
2.15.1 fixed a DL3066 false positive that 2.15.0 still reports, so a `latest`
run locally passes while CI fails. If Dependabot bumps the action, bump this
tag with it.

`actionlint` in particular catches workflow expressions that GitHub rejects
only at run time — for example the `matrix` context, which is not available in
a job-level `if`.

Rules we deliberately ignore are listed with their reasons in
[.hadolint.yaml](.hadolint.yaml).

## Before opening a PR

* the linters above pass
* `docker build .` succeeds
* the smoke test passes:

  ```bash
  docker run --rm pipesutils:dev bash -lc '
    tailpipe --version && tailpipe plugin list && tailpipe query "select 1 as ok"'
  ```

CI runs that same smoke test on both `linux/amd64` and `linux/arm64` and
pushes nothing for pull requests.

## Things worth knowing before you change the Dockerfile

* **musl bases will not work.** Tailpipe embeds DuckDB, so it is a cgo build
  dynamically linked against glibc; on alpine it will not exec at all. The
  README's "Why this base" section has the full comparison, including why
  Wolfi and distroless were rejected — read it before proposing a base change.
* **Non-root is a choice, not a requirement.** Tailpipe runs fine as root, so
  nothing breaks loudly if uid 10001 is changed. Keep it anyway; only the lake
  and the plugin directory need write access.
* `libstdc++6` is needed by the DuckDB engine inside Tailpipe.
* The embedded PostgreSQL binaries bundle their own OpenSSL and do not link
  ICU, so do not add `libicu` back "just in case".
* Anything a build can exclude must be decided in the **fetch stage**. A
  `COPY` followed by a conditional `rm` in the runtime stage still leaves the
  bytes in the lower layer — the image gets no smaller, it just hides them.
* `COPY` dereferences a symlink named directly as its source. The AWS CLI's
  `/usr/local/bin/aws` is a symlink into a versioned tree; copy it and you get
  a binary that cannot find its own libpython.
* The build pre-pulls the embedded database and then deletes the initialised
  cluster and its generated password, so every container generates its own.
  Keep it that way.
