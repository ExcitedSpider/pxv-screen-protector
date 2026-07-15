#!/usr/bin/env bash
#
# Git and GitHub publication state machine for ./dev.sh release.
#
# The controlled build driver owns version inspection/bumping and packaging.
# This helper owns the source commit, annotated tag, atomic push, and GitHub
# draft/upload/publish sequence. Its ignored state file makes every step
# resumable without incrementing the version a second time.
#
set -euo pipefail

readonly VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly COMMIT_PATTERN='^[0-9a-f]{40,64}$'
readonly REPOSITORY_PATTERN='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
readonly -a VERSION_FILES=(
    package-lock.json
    package.json
    src-tauri/Cargo.lock
    src-tauri/Cargo.toml
    src-tauri/tauri.conf.json
)

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  release-workflow.sh begin ROOT CURRENT_VERSION NEXT_VERSION
  release-workflow.sh bumped ROOT VERSION
  release-workflow.sh commit ROOT VERSION
  release-workflow.sh source-commit ROOT VERSION
  release-workflow.sh built ROOT VERSION ARTIFACT_DIR
  release-workflow.sh publish ROOT VERSION
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

git_run() {
    "$GIT_BIN" -C "$ROOT" "$@"
}

gh_run() {
    GH_PROMPT_DISABLED=1 GH_HOST="$GITHUB_HOST" "$GH_BIN" "$@"
}

require_version() {
    [[ "$1" =~ $VERSION_PATTERN ]] || die "invalid release version: $1"
}

require_repository() {
    [[ "$1" =~ $REPOSITORY_PATTERN ]] || die "invalid GitHub repository name: $1"
}

