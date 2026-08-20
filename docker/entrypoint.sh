#!/usr/bin/env bash
# pipesutils entrypoint.
#
# Keeps the CLI images usable in three shapes:
#   * StatefulSet pod you `kubectl exec` into  (CMD: sleep infinity)
#   * Job / CronJob running a collection or query  (CMD overridden)
#   * `docker run pipesutils steampipe query ...`  (CMD overridden)
#
# Env:
#   STEAMPIPE_START_SERVICE=true   start the embedded postgres in the background
#                                  before running CMD, and stop it on exit.
#   STEAMPIPE_DATABASE_LISTEN      local (default) | network
set -euo pipefail

# Persistent volumes mount in empty; make sure the dirs the CLIs expect exist.
# Ignore failures so a read-only rootfs / read-only mount is not fatal.
for d in "${STEAMPIPE_INSTALL_DIR:-}" "${TAILPIPE_INSTALL_DIR:-}" \
         "${POWERPIPE_INSTALL_DIR:-}" "${PIPES_WORKSPACE_DIR:-}"; do
  [ -n "$d" ] && mkdir -p "$d" 2>/dev/null || true
done

if [ "$#" -eq 0 ]; then
  set -- bash
fi

if [ "${STEAMPIPE_START_SERVICE:-false}" != "true" ]; then
  exec "$@"
fi

echo "==> starting steampipe service (listen=${STEAMPIPE_DATABASE_LISTEN:-local})"
steampipe service start --database-listen "${STEAMPIPE_DATABASE_LISTEN:-local}"

child=""
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
