#!/usr/bin/env bash
#
# Host-side driver for controlled Linux packaging. Packaging mounts the
# repository read-only; release preparation uses a short-lived version helper
# plus a guarded Git/GitHub state machine. The builder writes only completed
# bundle artifacts to the fresh /output staging mount.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BUILDS_DIR="$ROOT/builds"
IMAGE="localhost/pixiv-slides-linux-builder:ubuntu-22.04"
CONTAINER_PREFIX="pixiv-slides-linux-build"
CONTAINERFILE="$SCRIPT_DIR/Containerfile"
VERSION_HELPER="$ROOT/tools/release/bump-version.mjs"
RELEASE_WORKFLOW="$ROOT/tools/release/release-workflow.sh"

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
RELEASE_VERSION=""
RELEASE_STAGE=""
RELEASE_PACKAGED="false"
RELEASE_SOURCE_DIR=""
RELEASE_SOURCE_COMMIT=""
RELEASE_SOURCE_FINGERPRINT=""
PACKAGING_SOURCE_DIR="$ROOT"

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: build.sh {build [TAURI_BUILD_ARGS...]|release [TAURI_BUILD_ARGS...]|image|clean}
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
    for staging in "$BUILDS_DIR"/.release-source.*; do
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
    local saved_stage=""
    local state_key
    local state_value
    local state_file="${PIXIV_SLIDES_RELEASE_STATE:-$BUILDS_DIR/.release-state}"
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
    if [[ -n "$RELEASE_SOURCE_DIR" && -e "$RELEASE_SOURCE_DIR" ]]; then
        rm -rf -- "$RELEASE_SOURCE_DIR"
    fi

    if ((status != 0)) && [[ -n "$RELEASE_VERSION" ]]; then
        if [[ -f "$state_file" ]]; then
            while IFS='=' read -r state_key state_value; do
                if [[ "$state_key" == "stage" && \
                      "$state_value" =~ ^(ready|bumped|committed|built|tagged|pushed|draft|uploaded)$ ]]; then
                    saved_stage="$state_value"
                    break
                fi
            done < "$state_file"
        fi
        if [[ -n "$saved_stage" ]]; then
            RELEASE_STAGE="$saved_stage"
        fi
        echo "Release v$RELEASE_VERSION paused at stage ${RELEASE_STAGE:-unknown}." >&2
        if [[ "$RELEASE_PACKAGED" == "true" ]]; then
            echo "The validated bundles and release state were kept." >&2
        else
            echo "The release state was kept; its version will not be incremented again." >&2
        fi
        echo "Fix the failure, then resume with: ./dev.sh release" >&2
    fi

    exit "$status"
}

source_metadata() {
    SOURCE_COMMIT="unknown"
    SOURCE_DIRTY="true"
    SOURCE_EPOCH="0"

    if [[ -n "$RELEASE_SOURCE_COMMIT" ]]; then
        SOURCE_COMMIT="$RELEASE_SOURCE_COMMIT"
        SOURCE_EPOCH="$(git -C "$ROOT" show -s --format=%ct "$SOURCE_COMMIT" 2>/dev/null)" ||
            die "could not read the release source commit timestamp"
        [[ "$SOURCE_EPOCH" =~ ^[0-9]+$ ]] ||
            die "release source commit has an invalid timestamp"
        SOURCE_DIRTY="false"
        return
    fi

    if SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
        SOURCE_EPOCH="$(git -C "$ROOT" show -s --format=%ct HEAD 2>/dev/null || echo 0)"
        if [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
            SOURCE_DIRTY="false"
        fi
    else
        SOURCE_COMMIT="unknown"
    fi
}

prepare_release_source_snapshot() {
    command -v git >/dev/null 2>&1 || die "Git is required to export the release source"
    command -v tar >/dev/null 2>&1 || die "tar is required to export the release source"
    [[ -n "$RELEASE_SOURCE_COMMIT" ]] || die "release source commit was not selected"
    [[ "$RELEASE_SOURCE_COMMIT" =~ ^[0-9a-f]{40,64}$ ]] ||
        die "Git returned an invalid release source commit"
    RELEASE_SOURCE_DIR="$(mktemp -d "$BUILDS_DIR/.release-source.XXXXXX")"
    if ! git -C "$ROOT" archive --format=tar "$RELEASE_SOURCE_COMMIT" |
        tar --extract --directory "$RELEASE_SOURCE_DIR"; then
        die "could not export the immutable release source snapshot"
    fi
    PACKAGING_SOURCE_DIR="$RELEASE_SOURCE_DIR"
    RELEASE_SOURCE_FINGERPRINT="$(release_source_snapshot_fingerprint)"
    echo "Exported committed release source $RELEASE_SOURCE_COMMIT for packaging."
}

release_source_snapshot_fingerprint() {
    [[ -n "$RELEASE_SOURCE_DIR" && -d "$RELEASE_SOURCE_DIR" ]] ||
        die "release source snapshot is missing"
    local checksum_output
    checksum_output="$(
        tar \
            --create \
            --format=pax \
            --sort=name \
            --mtime=@0 \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            --pax-option=delete=atime,delete=ctime \
            --file=- \
            --directory="$RELEASE_SOURCE_DIR" \
            . |
            sha256sum
    )" || die "could not fingerprint the release source snapshot"
    checksum_output="${checksum_output%% *}"
    [[ "$checksum_output" =~ ^[0-9a-f]{64}$ ]] ||
        die "sha256sum returned an invalid release source fingerprint"
    printf '%s\n' "$checksum_output"
}