state_load() {
    [[ -f "$STATE_FILE" ]] || die "release state not found: $STATE_FILE"

    STATE_STAGE=""
    STATE_BASE_VERSION=""
    STATE_VERSION=""
    STATE_TAG=""
    STATE_BRANCH_REF=""
    STATE_MERGE_REF=""
    STATE_REMOTE=""
    STATE_REPOSITORY=""
    STATE_ARGS_SHA256=""
    STATE_BUMP_SHA256=""
    STATE_BASE_COMMIT=""
    STATE_RELEASE_COMMIT=""
    STATE_TAG_OBJECT=""
    STATE_ARTIFACT_DIR=""
    STATE_ARTIFACT_SET_SHA256=""

    local key
    local value
    declare -A seen=()
    while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
        [[ -n "$key" ]] || die "release state contains an empty key"
        [[ -z "${seen[$key]:-}" ]] || die "release state contains duplicate key: $key"
        seen[$key]=1
        case "$key" in
            stage) STATE_STAGE="$value" ;;
            base_version) STATE_BASE_VERSION="$value" ;;
            version) STATE_VERSION="$value" ;;
            tag) STATE_TAG="$value" ;;
            branch_ref) STATE_BRANCH_REF="$value" ;;
            merge_ref) STATE_MERGE_REF="$value" ;;
            remote) STATE_REMOTE="$value" ;;
            repository) STATE_REPOSITORY="$value" ;;
            args_sha256) STATE_ARGS_SHA256="$value" ;;
            bump_sha256) STATE_BUMP_SHA256="$value" ;;
            base_commit) STATE_BASE_COMMIT="$value" ;;
            release_commit) STATE_RELEASE_COMMIT="$value" ;;
            tag_object) STATE_TAG_OBJECT="$value" ;;
            artifact_dir) STATE_ARTIFACT_DIR="$value" ;;
            artifact_set_sha256) STATE_ARTIFACT_SET_SHA256="$value" ;;
            *) die "release state contains unknown key: $key" ;;
        esac
    done < "$STATE_FILE"

    case "$STATE_STAGE" in
        ready|bumped|committed|built|tagged|pushed|draft|uploaded) ;;
        *) die "release state has an invalid stage: $STATE_STAGE" ;;
    esac
    require_version "$STATE_BASE_VERSION"
    require_version "$STATE_VERSION"
    [[ "$STATE_TAG" == "v$STATE_VERSION" ]] || die "release state tag does not match its version"
    [[ "$STATE_BRANCH_REF" == refs/heads/* ]] || die "release state has an invalid branch ref"
    [[ "$STATE_MERGE_REF" == refs/heads/* ]] || die "release state has an invalid upstream ref"
    [[ "$STATE_REMOTE" =~ ^[A-Za-z0-9._-]+$ ]] || die "release state has an invalid remote name"
    require_repository "$STATE_REPOSITORY"
    [[ "$STATE_ARGS_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
        die "release state has an invalid build-argument fingerprint"
    [[ "$STATE_ARGS_SHA256" == "$RELEASE_ARGS_SHA256" ]] ||
        die "release build arguments differ from the pending release; rerun the same ./dev.sh release command"
    [[ "$STATE_BUMP_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
        die "release state has an invalid deterministic bump fingerprint"
    [[ "$STATE_BASE_COMMIT" =~ $COMMIT_PATTERN ]] || die "release state has an invalid base commit"
    if [[ -n "$STATE_RELEASE_COMMIT" ]]; then
        [[ "$STATE_RELEASE_COMMIT" =~ $COMMIT_PATTERN ]] ||
            die "release state has an invalid release commit"
    fi
    if [[ -n "$STATE_TAG_OBJECT" ]]; then
        [[ "$STATE_TAG_OBJECT" =~ $COMMIT_PATTERN ]] ||
            die "release state has an invalid tag object"
    fi
    if [[ -n "$STATE_ARTIFACT_DIR" ]]; then
        [[ "$STATE_ARTIFACT_DIR" =~ ^builds/$STATE_VERSION/linux-[A-Za-z0-9_-]+$ ]] ||
            die "release state has an invalid artifact directory"
    fi
    if [[ -n "$STATE_ARTIFACT_SET_SHA256" ]]; then
        [[ "$STATE_ARTIFACT_SET_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
            die "release state has an invalid artifact-set fingerprint"
    fi
    case "$STATE_STAGE" in
        tagged|pushed|draft|uploaded)
            [[ -n "$STATE_TAG_OBJECT" ]] ||
                die "release state stage $STATE_STAGE is missing its annotated tag object"
            ;;
        *)
            [[ -z "$STATE_TAG_OBJECT" ]] ||
                die "release state contains a tag object before the tagged stage"
            ;;
    esac
    case "$STATE_STAGE" in
        built|tagged|pushed|draft|uploaded)
            [[ -n "$STATE_ARTIFACT_DIR" && -n "$STATE_ARTIFACT_SET_SHA256" ]] ||
                die "release state stage $STATE_STAGE is missing validated artifact identity"
            ;;
        *)
            [[ -z "$STATE_ARTIFACT_DIR" && -z "$STATE_ARTIFACT_SET_SHA256" ]] ||
                die "release state contains artifacts before the build stage"
            ;;
    esac
}

state_write() {
    local state_dir
    local temp_file
    local previous_umask
    state_dir="$(dirname -- "$STATE_FILE")"
    mkdir -p -- "$state_dir"
    previous_umask="$(umask)"
    umask 077
    temp_file="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || {
        umask "$previous_umask"
        die "could not create temporary release state"
    }
    umask "$previous_umask"
    if ! {
        printf 'stage=%s\n' "$STATE_STAGE"
        printf 'base_version=%s\n' "$STATE_BASE_VERSION"
        printf 'version=%s\n' "$STATE_VERSION"
        printf 'tag=%s\n' "$STATE_TAG"
        printf 'branch_ref=%s\n' "$STATE_BRANCH_REF"
        printf 'merge_ref=%s\n' "$STATE_MERGE_REF"
        printf 'remote=%s\n' "$STATE_REMOTE"
        printf 'repository=%s\n' "$STATE_REPOSITORY"
        printf 'args_sha256=%s\n' "$STATE_ARGS_SHA256"
        printf 'bump_sha256=%s\n' "$STATE_BUMP_SHA256"
        printf 'base_commit=%s\n' "$STATE_BASE_COMMIT"
        printf 'release_commit=%s\n' "$STATE_RELEASE_COMMIT"
        printf 'tag_object=%s\n' "$STATE_TAG_OBJECT"
        printf 'artifact_dir=%s\n' "$STATE_ARTIFACT_DIR"
        printf 'artifact_set_sha256=%s\n' "$STATE_ARTIFACT_SET_SHA256"
    } > "$temp_file"; then
        rm -f -- "$temp_file"
        die "could not write release state"
    fi
    mv -- "$temp_file" "$STATE_FILE"
}

require_clean_worktree() {
    local status
    status="$(git_run status --porcelain=v1 --untracked-files=all)"
    [[ -z "$status" ]] ||
        die "release requires a clean worktree; commit or stash all tracked and untracked changes"
}

require_exact_paths() {
    local description="$1"
    shift
    local -a actual=("$@")
    local index

    ((${#actual[@]} == ${#VERSION_FILES[@]})) ||
        die "$description must contain exactly the five application version files"
    for index in "${!VERSION_FILES[@]}"; do
        [[ "${actual[$index]}" == "${VERSION_FILES[$index]}" ]] ||
            die "$description contains an unexpected path: ${actual[$index]}"
    done
}

version_files_fingerprint() {
    local commit="${1:-}"
    local aggregate
    aggregate="$({
        local path
        local checksum_output
        local digest
        for path in "${VERSION_FILES[@]}"; do
            if [[ -n "$commit" ]]; then
                checksum_output="$(git_run show "$commit:$path" | sha256sum)" || exit 1
            else
                checksum_output="$(sha256sum -- "$ROOT/$path")" || exit 1
            fi
            digest="${checksum_output%% *}"
            [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 1
            printf '%s\0%s\0' "$path" "$digest"
        done
    } | sha256sum)" || die "could not fingerprint the application version files"
    aggregate="${aggregate%% *}"
    [[ "$aggregate" =~ ^[0-9a-f]{64}$ ]] ||
        die "sha256sum returned an invalid version-file fingerprint"
    printf '%s\n' "$aggregate"
}

require_expected_bump_worktree() {
    [[ "$(version_files_fingerprint)" == "$STATE_BUMP_SHA256" ]] ||
        die "application version files do not match the deterministic patch-only bump"
}

require_bump_changes() {
    local -a changed=()
    local untracked
    mapfile -t changed < <(git_run diff HEAD --name-only --)
    require_exact_paths "version bump" "${changed[@]}"
    require_expected_bump_worktree
    untracked="$(git_run ls-files --others --exclude-standard)"
    [[ -z "$untracked" ]] || die "untracked files appeared while preparing the release"
}

verify_release_commit() {
    local commit="$1"
    local expected_parent="$2"
    local parent
    local subject
    local -a changed=()

    [[ "$commit" =~ $COMMIT_PATTERN ]] || die "invalid release commit: $commit"
    parent="$(git_run rev-parse "$commit^")" || die "release commit has no parent"
    [[ "$parent" == "$expected_parent" ]] || die "release commit is not based on the recorded source commit"
    subject="$(git_run show -s --format=%s "$commit")"
    [[ "$subject" == "chore: release $STATE_TAG" ]] ||
        die "release commit has an unexpected subject: $subject"
    mapfile -t changed < <(git_run diff-tree --no-commit-id --name-only -r "$commit")
    require_exact_paths "release commit" "${changed[@]}"
    [[ "$(version_files_fingerprint "$commit")" == "$STATE_BUMP_SHA256" ]] ||
        die "release commit does not contain the deterministic patch-only version bump"
}

require_local_release_source() {
    local branch_ref
    local head
    branch_ref="$(git_run symbolic-ref --quiet HEAD)" || die "release source is on a detached HEAD"
    [[ "$branch_ref" == "$STATE_BRANCH_REF" ]] ||
        die "checked-out branch moved away from pending release branch $STATE_BRANCH_REF"
    head="$(git_run rev-parse --verify HEAD)"
    [[ "$head" == "$STATE_RELEASE_COMMIT" ]] ||
        die "HEAD moved away from pending release commit $STATE_RELEASE_COMMIT"
    require_clean_worktree
    verify_release_commit "$head" "$STATE_BASE_COMMIT"
}

github_repository_from_url() {
    local url="${1%.git}"
    local repository=""
    case "$url" in
        git@github.com:*) repository="${url#git@github.com:}" ;;
        https://github.com/*) repository="${url#https://github.com/}" ;;
        ssh://git@github.com/*) repository="${url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    require_repository "$repository"
    printf '%s\n' "$repository"
}

release_status() {
    local repository="$1"
    local tag="$2"
    local owner="${repository%%/*}"
    local name="${repository#*/}"
    local status
    status="$(gh_run api graphql \
        -f 'query=query($owner:String!,$name:String!,$tag:String!){repository(owner:$owner,name:$name){release(tagName:$tag){isDraft}}}' \
        -F "owner=$owner" \
        -F "name=$name" \
        -F "tag=$tag" \
        --jq '.data.repository.release | if . == null then "missing" elif .isDraft then "draft" else "published" end')" ||
        die "could not query GitHub release $tag"
    case "$status" in
        missing|draft|published) printf '%s\n' "$status" ;;
        *) die "GitHub returned an invalid release status for $tag" ;;
    esac
}

