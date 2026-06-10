#!/usr/bin/env bash
#
# Extract a Pixiv refresh token using your EXISTING logged-in browser session.
# No password typing, no headless captcha — you just authorize once and copy a
# short-lived `code` out of DevTools. Uses only curl/openssl/jq.
#
#     ./tools/pixiv-token/browser-login.sh
#
set -euo pipefail

# client_id ends in "DS8" — "DS9" yields "Invalid OAuth client".
CLIENT_ID="MOBrBDS8blbauoSck0ZfDbtuzpyT"
CLIENT_SECRET="lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj"
HASH_SECRET="28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c"
TOKEN_URL="https://oauth.secure.pixiv.net/auth/token"
LOGIN_URL="https://app-api.pixiv.net/web/v1/login"
REDIRECT_URI="https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback"
USER_AGENT="PixivIOSApp/7.13.3 (iOS 14.6; iPhone13,2)"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pixiv-slides"
CONFIG_FILE="$CONFIG_DIR/config.toml"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

CODE_VERIFIER="$(openssl rand 32 | b64url)"
CODE_CHALLENGE="$(printf '%s' "$CODE_VERIFIER" | openssl dgst -binary -sha256 | b64url)"

cat <<EOF

==========================================================================
 1. In the browser where you're ALREADY logged into pixiv.net, open:

    ${LOGIN_URL}?code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&client=pixiv-android

 2. Open DevTools (F12) -> Network tab. Tick "Preserve log".

 3. Complete the login button / prompt (solve a captcha if one appears).
    The page will then try to open a "pixiv://..." link and appear to do
    nothing — that is expected.

 4. In the Network tab, find the request whose URL contains:
        /users/auth/pixiv/callback?...&code=...
    Copy the value of the  code=  parameter (a long string before any '&').
==========================================================================

EOF

echo "(You can paste the bare code, the whole callback URL, or the pixiv://... link —"
echo " whatever's easiest. The script will pull the code out of it.)"
read -rp "Paste here: " RAW

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

CODE="$RAW"
# If a full URL / query string was pasted, isolate the code parameter.
if [[ "$CODE" == *code=* ]]; then
    CODE="${CODE#*code=}"   # drop everything up to and including code=
    CODE="${CODE%%&*}"      # drop a trailing &state=... etc.
fi
CODE="$(urldecode "$CODE")"
CODE="${CODE//[[:space:]]/}"

if [ -z "$CODE" ]; then
    echo "!! No code found in what you pasted." >&2
    exit 1
fi
echo ">> Using code: ${CODE:0:6}…${CODE: -4} (length ${#CODE})"

echo ">> Exchanging code for a refresh token…"
NOW="$(date +%Y-%m-%dT%H:%M:%S+00:00)"
HASH="$(printf '%s' "${NOW}${HASH_SECRET}" | md5sum | cut -d' ' -f1)"
RESP="$(curl -s "$TOKEN_URL" \
    -H "User-Agent: $USER_AGENT" \
    -H "App-OS: ios" \
    -H "App-OS-Version: 14.6" \
    -H "X-Client-Time: $NOW" \
    -H "X-Client-Hash: $HASH" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "grant_type=authorization_code" \
    -d "code=$CODE" \
    -d "code_verifier=$CODE_VERIFIER" \
    -d "redirect_uri=$REDIRECT_URI" \
    -d "include_policy=true")"

REFRESH="$(printf '%s' "$RESP" | jq -r '.refresh_token // empty')"
if [ -z "$REFRESH" ]; then
    echo "!! No refresh_token returned. Pixiv said:" >&2
    printf '%s\n' "$RESP" | jq . 2>/dev/null >&2 || printf '%s\n' "$RESP" >&2
    echo >&2
    REASON="$(printf '%s' "$RESP" | jq -r '.error // .errors.system.message // empty' 2>/dev/null)"
    case "$REASON" in
        *invalid_grant*|*Invalid*)
            echo "   'invalid_grant' = the code was already used, expired (~30s), or came" >&2
            echo "   from a DIFFERENT run of this script than the one now waiting. Each run" >&2
            echo "   makes a fresh URL — use the URL printed by THIS run, log in, and paste" >&2
            echo "   the code back into THIS same run." >&2
            ;;
        *) echo "   Re-run and grab a fresh code (it expires ~30s after login)." >&2 ;;
    esac
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
echo ">> Done. Launch with:  cd src-tauri && cargo tauri dev"
