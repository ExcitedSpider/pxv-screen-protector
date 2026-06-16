//! Image proxy: fetches i.pximg.net images with the Referer header Pixiv
//! requires (a webview `<img>` can't set it), behind the `pximg://` protocol,
//! backed by an on-disk LRU cache (see `cache.rs`).

use std::path::Path;

const PREFIX: &str = "pximg://localhost/";

/// `uri` looks like `pximg://localhost/<percent-encoded https url>`.
/// Returns (bytes, content-type). Serves from the disk cache when present;
/// otherwise downloads, caches, and prunes. `cache_max_bytes == 0` disables it.
pub async fn fetch_image(
    client: &reqwest::Client,
    uri: &str,
    cache_dir: &Path,
    cache_max_bytes: u64,
) -> Result<(Vec<u8>, String), String> {
    let real = decode_url(uri)?;
    let content_type = content_type_for(&real);

    if cache_max_bytes > 0 {
        let key = crate::cache::key_for(&real);
        if let Some(bytes) = crate::cache::get(cache_dir, &key) {
            log::info!("cache HIT {key}");
            return Ok((bytes, content_type));
        }
        log::info!("cache MISS {key}");
        let bytes = download(client, &real).await?;
        crate::cache::put(cache_dir, &key, &bytes);
        crate::cache::evict_if_over_cap(cache_dir, cache_max_bytes);
        return Ok((bytes, content_type));
    }

    let bytes = download(client, &real).await?;
    Ok((bytes, content_type))
}

/// Decode the protocol URI to a validated i.pximg.net URL.
fn decode_url(uri: &str) -> Result<String, String> {
    let encoded = uri
        .strip_prefix(PREFIX)
        .ok_or_else(|| format!("unexpected protocol uri: {uri}"))?;

    // The webview may or may not have already decoded the path.
    let real = if encoded.starts_with("https://") || encoded.starts_with("http://") {
        encoded.to_string()
    } else {
        urlencoding::decode(encoded)
            .map_err(|e| format!("url decode failed: {e}"))?
            .into_owned()
    };

    // Only ever proxy Pixiv's image CDN.
    if !real.starts_with("https://") || !real.contains(".pximg.net") {
        return Err(format!("refusing to proxy non-pximg url: {real}"));
    }
    Ok(real)
}

/// Download an image from Pixiv's CDN with the required Referer.
async fn download(client: &reqwest::Client, real: &str) -> Result<Vec<u8>, String> {
    let resp = client
        .get(real)
        .header("Referer", "https://www.pixiv.net/")
        .header("User-Agent", crate::auth::USER_AGENT)
        .send()
        .await
        .map_err(|e| format!("image fetch failed: {e}"))?;

    if !resp.status().is_success() {
        return Err(format!("image fetch {}: {real}", resp.status()));
    }

    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("image body read failed: {e}"))?
        .to_vec();

    if bytes.is_empty() {
        return Err(format!("empty image body: {real}"));
    }
    Ok(bytes)
}

/// Content-Type from the URL's extension (consistent for cache hits and misses).
fn content_type_for(url: &str) -> String {
    let ext = url.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => "image/jpeg",
    }
    .to_string()
}
