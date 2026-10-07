#!/usr/bin/env bash
# team-management host setup entry point. The host operations live in
# common/ops/setup-server-as-root.sh; this wrapper points it at this checkout
# and its app.conf.
#
#   sudo scripts/setup-server-as-root.sh USER [--install-service] [--install-nginx]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export APP_RUN_ROOT="$ROOT"
export APP_CONFIG="${APP_CONFIG:-$ROOT/app.conf}"

# CI deploy upload parameters (hardcoded for this project).
export DEPLOY_GH_OWNER="MaciejHubisz"
export DEPLOY_GH_REPO="team-management"
export DEPLOY_ENV_PREFIX="TEAMMGMT"
export DEPLOY_HOST="odynce.nfy.pl"
export DEPLOY_PORT="22"
export DEPLOY_PATH="team-management-run"
export DEPLOY_SERVER_USER="maciej"

entry="$ROOT/common/ops/setup-server-as-root.sh"
[[ -f "$entry" ]] || {
  echo "common/ops/setup-server-as-root.sh is missing (vendor common with tools/vendor.sh)" >&2
  exit 1
}
exec "$entry" "$@"
