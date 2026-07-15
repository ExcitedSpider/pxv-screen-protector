//! Save the currently-viewed illustration to a local folder.

use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::time::Instant;

#[derive(Deserialize)]
pub struct SaveRequest {
    pub illust_id: u64,
    pub user_id: u64,
    #[serde(default)]
    pub is_followed: Option<bool>,
    #[serde(default)]
    pub is_bookmarked: Option<bool>,
    pub feed_mode: String,
    pub artist: String,
    pub title: String,
    pub image_url: String,
    pub page: u32,
}

/// Expand a leading `~/` to `$HOME`; otherwise use the path as given.
pub fn resolve_dir(s: &str) -> PathBuf {
    if let Some(rest) = s.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(s)
}

/// Download the image (with the Referer Pixiv requires) and write it into
/// `save_dir`. Returns a short human-readable status for the toast.
pub async fn save(
    client: &reqwest::Client,
    req: &SaveRequest,
    save_dir: &Path,
) -> Result<String, String> {
    let started = Instant::now();
    log::info!(
        "event=save_start illust_id={} user_id={} page={} target_dir={:?}",
        req.illust_id,
        req.user_id,
        req.page,
        save_dir
    );

    let result = save_inner(client, req, save_dir).await;
    match &result {
        Ok(SaveOutcome::Saved { filename }) => log::info!(
            "event=save_success illust_id={} user_id={} page={} filename={:?} duration_ms={}",
            req.illust_id,
            req.user_id,
            req.page,
            filename,
            started.elapsed().as_millis()
        ),
        Ok(SaveOutcome::AlreadySaved { filename }) => log::info!(
            "event=save_already_saved illust_id={} user_id={} page={} filename={:?} duration_ms={}",
            req.illust_id,
            req.user_id,
            req.page,
            filename,
            started.elapsed().as_millis()
        ),
        Err(err) => log::error!(
            "event=save_failure illust_id={} user_id={} page={} duration_ms={} error={:?}",
            req.illust_id,
            req.user_id,
            req.page,
            started.elapsed().as_millis(),
            err
        ),
    }

    result.map(SaveOutcome::into_status)
}

enum SaveOutcome {
    Saved { filename: String },
    AlreadySaved { filename: String },
}

impl SaveOutcome {
    fn into_status(self) -> String {
        match self {
            Self::Saved { filename } => format!("Saved · {filename}"),
            Self::AlreadySaved { filename } => format!("Already saved · {filename}"),
        }
    }
}

async fn save_inner(
    client: &reqwest::Client,
    req: &SaveRequest,
    save_dir: &Path,
) -> Result<SaveOutcome, String> {
    std::fs::create_dir_all(save_dir)
        .map_err(|e| format!("cannot create {}: {e}", save_dir.display()))?;

    let ext = req
        .image_url
        .rsplit('.')
        .next()
        .filter(|e| !e.is_empty() && e.len() <= 4 && e.chars().all(|c| c.is_ascii_alphanumeric()))
        .unwrap_or("jpg");

    let stem = sanitize(&format!(
        "{} - {} - {}_p{}",
        req.artist, req.title, req.illust_id, req.page
    ));
    let filename = format!("{stem}.{ext}");
    let path = save_dir.join(&filename);

    if path.exists() {
        return Ok(SaveOutcome::AlreadySaved { filename });
    }

    let download_started = Instant::now();
    let resp = client
        .get(&req.image_url)
        .header("Referer", "https://www.pixiv.net/")
        .header("User-Agent", crate::auth::USER_AGENT)
        .send()
        .await;
    let resp = match resp {
        Ok(resp) => resp,
        Err(err) => {
            log::error!(
                "event=api_timing operation=save_image_download outcome=failure illust_id={} page={} duration_ms={} error={:?}",
                req.illust_id,
                req.page,
                download_started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("download failed: {err}"));
        }
    };
    if !resp.status().is_success() {
        let status = resp.status();
        log::error!(
            "event=api_timing operation=save_image_download outcome=failure illust_id={} page={} status={} duration_ms={}",
            req.illust_id,
            req.page,
            status.as_u16(),
            download_started.elapsed().as_millis()
        );
        return Err(format!("download failed: {status}"));
    }
    let status = resp.status();
    let bytes = resp.bytes().await;
    let bytes = match bytes {
        Ok(bytes) => bytes,
        Err(err) => {
            log::error!(
                "event=api_timing operation=save_image_download outcome=failure illust_id={} page={} status={} duration_ms={} error={:?}",
                req.illust_id,
                req.page,
                status.as_u16(),
                download_started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("download read failed: {err}"));
        }
    };
    log::info!(
        "event=api_timing operation=save_image_download outcome=success illust_id={} page={} status={} bytes={} duration_ms={}",
        req.illust_id,
        req.page,
        status.as_u16(),
        bytes.len(),
        download_started.elapsed().as_millis()
    );

    std::fs::write(&path, &bytes).map_err(|e| format!("write failed: {e}"))?;
    Ok(SaveOutcome::Saved { filename })
}

/// Make a string safe for a filename: strip path/illegal chars, collapse
/// whitespace, and cap the length (bytes-aware, no mid-char truncation).
fn sanitize(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0' | '\n' | '\r' | '\t' => ' ',
            _ => c,
        })
        .collect();
    let collapsed = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed
        .chars()
        .take(120)
        .collect::<String>()
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::SaveRequest;

    #[test]
    fn save_request_accepts_pixiv_bookmark_state() {
        let request: SaveRequest = serde_json::from_str(
            r#"{
                "illust_id": 42,
                "user_id": 99,
                "is_followed": false,
                "is_bookmarked": true,
                "feed_mode": "tag_search",
                "artist": "Artist",
                "title": "Work",
                "image_url": "https://i.pximg.net/image.jpg",
                "page": 1
            }"#,
        )
        .unwrap();

        assert_eq!(request.is_bookmarked, Some(true));
    }
}
