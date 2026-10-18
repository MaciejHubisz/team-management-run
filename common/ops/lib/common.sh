# shellcheck shell=bash
# Pure helpers shared by every script. No side effects; safe to source anywhere.
# Entry scripts set APP_ENV_PREFIX (and source app.conf) before sourcing the
# other libs.

# A parent script that captures its output into a run log pipes our stdout
# through tee; RUN_LOG_TTY tells us the console behind that pipe is a terminal.
_run_log_tty="${APP_ENV_PREFIX:-APP}_RUN_LOG_TTY"
if [[ -t 1 || "${!_run_log_tty-}" == 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m'
  RED=$'\033[38;5;203m' GREEN=$'\033[38;5;114m' YELLOW=$'\033[38;5;221m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "${YELLOW}warn:${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Read <APP_ENV_PREFIX>_NAME from the environment. APP_ENV_PREFIX defaults to
# APP so a repo without app.conf still gets sane variable names.
app_env() {
  local var="${APP_ENV_PREFIX:-APP}_$1"
  printf '%s' "${!var-}"
}

app_export() {
  local name="$1" value="$2"
  export "${APP_ENV_PREFIX:-APP}_${name}=${value}"
}

# Export NAME only when it is not already set in the environment.
app_export_default() {
  local name="$1" value="$2" var="${APP_ENV_PREFIX:-APP}_$1"
  [[ -n "${!var:-}" ]] || app_export "$name" "$value"
}

# Run a command with root privileges. `sudo` is not guaranteed on a server
# where the operator logs in as root, so only escalate when we are not root.
as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# Ask a yes/no question. Yes -> 0. In a pipe (no TTY) it is "no" unless
# <APP_ENV_PREFIX>_ASSUME_YES=1, which is handy for unattended installs.
confirm() {
  local prompt="$1"
  if [[ "$(app_env ASSUME_YES)" == 1 ]]; then
    say "${prompt} [auto-yes]"
    return 0
  fi
  [[ -t 0 ]] || return 1
  local reply
  printf '%s [y/N] ' "$prompt"
  read -r reply || return 1
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

print_version() { printf '%s\n' "${APP_NAME:-App} ${APP_VERSION:-?}"; }

# Mirror everything this script prints (stdout + stderr, children included)
# into <APP_RUN_ROOT>/tmp/<name>.log (${TMPDIR:-/tmp}/<APP_SLUG>-<name>.log
# when there is no run root, e.g. a standalone build), colours stripped. One file per
# name, overwritten by the next run. Nested scripts (build.sh under start.sh)
# inherit the parent's log instead of opening their own.
start_run_log() {
  local name="$1"; shift
  [[ -n "$(app_env RUN_LOG)" ]] && return 0
  local file
  if [[ -n "${APP_RUN_ROOT:-}" ]]; then
    file="${APP_RUN_ROOT}/tmp/${name}.log"
    mkdir -p "${APP_RUN_ROOT}/tmp" 2>/dev/null || true
  else
    file="${TMPDIR:-/tmp}/${APP_SLUG:-app}-${name}.log"
  fi
  if ! printf '# %s  %s %s\n' "$(date '+%F %T')" "$0" "$*" > "$file" 2>/dev/null; then
    warn "cannot write ${file} — run log disabled"
    return 0
  fi
  app_export RUN_LOG "$file"
  [[ -t 1 ]] && app_export RUN_LOG_TTY 1
  exec {RUN_LOG_OUT}>&1 {RUN_LOG_ERR}>&2
  exec > >(tee "/dev/fd/${RUN_LOG_OUT}" | sed -u $'s/\033\\[[0-9;?]*[A-Za-z]//g' >> "$file") 2>&1
  RUN_LOG_PID=$!
  trap finish_run_log EXIT
}

# Flush the run log on exit and point at it on the console.
finish_run_log() {
  local status=$?
  exec >&"$RUN_LOG_OUT" 2>&"$RUN_LOG_ERR"
  wait "$RUN_LOG_PID" 2>/dev/null || true
  printf '%s\n' "${DIM}log: $(app_env RUN_LOG)${RESET}" >&2
  return "$status"
}
