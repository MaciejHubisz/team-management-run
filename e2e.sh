#!/usr/bin/env bash
# Run the browser end-to-end suite from the team-management-e2e image. The
# tests live in the source repo (team-management/e2e); this script only builds
# or pulls the image and runs it against a throwaway database inside it.
#
#   ./e2e.sh                    watch it in your web browser (noVNC, opens itself)
#   ./e2e.sh --window           a real Chromium window on this desktop (X11/XWayland)
#   ./e2e.sh --fast             headless, full speed, just the result
#   ./e2e.sh roster events      only tests matching "roster" or "events"
#   ./e2e.sh --slow 800 auth    slower clicks (ms per action; default 300)
#   ./e2e.sh --list             list all tests
#   ./e2e.sh --build            rebuild the image from ../team-management first
#   ./e2e.sh --pull             pull the published image instead of building
#   ./e2e.sh -- -x --lf         anything after -- goes to pytest
#
# Results: tmp/e2e/report.html; a failed test keeps a screenshot and trace.zip
# in tmp/e2e/<test>/ (open the trace at https://trace.playwright.dev).
# Env: TEAMMGMT_E2E_TAG (image tag, default latest), TEAMMGMT_E2E_PORT (viewer, 7900).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/app.conf"
SRC="${TEAMMGMT_SRC:-$ROOT/../${APP_SRC_DIR}}"
IMAGE="${TEAMMGMT_IMAGE_PREFIX:-$APP_IMAGE_PREFIX}-e2e:${TEAMMGMT_E2E_TAG:-latest}"
PORT="${TEAMMGMT_E2E_PORT:-7900}"
OUT="$ROOT/tmp/e2e"

display=vnc
image_source=auto
pass=()

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) display=host ;;
    --fast | --headless) display=none ;;
    --build) image_source=build ;;
    --pull) image_source=pull ;;
    --list) display=none; pass+=("$1") ;;
    -h | --help) usage; exit 0 ;;
    --) pass+=("$@"); break ;;
    *) pass+=("$1") ;;
  esac
  shift
done

ENGINE="${TEAMMGMT_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  for bin in docker podman; do
    if command -v "$bin" >/dev/null 2>&1 && "$bin" info >/dev/null 2>&1; then
      ENGINE="$bin"
      break
    fi
  done
fi
[[ -n "$ENGINE" ]] || { echo "No working docker or podman found." >&2; exit 1; }

have_image() { "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; }

if [[ "$image_source" == auto ]]; then
  if [[ -x "$SRC/e2e/build.sh" ]]; then image_source=build; else image_source=pull; fi
fi
if [[ "$image_source" == build ]]; then
  [[ -x "$SRC/e2e/build.sh" ]] || { echo "No source repo at $SRC (try --pull)." >&2; exit 1; }
  TEAMMGMT_ENGINE="$ENGINE" "$SRC/e2e/build.sh"
elif ! have_image || [[ "${TEAMMGMT_E2E_TAG:-latest}" == latest ]]; then
  "$ENGINE" pull "$IMAGE"
fi

mkdir -p "$OUT"
find "$OUT" -mindepth 1 -delete

run=(run --rm --name team-management-e2e --shm-size=1g --security-opt label=disable
  -e "E2E_DISPLAY=$display" -e "E2E_VIEWER_PORT=$PORT"
  -e TEAMMGMT_DEMO_DIR=/demo
  -v "$ROOT/demo:/demo:ro"
  -v "$OUT:/app/e2e/.artifacts")
[[ -t 0 && -t 1 ]] && run+=(-it)
if [[ "$ENGINE" == podman ]]; then
  run+=(--userns=keep-id)
else
  run+=(--user "$(id -u):$(id -g)")
fi

case "$display" in
  vnc)
    run+=(-p "127.0.0.1:${PORT}:7900")
    url="http://localhost:${PORT}/vnc.html?autoconnect=1&resize=scale"
    if [[ "${TEAMMGMT_E2E_OPEN:-1}" == 1 ]] && command -v xdg-open >/dev/null 2>&1; then
      (sleep 4 && xdg-open "$url" >/dev/null 2>&1) &
    fi
    ;;
  host)
    [[ -n "${DISPLAY:-}" ]] || { echo "--window needs an X display (DISPLAY is empty)." >&2; exit 1; }
    run+=(-e "DISPLAY=$DISPLAY" -v /tmp/.X11-unix:/tmp/.X11-unix:ro)
    if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
      run+=(-e XAUTHORITY=/tmp/.Xauthority -v "$XAUTHORITY:/tmp/.Xauthority:ro")
    fi
    ;;
esac

status=0
"$ENGINE" "${run[@]}" "$IMAGE" "${pass[@]}" || status=$?
if [[ -f "$OUT/report.html" ]]; then
  echo "Report: $OUT/report.html"
fi
exit "$status"
