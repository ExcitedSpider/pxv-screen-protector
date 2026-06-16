#!/usr/bin/env bash
#
# Launch the dev stack from the repo root, regardless of your current dir.
# Equivalent to `cargo tauri dev`, which boots the Vite container via
# beforeDevCommand. Ctrl-C stops everything cleanly.
#
# A leftover Vite container from a previous unclean exit is handled
# automatically: fe.sh runs it with `--name pixiv-slides-vite --replace`, so a
# relaunch just takes over the name and port — no process-killing needed.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec cargo tauri dev "$@"
