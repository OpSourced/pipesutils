# syntax=docker/dockerfile:1.9

###############################################################################
# Turbot Pipes CLI image: steampipe + tailpipe (+ powerpipe).
#
# One knob drives the contents: CLOUDS. It selects the steampipe and tailpipe
# plugins AND the matching vendor CLI, because the two travel together - the
# Azure plugin literally shells out to `az` unless you hand it a client secret,
# and `gcloud` is what mints Application Default Credentials.
#
#   --build-arg CLOUDS="aws"              default: AWS only, ~1.2 GB
#   --build-arg CLOUDS="aws azure gcp"    everything, ~3.2 GB
#
# Built natively per architecture (linux/amd64, linux/arm64) and joined into a
# manifest list by .github/workflows/build.yml.
###############################################################################

ARG DEBIAN_TAG=bookworm-slim

# Renovate/dependabot-friendly pins. Bump these to upgrade the CLIs.
ARG STEAMPIPE_VERSION=v2.4.5
ARG TAILPIPE_VERSION=v0.7.4
ARG POWERPIPE_VERSION=v1.5.3

# Which clouds this image speaks. Space separated: aws, azure, gcp.
ARG CLOUDS="aws"

# Runtime user. initdb (embedded postgres) refuses to run as root and requires
# the uid to resolve to a real passwd entry, so this uid is baked in.
ARG PIPES_UID=10001
ARG PIPES_GID=10001
ARG PIPES_USER=pipes

###############################################################################
# Stage 1 - download and verify everything that comes from outside
###############################################################################
FROM debian:${DEBIAN_TAG} AS fetch

ARG STEAMPIPE_VERSION
ARG TAILPIPE_VERSION
ARG POWERPIPE_VERSION
ARG TARGETARCH
ARG CLOUDS
ARG INCLUDE_POWERPIPE=true

