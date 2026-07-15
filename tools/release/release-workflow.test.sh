#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$SCRIPT_DIR/release-workflow.sh"
BUMP_VERSION="$SCRIPT_DIR/bump-version.mjs"
REAL_GIT="$(command -v git)"
NODE_BIN="$(command -v node)"

fail() {
    echo "release-workflow test failed: $*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$description: expected '$expected', found '$actual'"
}

assert_contains() {
    local file="$1"
    local expected="$2"
    local description="$3"
    grep -F -- "$expected" "$file" >/dev/null ||
        fail "$description: '$expected' not found in $file"
}

assert_command_fails() {
    local description="$1"
    shift
    if "$@"; then
        fail "$description unexpectedly succeeded"
    fi
}

[[ -x "$WORKFLOW" ]] || fail "workflow is not executable: $WORKFLOW"
[[ -f "$BUMP_VERSION" ]] || fail "version helper is missing: $BUMP_VERSION"
[[ -n "$REAL_GIT" ]] || fail "git is required"
[[ -n "$NODE_BIN" ]] || fail "node is required"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pixiv-slides-release-workflow-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
mkdir -p -- "$HOME"

FAKE_BIN="$TEST_ROOT/bin"
FAKE_GIT="$FAKE_BIN/git"
FAKE_GH="$FAKE_BIN/gh"
mkdir -p -- "$FAKE_BIN"

cat > "$FAKE_GIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    first=1
    for arg in "$@"; do
        if ((first)); then
            first=0
        else
            printf ' '
        fi
        printf '%q' "$arg"
    done
    printf '\n'
} >> "$FAKE_GIT_LOG"
exec "$REAL_GIT_BIN" "$@"
EOF

cat > "$FAKE_GH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_call() {
    local first=1
    local arg
    for arg in "$@"; do
        if ((first)); then
            first=0
        else
            printf '\t' >> "$FAKE_GH_LOG"
        fi
        printf '%s' "$arg" >> "$FAKE_GH_LOG"
    done
    printf '\n' >> "$FAKE_GH_LOG"
}

release_status() {
    if [[ -f "$FAKE_GH_STATE/release-status" ]]; then
        cat "$FAKE_GH_STATE/release-status"
    else
        printf 'missing\n'
    fi
}

copy_asset_arguments() {
    local arg
    local source
    mkdir -p -- "$FAKE_GH_STATE/assets"
    for arg in "$@"; do
        source="${arg%%#*}"
        if [[ -f "$source" ]]; then
            cp -- "$source" "$FAKE_GH_STATE/assets/$(basename -- "$source")"
        fi
    done
}

log_call "$@"

