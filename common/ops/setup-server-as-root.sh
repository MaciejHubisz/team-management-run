#!/usr/bin/env bash
# Prepare a Linux server to run the app in APP_RUN_ROOT. An administrator runs
# this once with root (or sudo). It installs Homebrew for the operator and the
# few system bits Homebrew/Podman need, then everything else is done by
# ./start.sh without sudo.
#
#   sudo scripts/setup-server-as-root.sh                    # user = $SUDO_USER
#   sudo scripts/setup-server-as-root.sh USER               # prepare server only
#   sudo scripts/setup-server-as-root.sh USER --install-service
#   sudo scripts/setup-server-as-root.sh USER --install-service --install-nginx
#   sudo scripts/setup-server-as-root.sh USER --deploy-key
#
# Three phases, clearly split by privilege:
#   Phase 1 (root):    prerequisites, Homebrew, subuid range, userns, a shell
#                      alias, lingering, an optional CI deploy key.
#   Phase 1b (root):   nginx reverse proxy + certbot TLS.
#   Phase 2 (USER):    ./start.sh --install-service — installs Podman and starts
#                      the app now and on every boot.
#
# Idempotent: safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
ROOT="${APP_RUN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
APP_CONFIG="${APP_CONFIG:-$ROOT/app.conf}"
# shellcheck disable=SC1090
[[ -f "$APP_CONFIG" ]] && source "$APP_CONFIG"
export APP_ENV_PREFIX="${APP_ENV_PREFIX:-APP}"
export APP_NAME APP_IMAGE_PREFIX

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/platform.sh
source "$LIB_DIR/platform.sh"
# shellcheck source=lib/registry.sh
source "$LIB_DIR/registry.sh"

RUN_SCRIPT="${APP_RUN_SCRIPT:-start.sh}"
SLUG="${APP_SLUG:-app}"
ALIAS_NAME="${APP_ALIAS:-$SLUG}"
SYSTEMD_UNIT="${APP_SYSTEMD_UNIT:-$SLUG}"
DEPLOY_DOC="${APP_DEPLOY_DOC:-docs/deploy.md}"

# --- Presentation -----------------------------------------------------------
STEP=0
step() {
  STEP=$((STEP + 1))
  say ""
  say "${BOLD}[${STEP}] $*${RESET}"
}
step_ok() { say "  ${GREEN}ok${RESET}  $*"; }
step_info() { say "  ${DIM}$*${RESET}"; }

# Run a command quietly, printing its output only when it fails.
run_quiet() {
  local log status=0 setup_log
  setup_log="$(app_env SETUP_LOG)"
  log="$(mktemp)"
  "$@" >"$log" 2>&1 || status=$?
  if [[ "$status" -eq 0 ]]; then
    rm -f "$log"
    return 0
  fi
  warn "command failed: $*"
  sed 's/^/    /' "$log" >&2
  if [[ -n "$setup_log" ]]; then
    cat "$log" >>"$setup_log"
  fi
  rm -f "$log"
  return "$status"
}

# Image prefix (registry host) used by start.sh, for the login step below.
# shellcheck disable=SC1090
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
# Registry credentials (gitignored) let the login run unattended.
# shellcheck disable=SC1090
[[ -f "$ROOT/registry.env" ]] && source "$ROOT/registry.env"

# Admin-level configuration (nginx site + TLS).
ADMIN_ENV="$ROOT/${APP_ADMIN_ENV:-scripts/admin/admin.env}"
# shellcheck disable=SC1090
[[ -f "$ADMIN_ENV" ]] && source "$ADMIN_ENV"
DOMAIN="$(app_env DOMAIN)"
NGINX_PORT="$(app_env PORT)"; NGINX_PORT="${NGINX_PORT:-${APP_PORT:-8000}}"
TLS_EMAIL="$(app_env TLS_EMAIL)"
ENABLE_TLS="$(app_env ENABLE_TLS)"; ENABLE_TLS="${ENABLE_TLS:-1}"
NGINX_TEMPLATE="$ROOT/${APP_NGINX_TEMPLATE:-scripts/admin/nginx-site.conf.template}"
NGINX_SITE="${APP_NGINX_SITE_NAME:-$SLUG}"
# Operator-owned registry credentials (written by ensure_registry_login).
REGISTRY_ENV="$ROOT/registry.env"