require_github_access() {
    local repository="$1"
    local can_push
    gh_run auth status --hostname "$GITHUB_HOST" >/dev/null ||
        die "GitHub CLI authentication is required; run: gh auth login -h $GITHUB_HOST"
    can_push="$(gh_run api "repos/$repository" --jq '.permissions.push')" ||
        die "could not verify GitHub repository permissions for $repository"
    [[ "$can_push" == "true" ]] || die "GitHub account does not have push access to $repository"
}

remote_branch_and_tag() {
    REMOTE_BRANCH_COMMIT=""
    REMOTE_TAG_OBJECT=""
    REMOTE_TAG_COMMIT=""
    local refs
    local sha
    local ref
    refs="$(git_run ls-remote "$VALIDATED_REMOTE_URL" \
        "$STATE_MERGE_REF" \
        "refs/tags/$STATE_TAG" \
        "refs/tags/$STATE_TAG^{}")" ||
        die "could not inspect release refs on remote $STATE_REMOTE"
    while IFS=$'\t' read -r sha ref; do
        case "$ref" in
            "$STATE_MERGE_REF") REMOTE_BRANCH_COMMIT="$sha" ;;
            "refs/tags/$STATE_TAG") REMOTE_TAG_OBJECT="$sha" ;;
            "refs/tags/$STATE_TAG^{}") REMOTE_TAG_COMMIT="$sha" ;;
        esac
    done <<< "$refs"
}

set_validated_remote_url() {
    local remote="$1"
    local fetch_output
    local push_output
    local -a fetch_urls=()
    local -a push_urls=()
    fetch_output="$(git_run remote get-url --all "$remote")" ||
        die "could not read fetch URLs for remote $remote"
    push_output="$(git_run remote get-url --push --all "$remote")" ||
        die "could not read push URLs for remote $remote"
    mapfile -t fetch_urls <<< "$fetch_output"
    mapfile -t push_urls <<< "$push_output"
    ((${#fetch_urls[@]} == 1 && ${#push_urls[@]} == 1)) ||
        die "release requires exactly one fetch URL and one push URL for remote $remote"
    [[ -n "${fetch_urls[0]}" && "${fetch_urls[0]}" == "${push_urls[0]}" ]] ||
        die "release requires matching fetch and push URLs for remote $remote"
    VALIDATED_REMOTE_URL="${push_urls[0]}"
}

remote_branch_contains_release() {
    [[ -n "$REMOTE_BRANCH_COMMIT" && -n "$STATE_RELEASE_COMMIT" ]] || return 1
    git_run cat-file -e "$REMOTE_BRANCH_COMMIT^{commit}" 2>/dev/null || return 1
    git_run merge-base --is-ancestor "$STATE_RELEASE_COMMIT" "$REMOTE_BRANCH_COMMIT"
}

remote_release_refs_match() (
    git_run fetch --quiet --no-tags "$STATE_REMOTE" "$STATE_MERGE_REF" || exit 1
    remote_branch_and_tag
    [[ "$REMOTE_TAG_OBJECT" == "$STATE_TAG_OBJECT" ]] || exit 1
    [[ "$REMOTE_TAG_COMMIT" == "$STATE_RELEASE_COMMIT" ]] || exit 1
    remote_branch_contains_release
)

require_remote_release_refs() {
    local context="$1"
    remote_release_refs_match ||
        die "remote release refs changed $context; the GitHub release was not published"
}

redraft_if_remote_refs_changed() {
    remote_release_refs_match && return 0
    echo "error: remote release refs changed during GitHub publication" >&2
    if gh_run release edit "$STATE_TAG" \
        --repo "$STATE_REPOSITORY" \
        --draft=true; then
        echo "The GitHub release was returned to draft state." >&2
    else
        echo "URGENT: could not return the GitHub release to draft state." >&2
    fi
    die "release tag and branch must be restored before resuming"
}

rebase_pending_release() {
    [[ -n "$STATE_RELEASE_COMMIT" ]] || die "cannot rebase a release without its commit"
    [[ -n "$REMOTE_BRANCH_COMMIT" ]] || die "upstream branch disappeared during release"
    [[ -z "$REMOTE_TAG_OBJECT" && -z "$REMOTE_TAG_COMMIT" ]] ||
        die "release tag appeared remotely before the release could be rebased"
    git_run merge-base --is-ancestor "$STATE_BASE_COMMIT" "$REMOTE_BRANCH_COMMIT" ||
        die "upstream branch diverged from the recorded release base"

    local diff_status=0
    git_run diff --quiet "$STATE_BASE_COMMIT" "$REMOTE_BRANCH_COMMIT" -- "${VERSION_FILES[@]}" ||
        diff_status=$?
    case "$diff_status" in
        0) ;;
        1)
            die "upstream changed application version files during the release; resolve the pending release manually"
            ;;
        *) die "could not compare the updated upstream with the release base" ;;
    esac

    local old_commit="$STATE_RELEASE_COMMIT"
    if ! git_run rebase --onto "$REMOTE_BRANCH_COMMIT" "$STATE_BASE_COMMIT"; then
        git_run rebase --abort >/dev/null 2>&1 || true
        die "could not replay the unpushed release commit on the updated upstream"
    fi
    [[ "$(git_run symbolic-ref --quiet HEAD)" == "$STATE_BRANCH_REF" ]] ||
        die "release replay detached HEAD instead of updating $STATE_BRANCH_REF"
    local new_commit
    new_commit="$(git_run rev-parse --verify HEAD)"
    verify_release_commit "$new_commit" "$REMOTE_BRANCH_COMMIT"
    require_clean_worktree
    if git_run show-ref --verify --quiet "refs/tags/$STATE_TAG"; then
        [[ "$(git_run rev-list -n 1 "$STATE_TAG")" == "$old_commit" ]] ||
            die "local release tag changed while rebasing the pending release"
        git_run tag --delete "$STATE_TAG" >/dev/null
    fi
    STATE_BASE_COMMIT="$REMOTE_BRANCH_COMMIT"
    STATE_RELEASE_COMMIT="$new_commit"
    STATE_TAG_OBJECT=""
    STATE_ARTIFACT_DIR=""
    STATE_ARTIFACT_SET_SHA256=""
    STATE_STAGE="committed"
    state_write
    echo "Upstream advanced; replayed $STATE_TAG as $new_commit. Its bundles will be rebuilt." >&2
    STATE_STAGE="replayed"
}

