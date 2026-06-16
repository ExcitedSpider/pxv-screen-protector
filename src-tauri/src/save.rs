//! Save the currently-viewed illustration to a local folder.

use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Deserialize)]
pub struct SaveRequest {
    pub illust_id: u64,
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
    req: SaveRequest,
    save_dir: &Path,
) -> Result<String, String> {
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
        return Ok(format!("Already saved · {filename}"));
    }

    let resp = client
        .get(&req.image_url)
        .header("Referer", "https://www.pixiv.net/")
        .header("User-Agent", crate::auth::USER_AGENT)
        .send()
        .await
        .map_err(|e| format!("download failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("download failed: {}", resp.status()));
    }
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("download read failed: {e}"))?;

    std::fs::write(&path, &bytes).map_err(|e| format!("write failed: {e}"))?;
    Ok(format!("Saved · {filename}"))
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
    collapsed.chars().take(120).collect::<String>().trim().to_string()
}