usage() {
  cat <<EOF
${BOLD}${APP_NAME:-App} server setup${RESET} (run as root)

  sudo $0 [USER]                     prepare the server only (Phase 1)
  sudo $0 [USER] --install-service   prepare the server + run the app on boot
  sudo $0 [USER] --install-nginx     also install nginx + TLS (Phase 1b)

  USER defaults to \$SUDO_USER.

  Phase 1 (root):  prerequisites, Homebrew, subuid range, user namespaces,
                   a '${ALIAS_NAME}' shell alias, and lingering for USER.
  Phase 1b (root): nginx reverse proxy + certbot TLS, configured from
                   ${APP_ADMIN_ENV:-scripts/admin/admin.env}.
  Phase 2 (USER):  ./${RUN_SCRIPT} --install-service — installs Podman, starts
                   the app now, and enables it on every boot. No sudo.

  Overrides for Phase 1b:
    --domain HOST    public hostname        (${APP_ENV_PREFIX}_DOMAIN)
    --port PORT      local app port         (${APP_ENV_PREFIX}_PORT, default ${NGINX_PORT})
    --email ADDR     Let's Encrypt contact  (${APP_ENV_PREFIX}_TLS_EMAIL)
    --no-tls         install nginx HTTP-only, skip certbot

  Private image registry:
    --registry-user USER        registry username (${APP_ENV_PREFIX}_REGISTRY_USER)
    --registry-token-file FILE  file with a read:packages token

  Without a token the script asks for one, logs in, and saves it to
  registry.env (mode 600). Re-running is safe.

  Continuous deployment (GitHub Actions over SSH):
    --deploy-key                generate a key pair here, authorize the public
                                half, and print the private half once
    --deploy-key-file FILE      authorize an SSH public key you already have
    --deploy-key-options OPTS   authorized_keys options for the deploy key
                                (see ${DEPLOY_DOC})
EOF
}

