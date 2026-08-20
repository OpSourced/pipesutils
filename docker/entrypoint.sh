#!/usr/bin/env bash
# pipesutils entrypoint.
#
# Shapes this image runs in:
#   * StatefulSet pod you `kubectl exec` into  (CMD: sleep infinity)
#   * CronJob running a collection             (CMD overridden)
#   * `docker run pipesutils tailpipe collect` (CMD overridden)
#
# Env:
#   EXTRA_TAILPIPE_PLUGINS   space separated plugins to install at startup if
#                            not already baked in.
#   EXTRA_CLI                vendor CLIs to install at startup into
#                            $HOME/.local. Only "aws" is supported; see below.
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

# Persistent volumes mount in empty; make sure the dirs tailpipe expects exist.
# Ignore failures so a read-only mount is not fatal.
mkdir -p "${TAILPIPE_INSTALL_DIR:-}/data" 2>/dev/null || true

# --- startup installs ------------------------------------------------------
# These land in $HOME, which is an image layer unless a volume is mounted over
# it - so they are re-installed on every start. Fine while you work out what
# you need; bake them in with CLOUDS once you know.

install_plugins() {
  local list="$1" p
  for p in $list; do
    if tailpipe plugin list 2>/dev/null | grep -q "/${p%%@*}@"; then
      echo "==> tailpipe plugin ${p} already present"
      continue
    fi
    echo "==> installing tailpipe plugin ${p}"
    tailpipe plugin install "$p" --progress=false
  done
}

if [ -n "${EXTRA_TAILPIPE_PLUGINS:-}" ]; then
  install_plugins "$EXTRA_TAILPIPE_PLUGINS"
fi

install_cli() {
  local name="$1"
  case "$name" in
  aws)
    if command -v aws >/dev/null 2>&1; then
      echo "==> aws CLI already present"
      return 0
    fi
    local dir="${HOME}/.local" tmp asset
    tmp="$(mktemp -d)"
    echo "==> installing AWS CLI v2 into ${dir}"
    case "$(uname -m)" in
      x86_64) asset=awscli-exe-linux-x86_64.zip ;;
      aarch64) asset=awscli-exe-linux-aarch64.zip ;;
      *) echo "unsupported arch $(uname -m)" >&2; return 1 ;;
    esac
    # No signature check here: the build-time install verifies GPG, this
    # convenience path only has HTTPS to AWS. Prefer a baked-in CLI.
    curl -fsSL --retry 3 -o "${tmp}/${asset}" "https://awscli.amazonaws.com/${asset}"
    unzip -q "${tmp}/${asset}" -d "$tmp"
    "${tmp}/aws/install" --install-dir "${dir}/aws-cli" --bin-dir "${dir}/bin"
    rm -rf "$tmp"
    aws --version
    ;;
  azure | az | gcp | gcloud)
    # az and gcloud come from vendor apt repos and need root to install; this
    # container runs as uid 10001 and has no package manager access.
    local image
    case "$name" in
      azure | az) image="ghcr.io/opsourced/pipesutils:latest-azure" ;;
      *) image="ghcr.io/opsourced/pipesutils:latest-gcp" ;;
    esac
    echo "!!! ${name} CLI cannot be installed at startup - it needs root and apt." >&2
    echo "    Use the image built with it: ${image}" >&2
    return 1
    ;;
  *)
    echo "!!! unknown CLI '${name}' (supported: aws)" >&2
    return 1
    ;;
  esac
}

for c in ${EXTRA_CLI:-}; do
  install_cli "$c"
done
# ---------------------------------------------------------------------------

if [ "$#" -eq 0 ]; then
  set -- bash
fi

exec "$@"
