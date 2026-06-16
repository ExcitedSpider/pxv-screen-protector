#!/usr/bin/env bash
#
# Runs the React/Vite frontend toolchain inside a Podman container so no Node
# is needed on the host. Used by Tauri's beforeDevCommand / beforeBuildCommand,
# and directly for one-off installs.
#
#   ./tools/frontend/fe.sh install   # install node_modules
#   ./tools/frontend/fe.sh dev       # vite dev server on localhost:1420
#   ./tools/frontend/fe.sh build     # type-check + vite build -> dist/
#
set -euo pipefail

IMAGE="docker.io/library/node:22-bookworm-slim"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"

# label=disable: let the container read the bind mount without relabeling the
# whole repo (which would disturb the host's access to src-tauri/target).
COMMON=(--rm --init --security-opt label=disable -v "$ROOT":/app -w /app "$IMAGE")

case "$MODE" in
  install)
    exec podman run "${COMMON[@]}" npm install
    ;;
  dev)
    # --name + --replace so a leftover container never blocks port 1420.
    exec podman run --name pixiv-slides-vite --replace -p 1420:1420 "${COMMON[@]}" \
      sh -c '[ -d node_modules ] || npm install; exec npm run dev'
    ;;
  build)
    exec podman run "${COMMON[@]}" \
      sh -c '[ -d node_modules ] || npm install; exec npm run build'
    ;;
  *)
    echo "usage: fe.sh {install|dev|build}" >&2
    exit 1
    ;;
esac
