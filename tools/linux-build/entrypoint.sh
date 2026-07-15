#!/usr/bin/env bash
# Build and validate the Linux packages in an ephemeral workspace.
set -Eeuo pipefail

readonly SOURCE_DIR=/source
readonly WORKSPACE_DIR=/workspace
readonly OUTPUT_DIR=/output
readonly CARGO_CACHE_DIR=/cache/cargo
readonly TARGET_CACHE_DIR=/cache/target
readonly NPM_CACHE_DIR=/cache/npm
readonly TAURI_CACHE_DIR=/cache/tauri
readonly PINNED_TAURI_TOOLS_DIR=${PIXIV_SLIDES_TAURI_TOOLS_DIR:-/usr/local/share/pixiv-slides/tauri-tools}

die() {
  echo "linux-build: $*" >&2
  exit 1
}

require_directory() {
  local path=$1
  local description=$2
  [[ -d "$path" ]] || die "$description is not mounted at $path"
}

contains_value() {
  local wanted=$1
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$wanted" ]] && return 0
  done
  return 1
}

append_bundle_values() {
  local value=$1
  local item
  local -a split_values=()
  IFS=',' read -r -a split_values <<< "$value"
  for item in "${split_values[@]}"; do
    case "$item" in
      deb|rpm|appimage)
        if ! contains_value "$item" "${requested_bundles[@]}"; then
          requested_bundles+=("$item")
        fi
        ;;
      '')
        ;;
      *)
        die "unsupported Linux bundle '$item'"
        ;;
    esac
  done
}