recover_completed_replay() {
    local head="$1"
    REPLAY_RECOVERED="false"
    case "$STATE_STAGE" in
        committed|built|tagged) ;;
        *) return 0 ;;
    esac
    [[ "$head" != "$STATE_RELEASE_COMMIT" ]] || return 0
    [[ "$CURRENT_VERSION" == "$STATE_VERSION" ]] ||
        die "project version no longer matches pending release $STATE_TAG"
    require_clean_worktree
    [[ -z "$REMOTE_TAG_OBJECT" && -z "$REMOTE_TAG_COMMIT" ]] ||
        die "remote release tag appeared while recovering an upstream replay"

    local new_parent
    new_parent="$(git_run rev-parse "$head^")" || die "replayed release commit has no parent"
    git_run merge-base --is-ancestor "$STATE_BASE_COMMIT" "$new_parent" ||
        die "HEAD moved to an unrelated commit during the pending release"
    git_run merge-base --is-ancestor "$new_parent" "$REMOTE_BRANCH_COMMIT" ||
        die "replayed release commit is not based on the current upstream history"
    local diff_status=0
    git_run diff --quiet "$STATE_BASE_COMMIT" "$new_parent" -- "${VERSION_FILES[@]}" ||
        diff_status=$?
    case "$diff_status" in
        0) ;;
        1) die "upstream changed version files during replay recovery" ;;
        *) die "could not validate replayed release history" ;;
    esac
    verify_release_commit "$head" "$new_parent"
    if git_run show-ref --verify --quiet "refs/tags/$STATE_TAG"; then
        [[ "$(git_run rev-list -n 1 "$STATE_TAG")" == "$STATE_RELEASE_COMMIT" ]] ||
            die "local release tag changed during replay recovery"
        git_run tag --delete "$STATE_TAG" >/dev/null
    fi
    STATE_BASE_COMMIT="$new_parent"
    STATE_RELEASE_COMMIT="$head"
    STATE_TAG_OBJECT=""
    STATE_ARTIFACT_DIR=""
    STATE_ARTIFACT_SET_SHA256=""
    STATE_STAGE="committed"
    state_write
    STATE_STAGE="replayed"
    REPLAY_RECOVERED="true"
    echo "Recovered the replayed release commit $head; restart release to rebuild with current tooling." >&2
}

validate_repository_identity() {
    local parsed_repository=""
    set_validated_remote_url "$STATE_REMOTE"
    if parsed_repository="$(github_repository_from_url "$VALIDATED_REMOTE_URL" 2>/dev/null)"; then
        [[ "${parsed_repository,,}" == "${STATE_REPOSITORY,,}" ]] ||
            die "remote $STATE_REMOTE points to $parsed_repository, not $STATE_REPOSITORY"
    elif [[ -z "$REPOSITORY_OVERRIDE" ]]; then
        die "remote $STATE_REMOTE is not a supported GitHub URL"
    fi
}

validate_resume_environment() {
    local branch_ref
    local head
    branch_ref="$(git_run symbolic-ref --quiet HEAD)" || die "release cannot resume from a detached HEAD"
    [[ "$branch_ref" == "$STATE_BRANCH_REF" ]] ||
        die "release state belongs to $STATE_BRANCH_REF, not $branch_ref"
    git_run check-ref-format "$STATE_BRANCH_REF" >/dev/null || die "release state branch ref is invalid"
    git_run check-ref-format "$STATE_MERGE_REF" >/dev/null || die "release state upstream ref is invalid"
    validate_repository_identity
    require_github_access "$STATE_REPOSITORY"
    git_run fetch --quiet --prune --tags "$STATE_REMOTE" ||
        die "could not refresh remote $STATE_REMOTE"

    head="$(git_run rev-parse --verify HEAD)"
    remote_branch_and_tag
    recover_completed_replay "$head"
    if [[ "$REPLAY_RECOVERED" == "true" ]]; then
        return
    fi
    case "$STATE_STAGE" in
        ready)
            if [[ "$CURRENT_VERSION" == "$STATE_BASE_VERSION" && "$head" == "$STATE_BASE_COMMIT" ]]; then
                require_clean_worktree
            elif [[ "$CURRENT_VERSION" == "$STATE_VERSION" && "$head" == "$STATE_BASE_COMMIT" ]]; then
                require_bump_changes
                STATE_STAGE="bumped"
                state_write
                echo "Recovered the completed version bump for $STATE_TAG." >&2
            else
                die "worktree no longer matches the pending release preparation"
            fi
            ;;
        bumped)
            if [[ "$head" == "$STATE_BASE_COMMIT" ]]; then
                [[ "$CURRENT_VERSION" == "$STATE_VERSION" ]] ||
                    die "project version no longer matches pending release $STATE_TAG"
                require_bump_changes
            else
                [[ "$CURRENT_VERSION" == "$STATE_VERSION" ]] ||
                    die "project version no longer matches pending release $STATE_TAG"
                require_clean_worktree
                verify_release_commit "$head" "$STATE_BASE_COMMIT"
                STATE_RELEASE_COMMIT="$head"
                STATE_STAGE="committed"
                state_write
                echo "Recovered release commit $head for $STATE_TAG." >&2
            fi
            ;;
        committed|built|tagged|pushed|draft|uploaded)
            [[ -n "$STATE_RELEASE_COMMIT" ]] || die "release state is missing its release commit"
            [[ "$CURRENT_VERSION" == "$STATE_VERSION" ]] ||
                die "project version no longer matches pending release $STATE_TAG"
            [[ "$head" == "$STATE_RELEASE_COMMIT" ]] ||
                die "HEAD moved away from pending release commit $STATE_RELEASE_COMMIT"
            require_clean_worktree
            verify_release_commit "$head" "$STATE_BASE_COMMIT"
            ;;
    esac

    case "$STATE_STAGE" in
        ready|bumped)
            [[ -z "$REMOTE_TAG_OBJECT" && -z "$REMOTE_TAG_COMMIT" ]] ||
                die "remote tag $STATE_TAG appeared while preparing the release"
            ;;
        committed|built|tagged)
            if [[ -n "$REMOTE_TAG_OBJECT" || -n "$REMOTE_TAG_COMMIT" ]]; then
                if [[ "$STATE_STAGE" == "tagged" && \
                      "$REMOTE_TAG_OBJECT" == "$STATE_TAG_OBJECT" && \
                      "$REMOTE_TAG_COMMIT" == "$STATE_RELEASE_COMMIT" ]] &&
                    remote_branch_contains_release; then
                    STATE_STAGE="pushed"
                    state_write
                    echo "Recovered the atomic push for $STATE_TAG." >&2
                else
                    die "remote tag $STATE_TAG is not in the expected pending-release state"
                fi
            elif [[ "$REMOTE_BRANCH_COMMIT" != "$STATE_BASE_COMMIT" ]]; then
                rebase_pending_release
            fi
            ;;
        pushed|draft|uploaded)
            [[ "$REMOTE_TAG_OBJECT" == "$STATE_TAG_OBJECT" ]] ||
                die "remote annotated tag object no longer matches the release state"
            [[ "$REMOTE_TAG_COMMIT" == "$STATE_RELEASE_COMMIT" ]] ||
                die "remote tag $STATE_TAG no longer points to the release commit"
            remote_branch_contains_release ||
                die "remote branch no longer contains the release commit"
            ;;
    esac
}

