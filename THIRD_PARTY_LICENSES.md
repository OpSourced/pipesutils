# Third-party components in the pipesutils image

The image redistributes third-party software **unmodified**. This repository's
own files (Dockerfile, entrypoint, build scripts, CI) are Apache-2.0; the
components below keep their own licenses, and those licenses govern their use.

Nothing here is patched, recompiled, or statically linked into our code — each
component is downloaded from its upstream release, checksum-verified against
the publisher's `checksums.txt`, and installed as a separate binary. Under GPL
terminology this is mere aggregation.

## CLIs (AGPL-3.0)

| Component | License | Source |
| --- | --- | --- |
| Steampipe CLI | AGPL-3.0-or-later | https://github.com/turbot/steampipe |
| Tailpipe CLI | AGPL-3.0-or-later | https://github.com/turbot/tailpipe |
| Powerpipe CLI | AGPL-3.0-or-later | https://github.com/turbot/powerpipe |

The AGPL applies to these binaries, not to the rest of the image and not to
this repository. Because they are redistributed unmodified, the corresponding
source is the upstream release tagged in the image labels
(`io.pipesutils.steampipe-version` and friends) at the URLs above. If you
modify them and offer the result to users over a network, AGPL-3.0 section 13
requires you to offer those users the modified source.

## Plugins and libraries pulled at build time (Apache-2.0)

| Component | License | Source |
| --- | --- | --- |
| steampipe-postgres-fdw | Apache-2.0 | https://github.com/turbot/steampipe-postgres-fdw |
| steampipe-plugin-aws | Apache-2.0 | https://github.com/turbot/steampipe-plugin-aws |
| tailpipe-plugin-aws | Apache-2.0 | https://github.com/turbot/tailpipe-plugin-aws |
| tailpipe-plugin-core | Apache-2.0 | https://github.com/turbot/tailpipe-plugin-core |

Which plugins are present depends on the `STEAMPIPE_PLUGINS` and
`TAILPIPE_PLUGINS` build args; the defaults are listed above. Run
`steampipe plugin list` / `tailpipe plugin list` in a container to see what a
given image actually contains.

## Embedded in the upstream binaries

| Component | License | Notes |
| --- | --- | --- |
| PostgreSQL 14 | PostgreSQL License | embedded database, pulled by Steampipe from `ghcr.io/turbot/steampipe/db` |
| DuckDB | MIT | embedded query engine inside Tailpipe and Powerpipe |

## Base image

`debian:bookworm-slim` plus `ca-certificates`, `git`, `less`, `libstdc++6`,
`procps` and `tzdata`. Debian packages carry their own licenses; see
`/usr/share/doc/*/copyright` inside the image, and Debian's
[license information](https://www.debian.org/legal/licenses/).

## Reproducing the license set for a specific image

The published images ship an SBOM attestation:

```bash
docker buildx imagetools inspect ghcr.io/opsourced/pipesutils:latest \
  --format '{{ json .SBOM }}'
```
