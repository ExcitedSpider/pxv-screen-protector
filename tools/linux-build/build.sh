#!/usr/bin/env bash
#
# Host-side driver for controlled Linux packaging. The repository is mounted
# read-only; the builder copies it to its disposable workspace and writes only
# completed bundle artifacts to the fresh /output staging mount.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BUILDS_DIR="$ROOT/builds"
IMAGE="localhost/pixiv-slides-linux-builder:ubuntu-22.04"
CONTAINER_PREFIX="pixiv-slides-linux-build"
CONTAINERFILE="$SCRIPT_DIR/Containerfile"

CACHE_VOLUMES=(
    pixiv-slides-linux-cargo-registry
    pixiv-slides-linux-cargo-git
    pixiv-slides-linux-target
    pixiv-slides-linux-npm
    pixiv-slides-linux-tauri
)

STAGING_DIR=""
CANDIDATE_DIR=""
BACKUP_DIR=""
FINAL_DIR=""
CONTAINER_NAME=""

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: build.sh {build [TAURI_BUILD_ARGS...]|image|clean}
EOF
}

require_podman() {
    command -v podman >/dev/null 2>&1 ||
        die "Podman is required for the controlled Linux build"

    local rootless
    rootless="$(podman info --format '{{.Host.Security.Rootless}}')" ||
        die "Podman is unavailable; check that the rootless Podman service works"
    [[ "$rootless" == "true" ]] ||
        die "the controlled Linux build must run with rootless Podman"
}

require_supported_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            ;;
        *)
            die "the controlled Linux builder currently supports x86-64 hosts only (found $arch)"
            ;;
    esac
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 ||
        die "flock is required to coordinate project build state"
    mkdir -p -- "$BUILDS_DIR"
    exec 9>"$BUILDS_DIR/.build.lock"
    flock -n 9 || die "another pixiv-slides Linux build operation is running"
    recover_interrupted_publications
}

recover_interrupted_publications() {
    local backup
    local candidate
    local final
    local staging

    shopt -s nullglob
    for backup in "$BUILDS_DIR"/*/linux-*.previous.*; do
        final=${backup%.previous.*}
        if [[ -e "$final" ]]; then
            rm -rf -- "$backup"
        else
            echo "Restoring interrupted build output: $final"
            mv -- "$backup" "$final"
        fi
    done
    for candidate in "$BUILDS_DIR"/*/linux-*.new.*; do
        rm -rf -- "$candidate"
    done
    for staging in "$BUILDS_DIR"/.staging.*; do
        rm -rf -- "$staging"
    done
    shopt -u nullglob
}

build_image() {
    require_supported_arch
    [[ -f "$CONTAINERFILE" ]] || die "builder definition not found: $CONTAINERFILE"
    echo "Building controlled Linux builder image: $IMAGE"
    podman build \
        --layers \
        --file "$CONTAINERFILE" \
        --tag "$IMAGE" \
        "$SCRIPT_DIR"
}

