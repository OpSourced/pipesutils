# Third-party components in the pipesutils image

The image redistributes third-party software **unmodified**. This repository's
own files (Dockerfile, entrypoint, build scripts, CI) are Apache-2.0; the
components below keep their own licenses, and those licenses govern their use.

Nothing here is patched, recompiled, or statically linked into our code — each
component is downloaded from its upstream release, checksum-verified against
the publisher's `checksums.txt`, and installed as a separate binary. Under GPL
terminology this is mere aggregation.

## Tailpipe (AGPL-3.0)

| Component | License | Source |
| --- | --- | --- |
| Tailpipe CLI | AGPL-3.0-or-later | https://github.com/turbot/tailpipe |

The AGPL applies to this binary, not to the rest of the image and not to this
repository. Because it is redistributed unmodified, the corresponding source
is the upstream release named in the image label
`io.pipesutils.tailpipe-version` at the URL above. If you modify it and offer
the result to users over a network, AGPL-3.0 section 13 requires you to offer
those users the modified source.

## Plugins pulled at build time (Apache-2.0)

| Component | License | Source |
| --- | --- | --- |
| tailpipe-plugin-aws | Apache-2.0 | https://github.com/turbot/tailpipe-plugin-aws |
| tailpipe-plugin-azure | Apache-2.0 | https://github.com/turbot/tailpipe-plugin-azure |
| tailpipe-plugin-gcp | Apache-2.0 | https://github.com/turbot/tailpipe-plugin-gcp |
| tailpipe-plugin-core | Apache-2.0 | https://github.com/turbot/tailpipe-plugin-core |

Which plugins are present follows the `CLOUDS` build arg (or the
`TAILPIPE_PLUGINS` override); the table above lists every plugin any variant
can contain. Run `tailpipe plugin list` in a container to see what a given
image actually contains.

## Vendor cloud CLIs

| Component | License | Source |
| --- | --- | --- |
| AWS CLI v2 | Apache-2.0 | https://github.com/aws/aws-cli |
| Azure CLI | MIT | https://github.com/Azure/azure-cli |
| Google Cloud CLI | Apache-2.0, some components under the [Google Cloud SDK Terms of Service](https://cloud.google.com/sdk/docs/terms) | https://cloud.google.com/sdk |

The AWS CLI installer is GPG-verified against the AWS CLI Team key
(`FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C`, committed at
[hack/aws-cli-public-key.asc](hack/aws-cli-public-key.asc)) before it is
unpacked. The Azure and Google CLIs come from their vendor apt repositories,
verified by apt against the repository signing keys.

Each ships its own copyright file inside the image:
`/usr/share/doc/azure-cli/copyright` and
`/usr/share/doc/google-cloud-cli/copyright`.

Which of these are present follows the `CLOUDS` build arg — an `aws` image
contains only the AWS CLI. Check a given image with:

```bash
docker inspect -f '{{ index .Config.Labels "io.pipesutils.clouds" }}' <image>
```

## Embedded in the upstream binaries

| Component | License | Notes |
| --- | --- | --- |
| DuckDB | MIT | embedded query engine inside Tailpipe |

## Base image

`debian:bookworm-slim` plus `ca-certificates`, `curl`, `libstdc++6`, `tzdata`
and `unzip`. Debian packages carry their own licenses; see
`/usr/share/doc/*/copyright` inside the image, and Debian's
[license information](https://www.debian.org/legal/licenses/).

## Reproducing the license set for a specific image

The published images ship an SBOM attestation:

```bash
docker buildx imagetools inspect ghcr.io/opsourced/pipesutils:latest \
  --format '{{ json .SBOM }}'
```
