#!/usr/bin/env bash
# team-management run entry point. The lifecycle lives in common/ops/start.sh;
# this wrapper points it at this checkout and prints the demo sign-in details
# after a successful start.
#
#   ./start.sh --start
#   ./start.sh --stop
#   ./start.sh --update
#   ./start.sh --force-recreate-demo | --force-recreate-prod
#   ./start.sh --help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export APP_RUN_ROOT="$ROOT"
# All configuration lives in .env (see its header).
export APP_CONFIG="${APP_CONFIG:-$ROOT/.env}"
# shellcheck disable=SC1090
[[ -f "$APP_CONFIG" ]] && source "$APP_CONFIG"

is_start_command() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      start | --start | update | --update | --force-recreate | --force-recreate-demo | --force-recreate-prod | --reset) return 0 ;;
    esac
  done
  return 1
}

print_login_hint() {
  local port seed email
  port="${TEAMMGMT_PORT:-8000}"
  seed="${TEAMMGMT_SEED_DEMO:-false}"
  printf '\nSign in  http://localhost:%s/\n\n' "$port"
  if ! is_reset_command "$@"; then
    return 0
  elif [[ "${TEAMMGMT_SEED_PROD:-false}" == true ]]; then
    cat <<EOF
  admin    admin                           changeme   (change it in Settings)
  player   mhubisz91@gmail.com
EOF
  elif [[ "$seed" == true ]]; then
    cat <<EOF
  admin    admin@team-management.local     changeme
  coach    coach@team-management.local     changeme
EOF
  else
    email="${TEAMMGMT_ADMIN_EMAIL:-admin@team-management.local}"
    printf '  admin    %s\n' "$email"
    echo "  password changeme (or TEAMMGMT_ADMIN_PASSWORD from .env)"
    echo "  A fresh database holds only this login; add data from the Data page."
  fi
}

is_reset_command() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force-recreate | --force-recreate-demo | --force-recreate-prod | --reset) return 0 ;;
    esac
  done
  return 1
}

STASH=""

restore_exports() {
  [[ -n "$STASH" && -d "$STASH" ]] || return 0
  mkdir -p "$ROOT/exports"
  find "$STASH" -mindepth 1 -maxdepth 1 -exec mv -n {} "$ROOT/exports/" \;
  rmdir "$STASH" 2>/dev/null || true
}

# A reset empties the exports folder too. Take a last JSON export from the
# running backend first (not for the demo reset, which replaces data on purpose;
# the prod reset does export, since it may replace real data),
# then set the folder aside and put it back after.
protect_exports() {
  local engine="" cid e
  if [[ "$TEAMMGMT_SEED_DEMO" != true ]]; then
    for e in docker podman; do
      command -v "$e" >/dev/null 2>&1 && "$e" ps >/dev/null 2>&1 && { engine="$e"; break; }
    done
  fi
  if [[ -n "$engine" ]]; then
    cid="$("$engine" ps -q --filter label=com.docker.compose.project=team-management \
      --filter label=com.docker.compose.service=backend 2>/dev/null | head -n1)"
    if [[ -n "$cid" ]]; then
      echo "Exporting current data before the reset…"
      "$engine" exec "$cid" python manage.py export_data ||
        echo "warning: pre-reset export failed — continuing" >&2
    fi
  fi
  [[ -d "$ROOT/exports" ]] || return 0
  STASH="$ROOT/tmp/exports-keep.$$"
  mkdir -p "$STASH"
  find "$ROOT/exports" -mindepth 1 -maxdepth 1 -exec mv {} "$STASH/" \;
  trap restore_exports EXIT
}

entry="$ROOT/common/ops/start.sh"
[[ -f "$entry" ]] || {
  echo "common/ops/start.sh is missing (vendor common with tools/vendor.sh)" >&2
  exit 1
}

# --force-recreate-demo / --force-recreate-prod are --force-recreate plus the
# demo / production dataset; the shared lifecycle script only knows the first,
# and the backend reads the seed switch.
export TEAMMGMT_SEED_DEMO=false TEAMMGMT_SEED_PROD=false
args=()
for arg in "$@"; do
  case "$arg" in
    --force-recreate-demo)
      export TEAMMGMT_SEED_DEMO=true
      arg=--force-recreate
      ;;
    --force-recreate-prod)
      export TEAMMGMT_SEED_PROD=true
      arg=--force-recreate
      ;;
  esac
  args+=("$arg")
done
set -- "${args[@]}"

if is_reset_command "$@"; then
  protect_exports
fi

status=0
"$entry" "$@" || status=$?
restore_exports

if [[ "$status" == 0 ]] && is_start_command "$@"; then
  print_login_hint "$@"
fi

exit "$status"
