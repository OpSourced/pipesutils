# syntax=docker/dockerfile:1.9

###############################################################################
# Turbot Pipes CLI image: steampipe + tailpipe (+ optional powerpipe).
#
# Built natively per architecture (linux/amd64, linux/arm64) and joined into a
# manifest list by .github/workflows/build.yml.
###############################################################################

ARG DEBIAN_TAG=bookworm-slim

# Renovate/dependabot-friendly pins. Bump these to upgrade the CLIs.
ARG STEAMPIPE_VERSION=v2.4.5
ARG TAILPIPE_VERSION=v0.7.4
ARG POWERPIPE_VERSION=v1.5.3

# Runtime user. initdb (embedded postgres) refuses to run as root and requires
# the uid to resolve to a real passwd entry, so this uid is baked in.
ARG PIPES_UID=10001
ARG PIPES_GID=10001
ARG PIPES_USER=pipes

###############################################################################
# Stage 1 - download + checksum-verify the CLI binaries
###############################################################################
FROM debian:${DEBIAN_TAG} AS fetch

ARG STEAMPIPE_VERSION
ARG TAILPIPE_VERSION
ARG POWERPIPE_VERSION
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

COPY hack/fetch-release.sh /usr/local/bin/fetch-release.sh

RUN fetch-release.sh steampipe "${STEAMPIPE_VERSION}" "steampipe_linux_${TARGETARCH}.tar.gz"
RUN fetch-release.sh tailpipe  "${TAILPIPE_VERSION}"  "tailpipe.linux.${TARGETARCH}.tar.gz"
RUN fetch-release.sh powerpipe "${POWERPIPE_VERSION}" "powerpipe.linux.${TARGETARCH}.tar.gz"

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
ARG INCLUDE_POWERPIPE=true

# Which plugins to bake in. Space separated, passed straight to
# `<cli> plugin install`. Baking them keeps Job pods cold-start free and makes
# the image self-contained (no registry pulls at run time).
ARG STEAMPIPE_PLUGINS="aws"
ARG TAILPIPE_PLUGINS="aws"

# Pre-download the embedded postgres (~14.x, pulled from ghcr.io/turbot) so a
# fresh pod does not have to fetch ~250MB before its first query.
ARG PRELOAD_STEAMPIPE_DB=true

# ca-certificates : TLS to AWS/GHCR
# git             : `powerpipe mod install`, mod dependency resolution
# less            : steampipe/powerpipe pager
# tzdata          : timestamp handling in queries
# procps          : steampipe service start/stop process checks
# libstdc++6      : embedded DuckDB used by tailpipe/powerpipe
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      less \
      libstdc++6 \
      procps \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd -g "${PIPES_GID}" "${PIPES_USER}" \
 && useradd -u "${PIPES_UID}" -g "${PIPES_GID}" -m -d "/home/${PIPES_USER}" -s /bin/bash "${PIPES_USER}"

COPY --from=fetch /out/bin/steampipe /usr/local/bin/steampipe
COPY --from=fetch /out/bin/tailpipe  /usr/local/bin/tailpipe
COPY --from=fetch /out/bin/powerpipe /usr/local/bin/powerpipe

RUN if [ "${INCLUDE_POWERPIPE}" != "true" ]; then rm -f /usr/local/bin/powerpipe; fi

ENV HOME="/home/${PIPES_USER}" \
    STEAMPIPE_INSTALL_DIR="/home/${PIPES_USER}/.steampipe" \
    TAILPIPE_INSTALL_DIR="/home/${PIPES_USER}/.tailpipe" \
    POWERPIPE_INSTALL_DIR="/home/${PIPES_USER}/.powerpipe" \
    PIPES_WORKSPACE_DIR="/workspace" \
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

# Plugins + embedded postgres, baked as the runtime user so ownership is right.
RUN set -eux; \
    for p in ${STEAMPIPE_PLUGINS}; do steampipe plugin install "$p" --progress=false; done; \
    for p in ${TAILPIPE_PLUGINS}; do tailpipe plugin install "$p" --progress=false; done

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
      org.opencontainers.image.description="Minimal multi-arch image with the Turbot Pipes CLIs (steampipe, tailpipe, powerpipe)" \
      org.opencontainers.image.source="https://github.com/OpSourced/pipesutils" \
      org.opencontainers.image.url="https://github.com/OpSourced/pipesutils" \
      org.opencontainers.image.vendor="OpSourced" \
      org.opencontainers.image.licenses="Apache-2.0 AND AGPL-3.0-or-later" \
      io.pipesutils.steampipe-version="${STEAMPIPE_VERSION}" \
      io.pipesutils.tailpipe-version="${TAILPIPE_VERSION}" \
      io.pipesutils.powerpipe-version="${POWERPIPE_VERSION}"

ENTRYPOINT ["/usr/local/bin/pipes-entrypoint.sh"]
CMD ["sleep", "infinity"]