parse_build_arguments() {
  local index=0
  local collecting_bundles=0
  local collecting_features=0
  local arg

  while (( index < ${#build_args[@]} )); do
    arg=${build_args[index]}
    case "$arg" in
      --no-bundle)
        die "--no-bundle is incompatible with the packaging build"
        ;;
      -d|--debug)
        die "$arg is incompatible with the controlled release build; use ./dev.sh build-host for debug packaging"
        ;;
      -c|--config)
        die "$arg cannot override the controlled build configuration; use ./dev.sh build-host for custom configurations"
        ;;
      -c?*|--config=*)
        die "--config cannot override the controlled build configuration; use ./dev.sh build-host for custom configurations"
        ;;
      -r|--runner)
        die "$arg cannot override the controlled Cargo runner"
        ;;
      -r?*|--runner=*)
        die "--runner cannot override the controlled Cargo runner"
        ;;
      -h|--help|-V|--version)
        die "$arg does not produce packages; use ./dev.sh help or ./dev.sh build-host $arg"
        ;;
      -b|--bundles)
        explicit_bundles=1
        collecting_bundles=1
        collecting_features=0
        ;;
      --bundles=*)
        explicit_bundles=1
        collecting_bundles=0
        collecting_features=0
        append_bundle_values "${arg#*=}"
        ;;
      -b=*)
        explicit_bundles=1
        collecting_bundles=0
        collecting_features=0
        append_bundle_values "${arg#*=}"
        ;;
      -b?*)
        explicit_bundles=1
        collecting_bundles=0
        collecting_features=0
        append_bundle_values "${arg#-b}"
        ;;
      -f|--features)
        collecting_bundles=0
        collecting_features=1
        ;;
      --features=*|-f=*|-f?*)
        collecting_bundles=0
        collecting_features=0
        ;;
      --target=*)
        target_triple=${arg#*=}
        collecting_bundles=0
        collecting_features=0
        ;;
      -t=*)
        target_triple=${arg#*=}
        collecting_bundles=0
        collecting_features=0
        ;;
      -t|--target)
        collecting_bundles=0
        collecting_features=0
        (( index + 1 < ${#build_args[@]} )) || die "$arg requires a target triple"
        ((index += 1))
        target_triple=${build_args[index]}
        ;;
      -t?*)
        target_triple=${arg#-t}
        collecting_bundles=0
        collecting_features=0
        ;;
      -v|--verbose|-vv*|--ci|--skip-stapling|--ignore-version-mismatches|--no-sign)
        collecting_bundles=0
        collecting_features=0
        ;;
      --)
        die "custom Cargo runner arguments are not supported by the controlled build"
        ;;
      -*)
        collecting_bundles=0
        collecting_features=0
        ;;
      *)
        if (( collecting_bundles )); then
          append_bundle_values "$arg"
        elif (( collecting_features )); then
          :
        else
          die "custom Cargo runner arguments are not supported by the controlled build: $arg"
        fi
        ;;
    esac
    ((index += 1))
  done

  if (( explicit_bundles )); then
    ((${#requested_bundles[@]} > 0)) || die "--bundles requires at least one bundle format"
  else
    requested_bundles=(deb rpm appimage)
  fi

  [[ "$target_triple" == x86_64-unknown-linux-gnu ]] || \
    die "the controlled builder supports only x86_64-unknown-linux-gnu (requested $target_triple)"
}

inject_locked_runner_argument() {
  local saw_delimiter=0
  local arg
  locked_build_args=()

  for arg in "${build_args[@]}"; do
    if (( ! saw_delimiter )) && [[ "$arg" == -- ]]; then
      locked_build_args+=(-- --locked)
      saw_delimiter=1
    else
      locked_build_args+=("$arg")
    fi
  done

  if (( ! saw_delimiter )); then
    locked_build_args+=(-- --locked)
  fi
}

clear_stale_bundles() {
  local bundle_dir
  while IFS= read -r -d '' bundle_dir; do
    rm -rf -- "$bundle_dir"
  done < <(find "$TARGET_CACHE_DIR" -type d -name bundle -print0)
}

seed_tauri_tools() {
  local tool
  local -a tools=(
    AppRun-x86_64
    linuxdeploy-x86_64.AppImage
    linuxdeploy-plugin-gtk.sh
    linuxdeploy-plugin-gstreamer.sh
    linuxdeploy-plugin-appimage.AppImage
  )

  [[ -s "$PINNED_TAURI_TOOLS_DIR/SHA256SUMS" ]] || \
    die "pinned Tauri AppImage tools are missing from the builder image"
  for tool in "${tools[@]}"; do
    install -m 0755 "$PINNED_TAURI_TOOLS_DIR/$tool" "$TAURI_CACHE_DIR/$tool"
  done
  (
    cd "$TAURI_CACHE_DIR"
    sha256sum --check "$PINNED_TAURI_TOOLS_DIR/SHA256SUMS" >/dev/null
  ) || die "pinned Tauri AppImage tool verification failed"
}

find_one_bundle() {
  local format=$1
  local extension=$2
  local -a matches=()

  mapfile -d '' matches < <(
    find "$TARGET_CACHE_DIR" \
      -type f \
      -path "*/bundle/$format/*.$extension" \
      -print0
  )

  ((${#matches[@]} == 1)) || \
    die "expected one $format package, found ${#matches[@]}"
  printf '%s\n' "${matches[0]}"
}

copy_and_validate_deb() {
  local contents
  local entry
  local license_found=false
  local license_path="usr/lib/$product_name/LICENSE"
  local source_file
  local output_file
  source_file=$(find_one_bundle deb deb)
  output_file="$OUTPUT_DIR/$(basename "$source_file")"
  cp -- "$source_file" "$output_file"
  dpkg-deb --info "$output_file" >/dev/null
  contents=$(dpkg-deb --contents "$output_file")
  while IFS= read -r entry; do
    entry=${entry##* }
    if [[ "$entry" == "$license_path" || "$entry" == "./$license_path" ]]; then
      license_found=true
      break
    fi
  done <<<"$contents"
  [[ "$license_found" == true ]] || die "Debian package is missing $license_path"
  artifact_names+=("$(basename "$output_file")")
}

copy_and_validate_rpm() {
  local contents
  local license
  local license_path="/usr/lib/$product_name/LICENSE"
  local source_file
  local output_file
  source_file=$(find_one_bundle rpm rpm)
  output_file="$OUTPUT_DIR/$(basename "$source_file")"
  cp -- "$source_file" "$output_file"
  rpm --query --package --info "$output_file" >/dev/null
  license=$(rpm --query --package --queryformat '%{LICENSE}' "$output_file")
  [[ "$license" == MIT ]] || \
    die "RPM package license is '$license', expected 'MIT'"
  contents=$(rpm --query --package --list "$output_file")
  grep -Fx "$license_path" <<<"$contents" >/dev/null || \
    die "RPM package is missing $license_path"
  artifact_names+=("$(basename "$output_file")")
}

copy_and_validate_appimage() {
  local source_file
  local output_file
  local validation_dir=/tmp/pixiv-slides-appimage-validation
  source_file=$(find_one_bundle appimage AppImage)
  output_file="$OUTPUT_DIR/$(basename "$source_file")"
  cp -- "$source_file" "$output_file"
  chmod 0755 "$output_file"
  file "$output_file" | grep -Eq 'ELF .* executable' || \
    die "AppImage is not an ELF executable: $(basename "$output_file")"
  rm -rf -- "$validation_dir"
  mkdir -p "$validation_dir"
  (
    cd "$validation_dir"
    "$output_file" --appimage-extract >/dev/null
    [[ -x squashfs-root/AppRun ]] || exit 1
    [[ -L squashfs-root/.DirIcon ]] || exit 1
    [[ -f "squashfs-root/usr/lib/$product_name/LICENSE" ]] || exit 1
    local link
    local link_target
    while IFS= read -r -d '' link; do
      link_target=$(readlink "$link")
      if [[ "$link_target" == /* || ! -e "$link" ]]; then
        echo "linux-build: invalid AppImage symlink: $link -> $link_target" >&2
        exit 1
      fi
    done < <(find squashfs-root -maxdepth 1 -type l -print0)
  ) || die "AppImage extraction validation failed: $(basename "$output_file")"
  rm -rf -- "$validation_dir"
  artifact_names+=("$(basename "$output_file")")
}

write_metadata() {
  local bundle_list
  local built_at
  local os_description
  bundle_list=$(IFS=,; echo "${requested_bundles[*]}")
  os_description=$(. /etc/os-release; echo "$PRETTY_NAME")

  if [[ -n ${SOURCE_DATE_EPOCH:-} ]]; then
    built_at=$(date --utc --date="@${SOURCE_DATE_EPOCH}" +'%Y-%m-%dT%H:%M:%SZ')
  else
    built_at=$(date --utc +'%Y-%m-%dT%H:%M:%SZ')
  fi

  {
    printf 'format_version=1\n'
    printf 'product=%s\n' "$product_name"
    printf 'version=%s\n' "$app_version"
    printf 'target_triple=%s\n' "$target_triple"
    printf 'target_arch=%s\n' "$target_arch"
    printf 'bundle_formats=%s\n' "$bundle_list"
    printf 'source_commit=%s\n' "${PIXIV_SLIDES_BUILD_COMMIT:-unknown}"
    printf 'source_dirty=%s\n' "${PIXIV_SLIDES_BUILD_DIRTY:-unknown}"
    printf 'source_date_epoch=%s\n' "${SOURCE_DATE_EPOCH:-unknown}"
    printf 'builder_image=%s\n' "${PIXIV_SLIDES_BUILD_IMAGE:-unknown}"
    printf 'builder_image_id=%s\n' "${PIXIV_SLIDES_BUILD_IMAGE_ID:-unknown}"
    printf 'builder_os=%s\n' "$os_description"
    printf 'rustc=%s\n' "$(rustc --version)"
    printf 'cargo=%s\n' "$(cargo --version)"
    printf 'node=%s\n' "$(node --version)"
    printf 'npm=%s\n' "$(npm --version)"
    printf 'tauri_cli=%s\n' "$(cargo tauri --version)"
    printf 'source_date_utc=%s\n' "$built_at"
  } > "$OUTPUT_DIR/build-info.txt"

  printf '%s\n' "$app_version" > "$OUTPUT_DIR/.version"
  printf '%s\n' "$target_arch" > "$OUTPUT_DIR/.arch"
}

command_mode=${1:-}
case "$command_mode" in
  build|validate)
    ;;
  *)
    die "usage: pixiv-slides-linux-build {build|validate} [TAURI_BUILD_ARGS...]"
    ;;
esac
shift

declare -a build_args=("$@")
declare -a locked_build_args=()
declare -a requested_bundles=()
declare -a artifact_names=()
explicit_bundles=0
target_triple=$(rustc -vV | grep '^host:' | cut -d ' ' -f 2)

parse_build_arguments
inject_locked_runner_argument
target_arch=${target_triple%%-*}

if [[ "$command_mode" == validate ]]; then
  if ! cargo tauri build "${build_args[@]}" --help >/dev/null; then
    die "Tauri rejected the controlled build arguments"
  fi
  echo "linux-build: build arguments are valid (${requested_bundles[*]}) for $target_triple"
  exit 0
fi

require_directory "$SOURCE_DIR" "source tree"
require_directory "$OUTPUT_DIR" "output directory"
require_directory "$CARGO_CACHE_DIR/registry" "Cargo registry cache"
require_directory "$CARGO_CACHE_DIR/git" "Cargo git cache"
require_directory "$TARGET_CACHE_DIR" "Cargo target cache"
require_directory "$NPM_CACHE_DIR" "npm cache"
require_directory "$TAURI_CACHE_DIR" "Tauri tools cache"
[[ -r "$SOURCE_DIR/package-lock.json" ]] || die "package-lock.json is required"
[[ -r "$SOURCE_DIR/src-tauri/Cargo.lock" ]] || die "src-tauri/Cargo.lock is required"
[[ -r "$SOURCE_DIR/src-tauri/tauri.container.conf.json" ]] || \
  die "src-tauri/tauri.container.conf.json is required"
if [[ -n $(find "$OUTPUT_DIR" -mindepth 1 -print -quit) ]]; then
  die "output directory must be empty: $OUTPUT_DIR"
fi

export CARGO_HOME=$CARGO_CACHE_DIR
export CARGO_TARGET_DIR=$TARGET_CACHE_DIR
export npm_config_cache=$NPM_CACHE_DIR
export XDG_CACHE_HOME=/cache
export CI=true
export APPIMAGE_EXTRACT_AND_RUN=1

seed_tauri_tools

mkdir -p "$WORKSPACE_DIR"
rsync --archive --delete \
  --exclude=/.git/ \
  --exclude=/builds/ \
  --exclude=/dist/ \
  --exclude=/node_modules/ \
  --exclude=/src-tauri/target/ \
  "$SOURCE_DIR/" "$WORKSPACE_DIR/"

cd "$WORKSPACE_DIR"
product_name=$(node -e \
  'const c=JSON.parse(require("fs").readFileSync("src-tauri/tauri.conf.json")); console.log(c.productName)')
app_version=$(node -e \
  'const c=JSON.parse(require("fs").readFileSync("src-tauri/tauri.conf.json")); console.log(c.version)')
[[ -n "$product_name" ]] || die "tauri.conf.json has no productName"
[[ "$app_version" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || \
  die "invalid application version in tauri.conf.json: $app_version"

echo "linux-build: installing locked frontend dependencies"
npm ci --prefer-offline --no-audit --no-fund

clear_stale_bundles
echo "linux-build: building bundles (${requested_bundles[*]}) for $target_triple"
echo "linux-build: Tauri /cache paths are intermediate container paths, not published outputs"
cargo tauri build \
  --ci \
  --config src-tauri/tauri.container.conf.json \
  "${locked_build_args[@]}"

for bundle in "${requested_bundles[@]}"; do
  case "$bundle" in
    deb) copy_and_validate_deb ;;
    rpm) copy_and_validate_rpm ;;
    appimage) copy_and_validate_appimage ;;
  esac
done

(
  cd "$OUTPUT_DIR"
  sha256sum "${artifact_names[@]}" > SHA256SUMS
)
write_metadata

echo "linux-build: validated ${#artifact_names[@]} package(s) for repository publication"
