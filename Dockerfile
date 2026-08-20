# syntax=docker/dockerfile:1.9

###############################################################################
# Tailpipe image: collect cloud logs into a local parquet lake.
#
# One knob drives the contents: CLOUDS. It selects the tailpipe plugins AND the
# matching vendor CLI, because the two travel together - the vendor CLI is how
# you authenticate interactively and how you ship parquet on to object storage.
#
#   --build-arg CLOUDS="aws"      default
#   --build-arg CLOUDS="azure"
#   --build-arg CLOUDS="gcp"
#
# Built natively per architecture (linux/amd64, linux/arm64) and joined into a
# manifest list by .github/workflows/build.yml.
###############################################################################

ARG DEBIAN_TAG=bookworm-slim

# Renovate/dependabot-friendly pin. Bump to upgrade the CLI.
ARG TAILPIPE_VERSION=v0.7.4

# Which clouds this image speaks. Space separated: aws, azure, gcp.
ARG CLOUDS="aws"

# Runtime user.
ARG PIPES_UID=10001
ARG PIPES_GID=10001
ARG PIPES_USER=pipes

###############################################################################
# Stage 1 - download and verify everything that comes from outside
###############################################################################
FROM debian:${DEBIAN_TAG} AS fetch

ARG TAILPIPE_VERSION
ARG TARGETARCH
ARG CLOUDS

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

RUN fetch-release.sh tailpipe "${TAILPIPE_VERSION}" "tailpipe.linux.${TARGETARCH}.tar.gz"

# AWS CLI v2 is a GPG-signed installer rather than a release tarball. The Azure
# and Google CLIs come from apt repos whose keys are fetched here, so the
# runtime stage never needs gnupg.
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
ARG TAILPIPE_VERSION
ARG CLOUDS

ARG INSTALL_AWS_CLI=auto
ARG INSTALL_AZURE_CLI=auto
ARG INSTALL_GCLOUD=auto

# Plugins to bake in, space separated, passed straight to `tailpipe plugin
# install`. Empty means "follow CLOUDS", which is what you usually want.
ARG TAILPIPE_PLUGINS=""

# Base is debian:bookworm-slim and cannot be alpine - see "Why this base" in
# the README. Short version: tailpipe embeds DuckDB, is a cgo build, and is
# dynamically linked against glibc.
#
# ca-certificates : TLS to the cloud APIs and GHCR
# libstdc++6      : embedded DuckDB
# tzdata          : timestamp handling in queries
# curl, unzip     : EXTRA_CLI startup installs, and general debugging
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      libstdc++6 \
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

# Non-root by default. Tailpipe does not require it, but the parquet lake and
# the plugin directory are the only things that need write access, so there is
# no reason to run privileged.
RUN groupadd -g "${PIPES_GID}" "${PIPES_USER}" \
 && useradd -l -u "${PIPES_UID}" -g "${PIPES_GID}" -m -d "/home/${PIPES_USER}" -s /bin/bash "${PIPES_USER}"

ENV HOME="/home/${PIPES_USER}" \
    TAILPIPE_INSTALL_DIR="/home/${PIPES_USER}/.tailpipe" \
    PIPES_CLOUDS="${CLOUDS}" \
    TAILPIPE_UPDATE_CHECK=false \
    TAILPIPE_TELEMETRY=none \
    LANG=C.UTF-8

RUN mkdir -p "${TAILPIPE_INSTALL_DIR}" \
 && chown -R "${PIPES_UID}:${PIPES_GID}" "${TAILPIPE_INSTALL_DIR}"

USER ${PIPES_UID}:${PIPES_GID}
WORKDIR ${TAILPIPE_INSTALL_DIR}

# Plugins, baked as the runtime user so ownership is right.
RUN set -eux; \
    for p in ${TAILPIPE_PLUGINS:-${CLOUDS}}; do tailpipe plugin install "$p" --progress=false; done

COPY docker/entrypoint.sh /usr/local/bin/pipes-entrypoint.sh

# Redistribution notices for the bundled upstream binaries. Tailpipe is
# AGPL-3.0 and is shipped unmodified; see THIRD_PARTY_LICENSES.md.
COPY LICENSE NOTICE THIRD_PARTY_LICENSES.md /usr/share/doc/pipesutils/

LABEL org.opencontainers.image.title="pipesutils" \
      org.opencontainers.image.description="Multi-arch Tailpipe image with the plugin and vendor CLI for each selected cloud" \
      org.opencontainers.image.source="https://github.com/OpSourced/pipesutils" \
      org.opencontainers.image.url="https://github.com/OpSourced/pipesutils" \
      org.opencontainers.image.vendor="OpSourced" \
      org.opencontainers.image.licenses="Apache-2.0 AND AGPL-3.0-or-later AND MIT" \
      io.pipesutils.clouds="${CLOUDS}" \
      io.pipesutils.tailpipe-version="${TAILPIPE_VERSION}"

ENTRYPOINT ["/usr/local/bin/pipes-entrypoint.sh"]
CMD ["sleep", "infinity"]
