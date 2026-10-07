# shellcheck shell=bash
# Container runtime: find/start docker or podman + compose, and wait for the app.
# Requires ROOT and platform.sh.

ENGINE=""
COMPOSE=()

# Homebrew (Linux) installs into a user prefix; locate it and pull its bin
# dirs onto PATH so a non-interactive SSH session can still find podman.
brew_bin() {
  local c
  for c in "$HOME/.linuxbrew/bin/brew" "/home/linuxbrew/.linuxbrew/bin/brew"; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  have brew && command -v brew
}

ensure_brew_path() {
  local b
  b="$(brew_bin)" || return 1
  eval "$("$b" shellenv)" 2>/dev/null || true
  hash -r 2>/dev/null || true
  return 0
}

# No sudo and no runtime yet: install Podman + Compose from Homebrew, entirely
# in the user's prefix. Returns 0 once an engine is available.
brew_install_podman() {
  local b
  b="$(brew_bin)" || return 1
  say "${BOLD}Installing Podman with Homebrew (no sudo)…${RESET}"
  HOMEBREW_NO_AUTO_UPDATE=1 "$b" install podman podman-compose || return 1
  ensure_brew_path
  find_engine || return 1
  ensure_podman_config
  # A runtime that is present but cannot start usually means Ubuntu's AppArmor
  # userns restriction (or a missing uidmap); point at the host setup script.
  if ! engine_ready; then
    die "$ENGINE is installed but cannot start rootless containers.
  Ask an administrator to run once:  sudo scripts/setup-server-as-root.sh $USER
  (it installs uidmap, sets a subuid range, and allows user namespaces)."
  fi
  return 0
}

# Homebrew's Podman looks for its policy.json in the system/user paths, not in
# the brew prefix, so pulling fails with "no policy.json file found". Write a
# per-user policy (and registries) config only when none exists anywhere.
ensure_podman_config() {
  [[ "${ENGINE:-}" == podman ]] || return 0
  local dir="$HOME/.config/containers"
  if [[ ! -f "$dir/policy.json" && ! -f /etc/containers/policy.json &&
    ! -f /usr/share/containers/policy.json ]]; then
    mkdir -p "$dir" || return 0
    printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' >"$dir/policy.json"
    say "${DIM}wrote $dir/policy.json${RESET}"
  fi
  if [[ ! -f "$dir/registries.conf" && ! -f /etc/containers/registries.conf &&
    ! -f /usr/share/containers/registries.conf ]]; then
    mkdir -p "$dir" || return 0
    printf 'unqualified-search-registries=["docker.io"]\n' >"$dir/registries.conf"
  fi
}

find_engine() {
  ensure_brew_path || true
  local bin
  for bin in docker podman; do
    if have "$bin" && "$bin" info >/dev/null 2>&1; then ENGINE="$bin"; return 0; fi
  done
  for bin in docker podman; do
    if have "$bin"; then ENGINE="$bin"; return 0; fi
  done
  return 1
}

find_compose() {
  COMPOSE=()
  if [[ "$ENGINE" == docker ]]; then
    docker compose version >/dev/null 2>&1 && { COMPOSE=(docker compose); return 0; }
    have docker-compose && { COMPOSE=(docker-compose); return 0; }
  fi
  if [[ "$ENGINE" == podman ]]; then
    # Use podman-compose directly: 'podman compose' just re-execs it and prints
    # an "Executing external compose provider" notice on every call.
    have podman-compose && { COMPOSE=(podman-compose); return 0; }
    podman compose version >/dev/null 2>&1 && { COMPOSE=(podman compose); return 0; }
  fi
  have docker-compose && { COMPOSE=(docker-compose); return 0; }
  have podman-compose && { COMPOSE=(podman-compose); return 0; }
  return 1
}

engine_ready() { [[ -n "${ENGINE:-}" ]] && "$ENGINE" info >/dev/null 2>&1; }

wake_engine() {
  engine_ready && return 0
  if have podman && have systemctl; then
    systemctl --user start podman.socket >/dev/null 2>&1 || true
    as_root systemctl enable --now podman.socket >/dev/null 2>&1 || true
  fi
  if have docker && have systemctl; then
    as_root systemctl enable --now docker >/dev/null 2>&1 ||
      as_root systemctl start docker >/dev/null 2>&1 || true
  fi
}