verify_release_source_snapshot() {
    [[ -n "$RELEASE_SOURCE_DIR" ]] || return 0
    [[ -n "$RELEASE_SOURCE_FINGERPRINT" ]] ||
        die "release source snapshot fingerprint is missing"
    [[ "$(release_source_snapshot_fingerprint)" == "$RELEASE_SOURCE_FINGERPRINT" ]] ||
        die "release source snapshot changed during packaging"
}

remove_release_source_snapshot() {
    if [[ -n "$RELEASE_SOURCE_DIR" && -e "$RELEASE_SOURCE_DIR" ]]; then
        rm -rf -- "$RELEASE_SOURCE_DIR"
    fi
    RELEASE_SOURCE_DIR=""
    RELEASE_SOURCE_FINGERPRINT=""
    PACKAGING_SOURCE_DIR="$ROOT"
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

bump_release_version() {
    local expected_version="$1"
    [[ -f "$VERSION_HELPER" ]] || die "version helper not found: $VERSION_HELPER"

    if ! RELEASE_VERSION="$(
        podman run \
            --rm \
            --init \
            --cap-drop all \
            --security-opt label=disable \
            --security-opt no-new-privileges \
            --mount "type=bind,src=$ROOT,dst=/workspace" \
            --workdir /workspace \
            --entrypoint node \
            "$IMAGE" tools/release/bump-version.mjs --bump
    )"; then
        die "could not increment the project patch version"
    fi
    [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "version helper returned an invalid version: $RELEASE_VERSION"
    [[ "$RELEASE_VERSION" == "$expected_version" ]] ||
        die "version helper produced $RELEASE_VERSION, expected $expected_version"
}

inspect_project_versions() {
    local version_info
    local extra_version_field
    version_info="$(
        podman run \
            --rm \
            --init \
            --cap-drop all \
            --security-opt label=disable \
            --security-opt no-new-privileges \
            --mount "type=bind,src=$ROOT,dst=/workspace,ro=true" \
            --workdir /workspace \
            --entrypoint node \
            "$IMAGE" tools/release/bump-version.mjs --inspect
    )" || die "could not inspect the synchronized project versions"
    IFS=$'\t' read -r \
        CURRENT_VERSION \
        NEXT_VERSION \
        PIXIV_SLIDES_RELEASE_BUMP_SHA256 \
        extra_version_field <<< "$version_info"
    [[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "version helper returned an invalid current version"
    [[ "$NEXT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "version helper returned an invalid next version"
    [[ "$PIXIV_SLIDES_RELEASE_BUMP_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
        die "version helper returned an invalid deterministic bump fingerprint"
    [[ -z "${extra_version_field:-}" ]] || die "version helper returned unexpected output"
    export PIXIV_SLIDES_RELEASE_BUMP_SHA256
}

set_release_arguments_fingerprint() {
    local fingerprint_output
    if (($# == 0)); then
        fingerprint_output="$(sha256sum </dev/null)" ||
            die "could not fingerprint the release build arguments"
    else
        fingerprint_output="$(printf '%s\0' "$@" | sha256sum)" ||
            die "could not fingerprint the release build arguments"
    fi
    PIXIV_SLIDES_RELEASE_ARGS_SHA256="${fingerprint_output%% *}"
    [[ "$PIXIV_SLIDES_RELEASE_ARGS_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
        die "sha256sum returned an invalid release build-argument fingerprint"
    export PIXIV_SLIDES_RELEASE_ARGS_SHA256
}

validate_build_arguments() {
    podman run \
        --rm \
        --init \
        --cap-drop all \
        --security-opt no-new-privileges \
        "$IMAGE" validate "$@"
}

run_packaging() {
    source_metadata
    verify_release_source_snapshot

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
        --mount "type=bind,src=$PACKAGING_SOURCE_DIR,dst=/source,ro=true" \
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
    verify_release_source_snapshot

    install_staged_output
}

run_build() {
    require_podman
    acquire_lock
    build_image
    run_packaging "$@"
}

run_release() {
    require_podman
    acquire_lock
    build_image
    validate_build_arguments "$@"
    [[ -x "$RELEASE_WORKFLOW" ]] || die "release workflow helper is not executable: $RELEASE_WORKFLOW"
    set_release_arguments_fingerprint "$@"
    inspect_project_versions

    local release_context
    local context_version
    local context_stage
    local context_extra
    release_context="$(
        "$RELEASE_WORKFLOW" begin "$ROOT" "$CURRENT_VERSION" "$NEXT_VERSION"
    )" || die "release preflight or recovery failed"
    IFS=$'\t' read -r context_version context_stage context_extra <<< "$release_context"
    [[ "$context_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "release workflow returned an invalid version"
    [[ -z "${context_extra:-}" ]] || die "release workflow returned unexpected output"
    case "$context_stage" in
        ready|bumped|committed|built|tagged|pushed|draft|uploaded|replayed) ;;
        *) die "release workflow returned an invalid stage: $context_stage" ;;
    esac
    RELEASE_VERSION="$context_version"
    RELEASE_STAGE="$context_stage"
    case "$RELEASE_STAGE" in
        built|tagged|pushed|draft|uploaded) RELEASE_PACKAGED="true" ;;
    esac
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ "$RELEASE_STAGE" == "replayed" ]]; then
        die "upstream was replayed into the release; rerun ./dev.sh release so current build tooling is loaded"
    fi

    if [[ "$RELEASE_STAGE" == "ready" ]]; then
        bump_release_version "$RELEASE_VERSION"
        "$RELEASE_WORKFLOW" bumped "$ROOT" "$RELEASE_VERSION"
        RELEASE_STAGE="bumped"
    fi
    if [[ "$RELEASE_STAGE" == "bumped" ]]; then
        "$RELEASE_WORKFLOW" commit "$ROOT" "$RELEASE_VERSION"
        RELEASE_STAGE="committed"
    fi
    if [[ "$RELEASE_STAGE" == "committed" ]]; then
        release_context="$(
            "$RELEASE_WORKFLOW" begin "$ROOT" "$RELEASE_VERSION" "$RELEASE_VERSION"
        )" || die "release changed upstream and could not be refreshed before packaging"
        IFS=$'\t' read -r context_version context_stage context_extra <<< "$release_context"
        [[ "$context_version" == "$RELEASE_VERSION" && -z "${context_extra:-}" ]] ||
            die "release workflow returned an unexpected state before packaging"
        if [[ "$context_stage" == "replayed" ]]; then
            RELEASE_STAGE="replayed"
            die "upstream was replayed into the release; rerun ./dev.sh release so current build tooling is loaded"
        fi
        [[ "$context_stage" == "committed" ]] ||
            die "release workflow returned an unexpected stage before packaging: $context_stage"
        RELEASE_SOURCE_COMMIT="$(
            "$RELEASE_WORKFLOW" source-commit "$ROOT" "$RELEASE_VERSION"
        )" || die "could not select the immutable release source commit"
        prepare_release_source_snapshot
        run_packaging "$@"
        remove_release_source_snapshot
        "$RELEASE_WORKFLOW" built "$ROOT" "$RELEASE_VERSION" "$FINAL_DIR"
        RELEASE_STAGE="built"
        RELEASE_PACKAGED="true"
    fi

    "$RELEASE_WORKFLOW" publish "$ROOT" "$RELEASE_VERSION"
    RELEASE_STAGE="published"
    echo "Release v$RELEASE_VERSION is complete."
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
    release)
        run_release "$@"
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
