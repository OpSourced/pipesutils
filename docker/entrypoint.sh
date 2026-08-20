#!/usr/bin/env bash
# pipesutils entrypoint.
#
# Keeps the image usable in three shapes:
#   * StatefulSet pod you `kubectl exec` into  (CMD: sleep infinity)
#   * Job / CronJob running a collection or query  (CMD overridden)
#   * `docker run pipesutils steampipe query ...`  (CMD overridden)
#
# Env:
#   STEAMPIPE_START_SERVICE=true    start the embedded postgres in the
#                                   background before running CMD, stop it on
#                                   exit.
#   STEAMPIPE_DATABASE_LISTEN       local (default) | network
#   EXTRA_STEAMPIPE_PLUGINS         space separated plugins to install at
#   EXTRA_TAILPIPE_PLUGINS          startup if not already baked in.
#   EXTRA_CLI                       vendor CLIs to install at startup into
#                                   $HOME/.local. Only "aws" is supported;
#                                   see the note below.
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

# Persistent volumes mount in empty; make sure the dirs the CLIs expect exist.
# Ignore failures so a read-only rootfs / read-only mount is not fatal.
for d in "${STEAMPIPE_INSTALL_DIR:-}" "${TAILPIPE_INSTALL_DIR:-}" \
         "${POWERPIPE_INSTALL_DIR:-}" "${PIPES_WORKSPACE_DIR:-}"; do
  [ -n "$d" ] && mkdir -p "$d" 2>/dev/null || true
done

# --- startup installs ------------------------------------------------------
# These land in $HOME, which is an image layer unless you mount a volume over
# it - so they are re-installed on every start. Fine for a one-off or while
# you work out what you need; bake them in with CLOUDS / STEAMPIPE_PLUGINS
# once you know.

install_plugins() {
  local cli="$1" list="$2" p
  for p in $list; do
    if "$cli" plugin list 2>/dev/null | grep -q "/${p%%@*}@"; then
      echo "==> ${cli} plugin ${p} already present"
      continue
    fi
    echo "==> installing ${cli} plugin ${p}"
    "$cli" plugin install "$p" --progress=false
  done
}

if [ -n "${EXTRA_STEAMPIPE_PLUGINS:-}" ]; then
  install_plugins steampipe "$EXTRA_STEAMPIPE_PLUGINS"
fi
if [ -n "${EXTRA_TAILPIPE_PLUGINS:-}" ]; then
  install_plugins tailpipe "$EXTRA_TAILPIPE_PLUGINS"
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
    echo "    (or build one: --build-arg CLOUDS=\"aws azure gcp\")" >&2
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

if [ "${STEAMPIPE_START_SERVICE:-false}" != "true" ]; then
  exec "$@"
fi

echo "==> starting steampipe service (listen=${STEAMPIPE_DATABASE_LISTEN:-local})"
steampipe service start --database-listen "${STEAMPIPE_DATABASE_LISTEN:-local}"

child=""
# shellcheck disable=SC2329  # invoked by the trap below
shutdown() {
  trap - INT TERM EXIT
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null || true
  echo "==> stopping steampipe service"
  steampipe service stop || true
}
trap shutdown INT TERM EXIT

# Background + wait, so signals reach the trap immediately instead of being
# queued behind a foreground `sleep infinity`.
"$@" &
child=$!
rc=0
wait "$child" || rc=$?
exit "$rc"
