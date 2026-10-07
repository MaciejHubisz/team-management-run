# shellcheck shell=bash
# Linux-only platform helpers.

OS=""

detect_os() { OS=linux; }
is_linux() { [[ "$OS" == linux ]]; }

# Docker bind-mount relabel suffix for SELinux hosts.
volume_opts() { printf ':z'; }
# Same, for read-only mounts where the mode is a comma list (`:ro,z`).
volume_opts_ro() { printf ',z'; }

# Host path Docker can bind-mount.
resolve_host_path() {
  local raw="$1"
  raw="${raw%$'\r'}"
  [[ -n "$raw" ]] || die "a folder path is required"
  if [[ "$raw" != /* ]]; then
    raw="$(pwd)/$raw"
  fi
  mkdir -p "$raw" || die "cannot create folder: $raw"
  (cd "$raw" && pwd)
}

open_browser() {
  local target="$1"
  if [[ "$(uname -s)" == Darwin ]]; then
    open "$target" >/dev/null 2>&1 || true
  elif have xdg-open; then
    xdg-open "$target" >/dev/null 2>&1 || true
  else
    say "Open ${target} in a browser."
  fi
}

detect_os
