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
      start | --start | update | --update | --force-recreate | --reset) return 0 ;;
    esac
  done
  return 1
}

print_login_hint() {
  local port
  port="$(sed -n 's/^[[:space:]]*TEAMMGMT_PORT[[:space:]]*=[[:space:]]*//p' "$ROOT/.env" 2>/dev/null | tail -n1)"
  port="${port:-8000}"
  cat <<EOF

Sign in  http://localhost:${port}/

  admin    admin@team-management.local     changeme
  coach    coach@team-management.local     changeme
  player   player@team-management.local    changeme
  guest    guest@team-management.local     changeme
EOF
}

entry="$ROOT/common/ops/start.sh"
[[ -f "$entry" ]] || {
  echo "common/ops/start.sh is missing (vendor common with tools/vendor.sh)" >&2
  exit 1
}

status=0
"$entry" "$@" || status=$?

if [[ "$status" == 0 ]] && is_start_command "$@"; then
  print_login_hint
fi

exit "$status"