# auto = follow CLOUDS. true/false force it either way.
ARG INSTALL_AWS_CLI=auto
ARG INSTALL_AZURE_CLI=auto
ARG INSTALL_GCLOUD=auto

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg unzip \
 && rm -rf /var/lib/apt/lists/*

COPY hack/cloud-select.sh hack/fetch-release.sh hack/fetch-cloud-clis.sh /usr/local/bin/
COPY hack/aws-cli-public-key.asc /usr/local/share/aws-cli-public-key.asc

# Fail on a typo'd cloud here rather than 20 minutes into the build.
RUN cloud-select.sh validate

RUN fetch-release.sh steampipe "${STEAMPIPE_VERSION}" "steampipe_linux_${TARGETARCH}.tar.gz"
RUN fetch-release.sh tailpipe  "${TAILPIPE_VERSION}"  "tailpipe.linux.${TARGETARCH}.tar.gz"
RUN if [ "${INCLUDE_POWERPIPE}" = "true" ]; then \
      fetch-release.sh powerpipe "${POWERPIPE_VERSION}" "powerpipe.linux.${TARGETARCH}.tar.gz"; \
    fi

# AWS CLI v2 is a GPG-signed installer rather than a release tarball. The Azure
# and Google CLIs come from apt repos whose keys are fetched here, so the
# runtime stage never needs curl or gnupg.
#
# Both steps are no-ops when the cloud is not selected, and they leave empty
# directories behind: the runtime stage copies unconditionally, so deciding
# here is what keeps unselected content out of the image entirely rather than
# shadowed by a later `rm`.
RUN fetch-cloud-clis.sh awscli
RUN fetch-cloud-clis.sh keyrings

###############################################################################
# Stage 2 - runtime
###############################################################################
FROM debian:${DEBIAN_TAG} AS runtime

ARG PIPES_UID
ARG PIPES_GID
ARG PIPES_USER
ARG STEAMPIPE_VERSION
ARG TAILPIPE_VERSION
ARG POWERPIPE_VERSION
ARG CLOUDS

ARG INSTALL_AWS_CLI=auto
ARG INSTALL_AZURE_CLI=auto
ARG INSTALL_GCLOUD=auto

# Plugins to bake in, space separated, passed straight to `<cli> plugin
# install`. Empty means "follow CLOUDS", which is what you usually want; set
# them explicitly to add something outside the cloud list, e.g. "aws azuread".
ARG STEAMPIPE_PLUGINS=""
ARG TAILPIPE_PLUGINS=""

# Pre-download the embedded postgres (pulled from ghcr.io/turbot) so a fresh
# pod does not have to fetch ~250MB before its first query.
ARG PRELOAD_STEAMPIPE_DB=true

# Base is debian:bookworm-slim and cannot be alpine - see "Why this base" in
# the README. Short version: the embedded postgres and the DuckDB-backed CLIs
# are glibc-linked, and steampipe v2 requires glibc >= 2.34.
#
# ca-certificates : TLS to the cloud APIs and GHCR
# git             : `powerpipe mod install`, mod dependency resolution
# less            : steampipe/powerpipe pager
# tzdata          : timestamp handling in queries
# procps          : steampipe service start/stop process checks
# libstdc++6      : embedded DuckDB used by tailpipe/powerpipe
# curl, unzip     : EXTRA_CLI startup installs, and general debugging
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      less \
      libstdc++6 \
      procps \
      tzdata \
      unzip \
 && rm -rf /var/lib/apt/lists/*

COPY hack/cloud-select.sh /usr/local/bin/cloud-select.sh
COPY --from=fetch /out/keyrings/ /etc/apt/keyrings/

# Azure and Google Cloud CLIs from their vendor apt repos - both ship arm64
# builds, and azure-cli bundles its own python so it costs no extra deps.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    pkgs=""; \
    if cloud-select.sh want azure "${INSTALL_AZURE_CLI}"; then \
      echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main" \
        > /etc/apt/sources.list.d/azure-cli.list; \
      pkgs="${pkgs} azure-cli"; \
    fi; \
    if cloud-select.sh want gcp "${INSTALL_GCLOUD}"; then \
      echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list; \
      pkgs="${pkgs} google-cloud-cli"; \
    fi; \
    if [ -n "${pkgs}" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends ${pkgs}; \
      rm -rf /var/lib/apt/lists/*; \
    fi

COPY --from=fetch /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=fetch /out/bin/ /usr/local/bin/

# COPY dereferences a symlink named as the source, so the /usr/local/bin
# entrypoints have to be recreated here rather than copied - a dereferenced
# `aws` binary looks for its bundled libpython next to itself and dies.
RUN set -eux; \
    if [ -x /usr/local/aws-cli/v2/current/bin/aws ]; then \
      ln -sf /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws; \
      ln -sf /usr/local/aws-cli/v2/current/bin/aws_completer /usr/local/bin/aws_completer; \
    fi

RUN groupadd -g "${PIPES_GID}" "${PIPES_USER}" \
 && useradd -l -u "${PIPES_UID}" -g "${PIPES_GID}" -m -d "/home/${PIPES_USER}" -s /bin/bash "${PIPES_USER}"

ENV HOME="/home/${PIPES_USER}" \
    STEAMPIPE_INSTALL_DIR="/home/${PIPES_USER}/.steampipe" \
    TAILPIPE_INSTALL_DIR="/home/${PIPES_USER}/.tailpipe" \
    POWERPIPE_INSTALL_DIR="/home/${PIPES_USER}/.powerpipe" \
    PIPES_WORKSPACE_DIR="/workspace" \
    PIPES_CLOUDS="${CLOUDS}" \
    STEAMPIPE_UPDATE_CHECK=false \
    TAILPIPE_UPDATE_CHECK=false \
    POWERPIPE_UPDATE_CHECK=false \
    STEAMPIPE_TELEMETRY=none \
    TAILPIPE_TELEMETRY=none \
    POWERPIPE_TELEMETRY=none \
    LANG=C.UTF-8

RUN mkdir -p "${STEAMPIPE_INSTALL_DIR}" "${TAILPIPE_INSTALL_DIR}" "${POWERPIPE_INSTALL_DIR}" "${PIPES_WORKSPACE_DIR}" \
 && chown -R "${PIPES_UID}:${PIPES_GID}" \
      "${STEAMPIPE_INSTALL_DIR}" "${TAILPIPE_INSTALL_DIR}" "${POWERPIPE_INSTALL_DIR}" "${PIPES_WORKSPACE_DIR}"

USER ${PIPES_UID}:${PIPES_GID}
WORKDIR ${PIPES_WORKSPACE_DIR}

# Plugins, baked as the runtime user so ownership is right.
RUN set -eux; \
    for p in ${STEAMPIPE_PLUGINS:-${CLOUDS}}; do steampipe plugin install "$p" --progress=false; done; \
    for p in ${TAILPIPE_PLUGINS:-${CLOUDS}}; do tailpipe plugin install "$p" --progress=false; done

RUN set -eux; \
    if [ "${PRELOAD_STEAMPIPE_DB}" = "true" ]; then \
      steampipe service start --database-listen local; \
      steampipe service stop; \
      rm -rf "${STEAMPIPE_INSTALL_DIR}"/db/*/data \
             "${STEAMPIPE_INSTALL_DIR}"/internal \
             "${STEAMPIPE_INSTALL_DIR}"/logs/*; \
    fi

COPY docker/entrypoint.sh /usr/local/bin/pipes-entrypoint.sh

# Redistribution notices for the bundled upstream binaries. The CLIs are
# AGPL-3.0 and are shipped unmodified; see THIRD_PARTY_LICENSES.md.
COPY LICENSE NOTICE THIRD_PARTY_LICENSES.md /usr/share/doc/pipesutils/

LABEL org.opencontainers.image.title="pipesutils" \
      org.opencontainers.image.description="Multi-arch image with the Turbot Pipes CLIs (steampipe, tailpipe, powerpipe) plus the plugins and vendor CLI for each selected cloud" \
      org.opencontainers.image.source="https://github.com/OpSourced/pipesutils" \
      org.opencontainers.image.url="https://github.com/OpSourced/pipesutils" \
      org.opencontainers.image.vendor="OpSourced" \
      org.opencontainers.image.licenses="Apache-2.0 AND AGPL-3.0-or-later AND MIT" \
      io.pipesutils.clouds="${CLOUDS}" \
      io.pipesutils.steampipe-version="${STEAMPIPE_VERSION}" \
      io.pipesutils.tailpipe-version="${TAILPIPE_VERSION}" \
      io.pipesutils.powerpipe-version="${POWERPIPE_VERSION}"

ENTRYPOINT ["/usr/local/bin/pipes-entrypoint.sh"]
CMD ["sleep", "infinity"]
