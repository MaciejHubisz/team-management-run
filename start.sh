#!/usr/bin/env bash
# team-management run entry point. The lifecycle lives in common/ops/start.sh;
# this wrapper points it at this checkout and prints the demo sign-in details
# after a successful start.
#
#   ./start.sh --start
#   ./start.sh --stop
#   ./start.sh --update
#   ./start.sh --help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export APP_RUN_ROOT="$ROOT"
export APP_CONFIG="${APP_CONFIG:-$ROOT/app.conf}"

is_start_command() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      start | --start | update | --update | --force-recreate | --force-recreate-demo | --reset) return 0 ;;
    esac
  done
  return 1
}

env_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ROOT/.env" 2>/dev/null | tail -n1
}

print_login_hint() {
  local port seed email
  port="$(env_value TEAMMGMT_PORT)"
  port="${port:-8000}"
  seed="${TEAMMGMT_SEED_DEMO:-false}"
  printf '\nSign in  http://localhost:%s/\n\n' "$port"
  if ! is_reset_command "$@"; then
    return 0
  elif [[ "$seed" == true ]]; then
    cat <<EOF
  admin    admin@team-management.local     changeme
  coach    coach@team-management.local     changeme
  player   player@team-management.local    changeme
  guest    guest@team-management.local     changeme
EOF
  else
    email="$(env_value TEAMMGMT_ADMIN_EMAIL)"
    printf '  admin    %s\n' "${email:-admin@team-management.local}"
    echo "  password changeme (or TEAMMGMT_ADMIN_PASSWORD from .env)"
    echo "  A fresh database holds only this login; add data from the Data page."
  fi
}

is_reset_command() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force-recreate | --force-recreate-demo | --reset) return 0 ;;
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
# running backend first (not for the demo reset, which replaces data on purpose),
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

# --force-recreate-demo is --force-recreate plus the demo dataset; the shared
# lifecycle script only knows the first, and the backend reads the seed switch.
export TEAMMGMT_SEED_DEMO=false
args=()
for arg in "$@"; do
  if [[ "$arg" == --force-recreate-demo ]]; then
    export TEAMMGMT_SEED_DEMO=true
    arg=--force-recreate
  fi
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