# Install a container runtime on a Linux host that has none. Docker is the
# default; the distro package manager is preferred, with Docker's own
# convenience script as a fallback. The atomic (rpm-ostree) case needs a reboot.
install_engine_linux() {
  say "${BOLD}No container runtime found — installing one…${RESET}"
  if ! confirm "Install Docker with the system package manager?"; then
    die "no docker or podman. Install one and re-run $0:
  Debian/Ubuntu:  sudo apt-get install -y docker.io docker-compose-v2
  Fedora/RHEL:    sudo dnf install -y docker docker-compose-plugin
  Arch:           sudo pacman -S --noconfirm docker docker-compose
  openSUSE:       sudo zypper install -y docker docker-compose
  Or just re-run with --yes to let this script do it."
  fi

  local installed=0
  if have rpm-ostree && [[ -e /run/ostree-booted ]]; then
    say "${BOLD}Atomic host detected — staging Docker with rpm-ostree…${RESET}"
    as_root rpm-ostree install --idempotent docker docker-compose ||
      die "rpm-ostree install failed"
    die "Docker is staged on this atomic system. Reboot, then re-run $0."
  elif have apt-get; then
    as_root apt-get update -y || die "apt-get update failed.
  If this account cannot sudo, ask an administrator to run once:
    sudo scripts/setup-server-as-root.sh $USER
  Then log out and back in, and re-run $0."
    if as_root apt-get install -y docker.io docker-compose-v2; then installed=1; fi
    if [[ "$installed" == 0 ]]; then
      if as_root apt-get install -y docker.io docker-compose; then installed=1; fi
    fi
  elif have dnf; then
    if as_root dnf install -y docker docker-compose-plugin; then installed=1; fi
    if [[ "$installed" == 0 ]] && as_root dnf install -y moby-engine docker-compose; then installed=1; fi
  elif have yum; then
    if as_root yum install -y docker docker-compose-plugin; then installed=1; fi
    if [[ "$installed" == 0 ]] && as_root yum install -y docker docker-compose; then installed=1; fi
  elif have pacman; then
    as_root pacman -S --noconfirm docker docker-compose && installed=1
  elif have zypper; then
    as_root zypper --non-interactive install docker docker-compose && installed=1
  fi

  if [[ "$installed" == 0 ]]; then
    if have curl; then
      say "${DIM}package manager failed or unsupported — using get.docker.com${RESET}"
      curl -fsSL https://get.docker.com | as_root sh ||
        die "Docker install script failed"
    else
      die "could not install a container runtime automatically (need curl or a supported package manager)"
    fi
  fi

  hash -r 2>/dev/null || true
  find_engine || die "a runtime was installed but no docker/podman was found on PATH"
}

ensure_runtime() {
  [[ -n "${ENGINE:-}" && ${#COMPOSE[@]} -gt 0 ]] && engine_ready && return 0
  if ! find_engine; then
    if brew_install_podman; then
      : # Podman installed from Homebrew; no sudo was needed.
    else
      install_engine_linux
    fi
  fi
  ensure_podman_config
  wake_engine
  local i
  for i in $(seq 1 30); do engine_ready && break; sleep 1; done
  engine_ready || die "$ENGINE is installed but the daemon is not running.
  Linux: sudo systemctl start docker   or   systemctl --user start podman.socket
  No sudo? Ask an administrator to run:  sudo scripts/setup-server-as-root.sh $USER
  Then re-run $0."
  # Rootless podman needs to create user namespaces; Ubuntu blocks that by
  # default unless setup-server-as-root.sh has allowed it. Warn early instead of
  # failing later with a cryptic "operation not permitted".
  if [[ "$ENGINE" == podman ]] && ! podman unshare true >/dev/null 2>&1; then
    warn "rootless Podman could not create a user namespace.
  If containers fail, ask an administrator to run:  sudo scripts/setup-server-as-root.sh $USER"
  fi
  find_compose || die "no compose for $ENGINE (need: docker compose / podman compose)"
  say "${DIM}engine ${ENGINE}  compose ${COMPOSE[*]}${RESET}"
}

compose() {
  "${COMPOSE[@]}" -f "$ROOT/${APP_COMPOSE_FILE:-docker-compose.yml}" "$@"
}

# Local image id for a ref, or empty when the image is not present.
image_id() {
  "$ENGINE" image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

wait_until_up() {
  local i
  say "${DIM}Waiting for ${URL}…${RESET}"
  for i in $(seq 1 180); do
    if have curl && curl -sf -o /dev/null --max-time 1 "$URL"; then return 0; fi
    sleep 1
  done
  return 1
}
