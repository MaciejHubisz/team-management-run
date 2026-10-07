# shellcheck shell=bash
# Pure helpers shared by every script. No side effects; safe to source anywhere.
# Entry scripts set APP_ENV_PREFIX (and source app.conf) before sourcing the
# other libs.

if [[ -t 1 ]]; then
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
