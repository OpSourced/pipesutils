# Security policy

## Reporting a vulnerability

Report vulnerabilities in this repository's own code (Dockerfile, entrypoint,
build scripts, workflows) privately through GitHub's
[security advisory form](https://github.com/OpSourced/pipesutils/security/advisories/new),
or by email to security@opsourced.com. Please do not open a public issue first.

We aim to acknowledge within 3 business days.

## What is in scope

The build and packaging: how binaries are fetched and verified, what the image
runs as, what is baked into it, and what the workflow publishes.

Vulnerabilities in **Steampipe, Tailpipe, Powerpipe or their plugins** belong
upstream at [github.com/turbot](https://github.com/turbot) — this image ships
those binaries unmodified. Tell us anyway if a fixed upstream release needs
picking up here, and we will bump the pinned version.

## Supply chain

* Every CLI is downloaded from its upstream GitHub release and verified
  against the publisher's `checksums.txt` before it is installed. A mismatch
  fails the build.
* Published manifest lists are signed with
  [cosign](https://github.com/sigstore/cosign) using keyless OIDC signing:

  ```bash
  cosign verify ghcr.io/opsourced/pipesutils:latest \
    --certificate-identity-regexp '^https://github\.com/OpSourced/pipesutils/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```

* Images carry SBOM and max-mode provenance attestations:

  ```bash
  docker buildx imagetools inspect ghcr.io/opsourced/pipesutils:latest \
    --format '{{ json .Provenance }}'
  ```

* The image is rebuilt weekly to pick up base-image patches, and scanned with
  Trivy on every push to `main`; results land in the repository's code scanning
  alerts.

## Hardening notes for operators

The image runs as uid/gid 10001 and needs no capabilities. It does need a
writable filesystem under `$STEAMPIPE_INSTALL_DIR` for the embedded PostgreSQL
data directory, so `readOnlyRootFilesystem: true` will not work without
mounting writable volumes over those paths.

Credentials are never baked in. Supply them at run time — IRSA/Pod Identity on
EKS, or the usual AWS environment variables elsewhere.