case "${1:-} ${2:-}" in
    "auth status")
        exit 0
        ;;
    "api graphql")
        release_status
        ;;
    "release create")
        mkdir -p -- "$FAKE_GH_STATE"
        printf 'draft\n' > "$FAKE_GH_STATE/release-status"
        ;;
    "release upload")
        if [[ -f "$FAKE_GH_FAIL_UPLOAD_FILE" ]]; then
            rm -- "$FAKE_GH_FAIL_UPLOAD_FILE"
            echo "simulated GitHub asset upload failure" >&2
            exit 42
        fi
        rm -rf -- "$FAKE_GH_STATE/assets"
        copy_asset_arguments "$@"
        ;;
    "release edit")
        draft_value=false
        for arg in "$@"; do
            case "$arg" in
                --draft=true) draft_value=true ;;
                --draft=false) draft_value=false ;;
            esac
        done
        if [[ "$draft_value" == true ]]; then
            printf 'draft\n' > "$FAKE_GH_STATE/release-status"
        else
            printf 'published\n' > "$FAKE_GH_STATE/release-status"
            if [[ -f "$FAKE_GH_REPLACE_TAG_ON_EDIT_FILE" ]]; then
                rm -- "$FAKE_GH_REPLACE_TAG_ON_EDIT_FILE"
                release_commit="$($REAL_GIT_BIN -C "$FAKE_GH_REPOSITORY" rev-parse HEAD)"
                "$REAL_GIT_BIN" -C "$FAKE_GH_REPOSITORY" tag --force --annotate v1.2.10 \
                    --message "Concurrent replacement v1.2.10" "$release_commit" >/dev/null
                "$REAL_GIT_BIN" -C "$FAKE_GH_REPOSITORY" push --force origin \
                    refs/tags/v1.2.10 >/dev/null
            fi
        fi
        ;;
    "release view")
        requested_field=""
        previous=""
        for arg in "$@"; do
            if [[ "$previous" == "--json" ]]; then
                requested_field="$arg"
                break
            fi
            previous="$arg"
        done
        case "$requested_field" in
            assets)
                if [[ -d "$FAKE_GH_STATE/assets" ]]; then
                    while IFS= read -r asset_name; do
                        asset_path="$FAKE_GH_STATE/assets/$asset_name"
                        asset_size="$(stat --format=%s -- "$asset_path")"
                        asset_hash="$(sha256sum -- "$asset_path")"
                        asset_hash="${asset_hash%% *}"
                        if [[ -f "$FAKE_GH_BAD_DIGEST_FILE" ]]; then
                            asset_hash="0000000000000000000000000000000000000000000000000000000000000000"
                        fi
                        printf '%s\t%s\tsha256:%s\n' "$asset_name" "$asset_size" "$asset_hash"
                    done < <(
                        find "$FAKE_GH_STATE/assets" -maxdepth 1 -type f -printf '%f\n' |
                            LC_ALL=C sort
                    )
                fi
                ;;
            url)
                printf 'https://example.invalid/releases/v1.2.10\n'
                ;;
            *)
                echo "fake gh: unsupported release view field: $requested_field" >&2
                exit 2
                ;;
        esac
        ;;
    "api "*)
        case "${2:-}" in
            repos/*)
                printf 'true\n'
                ;;
            *)
                echo "fake gh: unsupported api endpoint: ${2:-}" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "fake gh: unsupported invocation: $*" >&2
        exit 2
        ;;
esac
EOF

chmod 0755 "$FAKE_GIT" "$FAKE_GH"
export REAL_GIT_BIN="$REAL_GIT"
export PIXIV_SLIDES_GIT_BIN="$FAKE_GIT"
export PIXIV_SLIDES_GH_BIN="$FAKE_GH"
export PIXIV_SLIDES_RELEASE_REMOTE=origin
export PIXIV_SLIDES_GITHUB_REPOSITORY=example/pixiv-slides

FIXTURE_BASE=""
FIXTURE_REPOSITORY=""
FIXTURE_REMOTE=""
FIXTURE_STATE=""
FIXTURE_ARTIFACTS=""
FAKE_GIT_LOG=""
FAKE_GH_LOG=""
FAKE_GH_STATE=""
FAKE_GH_FAIL_UPLOAD_FILE=""
FAKE_GH_BAD_DIGEST_FILE=""
FAKE_GH_REPLACE_TAG_ON_EDIT_FILE=""
FAKE_GH_REPOSITORY=""

create_fixture() {
    local name="$1"
    local bump_inspection
    local bump_current
    local bump_next
    local bump_extra
    FIXTURE_BASE="$TEST_ROOT/$name"
    FIXTURE_REPOSITORY="$FIXTURE_BASE/work"
    FIXTURE_REMOTE="$FIXTURE_BASE/origin.git"
    FIXTURE_STATE="$FIXTURE_BASE/release-state"
    FAKE_GIT_LOG="$FIXTURE_BASE/git.log"
    FAKE_GH_LOG="$FIXTURE_BASE/gh.log"
    FAKE_GH_STATE="$FIXTURE_BASE/fake-gh"
    FAKE_GH_FAIL_UPLOAD_FILE="$FIXTURE_BASE/fail-upload-once"
    FAKE_GH_BAD_DIGEST_FILE="$FIXTURE_BASE/report-bad-digest"
    FAKE_GH_REPLACE_TAG_ON_EDIT_FILE="$FIXTURE_BASE/replace-tag-on-edit"
    FAKE_GH_REPOSITORY="$FIXTURE_REPOSITORY"

    mkdir -p -- "$FIXTURE_BASE" "$FIXTURE_REPOSITORY/src-tauri" "$FAKE_GH_STATE"
    : > "$FAKE_GIT_LOG"
    : > "$FAKE_GH_LOG"

    cat > "$FIXTURE_REPOSITORY/package.json" <<'EOF'
{
  "name": "pixiv-slides",
  "private": true,
  "version": "1.2.9"
}
EOF
    cat > "$FIXTURE_REPOSITORY/package-lock.json" <<'EOF'
{
  "name": "pixiv-slides",
  "version": "1.2.9",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "pixiv-slides",
      "version": "1.2.9"
    }
  }
}
EOF
    cat > "$FIXTURE_REPOSITORY/src-tauri/Cargo.toml" <<'EOF'
[package]
name = "app"
version = "1.2.9"
EOF
    cat > "$FIXTURE_REPOSITORY/src-tauri/Cargo.lock" <<'EOF'
version = 3

[[package]]
name = "app"
version = "1.2.9"
EOF
    cat > "$FIXTURE_REPOSITORY/src-tauri/tauri.conf.json" <<'EOF'
{
  "productName": "pixiv-slides",
  "version": "1.2.9",
  "identifier": "net.pixiv.slides"
}
EOF
    cat > "$FIXTURE_REPOSITORY/.gitignore" <<'EOF'
/builds/
.env*
EOF

    "$REAL_GIT" init --bare --initial-branch=main "$FIXTURE_REMOTE" >/dev/null
    "$REAL_GIT" init --initial-branch=main "$FIXTURE_REPOSITORY" >/dev/null
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" config user.name "Release Workflow Test"
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" config user.email "release-test@example.invalid"
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" add -- .
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" commit -m "test: seed release fixture" >/dev/null
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" remote add origin "$FIXTURE_REMOTE"
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" push --set-upstream origin main >/dev/null

    export FAKE_GIT_LOG FAKE_GH_LOG FAKE_GH_STATE FAKE_GH_FAIL_UPLOAD_FILE
    export FAKE_GH_BAD_DIGEST_FILE
    export FAKE_GH_REPLACE_TAG_ON_EDIT_FILE FAKE_GH_REPOSITORY
    export PIXIV_SLIDES_RELEASE_STATE="$FIXTURE_STATE"
    bump_inspection="$($NODE_BIN "$BUMP_VERSION" --inspect "$FIXTURE_REPOSITORY")"
    IFS=$'\t' read -r \
        bump_current \
        bump_next \
        PIXIV_SLIDES_RELEASE_BUMP_SHA256 \
        bump_extra <<< "$bump_inspection"
    assert_equal 1.2.9 "$bump_current" "planned bump current version"
    assert_equal 1.2.10 "$bump_next" "planned bump next version"
    [[ "$PIXIV_SLIDES_RELEASE_BUMP_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
        fail "planned bump fingerprint is invalid"
    [[ -z "${bump_extra:-}" ]] || fail "planned bump returned unexpected output"
    export PIXIV_SLIDES_RELEASE_BUMP_SHA256
}

assert_begin_stage() {
    local current="$1"
    local next="$2"
    local expected_version="$3"
    local expected_stage="$4"
    local result
    result="$($WORKFLOW begin "$FIXTURE_REPOSITORY" "$current" "$next")"
    assert_equal "$expected_version" "${result%%$'\t'*}" "release version at $expected_stage stage"
    assert_equal "$expected_stage" "${result#*$'\t'}" "release stage"
}

create_artifacts() {
    local version="$1"
    local release_commit="$2"
    local source_epoch
    local source_utc
    FIXTURE_ARTIFACTS="$FIXTURE_REPOSITORY/builds/$version/linux-x86_64"
    mkdir -p -- "$FIXTURE_ARTIFACTS"
    printf 'deb package for %s\n' "$version" \
        > "$FIXTURE_ARTIFACTS/pixiv-slides_${version}_amd64.deb"
    printf 'rpm package for %s\n' "$version" \
        > "$FIXTURE_ARTIFACTS/pixiv-slides-${version}-1.x86_64.rpm"
    printf 'AppImage package for %s\n' "$version" \
        > "$FIXTURE_ARTIFACTS/pixiv-slides_${version}_amd64.AppImage"
    (
        cd "$FIXTURE_ARTIFACTS"
        sha256sum \
            "pixiv-slides_${version}_amd64.deb" \
            "pixiv-slides-${version}-1.x86_64.rpm" \
            "pixiv-slides_${version}_amd64.AppImage" > SHA256SUMS
    )
    source_epoch="$($REAL_GIT -C "$FIXTURE_REPOSITORY" show -s --format=%ct "$release_commit")"
    source_utc="$(date --utc --date="@$source_epoch" +'%Y-%m-%dT%H:%M:%SZ')"
    cat > "$FIXTURE_ARTIFACTS/build-info.txt" <<EOF
format_version=1
product=pixiv-slides
version=$version
target_triple=x86_64-unknown-linux-gnu
target_arch=x86_64
bundle_formats=deb,rpm,appimage
source_commit=$release_commit
source_dirty=false
source_date_epoch=$source_epoch
builder_image=localhost/pixiv-slides-linux-builder:test
builder_image_id=0123456789abcdef
builder_os=Test Linux
rustc=rustc test
cargo=cargo test
node=v22.0.0
npm=10.0.0
tauri_cli=tauri-cli test
source_date_utc=$source_utc
EOF
}

prepare_release_through_build() {
    local bumped_version
    local release_commit
    local selected_commit
    local snapshot

    assert_begin_stage 1.2.9 1.2.10 1.2.10 ready
    bumped_version="$($NODE_BIN "$BUMP_VERSION" "$FIXTURE_REPOSITORY")"
    assert_equal 1.2.10 "$bumped_version" "bumped version"
    "$WORKFLOW" bumped "$FIXTURE_REPOSITORY" 1.2.10
    assert_begin_stage 1.2.10 1.2.11 1.2.10 bumped

    "$WORKFLOW" commit "$FIXTURE_REPOSITORY" 1.2.10 >/dev/null
    release_commit="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"
    assert_begin_stage 1.2.10 1.2.11 1.2.10 committed

    printf 'VITE_IGNORED_RELEASE_VALUE=must-not-be-packaged\n' > \
        "$FIXTURE_REPOSITORY/.env.production"
    selected_commit="$("$WORKFLOW" source-commit "$FIXTURE_REPOSITORY" 1.2.10)"
    assert_equal "$release_commit" "$selected_commit" "immutable release source commit"
    snapshot="$FIXTURE_BASE/source-snapshot"
    mkdir -p -- "$snapshot"
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" archive --format=tar "$selected_commit" |
        tar --extract --directory "$snapshot"
    [[ ! -e "$snapshot/.env.production" ]] ||
        fail "ignored environment file leaked into the committed release snapshot"
    rm -rf -- "$snapshot" "$FIXTURE_REPOSITORY/.env.production"

    create_artifacts 1.2.10 "$release_commit"
    "$WORKFLOW" built "$FIXTURE_REPOSITORY" 1.2.10 "$FIXTURE_ARTIFACTS"
    assert_begin_stage 1.2.10 1.2.11 1.2.10 built
}

assert_release_git_state() {
    local release_commit
    local remote_branch
    local remote_tag
    local remote_tag_object
    local local_tag_object
    local tag_type

    release_commit="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"
    tag_type="$($REAL_GIT -C "$FIXTURE_REPOSITORY" cat-file -t refs/tags/v1.2.10)"
    assert_equal tag "$tag_type" "release tag object type"
    assert_equal "$release_commit" \
        "$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-list -n 1 v1.2.10)" \
        "local release tag target"

    remote_branch="$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse refs/heads/main)"
    remote_tag="$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse 'refs/tags/v1.2.10^{}')"
    remote_tag_object="$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse refs/tags/v1.2.10)"
    local_tag_object="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse refs/tags/v1.2.10)"
    assert_equal "$release_commit" "$remote_branch" "remote main ref"
    assert_equal "$release_commit" "$remote_tag" "remote annotated tag target"
    assert_equal "$local_tag_object" "$remote_tag_object" "remote annotated tag object"

    local push_line
    push_line="$(grep -E ' push .*--atomic' "$FAKE_GIT_LOG")" ||
        fail "release did not issue an atomic Git push"
    [[ "$push_line" == *":refs/heads/main"* ]] ||
        fail "atomic push did not include the main branch ref"
    [[ "$push_line" == *":refs/tags/v1.2.10"* ]] ||
        fail "atomic push did not include the release tag ref"
}

assert_release_assets() {
    local asset
    local -a expected_assets=(
        SHA256SUMS
        build-info.txt
        pixiv-slides-1.2.10-1.x86_64.rpm
        pixiv-slides_1.2.10_amd64.AppImage
        pixiv-slides_1.2.10_amd64.deb
    )
    for asset in "${expected_assets[@]}"; do
        [[ -f "$FAKE_GH_STATE/assets/$asset" ]] ||
            fail "published release asset is missing: $asset"
        cmp -- "$FIXTURE_ARTIFACTS/$asset" "$FAKE_GH_STATE/assets/$asset" >/dev/null ||
            fail "published release asset differs from build output: $asset"
    done
    assert_equal "${#expected_assets[@]}" \
        "$(find "$FAKE_GH_STATE/assets" -maxdepth 1 -type f | wc -l)" \
        "published asset count"
}

assert_release_complete() {
    [[ ! -e "$FIXTURE_STATE" ]] || fail "completed release state was not removed"
    assert_equal published "$(cat "$FAKE_GH_STATE/release-status")" \
        "GitHub release status"
    assert_equal "" "$($REAL_GIT -C "$FIXTURE_REPOSITORY" status --porcelain=v1)" \
        "completed release worktree"
    assert_release_git_state
    assert_release_assets
}

test_happy_path() {
    create_fixture happy
    prepare_release_through_build
    "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10 >/dev/null

    assert_release_complete
    assert_equal 1 "$(grep -c $'^release\tcreate\t' "$FAKE_GH_LOG")" \
        "GitHub draft creation count"
    assert_equal 1 "$(grep -c $'^release\tupload\t' "$FAKE_GH_LOG")" \
        "GitHub asset upload count"
    assert_equal 1 "$(grep -c $'^release\tedit\t' "$FAKE_GH_LOG")" \
        "GitHub publication count"
    assert_command_fails "immediate version-only release" \
        "$WORKFLOW" begin "$FIXTURE_REPOSITORY" 1.2.10 1.2.11
}

test_non_version_content_in_bump_rejected() {
    local bumped_version

    create_fixture non-version-bump
    assert_begin_stage 1.2.9 1.2.10 1.2.10 ready
    bumped_version="$($NODE_BIN "$BUMP_VERSION" "$FIXTURE_REPOSITORY")"
    assert_equal 1.2.10 "$bumped_version" "bumped version before content tamper"
    "$NODE_BIN" -e '
      const fs = require("fs");
      const file = process.argv[1];
      const value = JSON.parse(fs.readFileSync(file, "utf8"));
      value.description = "unexpected release content";
      fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
    ' "$FIXTURE_REPOSITORY/package.json"

    assert_command_fails "non-version content inside bump files" \
        "$WORKFLOW" bumped "$FIXTURE_REPOSITORY" 1.2.10
    assert_contains "$FIXTURE_STATE" "stage=ready" "rejected bump state"
}

test_upload_failure_resume() {
    local release_commit
    local commit_count
    local resume_result

    create_fixture upload-resume
    prepare_release_through_build
    release_commit="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"
    commit_count="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-list --count HEAD)"
    : > "$FAKE_GH_FAIL_UPLOAD_FILE"

    assert_command_fails "GitHub upload failure" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    [[ -f "$FIXTURE_STATE" ]] || fail "failed upload removed resumable release state"
    assert_contains "$FIXTURE_STATE" "stage=draft" "failed upload state"
    assert_release_git_state

    local changed_args_hash
    changed_args_hash="$(printf '%s\0' '--bundles' 'deb' | sha256sum)"
    changed_args_hash="${changed_args_hash%% *}"
    assert_command_fails "changed release arguments" \
        env PIXIV_SLIDES_RELEASE_ARGS_SHA256="$changed_args_hash" \
        "$WORKFLOW" begin "$FIXTURE_REPOSITORY" 1.2.10 1.2.11

    resume_result="$($WORKFLOW begin "$FIXTURE_REPOSITORY" 1.2.10 1.2.11)"
    assert_equal $'1.2.10\tdraft' "$resume_result" \
        "release resume version and stage"
    "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10 >/dev/null

    assert_release_complete
    assert_equal "$release_commit" \
        "$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD)" \
        "release commit after resume"
    assert_equal "$commit_count" \
        "$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-list --count HEAD)" \
        "commit count after resume"
    assert_contains "$FIXTURE_REPOSITORY/package.json" '"version": "1.2.10"' \
        "version after upload resume"
    if "$REAL_GIT" -C "$FIXTURE_REPOSITORY" show-ref --verify --quiet refs/tags/v1.2.11; then
        fail "upload retry created a second release tag"
    fi
    assert_equal 1 "$(grep -c $'^release\tcreate\t' "$FAKE_GH_LOG")" \
        "draft creation count across retry"
    assert_equal 2 "$(grep -c $'^release\tupload\t' "$FAKE_GH_LOG")" \
        "upload attempt count across retry"
    assert_equal 1 "$(grep -c $'^release\tedit\t' "$FAKE_GH_LOG")" \
        "publication count across retry"
}

test_upstream_advance_rebuild() {
    local concurrent_clone
    local concurrent_commit
    local original_release_commit
    local rebased_release_commit
    local resume_result

    create_fixture upstream-advance
    prepare_release_through_build
    original_release_commit="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"

    concurrent_clone="$FIXTURE_BASE/concurrent"
    "$REAL_GIT" clone "$FIXTURE_REMOTE" "$concurrent_clone" >/dev/null
    "$REAL_GIT" -C "$concurrent_clone" config user.name "Concurrent Test"
    "$REAL_GIT" -C "$concurrent_clone" config user.email "concurrent@example.invalid"
    printf 'concurrent source change\n' > "$concurrent_clone/change.txt"
    "$REAL_GIT" -C "$concurrent_clone" add -- change.txt
    "$REAL_GIT" -C "$concurrent_clone" commit -m "test: concurrent source change" >/dev/null
    "$REAL_GIT" -C "$concurrent_clone" push origin main >/dev/null
    concurrent_commit="$($REAL_GIT -C "$concurrent_clone" rev-parse HEAD)"

    assert_command_fails "publication after upstream advance" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    assert_contains "$FIXTURE_STATE" "stage=tagged" "upstream-race release state"
    if "$REAL_GIT" --git-dir="$FIXTURE_REMOTE" show-ref --verify --quiet refs/tags/v1.2.10; then
        fail "failed atomic publication created a remote release tag"
    fi
    assert_equal "$concurrent_commit" \
        "$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse refs/heads/main)" \
        "remote branch after concurrent push"

    resume_result="$($WORKFLOW begin "$FIXTURE_REPOSITORY" 1.2.10 1.2.11)"
    assert_equal $'1.2.10\treplayed' "$resume_result" \
        "upstream-advance resume stage"
    rebased_release_commit="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"
    [[ "$rebased_release_commit" != "$original_release_commit" ]] ||
        fail "upstream advance did not recreate the release commit"
    assert_equal "$concurrent_commit" \
        "$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD^)" \
        "rebased release parent"
    if "$REAL_GIT" -C "$FIXTURE_REPOSITORY" show-ref --verify --quiet refs/tags/v1.2.10; then
        fail "stale local release tag survived the upstream replay"
    fi

    resume_result="$($WORKFLOW begin "$FIXTURE_REPOSITORY" 1.2.10 1.2.11)"
    assert_equal $'1.2.10\tcommitted' "$resume_result" \
        "post-replay restart stage"

    create_artifacts 1.2.10 "$rebased_release_commit"
    "$WORKFLOW" built "$FIXTURE_REPOSITORY" 1.2.10 "$FIXTURE_ARTIFACTS"
    "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10 >/dev/null
    assert_release_complete
}

test_artifact_tamper_rejected() {
    local remote_before
    create_fixture artifact-tamper
    prepare_release_through_build
    remote_before="$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse refs/heads/main)"

    printf 'tampered after validation\n' >> \
        "$FIXTURE_ARTIFACTS/pixiv-slides_1.2.10_amd64.deb"
    (
        cd "$FIXTURE_ARTIFACTS"
        sha256sum \
            pixiv-slides_1.2.10_amd64.deb \
            pixiv-slides-1.2.10-1.x86_64.rpm \
            pixiv-slides_1.2.10_amd64.AppImage > SHA256SUMS
    )
    assert_command_fails "post-validation artifact replacement" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    assert_contains "$FIXTURE_STATE" "stage=built" "artifact-tamper state"
    assert_equal "$remote_before" \
        "$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse refs/heads/main)" \
        "remote branch after artifact tamper"
    if "$REAL_GIT" --git-dir="$FIXTURE_REMOTE" show-ref --verify --quiet refs/tags/v1.2.10; then
        fail "artifact tamper published a remote release tag"
    fi
}

test_bad_remote_digest_stays_draft() {
    local edit_count
    create_fixture bad-remote-digest
    prepare_release_through_build
    : > "$FAKE_GH_BAD_DIGEST_FILE"

    assert_command_fails "wrong GitHub asset digest" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    assert_contains "$FIXTURE_STATE" "stage=uploaded" "bad-digest state"
    assert_equal draft "$(cat "$FAKE_GH_STATE/release-status")" \
        "release status after bad remote digest"
    edit_count="$(grep -c $'^release\tedit\t' "$FAKE_GH_LOG" || true)"
    assert_equal 0 "$edit_count" "publication count before digest verification"

    rm -- "$FAKE_GH_BAD_DIGEST_FILE"
    printf 'corrupted remote draft asset\n' > \
        "$FAKE_GH_STATE/assets/pixiv-slides_1.2.10_amd64.deb"
    "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10 >/dev/null
    assert_release_complete
    assert_equal 2 "$(grep -c $'^release\tupload\t' "$FAKE_GH_LOG")" \
        "upload count across uploaded-stage resume"
}

test_local_head_move_rejected() {
    local remote_before
    create_fixture local-head-move
    prepare_release_through_build
    remote_before="$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse refs/heads/main)"
    printf 'unexpected local commit\n' > "$FIXTURE_REPOSITORY/unexpected.txt"
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" add -- unexpected.txt
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" commit -m "test: unexpected local commit" >/dev/null

    assert_command_fails "local HEAD movement before publication" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    assert_equal "$remote_before" \
        "$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse refs/heads/main)" \
        "remote branch after local HEAD movement"
    if "$REAL_GIT" --git-dir="$FIXTURE_REMOTE" show-ref --verify --quiet refs/tags/v1.2.10; then
        fail "local HEAD movement published a release tag"
    fi
}

test_replaced_annotated_tag_rejected() {
    local original_tag_object
    local replacement_tag_object
    local release_commit

    create_fixture replaced-tag
    prepare_release_through_build
    : > "$FAKE_GH_FAIL_UPLOAD_FILE"
    assert_command_fails "initial upload failure for tag replacement test" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    assert_contains "$FIXTURE_STATE" "stage=draft" "tag-replacement resumable state"

    release_commit="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"
    original_tag_object="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse refs/tags/v1.2.10)"
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" tag --force --annotate v1.2.10 \
        --message "Replacement v1.2.10" "$release_commit" >/dev/null
    replacement_tag_object="$($REAL_GIT -C "$FIXTURE_REPOSITORY" rev-parse refs/tags/v1.2.10)"
    [[ "$replacement_tag_object" != "$original_tag_object" ]] ||
        fail "replacement annotated tag unexpectedly reused the original object"
    "$REAL_GIT" -C "$FIXTURE_REPOSITORY" push --force origin refs/tags/v1.2.10 >/dev/null
    assert_equal "$release_commit" \
        "$($REAL_GIT --git-dir="$FIXTURE_REMOTE" rev-parse 'refs/tags/v1.2.10^{}')" \
        "replacement annotated tag target"

    assert_command_fails "force-replaced annotated tag object" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    assert_contains "$FIXTURE_STATE" "stage=draft" "replaced-tag release state"
}

test_tag_race_during_publication_is_redrafted() {
    create_fixture publication-tag-race
    prepare_release_through_build
    : > "$FAKE_GH_REPLACE_TAG_ON_EDIT_FILE"

    assert_command_fails "tag replacement during GitHub publication" \
        "$WORKFLOW" publish "$FIXTURE_REPOSITORY" 1.2.10
    assert_contains "$FIXTURE_STATE" "stage=uploaded" "publication-race release state"
    assert_equal draft "$(cat "$FAKE_GH_STATE/release-status")" \
        "release status after publication tag race"
    assert_equal 2 "$(grep -c $'^release\tedit\t' "$FAKE_GH_LOG")" \
        "publish and emergency redraft count"
}

test_non_version_content_in_bump_rejected
test_happy_path
test_upload_failure_resume
test_upstream_advance_rebuild
test_artifact_tamper_rejected
test_bad_remote_digest_stays_draft
test_local_head_move_rejected
test_replaced_annotated_tag_rejected
test_tag_race_during_publication_is_redrafted
echo "release-workflow integration tests passed"
