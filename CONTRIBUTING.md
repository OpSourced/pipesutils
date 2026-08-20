# Contributing

Thanks for taking a look. This repo is small on purpose: it builds one image
containing the [Turbot Pipes](https://turbot.com) CLIs and nothing else.

## What belongs here

* the `Dockerfile` and its build args
* the entrypoint and the release-fetch script
* the GitHub Actions build

Deployment manifests, dashboards and query libraries do **not** live here — the
image is meant to be dropped into whatever you already run.

## Building locally

```bash
docker build -t pipesutils:dev .
docker run --rm pipesutils:dev steampipe query "select 1"
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
  --build-arg STEAMPIPE_PLUGINS=" " \
  --build-arg TAILPIPE_PLUGINS=" " \
  --build-arg INSTALL_AWS_CLI=false \
  --build-arg PRELOAD_STEAMPIPE_DB=false \
  -t pipesutils:dev .
```

## Bumping CLI versions

Change the `STEAMPIPE_VERSION` / `TAILPIPE_VERSION` / `POWERPIPE_VERSION`
defaults in the `Dockerfile`. Releases are checksum-verified against the
publisher's `checksums.txt`, so a bad tag fails the build rather than shipping.

To test a version without committing:

```bash
docker build --build-arg STEAMPIPE_VERSION=v2.4.4 -t pipesutils:test .
```

The same inputs exist on the `workflow_dispatch` trigger.

## Before opening a PR

* `docker build .` succeeds
* the smoke test passes:

  ```bash
  docker run --rm pipesutils:dev bash -lc '
    steampipe --version && tailpipe --version && powerpipe --version &&
    steampipe query "select 1 as ok" --output json'
  ```

CI runs that same smoke test on both `linux/amd64` and `linux/arm64` and
pushes nothing for pull requests.

## Things worth knowing before you change the Dockerfile

* **The image cannot run as root.** Steampipe refuses uid 0, and its embedded
  `initdb` needs the uid to resolve to a real passwd entry. The `pipes` user
  (uid 10001) is load-bearing.
* **musl bases will not work.** Steampipe v2's FDW requires glibc >= 2.34. On
  alpine `tailpipe` will not exec at all and steampipe's embedded postgres
  fails at `Initializing database`. The README's "Why this base" section has
  the full comparison, including why Wolfi and distroless were rejected — read
  it before proposing a base change.
* `libstdc++6` is needed by the DuckDB engine inside Tailpipe and Powerpipe.
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
