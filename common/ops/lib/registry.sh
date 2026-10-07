# shellcheck shell=bash
# Registry login helpers, shared by start.sh and setup-server-as-root.sh.
# Requires common.sh (say/warn/die/have). Uses ENGINE when already detected,
# otherwise finds docker/podman itself.
#
# When the image package is private, a machine that only pulls must authenticate
# once with a token that can read packages.

# Registry host of the configured image prefix, e.g. "ghcr.io".
registry_host() {
  local prefix
  prefix="$(app_env REGISTRY)"
  prefix="${prefix:-$(app_env IMAGE_PREFIX)}"
  prefix="${prefix:-${APP_IMAGE_PREFIX:-ghcr.io/owner/app}}"
  printf '%s\n' "${prefix%%/*}"
}

# Namespace that owns the package. Used as the default registry username.
registry_owner() {
  local prefix
  prefix="$(app_env REGISTRY)"
  prefix="${prefix:-$(app_env IMAGE_PREFIX)}"
  prefix="${prefix:-${APP_IMAGE_PREFIX:-ghcr.io/owner/app}}"
  prefix="${prefix#*/}"
  printf '%s\n' "${prefix%%/*}"
}

# Engine to use: the already-detected one, else docker, else podman.
registry_engine() {
  if [[ -n "${ENGINE:-}" ]]; then
    printf '%s\n' "$ENGINE"
    return 0
  fi
  local bin
  for bin in docker podman; do
    have "$bin" && {
      printf '%s\n' "$bin"
      return 0
    }
  done
  return 1
}

# Persistent auth file for rootless podman. Its default lives under
# $XDG_RUNTIME_DIR (tmpfs) and is lost on reboot; podman also reads this
# ~/.config fallback on pull, so writing here makes the login stick.
registry_authfile() {
  local configured
  configured="$(app_env AUTHFILE)"
  printf '%s\n' "${configured:-$HOME/.config/containers/auth.json}"
}

# True when the current user already has a credential for the registry.
registry_logged_in() {
  local engine host
  engine="$(registry_engine)" || return 1
  host="$(registry_host)"
  if [[ "$engine" == podman ]]; then
    "$engine" login --get-login "$host" --authfile "$(registry_authfile)" >/dev/null 2>&1
  else
    local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    [[ -f "$cfg" ]] && grep -q "\"$host\"" "$cfg" 2>/dev/null
  fi
}

# Token used for the registry, from the environment (registry.env is loaded by
# the entry scripts): <PREFIX>_REGISTRY_TOKEN, <PREFIX>_GITHUB_TOKEN or CR_PAT.
registry_token() {
  local token
  token="$(app_env REGISTRY_TOKEN)"
  [[ -n "$token" ]] || token="$(app_env GITHUB_TOKEN)"
  token="${token:-${CR_PAT:-}}"
  [[ "$token" == "ghp_replace_me" ]] && token=""
  printf '%s' "$token"
}

# Log in. Reads the token from <PREFIX>_REGISTRY_TOKEN or <PREFIX>_GITHUB_TOKEN
# (or CR_PAT); without a token it prompts. <PREFIX>_REGISTRY_USER is the
# registry username; it defaults to the package owner.
registry_login() {
  local engine host user token
  engine="$(registry_engine)" || die "no docker or podman found for registry login"
  host="$(registry_host)"
  user="$(app_env REGISTRY_USER)"; user="${user:-${GITHUB_ACTOR:-}}"
  token="$(registry_token)"
  local args=()
  if [[ "$engine" == podman ]]; then
    local authfile
    authfile="$(registry_authfile)"
    mkdir -p "$(dirname "$authfile")"
    args+=(--authfile "$authfile")
  fi
  if [[ -n "$token" ]]; then
    [[ -n "$user" ]] || user="$(registry_owner)"
    args+=(-u "$user")
    printf '%s' "$token" | "$engine" login "$host" "${args[@]}" --password-stdin
  else
    [[ -n "$user" ]] && args+=(-u "$user")
    "$engine" login "$host" "${args[@]}"
  fi
}
