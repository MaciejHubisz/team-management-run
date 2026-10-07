#!/usr/bin/env bash
# CI deploy setup. Generates a deploy SSH key, authorizes the public half for
# the operator, and uploads the private half plus the host variables to GitHub.
# Runs as the operator (the `gh`-authenticated user).
#
# Required environment:
#   DEPLOY_GH_OWNER      GitHub owner/org      e.g. MaciejHubisz
#   DEPLOY_GH_REPO       source repo           e.g. team-management
#   DEPLOY_ENV_PREFIX    compose env prefix    e.g. TEAMMGMT
#   DEPLOY_HOST          public hostname       e.g. odynce.nfy.pl
#   DEPLOY_PATH          run-repo dir on host  e.g. team-management-run
#   DEPLOY_SERVER_USER   ssh user on the host  e.g. maciej
# Optional:
#   DEPLOY_PORT          ssh port              default 22
#   DEPLOY_KEY_FILE      private key path      default ~/.ssh/deploy
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need gh
need ssh-keygen

if ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated — logging in"
  gh auth login
fi

: "${DEPLOY_GH_OWNER:?set DEPLOY_GH_OWNER}"
: "${DEPLOY_GH_REPO:?set DEPLOY_GH_REPO}"
: "${DEPLOY_ENV_PREFIX:?set DEPLOY_ENV_PREFIX}"
: "${DEPLOY_HOST:?set DEPLOY_HOST}"
: "${DEPLOY_PATH:?set DEPLOY_PATH}"
: "${DEPLOY_SERVER_USER:?set DEPLOY_SERVER_USER}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_KEY_FILE="${DEPLOY_KEY_FILE:-$HOME/.ssh/deploy}"

if [[ ! -f "$DEPLOY_KEY_FILE" ]]; then
  mkdir -p "$(dirname "$DEPLOY_KEY_FILE")"
  ssh-keygen -q -t ed25519 -N '' -C github-actions -f "$DEPLOY_KEY_FILE"
  echo "generated deploy key at $DEPLOY_KEY_FILE"
fi

auth="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
touch "$auth"
chmod 700 "$HOME/.ssh"
chmod 600 "$auth"
if ! grep -qF "$(cat "${DEPLOY_KEY_FILE}.pub")" "$auth" 2>/dev/null; then
  cat "${DEPLOY_KEY_FILE}.pub" >> "$auth"
  echo "authorized ${DEPLOY_KEY_FILE}.pub"
fi

full="${DEPLOY_GH_OWNER}/${DEPLOY_GH_REPO}"

gh secret set DEPLOY_USER                                  --repo "$full" --body "$DEPLOY_SERVER_USER"
gh secret set DEPLOY_SSH_KEY                               --repo "$full" < "$DEPLOY_KEY_FILE"
gh variable set "${DEPLOY_ENV_PREFIX}_DEPLOY_HOST"         --repo "$full" --body "$DEPLOY_HOST"
gh variable set "${DEPLOY_ENV_PREFIX}_DEPLOY_PORT"         --repo "$full" --body "$DEPLOY_PORT"
gh variable set "${DEPLOY_ENV_PREFIX}_DEPLOY_PATH"         --repo "$full" --body "$DEPLOY_PATH"

echo "uploaded deploy key and host variables to $full"
