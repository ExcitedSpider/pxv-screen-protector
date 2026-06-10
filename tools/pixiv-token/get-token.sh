#!/usr/bin/env bash
#
# Extracts your Pixiv refresh token in a throwaway Podman container (gppt +
# headless Chromium) and writes it to ~/.config/pixiv-slides/config.toml.
#
# Your credentials are read locally, passed only to the ephemeral container as
# env vars, and never written to disk or shell history. Run it yourself:
#
#     ./tools/pixiv-token/get-token.sh
#
set -euo pipefail

IMAGE="pixiv-token"
DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pixiv-slides"
CONFIG_FILE="$CONFIG_DIR/config.toml"

echo ">> Building the extractor image (first run only, ~a couple minutes)…"
podman build -t "$IMAGE" "$DIR"

read -rp "Pixiv ID or email: " PIXIV_ID
read -rsp "Pixiv password: " PIXIV_PW
echo
export PIXIV_ID PIXIV_PW

echo ">> Logging in headlessly…"
set +e
JSON="$(podman run --rm -e PIXIV_ID -e PIXIV_PW "$IMAGE" \
    login-headless -u "$PIXIV_ID" -p "$PIXIV_PW" -j 2>/tmp/gppt.err)"
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
    echo "!! Login failed. gppt output:" >&2
    cat /tmp/gppt.err >&2
    echo >&2
    echo "   Common cause: Pixiv showed a captcha to the headless browser." >&2
    echo "   Re-run, or extract the token on the host with a visible browser." >&2
    exit 1
fi

REFRESH="$(printf '%s' "$JSON" | jq -r '.refresh_token // .response.refresh_token // empty')"
if [ -z "$REFRESH" ]; then
    echo "!! Could not find refresh_token in gppt output:" >&2
    printf '%s\n' "$JSON" >&2
    exit 1
fi

mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
    echo ">> Backed up existing config to $CONFIG_FILE.bak"
fi

cat > "$CONFIG_FILE" <<EOF
refresh_token = "$REFRESH"
slide_interval_secs = 300
max_pages_per_post = 3
empty_day_fallback = true
EOF
chmod 600 "$CONFIG_FILE"

echo ">> Wrote $CONFIG_FILE"
echo ">> Done. Launch the app with:  cd src-tauri && cargo tauri dev"