TARGET_USER=""
INSTALL_SERVICE=0
INSTALL_NGINX=0
REGISTRY_USER="$(app_env REGISTRY_USER)"
REGISTRY_TOKEN_FILE="$(app_env REGISTRY_TOKEN_FILE)"
DEPLOY_KEY_FILE="$(app_env DEPLOY_KEY_FILE)"
GENERATE_DEPLOY_KEY=0
DEPLOY_KEY_OPTIONS="$(app_env DEPLOY_KEY_OPTIONS)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help | help) usage; exit 0 ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    --install-nginx) INSTALL_NGINX=1; shift ;;
    --deploy-key) GENERATE_DEPLOY_KEY=1; shift ;;
    --deploy-key-options)
      [[ $# -ge 2 ]] || die "$1 needs options"
      DEPLOY_KEY_OPTIONS="$2"; shift 2 ;;
    --deploy-key-file)
      [[ $# -ge 2 ]] || die "$1 needs a path"
      DEPLOY_KEY_FILE="$2"; shift 2 ;;
    --registry-user)
      [[ $# -ge 2 ]] || die "$1 needs a username"
      REGISTRY_USER="$2"; shift 2 ;;
    --registry-token-file)
      [[ $# -ge 2 ]] || die "$1 needs a path"
      REGISTRY_TOKEN_FILE="$2"; shift 2 ;;
    --domain)
      [[ $# -ge 2 ]] || die "$1 needs a hostname"
      DOMAIN="$2"; shift 2 ;;
    --port)
      [[ $# -ge 2 ]] || die "$1 needs a port"
      NGINX_PORT="$2"; shift 2 ;;
    --email)
      [[ $# -ge 2 ]] || die "$1 needs an address"
      TLS_EMAIL="$2"; shift 2 ;;
    --no-tls) ENABLE_TLS=0; shift ;;
    -*) die "unknown argument: $1  (try: $0 --help)" ;;
    *) TARGET_USER="$1"; shift ;;
  esac
done

detect_os
is_linux || die "this host setup script is Linux only"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "run me as root:  sudo $0 [USER]"
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
  die "specify the operator account:  sudo $0 USER"
fi
id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || die "no home directory for $TARGET_USER"

BREW_PREFIX="/home/linuxbrew/.linuxbrew"
if [[ -x "$TARGET_HOME/.linuxbrew/bin/brew" ]]; then
  BREW_PREFIX="$TARGET_HOME/.linuxbrew"
fi

if have runuser; then
  as_user() { runuser -u "$TARGET_USER" -- "$@"; }
elif have su; then
  as_user() { su -s /bin/bash "$TARGET_USER" -c "$(printf '%q ' "$@")"; }
else
  die "need 'runuser' or 'su' to install Homebrew as ${TARGET_USER}"
fi

# Run a command as the operator with a working systemd --user environment.
run_as_operator() {
  local uid runtime_dir assume_env
  uid="$(id -u "$TARGET_USER")"
  runtime_dir="/run/user/$uid"
  assume_env="${APP_ENV_PREFIX}_ASSUME_YES=1"
  for _ in $(seq 1 15); do [[ -S "$runtime_dir/bus" ]] && break; sleep 1; done
  if have runuser; then
    runuser -u "$TARGET_USER" -- env \
      HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
      "$assume_env" \
      "$@"
  else
    su -s /bin/bash "$TARGET_USER" -c \
      "HOME=$(printf '%q' "$TARGET_HOME") XDG_RUNTIME_DIR=$(printf '%q' "$runtime_dir") DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime_dir/bus $assume_env $(printf '%q ' "$@")"
  fi
}

# Log the operator in to the private image registry so the boot service can
# pull. Idempotent; the token comes from registry.env, the environment, or
# --registry-token-file; if none is found it prompts and saves the answer.
ensure_registry_login() {
  local host token user env_args=() prompted=0
  host="$(registry_host)"
  user="$REGISTRY_USER"
  step "Private image registry (${host})"

  if run_as_operator bash "$ROOT/$RUN_SCRIPT" --login --check >/dev/null 2>&1; then
    step_ok "already logged in as ${TARGET_USER}"
    return 0
  fi

  if [[ -n "$REGISTRY_TOKEN_FILE" ]]; then
    [[ -r "$REGISTRY_TOKEN_FILE" ]] || die "cannot read token file: $REGISTRY_TOKEN_FILE"
    token="$(tr -d '\r\n' <"$REGISTRY_TOKEN_FILE")"
  else
    token="$(registry_token)"
  fi

  if [[ -z "$token" ]]; then
    if [[ ! -t 0 ]]; then
      warn "not logged in to ${host} and no token available; skipping registry login"
      return 0
    fi
    say ""
    say "  Create a token with the read:packages scope:"
    say "    ${BOLD}https://github.com/settings/tokens/new?scopes=read:packages${RESET}"
    say ""
    [[ -n "$user" ]] || user="$(registry_owner)"
    local answer=""
    printf '  GitHub username [%s]: ' "$user"
    IFS= read -r answer || true
    user="${answer:-$user}"
    printf '  GitHub token (read:packages): '
    IFS= read -r -s token || true
    printf '\n'
    if [[ -z "$token" ]]; then
      warn "no token entered; skipping registry login.
  Re-run this script when you have one, or run as ${TARGET_USER}:
    cd ${ROOT} && ./${RUN_SCRIPT} --login"
      return 0
    fi
    prompted=1
  fi

  [[ -n "$user" ]] || user="$(registry_owner)"
  env_args=(env "${APP_ENV_PREFIX}_REGISTRY_USER=$user")

  local log
  log="$(mktemp)"
  if ! printf '%s' "$token" | run_as_operator "${env_args[@]}" bash "$ROOT/$RUN_SCRIPT" --login >"$log" 2>&1; then
    warn "registry login failed; output:"
    sed 's/^/    /' "$log" >&2
    rm -f "$log"
    die "registry login failed for ${TARGET_USER}.
  Check that the token has the read:packages scope and was pasted without
  whitespace, then try again."
  fi
  rm -f "$log"
  step_ok "logged in as ${user}"

  if [[ "$prompted" == 1 || ! -f "$REGISTRY_ENV" ]]; then
    {
      printf '# Written by setup-server-as-root.sh. Keep it private (chmod 600).\n'
      printf '%s_REGISTRY_USER=%s\n' "$APP_ENV_PREFIX" "$user"
      printf '%s_REGISTRY_TOKEN=%s\n' "$APP_ENV_PREFIX" "$token"
    } >"$REGISTRY_ENV"
    chown "$TARGET_USER" "$REGISTRY_ENV"
    chmod 600 "$REGISTRY_ENV"
    step_ok "saved ${REGISTRY_ENV} (mode 600, ${TARGET_USER})"
  fi
}

say "${BOLD}${APP_NAME:-App} server setup${RESET}  ${DIM}(run as root)${RESET}"
say "  operator : ${BOLD}${TARGET_USER}${RESET}"
say "  host     : $(hostname)"
say "  root     : ${ROOT}"

install_prereqs() {
  step "Prerequisites (build tools, curl, file, git, python3, uidmap, fuse3)"
  if have apt-get; then
    run_quiet apt-get update -y || die "apt-get update failed"
    run_quiet apt-get install -y build-essential procps curl file git python3 uidmap fuse3 ||
      die "installing prerequisites failed"
  elif have dnf; then
    run_quiet dnf install -y @development-tools procps-ng curl file git python3 shadow-utils fuse3 ||
      die "installing prerequisites failed"
  elif have yum; then
    run_quiet yum install -y gcc gcc-c++ make procps-ng curl file git python3 shadow-utils fuse3 ||
      die "installing prerequisites failed"
  elif have pacman; then
    run_quiet pacman -S --noconfirm base-devel procps-ng curl file git python3 shadow fuse3 ||
      die "installing prerequisites failed"
  elif have zypper; then
    run_quiet zypper --non-interactive install -t pattern devel_basis ||
      die "installing prerequisites failed"
    run_quiet zypper --non-interactive install procps curl file git python3 shadow fuse3 ||
      die "installing prerequisites failed"
  else
    warn "unknown package manager — install build tools, curl, file, git, python3, uidmap, fuse3 manually"
    return 0
  fi
  step_ok "installed"
}

# Rootless containers need a subordinate UID/GID range for the operator.
ensure_subids() {
  step "Subordinate UID/GID range for ${TARGET_USER}"
  if grep -qE "^(${TARGET_USER}|$(id -u "$TARGET_USER")):" /etc/subuid 2>/dev/null &&
    grep -qE "^(${TARGET_USER}|$(id -u "$TARGET_USER")):" /etc/subgid 2>/dev/null; then
    step_ok "already configured"
    return 0
  fi
  if have usermod; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$TARGET_USER" &&
      step_ok "added 100000-165535"
  else
    warn "no subuid/subgid range for ${TARGET_USER}; rootless Podman may fail"
  fi
}

# Ubuntu restricts unprivileged user namespaces with AppArmor, which breaks
# rootless Podman. Grant it for the Homebrew Podman binary.
setup_userns() {
  step "Unprivileged user namespaces (Ubuntu AppArmor)"
  local sysctl=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  if [[ ! -e "$sysctl" || "$(cat "$sysctl" 2>/dev/null)" != 1 ]]; then
    step_ok "not restricted"
    return 0
  fi
  local profile="/etc/apparmor.d/${SLUG}-homebrew"
  cat >"$profile" <<EOF
abi <abi/4.0>,
include <tunables/global>

# Allow rootless containers from Homebrew-installed Podman.
profile ${SLUG}-homebrew-podman-bin /home/*/.linuxbrew/bin/podman flags=(unconfined) {
  userns,
}
profile ${SLUG}-homebrew-podman-cellar /home/*/.linuxbrew/Cellar/podman/*/bin/podman flags=(unconfined) {
  userns,
}
EOF
  if have apparmor_parser && apparmor_parser -r "$profile" 2>/dev/null; then
    step_ok "allowed Homebrew Podman via AppArmor"
    return 0
  fi
  warn "could not load the AppArmor profile — relaxing the userns sysctl instead"
  printf 'kernel.apparmor_restrict_unprivileged_userns=0\n' \
    >"/etc/sysctl.d/99-${SLUG}-userns.conf"
  have sysctl && sysctl --system >/dev/null 2>&1 || true
  step_ok "relaxed kernel.apparmor_restrict_unprivileged_userns"
}

# Install Homebrew into the supported prefix (owned by the operator).
install_homebrew() {
  step "Homebrew (${BREW_PREFIX})"
  mkdir -p "$(dirname "$BREW_PREFIX")"
  chown "$TARGET_USER" "$(dirname "$BREW_PREFIX")"
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    step_ok "already installed"
  else
    step_info "cloning Homebrew…"
    mkdir -p "$BREW_PREFIX"
    chown "$TARGET_USER" "$BREW_PREFIX"
    as_user git clone --depth=1 https://github.com/Homebrew/brew "$BREW_PREFIX/Homebrew" ||
      die "could not clone Homebrew into ${BREW_PREFIX}"
    as_user mkdir -p "$BREW_PREFIX/bin"
    as_user ln -sfn ../Homebrew/bin/brew "$BREW_PREFIX/bin/brew"
    step_ok "installed"
  fi

  local rc="$TARGET_HOME/.bashrc"
  if grep -qs 'linuxbrew/bin/brew shellenv' "$rc" 2>/dev/null; then
    step_ok "shell environment already in ${rc}"
  else
    {
      printf '\n# Homebrew (host setup)\n'
      printf 'eval "$(%s/bin/brew shellenv)"\n' "$BREW_PREFIX"
    } >>"$rc"
    chown "$TARGET_USER" "$rc"
    step_ok "shell environment added to ${rc}"
  fi
}

# Add a shell alias so the app is one word away from anywhere on the host.
install_alias() {
  step "'${ALIAS_NAME}' shell alias"
  local rc="$TARGET_HOME/.bashrc"
  local alias_line
  alias_line="$(printf 'alias %s=%q' "$ALIAS_NAME" "$ROOT/$RUN_SCRIPT")"
  if grep -qs "alias ${ALIAS_NAME}=" "$rc" 2>/dev/null; then
    step_ok "already present in ${rc}"
  else
    {
      printf '\n# %s (host setup)\n' "${APP_NAME:-App}"
      printf '%s\n' "$alias_line"
    } >>"$rc"
    chown "$TARGET_USER" "$rc"
    step_ok "added to ${rc}"
  fi
  step_info "${alias_line}"
}

# Let the operator's systemd user manager keep running after logout.
enable_linger() {
  step "Lingering for ${TARGET_USER}"
  if ! have loginctl; then
    step_info "loginctl not available; skipped"
    return 0
  fi
  if loginctl enable-linger "$TARGET_USER" >/dev/null 2>&1; then
    step_ok "user service keeps running after logout"
  else
    warn "could not enable-linger; the user service may stop at logout"
  fi
}

authorize_deploy_key() {
  local key="$1" dir auth line
  dir="$TARGET_HOME/.ssh"
  auth="$dir/authorized_keys"
  line="$key"
  [[ -n "$DEPLOY_KEY_OPTIONS" ]] && line="$DEPLOY_KEY_OPTIONS $key"
  mkdir -p "$dir"
  touch "$auth"
  chown "$TARGET_USER" "$dir" "$auth"
  chmod 700 "$dir"
  chmod 600 "$auth"
  if grep -qF "$key" "$auth" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$line" >>"$auth"
  return 0
}

install_deploy_key_file() {
  step "Deploy key for ${TARGET_USER}"
  [[ -r "$DEPLOY_KEY_FILE" ]] || die "cannot read deploy key file: $DEPLOY_KEY_FILE"
  local key
  key="$(tr -d '\r' <"$DEPLOY_KEY_FILE")"
  case "$key" in
    ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-*\ *) ;;
    *) die "$DEPLOY_KEY_FILE does not look like an SSH public key" ;;
  esac
  if authorize_deploy_key "$key"; then
    step_ok "authorized in ${TARGET_HOME}/.ssh/authorized_keys"
  else
    step_ok "already authorized in ${TARGET_HOME}/.ssh/authorized_keys"
  fi
}

generate_deploy_key() {
  step "Deploy key for ${TARGET_USER}"
  have ssh-keygen || die "ssh-keygen is required to generate a deploy key"
  local auth="$TARGET_HOME/.ssh/authorized_keys" tmp pub
  if [[ -f "$auth" ]] && grep -q ' github-actions$' "$auth"; then
    step_ok "a deploy key is already authorized"
    step_info "remove that line and re-run to issue a new one"
    return 0
  fi
  tmp="$(mktemp -d)"
  chmod 700 "$tmp"
  ssh-keygen -q -t ed25519 -N '' -C 'github-actions' -f "$tmp/${SLUG}-deploy"
  pub="$(cat "$tmp/${SLUG}-deploy.pub")"
  authorize_deploy_key "$pub" || true
  step_ok "generated and authorized"
  say ""
  say "${BOLD}Copy the private key below into the GitHub secret DEPLOY_SSH_KEY${RESET}"
  say "${DIM}(Settings → Secrets and variables → Actions). It is shown once and"
  say "is not stored on this host.${RESET}"
  say ""
  cat "$tmp/${SLUG}-deploy"
  say ""
  rm -rf "$tmp"
}

# --- Phase 1b: nginx reverse proxy + TLS -------------------------------------

install_nginx_pkgs() {
  step "nginx + certbot"
  if have nginx && have certbot; then
    step_ok "already installed"
    return 0
  fi
  if have apt-get; then
    run_quiet apt-get update -y || die "apt-get update failed"
    run_quiet apt-get install -y nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have dnf; then
    run_quiet dnf install -y nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have yum; then
    run_quiet yum install -y nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have pacman; then
    run_quiet pacman -S --noconfirm nginx certbot certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have zypper; then
    run_quiet zypper --non-interactive install nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  else
    die "unknown package manager — install nginx and certbot manually, then re-run"
  fi
  step_ok "installed"
}

write_nginx_site() {
  step "nginx site for ${DOMAIN}:${NGINX_PORT}"
  [[ -f "$NGINX_TEMPLATE" ]] || die "missing nginx template: $NGINX_TEMPLATE"
  local target
  if [[ -d /etc/nginx/sites-available ]]; then
    target="/etc/nginx/sites-available/${NGINX_SITE}.conf"
  else
    target="/etc/nginx/conf.d/${NGINX_SITE}.conf"
  fi
  sed -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__PORT__/${NGINX_PORT}/g" \
    -e "s/__PUBLIC_DIR__/${APP_PUBLIC_DIR:-/}/g" \
    "$NGINX_TEMPLATE" >"$target"
  if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sfn "$target" "/etc/nginx/sites-enabled/${NGINX_SITE}.conf"
  fi
  step_ok "wrote ${target}"
}

reload_nginx() {
  step "Reload nginx"
  if ! nginx -t >/dev/null 2>&1; then
    nginx -t
    die "nginx config test failed"
  fi
  if have systemctl; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
  else
    nginx -s reload 2>/dev/null || nginx
  fi
  step_ok "reloaded"
}

open_firewall() {
  step "Firewall"
  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    step_ok "opened http/https in firewalld"
  else
    step_info "firewalld not active; skipped"
  fi
}

allow_selinux_proxy() {
  step "SELinux proxy permission"
  if have getenforce && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] && have setsebool; then
    if setsebool -P httpd_can_network_connect 1 2>/dev/null; then
      step_ok "allowed nginx to proxy (httpd_can_network_connect)"
      return 0
    fi
    warn "could not set httpd_can_network_connect"
    return 0
  fi
  step_info "not enforcing; skipped"
}

setup_nginx() {
  say ""
  say "${BOLD}nginx reverse proxy + TLS${RESET}"
  [[ -n "$DOMAIN" ]] || die "set ${APP_ENV_PREFIX}_DOMAIN in ${APP_ADMIN_ENV:-scripts/admin/admin.env} (or pass --domain)"
  install_nginx_pkgs
  write_nginx_site
  allow_selinux_proxy
  open_firewall
  reload_nginx
  step "TLS certificate for ${DOMAIN} (certbot)"
  if [[ "$ENABLE_TLS" != 1 ]]; then
    step_info "disabled — HTTP-only"
    return 0
  fi
  [[ -n "$TLS_EMAIL" ]] || die "set ${APP_ENV_PREFIX}_TLS_EMAIL in ${APP_ADMIN_ENV:-scripts/admin/admin.env} (or pass --email) for certbot"
  local log
  log="$(mktemp)"
  if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
    -m "$TLS_EMAIL" --redirect --keep-until-expiring >"$log" 2>&1; then
    rm -f "$log"
    step_ok "https://${DOMAIN}/ is live"
    return 0
  fi
  sed 's/^/    /' "$log" >&2
  rm -f "$log"
  warn "certbot could not issue a certificate yet.
  Check that DNS for ${DOMAIN} points here, then run:
    sudo certbot --nginx -d ${DOMAIN} -m ${TLS_EMAIL} --agree-tos --redirect"
}

install_prereqs
ensure_subids
setup_userns
install_homebrew
install_alias
enable_linger
if [[ "$GENERATE_DEPLOY_KEY" == 1 ]]; then
  generate_deploy_key
elif [[ -n "$DEPLOY_KEY_FILE" ]]; then
  install_deploy_key_file
fi
# Log in only when the app will run here or a real token was supplied.
have_token="$(registry_token)"
if [[ "$INSTALL_SERVICE" == 1 || -n "$REGISTRY_TOKEN_FILE" || -n "$have_token" ]]; then
  ensure_registry_login
fi
if [[ "$INSTALL_NGINX" == 1 ]]; then setup_nginx; fi

say ""
say "${GREEN}Server ready.${RESET}"
say ""
say "  ${BOLD}${ALIAS_NAME}${RESET}  ->  ${ROOT}/${RUN_SCRIPT}"
say "  ${DIM}Alias written to ${TARGET_HOME}/.bashrc — open a new shell, or run: source ~/.bashrc${RESET}"

# Phase 2: install the boot service as the operator (never as root).
install_service() {
  step "Boot service (systemd user unit for ${TARGET_USER})"
  if ! run_as_operator bash "$ROOT/$RUN_SCRIPT" --install-service; then
    die "could not install the service as ${TARGET_USER}.
  Log in and run it yourself:
    cd ${ROOT} && ./${RUN_SCRIPT} --install-service"
  fi
  if run_as_operator systemctl --user is-enabled "$SYSTEMD_UNIT" >/dev/null 2>&1; then
    step_ok "${SYSTEMD_UNIT}.service enabled — starts on every boot"
  else
    warn "could not confirm ${SYSTEMD_UNIT}.service is enabled as ${TARGET_USER}"
  fi
}

if [[ "$INSTALL_SERVICE" == 1 ]]; then
  install_service
  say ""
  say "Check it as ${TARGET_USER}:"
  say "  ${BOLD}systemctl --user status ${SYSTEMD_UNIT}${RESET}"
else
  say ""
  say "${BOLD}Next — install the boot service as ${TARGET_USER} (no sudo)${RESET}"
  say "  ssh ${TARGET_USER}@$(hostname)"
  say "  cd ${ROOT} && ./${RUN_SCRIPT} --install-service"
  say "  ${DIM}or re-run this script with --install-service${RESET}"
fi