cleanup() {
    local status=$?
    trap - EXIT

    if [[ -n "$CONTAINER_NAME" ]]; then
        podman rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if [[ -n "$BACKUP_DIR" && -e "$BACKUP_DIR" && -n "$FINAL_DIR" && ! -e "$FINAL_DIR" ]]; then
        mv -- "$BACKUP_DIR" "$FINAL_DIR" || true
        BACKUP_DIR=""
    fi

    if [[ -n "$CANDIDATE_DIR" && -e "$CANDIDATE_DIR" ]]; then
        rm -rf -- "$CANDIDATE_DIR"
    fi
    if [[ -n "$STAGING_DIR" && -e "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi

    exit "$status"
}

source_metadata() {
    SOURCE_COMMIT="unknown"
    SOURCE_DIRTY="true"
    SOURCE_EPOCH="0"

    if SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
        SOURCE_EPOCH="$(git -C "$ROOT" show -s --format=%ct HEAD 2>/dev/null || echo 0)"
        if [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
            SOURCE_DIRTY="false"
        fi
    else
        SOURCE_COMMIT="unknown"
    fi
}

install_staged_output() {
    local version_file="$STAGING_DIR/.version"
    local arch_file="$STAGING_DIR/.arch"
    local version
    local arch

    [[ -s "$version_file" ]] || die "builder did not report the application version"
    [[ -s "$arch_file" ]] || die "builder did not report the target architecture"
    [[ -s "$STAGING_DIR/SHA256SUMS" ]] || die "builder did not produce SHA256SUMS"
    [[ -s "$STAGING_DIR/build-info.txt" ]] || die "builder did not produce build-info.txt"
    (
        cd "$STAGING_DIR"
        sha256sum --check SHA256SUMS >/dev/null
    ) || die "builder artifact checksums did not verify"

    version="$(<"$version_file")"
    arch="$(<"$arch_file")"
    [[ "$version" =~ ^[0-9][0-9A-Za-z._+-]*$ ]] || die "invalid application version from builder: $version"
    [[ "$arch" =~ ^[0-9A-Za-z_-]+$ ]] || die "invalid target architecture from builder: $arch"

    rm -- "$version_file" "$arch_file"
    # mktemp creates the staging directory with mode 0700. The directory is
    # promoted into builds/ unchanged, so make the published artifacts
    # accessible like normal repository build output before the atomic move.
    chmod 0755 "$STAGING_DIR"

    FINAL_DIR="$BUILDS_DIR/$version/linux-$arch"
    mkdir -p -- "$(dirname -- "$FINAL_DIR")"
    CANDIDATE_DIR="${FINAL_DIR}.new.$$"
    BACKUP_DIR="${FINAL_DIR}.previous.$$"

    [[ ! -e "$CANDIDATE_DIR" ]] || die "temporary artifact directory already exists: $CANDIDATE_DIR"
    [[ ! -e "$BACKUP_DIR" ]] || die "backup artifact directory already exists: $BACKUP_DIR"

    mv -- "$STAGING_DIR" "$CANDIDATE_DIR"
    STAGING_DIR=""

    if [[ -e "$FINAL_DIR" ]]; then
        mv -- "$FINAL_DIR" "$BACKUP_DIR"
    else
        BACKUP_DIR=""
    fi

    if ! mv -- "$CANDIDATE_DIR" "$FINAL_DIR"; then
        if [[ -n "$BACKUP_DIR" && -e "$BACKUP_DIR" ]]; then
            mv -- "$BACKUP_DIR" "$FINAL_DIR"
            BACKUP_DIR=""
        fi
        die "could not install the completed artifact directory"
    fi
    CANDIDATE_DIR=""

    if [[ -n "$BACKUP_DIR" ]]; then
        rm -rf -- "$BACKUP_DIR"
        BACKUP_DIR=""
    fi

    local repository_relative_dir="${FINAL_DIR#"$ROOT"/}"
    local artifact

    echo
    echo "Published Linux bundles in the repository:"
    while read -r _ artifact; do
        artifact="${artifact#\*}"
        printf '  %s/%s\n' "$repository_relative_dir" "$artifact"
    done < "$FINAL_DIR/SHA256SUMS"
    echo "Build metadata:"
    printf '  %s/SHA256SUMS\n' "$repository_relative_dir"
    printf '  %s/build-info.txt\n' "$repository_relative_dir"
    echo "Absolute output directory: $FINAL_DIR"
}

run_build() {
    require_podman
    acquire_lock
    build_image
    source_metadata

    local image_id
    image_id="$(podman image inspect --format '{{.Id}}' "$IMAGE")"
    STAGING_DIR="$(mktemp -d "$BUILDS_DIR/.staging.XXXXXX")"
    CONTAINER_NAME="${CONTAINER_PREFIX}-$$"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo "Building Linux bundles in the controlled Ubuntu 22.04 environment..."
    echo "Tauri's /cache paths below are container-internal; published paths are listed after validation."
    podman run \
        --rm \
        --init \
        --name "$CONTAINER_NAME" \
        --cap-drop all \
        --security-opt label=disable \
        --security-opt no-new-privileges \
        --mount "type=bind,src=$ROOT,dst=/source,ro=true" \
        --mount "type=bind,src=$STAGING_DIR,dst=/output" \
        --volume "${CACHE_VOLUMES[0]}:/cache/cargo/registry" \
        --volume "${CACHE_VOLUMES[1]}:/cache/cargo/git" \
        --volume "${CACHE_VOLUMES[2]}:/cache/target" \
        --volume "${CACHE_VOLUMES[3]}:/cache/npm" \
        --volume "${CACHE_VOLUMES[4]}:/cache/tauri" \
        --env "PIXIV_SLIDES_BUILD_COMMIT=$SOURCE_COMMIT" \
        --env "PIXIV_SLIDES_BUILD_DIRTY=$SOURCE_DIRTY" \
        --env "PIXIV_SLIDES_BUILD_IMAGE=$IMAGE" \
        --env "PIXIV_SLIDES_BUILD_IMAGE_ID=$image_id" \
        --env "SOURCE_DATE_EPOCH=$SOURCE_EPOCH" \
        "$IMAGE" build "$@"
    CONTAINER_NAME=""

    install_staged_output
}

clean_builder() {
    require_podman
    acquire_lock

    local volume
    local failed=false
    for volume in "${CACHE_VOLUMES[@]}"; do
        if podman volume exists "$volume"; then
            echo "Removing build cache volume: $volume"
            if ! podman volume rm "$volume"; then
                failed=true
            fi
        fi
    done

    if podman image exists "$IMAGE"; then
        echo "Removing builder image: $IMAGE"
        if ! podman image rm "$IMAGE"; then
            failed=true
        fi
    fi

    [[ "$failed" == "false" ]] ||
        die "some project build caches are in use and could not be removed"
    echo "Controlled Linux builder image and caches are clean. Completed builds were preserved."
}

mode="${1:-}"
if (($# > 0)); then
    shift
fi

case "$mode" in
    build)
        run_build "$@"
        ;;
    image)
        (($# == 0)) || die "image does not accept arguments"
        require_podman
        acquire_lock
        build_image
        ;;
    clean)
        (($# == 0)) || die "clean does not accept arguments"
        clean_builder
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
