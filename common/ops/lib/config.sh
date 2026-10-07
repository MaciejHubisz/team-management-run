# shellcheck shell=bash
# Runtime configuration: defaults, .env loading, and bind-mount helpers.
# Requires common.sh and platform.sh, plus APP_ENV_PREFIX from app.conf.

APP_VERSION_FILE="${APP_VERSION_FILE:-VERSION}"
PORT="$(app_env PORT)"; PORT="${PORT:-${APP_PORT:-8000}}"
HOST="$(app_env HOST)"; HOST="${HOST:-${APP_HOST:-127.0.0.1}}"
URL="http://${HOST}:${PORT}/"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/$APP_VERSION_FILE" 2>/dev/null || printf '1.0.0')"

refresh_url() { URL="http://${HOST}:${PORT}/"; }

# Bind-mount relabel suffix shared with docker-compose (see volume_opts).
app_export_default VOL_OPTS "$(volume_opts)"
app_export_default VOL_OPTS_RO "$(volume_opts_ro)"
# The default protocols and exports mounts are host binds, so they want the
# same relabel suffix.
app_export_default PROTOCOLS_OPTS "$(app_env VOL_OPTS)"
app_export_default EXPORTS_OPTS "$(app_env VOL_OPTS)"

# Source one or more env files (later files win) and re-read port/host.
load_env() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  done
  local env_port env_host
  env_port="$(app_env PORT)"; PORT="${env_port:-$PORT}"
  env_host="$(app_env HOST)"; HOST="${env_host:-$HOST}"
  refresh_url
}

# Bind the JSON exports folder to a local directory.
apply_export_path() {
  local resolved
  resolved="$(resolve_host_path "$1")"
  mkdir -p "$resolved/archive" || die "cannot create $resolved/archive"
  app_export EXPORTS_SOURCE "$resolved"
  app_export EXPORTS_OPTS "$(app_env VOL_OPTS)"
  say "${DIM}exports → ${resolved}${RESET}"
}

# Bind the generated-files folder (protocols, exports, …) to a local directory.
apply_protocols_path() {
  local resolved
  resolved="$(resolve_host_path "$1")"
  app_export PROTOCOLS_SOURCE "$resolved"
  app_export PROTOCOLS_OPTS "$(app_env VOL_OPTS)"
  say "${DIM}protocols → ${resolved}${RESET}"
}