begin_release() {
    CURRENT_VERSION="$1"
    local next_version="$2"
    require_version "$CURRENT_VERSION"
    require_version "$next_version"

    if [[ -f "$STATE_FILE" ]]; then
        state_load
        validate_resume_environment
        printf '%s\t%s\n' "$STATE_VERSION" "$STATE_STAGE"
        return
    fi

    require_clean_worktree
    git_run var GIT_AUTHOR_IDENT >/dev/null || die "Git author identity is not configured"
    git_run var GIT_COMMITTER_IDENT >/dev/null || die "Git committer identity is not configured"

    local branch_ref
    local branch
    local configured_remote
    local remote
    local merge_ref
    local base_commit
    local upstream_commit
    local parsed_repository=""
    local repository
    branch_ref="$(git_run symbolic-ref --quiet HEAD)" || die "release requires a checked-out branch, not detached HEAD"
    branch="${branch_ref#refs/heads/}"
    configured_remote="$(git_run config --get "branch.$branch.remote")" ||
        die "branch $branch has no configured upstream remote"
    merge_ref="$(git_run config --get "branch.$branch.merge")" ||
        die "branch $branch has no configured upstream branch"
    remote="${REMOTE_OVERRIDE:-$configured_remote}"
    [[ "$remote" == "$configured_remote" ]] ||
        die "release remote $remote does not match branch upstream remote $configured_remote"
    [[ "$remote" != "." ]] || die "a local-dot upstream cannot be used for a GitHub release"
    [[ "$remote" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release remote name: $remote"
    git_run check-ref-format "$branch_ref" >/dev/null || die "invalid current branch ref"
    git_run check-ref-format "$merge_ref" >/dev/null || die "invalid upstream branch ref"

    set_validated_remote_url "$remote"
    if parsed_repository="$(github_repository_from_url "$VALIDATED_REMOTE_URL" 2>/dev/null)"; then
        repository="${REPOSITORY_OVERRIDE:-$parsed_repository}"
        [[ "${repository,,}" == "${parsed_repository,,}" ]] ||
            die "configured GitHub repository $repository does not match remote $parsed_repository"
    else
        repository="$REPOSITORY_OVERRIDE"
        [[ -n "$repository" ]] || die "remote $remote is not a supported GitHub URL"
    fi
    require_repository "$repository"
    require_github_access "$repository"

    git_run fetch --quiet --prune --tags "$remote" || die "could not refresh remote $remote"
    base_commit="$(git_run rev-parse --verify HEAD)"
    upstream_commit="$(git_run rev-parse --verify '@{upstream}')" ||
        die "could not resolve the current branch upstream"
    [[ "$base_commit" == "$upstream_commit" ]] ||
        die "release requires HEAD to exactly match its fetched upstream branch"

    local current_tag="v$CURRENT_VERSION"
    local current_tag_commit
    if git_run show-ref --verify --quiet "refs/tags/$current_tag"; then
        current_tag_commit="$(git_run rev-list -n 1 "$current_tag")"
        if [[ "$current_tag_commit" == "$base_commit" ]]; then
            die "HEAD is already released as $current_tag; commit a change before creating another patch release"
        fi
        git_run merge-base --is-ancestor "$current_tag_commit" "$base_commit" ||
            die "current version tag $current_tag is not an ancestor of HEAD"
    fi

    local tag="v$next_version"
    if git_run show-ref --verify --quiet "refs/tags/$tag"; then
        die "release tag already exists: $tag"
    fi
    [[ "$(release_status "$repository" "$tag")" == "missing" ]] ||
        die "GitHub release already exists: $tag"

    STATE_STAGE="ready"
    STATE_BASE_VERSION="$CURRENT_VERSION"
    STATE_VERSION="$next_version"
    STATE_TAG="$tag"
    STATE_BRANCH_REF="$branch_ref"
    STATE_MERGE_REF="$merge_ref"
    STATE_REMOTE="$remote"
    STATE_REPOSITORY="$repository"
    STATE_ARGS_SHA256="$RELEASE_ARGS_SHA256"
    [[ "$RELEASE_BUMP_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
        die "release driver did not provide a valid deterministic bump fingerprint"
    STATE_BUMP_SHA256="$RELEASE_BUMP_SHA256"
    STATE_BASE_COMMIT="$base_commit"
    STATE_RELEASE_COMMIT=""
    STATE_TAG_OBJECT=""
    STATE_ARTIFACT_DIR=""
    STATE_ARTIFACT_SET_SHA256=""
    state_write
    echo "Release preflight passed for $tag on $repository." >&2
    printf '%s\t%s\n' "$STATE_VERSION" "$STATE_STAGE"
}

mark_bumped() {
    local version="$1"
    state_load
    [[ "$STATE_STAGE" == "ready" ]] || die "cannot record a version bump from stage $STATE_STAGE"
    [[ "$version" == "$STATE_VERSION" ]] || die "bumped version does not match release state"
    require_bump_changes
    STATE_STAGE="bumped"
    state_write
}

commit_release() {
    local version="$1"
    state_load
    [[ "$STATE_STAGE" == "bumped" ]] || die "cannot create a release commit from stage $STATE_STAGE"
    [[ "$version" == "$STATE_VERSION" ]] || die "commit version does not match release state"
    [[ "$(git_run rev-parse --verify HEAD)" == "$STATE_BASE_COMMIT" ]] ||
        die "HEAD moved before the release commit was created"
    require_bump_changes

    git_run add -- "${VERSION_FILES[@]}"
    local -a staged=()
    mapfile -t staged < <(git_run diff --cached --name-only --)
    require_exact_paths "release index" "${staged[@]}"
    if ! git_run commit --only -m "chore: release $STATE_TAG" -- "${VERSION_FILES[@]}"; then
        die "could not create the release commit; fix the hook or Git error, then rerun ./dev.sh release"
    fi

    local commit
    commit="$(git_run rev-parse --verify HEAD)"
    verify_release_commit "$commit" "$STATE_BASE_COMMIT"
    require_clean_worktree
    STATE_RELEASE_COMMIT="$commit"
    STATE_STAGE="committed"
    state_write
    echo "Created release commit $commit for $STATE_TAG."
}

print_release_source_commit() {
    local version="$1"
    state_load
    [[ "$STATE_STAGE" == "committed" ]] ||
        die "cannot export release source from stage $STATE_STAGE"
    [[ "$version" == "$STATE_VERSION" ]] || die "source version does not match release state"
    [[ -n "$STATE_RELEASE_COMMIT" ]] || die "release source commit is missing from state"
    require_local_release_source
    printf '%s\n' "$STATE_RELEASE_COMMIT"
}

collect_release_assets() {
    local artifact_dir="$1"
    local checksum_file="$artifact_dir/SHA256SUMS"
    local metadata_file="$artifact_dir/build-info.txt"
    [[ -s "$checksum_file" ]] || die "release artifact checksum file is missing"
    [[ -s "$metadata_file" ]] || die "release build metadata is missing"
    (
        cd "$artifact_dir"
        sha256sum --check SHA256SUMS >/dev/null
    ) || die "release artifact checksums do not verify"

    RELEASE_ASSETS=()
    RELEASE_BUNDLE_FORMATS=()
    local hash
    local filename
    local extra
    local bundle_format
    declare -A seen=()
    declare -A seen_formats=()
    while read -r hash filename extra; do
        [[ -z "$extra" ]] || die "invalid checksum entry in $checksum_file"
        filename="${filename#\*}"
        [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 value in $checksum_file"
        [[ "$filename" == "$(basename -- "$filename")" ]] ||
            die "checksum entry escapes the artifact directory: $filename"
        [[ "$filename" =~ ^[A-Za-z0-9._+-]+$ ]] ||
            die "checksum entry has an unsafe artifact name: $filename"
        case "$filename" in
            *.deb) bundle_format="deb" ;;
            *.rpm) bundle_format="rpm" ;;
            *.AppImage) bundle_format="appimage" ;;
            *) die "unsupported GitHub release asset in checksum manifest: $filename" ;;
        esac
        [[ -z "${seen[$filename]:-}" ]] || die "duplicate artifact in checksum manifest: $filename"
        [[ -z "${seen_formats[$bundle_format]:-}" ]] ||
            die "checksum manifest contains more than one $bundle_format package"
        seen[$filename]=1
        seen_formats[$bundle_format]=1
        [[ -f "$artifact_dir/$filename" ]] || die "release artifact is missing: $filename"
        RELEASE_ASSETS+=("$artifact_dir/$filename")
        RELEASE_BUNDLE_FORMATS+=("$bundle_format")
    done < "$checksum_file"
    ((${#RELEASE_ASSETS[@]} > 0)) || die "checksum manifest contains no release packages"
    RELEASE_ASSETS+=("$checksum_file" "$metadata_file")
}

release_asset_set_fingerprint() {
    local aggregate
    aggregate="$({
        local asset
        local checksum_output
        local digest
        local name
        local size
        for asset in "${RELEASE_ASSETS[@]}"; do
            name="$(basename -- "$asset")"
            size="$(stat --format=%s -- "$asset")" || exit 1
            checksum_output="$(sha256sum -- "$asset")" || exit 1
            digest="${checksum_output%% *}"
            printf '%s\0%s\0%s\0' "$name" "$size" "$digest"
        done
    } | sha256sum)" || die "could not fingerprint the validated release assets"
    aggregate="${aggregate%% *}"
    [[ "$aggregate" =~ ^[0-9a-f]{64}$ ]] || die "invalid release asset-set fingerprint"
    printf '%s\n' "$aggregate"
}

require_pinned_release_assets() {
    [[ "$(release_asset_set_fingerprint)" == "$STATE_ARTIFACT_SET_SHA256" ]] ||
        die "release artifacts changed after they were validated"
}

validate_artifact_directory() {
    local version="$1"
    local requested_dir="$2"
    local real_dir
    local expected_prefix="$ROOT/builds/$version/"
    real_dir="$(realpath -e -- "$requested_dir")" || die "release artifact directory does not exist: $requested_dir"
    [[ -d "$real_dir" && "$real_dir" == "$expected_prefix"linux-* ]] ||
        die "release artifacts must be under builds/$version/linux-<arch>"
    [[ "$(basename -- "$real_dir")" =~ ^linux-[A-Za-z0-9_-]+$ ]] ||
        die "release artifact architecture directory is invalid"
    collect_release_assets "$real_dir"

    local metadata_file="$real_dir/build-info.txt"
    local key
    local value
    local expected_epoch
    local expected_utc
    local expected_formats
    local expected_arch="${real_dir##*/linux-}"
    local -a required_metadata=(
        format_version product version target_triple target_arch bundle_formats
        source_commit source_dirty source_date_epoch builder_image builder_image_id
        builder_os rustc cargo node npm tauri_cli source_date_utc
    )
    declare -A metadata=()
    while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
        case "$key" in
            format_version|product|version|target_triple|target_arch|bundle_formats|\
            source_commit|source_dirty|source_date_epoch|builder_image|builder_image_id|\
            builder_os|rustc|cargo|node|npm|tauri_cli|source_date_utc)
                ;;
            *) die "build metadata contains an unknown or malformed key: $key" ;;
        esac
        [[ -z "${metadata[$key]+present}" ]] ||
            die "build metadata contains duplicate key: $key"
        metadata[$key]="$value"
    done < "$metadata_file"
    for key in "${required_metadata[@]}"; do
        [[ -n "${metadata[$key]+present}" ]] || die "build metadata is missing key: $key"
    done
    ((${#metadata[@]} == ${#required_metadata[@]})) ||
        die "build metadata contains an unexpected number of fields"

    expected_epoch="$(git_run show -s --format=%ct "$STATE_RELEASE_COMMIT")" ||
        die "could not determine the release commit timestamp"
    [[ "$expected_epoch" =~ ^[0-9]+$ ]] || die "release commit has an invalid timestamp"
    expected_utc="$(date --utc --date="@$expected_epoch" +'%Y-%m-%dT%H:%M:%SZ')" ||
        die "could not format the release commit timestamp"
    expected_formats="$(IFS=,; echo "${RELEASE_BUNDLE_FORMATS[*]}")"

    [[ "${metadata[format_version]}" == "1" ]] || die "unsupported build metadata format"
    [[ "${metadata[product]}" == "pixiv-slides" ]] || die "build metadata identifies the wrong product"
    [[ "${metadata[version]}" == "$version" ]] || die "build metadata version does not match release $version"
    [[ "${metadata[target_triple]}" == "x86_64-unknown-linux-gnu" ]] ||
        die "build metadata identifies an unsupported target triple"
    [[ "${metadata[target_arch]}" == "$expected_arch" ]] ||
        die "build metadata architecture does not match its artifact directory"
    [[ "${metadata[bundle_formats]}" == "$expected_formats" ]] ||
        die "build metadata bundle formats do not match the checksum manifest"
    [[ "${metadata[source_commit]}" == "$STATE_RELEASE_COMMIT" ]] ||
        die "build metadata does not identify release commit $STATE_RELEASE_COMMIT"
    [[ "${metadata[source_dirty]}" == "false" ]] ||
        die "release bundles were not built from a clean worktree"
    [[ "${metadata[source_date_epoch]}" == "$expected_epoch" ]] ||
        die "build metadata timestamp does not match the release commit"
    [[ "${metadata[source_date_utc]}" == "$expected_utc" ]] ||
        die "build metadata UTC date does not match the release commit"
    for key in builder_image builder_image_id builder_os rustc cargo node npm tauri_cli; do
        [[ -n "${metadata[$key]}" && "${metadata[$key]}" != "unknown" ]] ||
            die "build metadata field $key is missing or unknown"
    done
    VALIDATED_ARTIFACT_DIR="$real_dir"
}

mark_built() {
    local version="$1"
    local artifact_dir="$2"
    state_load
    [[ "$STATE_STAGE" == "committed" ]] || die "cannot record release artifacts from stage $STATE_STAGE"
    [[ "$version" == "$STATE_VERSION" ]] || die "artifact version does not match release state"
    require_local_release_source
    validate_artifact_directory "$version" "$artifact_dir"
    STATE_ARTIFACT_DIR="${VALIDATED_ARTIFACT_DIR#"$ROOT"/}"
    STATE_ARTIFACT_SET_SHA256="$(release_asset_set_fingerprint)"
    STATE_STAGE="built"
    state_write
}

require_local_release_tag() {
    if git_run show-ref --verify --quiet "refs/tags/$STATE_TAG"; then
        [[ "$(git_run cat-file -t "refs/tags/$STATE_TAG")" == "tag" ]] ||
            die "local release tag is not annotated: $STATE_TAG"
        [[ "$(git_run rev-list -n 1 "$STATE_TAG")" == "$STATE_RELEASE_COMMIT" ]] ||
            die "local release tag points to an unexpected commit: $STATE_TAG"
    else
        git_run tag -a "$STATE_TAG" -m "Release $STATE_TAG" "$STATE_RELEASE_COMMIT"
    fi
    LOCAL_TAG_OBJECT="$(git_run rev-parse --verify "refs/tags/$STATE_TAG")"
    [[ "$LOCAL_TAG_OBJECT" =~ $COMMIT_PATTERN ]] ||
        die "Git returned an invalid annotated tag object"
    if [[ -n "$STATE_TAG_OBJECT" ]]; then
        [[ "$LOCAL_TAG_OBJECT" == "$STATE_TAG_OBJECT" ]] ||
            die "local annotated tag object no longer matches the release state"
    fi
}

verify_published_assets() {
    local remote_assets
    local asset
    local name
    local size
    local digest
    local extra
    local checksum_output
    local expected_count=0
    local actual_count=0
    declare -A expected_sizes=()
    declare -A expected_digests=()
    declare -A actual_names=()

    for asset in "${RELEASE_ASSETS[@]}"; do
        name="$(basename -- "$asset")"
        size="$(stat --format=%s -- "$asset")" || die "could not determine release asset size: $name"
        checksum_output="$(sha256sum -- "$asset")" || die "could not hash release asset: $name"
        digest="${checksum_output%% *}"
        expected_sizes[$name]="$size"
        expected_digests[$name]="sha256:$digest"
        ((expected_count += 1))
    done

    remote_assets="$(gh_run release view "$STATE_TAG" \
        --repo "$STATE_REPOSITORY" \
        --json assets \
        --jq '.assets[] | [.name, (.size | tostring), (.digest // "")] | @tsv')" ||
        die "could not inspect assets for GitHub release $STATE_TAG"
    while IFS=$'\t' read -r name size digest extra; do
        if [[ -z "$name$size$digest$extra" ]]; then
            continue
        fi
        [[ -z "$extra" && "$name" =~ ^[A-Za-z0-9._+-]+$ && "$size" =~ ^[0-9]+$ ]] ||
            die "GitHub release returned malformed asset metadata"
        [[ -z "${actual_names[$name]:-}" ]] ||
            die "GitHub release contains duplicate asset: $name"
        [[ -n "${expected_sizes[$name]+present}" ]] ||
            die "GitHub release contains unexpected asset: $name"
        [[ "$size" == "${expected_sizes[$name]}" ]] ||
            die "GitHub release asset has the wrong size: $name"
        [[ "$digest" == "${expected_digests[$name]}" ]] ||
            die "GitHub release asset has the wrong SHA-256 digest: $name"
        actual_names[$name]=1
        ((actual_count += 1))
    done <<< "$remote_assets"
    ((actual_count == expected_count)) ||
        die "GitHub release has a missing or unexpected asset set"
}

publish_release() {
    local version="$1"
    state_load
    [[ "$version" == "$STATE_VERSION" ]] || die "publish version does not match release state"
    case "$STATE_STAGE" in
        built|tagged|pushed|draft|uploaded) ;;
        *) die "cannot publish a release from stage $STATE_STAGE" ;;
    esac
    [[ -n "$STATE_RELEASE_COMMIT" ]] || die "release commit is missing from release state"
    [[ -n "$STATE_ARTIFACT_DIR" ]] || die "artifact directory is missing from release state"
    [[ -n "$STATE_ARTIFACT_SET_SHA256" ]] || die "artifact-set fingerprint is missing from release state"
    require_local_release_source
    validate_artifact_directory "$version" "$ROOT/$STATE_ARTIFACT_DIR"
    require_pinned_release_assets
    validate_repository_identity
    require_github_access "$STATE_REPOSITORY"

    require_local_release_tag
    if [[ "$STATE_STAGE" == "built" ]]; then
        STATE_TAG_OBJECT="$LOCAL_TAG_OBJECT"
        STATE_STAGE="tagged"
        state_write
    fi

    if [[ "$STATE_STAGE" == "tagged" ]]; then
        git_run fetch --quiet --prune --tags "$STATE_REMOTE" ||
            die "could not refresh remote refs before publishing $STATE_TAG"
        remote_branch_and_tag
        if [[ "$REMOTE_BRANCH_COMMIT" == "$STATE_BASE_COMMIT" && \
              -z "$REMOTE_TAG_OBJECT" && -z "$REMOTE_TAG_COMMIT" ]]; then
            require_local_release_source
            require_local_release_tag
            [[ "$(git_run cat-file -t "$STATE_TAG_OBJECT")" == "tag" ]] ||
                die "release tag object is not annotated"
            git_run push --atomic "$VALIDATED_REMOTE_URL" \
                "$STATE_RELEASE_COMMIT:$STATE_MERGE_REF" \
                "$STATE_TAG_OBJECT:refs/tags/$STATE_TAG"
        elif [[ "$REMOTE_TAG_OBJECT" == "$STATE_TAG_OBJECT" && \
                "$REMOTE_TAG_COMMIT" == "$STATE_RELEASE_COMMIT" ]] &&
                remote_branch_contains_release; then
            echo "Remote branch and tag were already published; resuming $STATE_TAG." >&2
        else
            die "upstream changed before atomic publication; rerun ./dev.sh release to replay and rebuild it"
        fi
        remote_branch_and_tag
        [[ "$REMOTE_TAG_OBJECT" == "$STATE_TAG_OBJECT" ]] ||
            die "remote annotated tag object does not match the release state"
        [[ "$REMOTE_TAG_COMMIT" == "$STATE_RELEASE_COMMIT" ]] ||
            die "remote tag did not resolve to the release commit"
        remote_branch_contains_release ||
            die "remote branch does not contain the release commit"
        STATE_STAGE="pushed"
        state_write
    fi

    if [[ "$STATE_STAGE" == "pushed" || \
          "$STATE_STAGE" == "draft" || \
          "$STATE_STAGE" == "uploaded" ]]; then
        git_run fetch --quiet --prune --tags "$STATE_REMOTE" ||
            die "could not refresh published release refs"
        remote_branch_and_tag
        [[ "$REMOTE_TAG_OBJECT" == "$STATE_TAG_OBJECT" ]] ||
            die "remote annotated tag object no longer matches the release state"
        [[ "$REMOTE_TAG_COMMIT" == "$STATE_RELEASE_COMMIT" ]] ||
            die "remote tag no longer points to the release commit"
        remote_branch_contains_release ||
            die "remote branch no longer contains the release commit"
    fi

    local github_status
    github_status="$(release_status "$STATE_REPOSITORY" "$STATE_TAG")"
    if [[ "$github_status" == "published" ]]; then
        redraft_if_remote_refs_changed
        verify_published_assets
        require_pinned_release_assets
        redraft_if_remote_refs_changed
        rm -- "$STATE_FILE"
        echo "GitHub release $STATE_TAG was already published with the expected assets."
        return
    fi

    if [[ "$github_status" == "missing" ]]; then
        gh_run release create "$STATE_TAG" \
            --repo "$STATE_REPOSITORY" \
            --verify-tag \
            --draft \
            --generate-notes \
            --fail-on-no-commits
        github_status="$(release_status "$STATE_REPOSITORY" "$STATE_TAG")"
        [[ "$github_status" == "draft" ]] || die "GitHub did not create a draft release for $STATE_TAG"
        STATE_STAGE="draft"
        state_write
    fi
    STATE_STAGE="draft"
    state_write
    require_pinned_release_assets
    gh_run release upload "$STATE_TAG" \
        "${RELEASE_ASSETS[@]}" \
        --repo "$STATE_REPOSITORY" \
        --clobber
    STATE_STAGE="uploaded"
    state_write
    require_pinned_release_assets
    verify_published_assets
    require_pinned_release_assets
    require_remote_release_refs "immediately before GitHub publication"

    gh_run release edit "$STATE_TAG" \
        --repo "$STATE_REPOSITORY" \
        --verify-tag \
        --draft=false
    [[ "$(release_status "$STATE_REPOSITORY" "$STATE_TAG")" == "published" ]] ||
        die "GitHub release did not become public: $STATE_TAG"
    redraft_if_remote_refs_changed
    verify_published_assets
    require_pinned_release_assets
    redraft_if_remote_refs_changed
    local release_url
    release_url="$(gh_run release view "$STATE_TAG" \
        --repo "$STATE_REPOSITORY" \
        --json url \
        --jq '.url')"
    rm -- "$STATE_FILE"
    echo "Published GitHub release $STATE_TAG: $release_url"
}

command_name="${1:-}"
if (($# > 0)); then
    shift
fi
case "$command_name" in
    begin)
        (($# == 3)) || { usage >&2; exit 2; }
        ROOT="$(cd -- "$1" && pwd -P)"
        CURRENT_VERSION="$2"
        NEXT_VERSION="$3"
        ;;
    bumped|commit|source-commit|publish)
        (($# == 2)) || { usage >&2; exit 2; }
        ROOT="$(cd -- "$1" && pwd -P)"
        VERSION="$2"
        ;;
    built)
        (($# == 3)) || { usage >&2; exit 2; }
        ROOT="$(cd -- "$1" && pwd -P)"
        VERSION="$2"
        ARTIFACT_DIR="$3"
        ;;
    help|-h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

GIT_BIN="${PIXIV_SLIDES_GIT_BIN:-git}"
GH_BIN="${PIXIV_SLIDES_GH_BIN:-gh}"
REMOTE_OVERRIDE="${PIXIV_SLIDES_RELEASE_REMOTE:-}"
REPOSITORY_OVERRIDE="${PIXIV_SLIDES_GITHUB_REPOSITORY:-}"
GITHUB_HOST="github.com"
STATE_FILE="${PIXIV_SLIDES_RELEASE_STATE:-$ROOT/builds/.release-state}"
RELEASE_ARGS_SHA256="${PIXIV_SLIDES_RELEASE_ARGS_SHA256:-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855}"
RELEASE_BUMP_SHA256="${PIXIV_SLIDES_RELEASE_BUMP_SHA256:-}"
[[ "$RELEASE_ARGS_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid release build-argument fingerprint"
if [[ -n "$RELEASE_BUMP_SHA256" ]]; then
    [[ "$RELEASE_BUMP_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
        die "invalid deterministic bump fingerprint"
fi
require_command "$GIT_BIN"
require_command "$GH_BIN"
require_command realpath
require_command sha256sum
require_command date
require_command stat
[[ "$(git_run rev-parse --show-toplevel)" == "$ROOT" ]] ||
    die "release root is not the Git worktree top level: $ROOT"

case "$command_name" in
    begin) begin_release "$CURRENT_VERSION" "$NEXT_VERSION" ;;
    bumped)
        require_version "$VERSION"
        mark_bumped "$VERSION"
        ;;
    commit)
        require_version "$VERSION"
        commit_release "$VERSION"
        ;;
    source-commit)
        require_version "$VERSION"
        print_release_source_commit "$VERSION"
        ;;
    built)
        require_version "$VERSION"
        mark_built "$VERSION" "$ARTIFACT_DIR"
        ;;
    publish)
        require_version "$VERSION"
        publish_release "$VERSION"
        ;;
esac
