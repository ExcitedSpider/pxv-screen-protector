//! Pixiv OAuth: exchange a refresh token for a short-lived access token.

use serde::Deserialize;
use std::time::Instant;

// Well-known constants from the official Pixiv mobile app (same as pixivpy).
// NOTE: the client_id ends in "DS8" — "DS9" yields "Invalid OAuth client".
const CLIENT_ID: &str = "MOBrBDS8blbauoSck0ZfDbtuzpyT";
const CLIENT_SECRET: &str = "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj";
const HASH_SECRET: &str = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c";
const AUTH_URL: &str = "https://oauth.secure.pixiv.net/auth/token";

// Auth requests impersonate the iOS app (matches pixivpy's working request).
const AUTH_USER_AGENT: &str = "PixivIOSApp/7.13.3 (iOS 14.6; iPhone13,2)";

pub const USER_AGENT: &str = "PixivAndroidApp/5.0.234 (Android 11; Pixel 5)";

#[derive(Debug, Deserialize)]
pub struct TokenResponse {
    pub access_token: String,
    #[allow(dead_code)]
    pub refresh_token: String,
    #[allow(dead_code)]
    pub expires_in: i64,
}

/// Refresh the access token. Pixiv requires `X-Client-Time` + `X-Client-Hash`
/// (md5 of the time concatenated with a fixed salt).
pub async fn refresh(
    client: &reqwest::Client,
    refresh_token: &str,
) -> Result<TokenResponse, String> {
    let started = Instant::now();
    // pixivpy uses local-time digits with a literal "+00:00" suffix.
    let now = chrono::Local::now()
        .format("%Y-%m-%dT%H:%M:%S+00:00")
        .to_string();
    let hash = format!("{:x}", md5::compute(format!("{now}{HASH_SECRET}")));

    let params = [
        ("client_id", CLIENT_ID),
        ("client_secret", CLIENT_SECRET),
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
        ("get_secure_url", "1"),
    ];

    let resp = client
        .post(AUTH_URL)
        .header("User-Agent", AUTH_USER_AGENT)
        .header("App-OS", "ios")
        .header("App-OS-Version", "14.6")
        .header("X-Client-Time", &now)
        .header("X-Client-Hash", &hash)
        .header("Accept-Language", "en-US")
        .form(&params)
        .send()
        .await;
    let resp = match resp {
        Ok(resp) => resp,
        Err(err) => {
            log::error!(
                "event=api_timing operation=oauth_refresh outcome=failure duration_ms={} error={:?}",
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("auth request failed: {err}"));
        }
    };

    let status = resp.status();
    let body = match resp.text().await {
        Ok(body) => body,
        Err(err) => {
            log::error!(
                "event=api_timing operation=oauth_refresh outcome=failure status={} duration_ms={} error={:?}",
                status.as_u16(),
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("auth response read failed: {err}"));
        }
    };
    if !status.is_success() {
        log::error!(
            "event=api_timing operation=oauth_refresh outcome=failure status={} duration_ms={}",
            status.as_u16(),
            started.elapsed().as_millis()
        );
        return Err(format!(
            "auth failed ({status}). Is your refresh_token valid? Body: {body}"
        ));
    }
    match serde_json::from_str(&body) {
        Ok(token) => {
            log::info!(
                "event=api_timing operation=oauth_refresh outcome=success status={} duration_ms={}",
                status.as_u16(),
                started.elapsed().as_millis()
            );
            Ok(token)
        }
        Err(err) => {
            log::error!(
                "event=api_timing operation=oauth_refresh outcome=failure status={} duration_ms={} error={:?}",
                status.as_u16(),
                started.elapsed().as_millis(),
                err.to_string()
            );
            // Do not include the OAuth response body: a successful response
            // contains both access and refresh tokens.
            Err(format!("auth response parse failed: {err}"))
        }
    }
}
