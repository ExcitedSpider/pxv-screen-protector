#!/usr/bin/env bash
#
# Project command wrapper. Run without arguments (or with `help`) to list the
# available commands. Commands work from any current directory.
#
# The `dev` command is equivalent to `cargo tauri dev`, which boots the Vite
# container via beforeDevCommand. Ctrl-C/app exit stops that project container.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
    cat <<'EOF'
Usage:
  ./dev.sh
  ./dev.sh {help|-h|--help}
  ./dev.sh dev [TAURI_DEV_ARGS...]
  ./dev.sh build [TAURI_BUILD_ARGS...]
  ./dev.sh release [TAURI_BUILD_ARGS...]
  ./dev.sh build-host [TAURI_BUILD_ARGS...]
  ./dev.sh build-image
  ./dev.sh build-clean
  ./dev.sh check [CARGO_CHECK_ARGS...]
  ./dev.sh test [CARGO_TEST_ARGS...]
  ./dev.sh frontend-build

Commands:
  dev             Launch the Tauri app and containerized Vite dev server.
  build           Build Linux packages in the controlled Podman environment.
                  Release-compatible Tauri options are forwarded. With no
                  arguments, all configured formats (DEB, RPM, AppImage) build.
                  Published packages are listed under builds/<version>/linux-<arch>/.
  release         Increment and commit the patch version, run the controlled
                  build, atomically push its tag, and publish a GitHub release.
                  Requires a clean, synchronized branch and authenticated gh.
                  A failed release resumes at the saved stage when rerun.
  build-host      Build directly with the host Rust/Tauri toolchain.
  build-image     Create or refresh the controlled Linux builder image.
  build-clean     Remove only the builder image and project build caches.
                  Previously completed artifacts under builds/ are preserved.
  check           Check the Rust backend without building artifacts for release.
  test            Run the Rust backend test suite.
  frontend-build  Type-check and build the frontend inside Podman.
  help            Show this help without launching the app.
EOF
}

command_name="${1:-help}"
if (($# > 0)); then
    shift
fi

case "$command_name" in
    help|-h|--help)
        if (($# > 0)); then
            echo "error: help does not accept arguments" >&2
            usage >&2
            exit 2
        fi
        usage
        ;;
    dev)
        cleanup() {
            podman stop pixiv-slides-vite >/dev/null 2>&1 || true
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cargo tauri dev "$@"
        ;;
    build)
        exec ./tools/linux-build/build.sh build "$@"
        ;;
    release)
        exec ./tools/linux-build/build.sh release "$@"
        ;;
    build-host)
        exec cargo tauri build "$@"
        ;;
    build-image)
        if (($# > 0)); then
            echo "error: build-image does not accept arguments" >&2
            usage >&2
            exit 2
        fi
        exec ./tools/linux-build/build.sh image
        ;;
    build-clean)
        if (($# > 0)); then
            echo "error: build-clean does not accept arguments" >&2
            usage >&2
            exit 2
        fi
        exec ./tools/linux-build/build.sh clean
        ;;
    check)
        exec cargo check --manifest-path src-tauri/Cargo.toml "$@"
        ;;
    test)
        exec cargo test --manifest-path src-tauri/Cargo.toml "$@"
        ;;
    frontend-build)
        if (($# > 0)); then
            echo "error: frontend-build does not accept arguments" >&2
            usage >&2
            exit 2
        fi
        exec ./tools/frontend/fe.sh build
        ;;
    *)
        echo "error: unknown command: $command_name" >&2
        usage >&2
        exit 2
        ;;
esac
