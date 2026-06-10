//! Image proxy: fetches i.pximg.net images with the Referer header Pixiv
//! requires (a webview `<img>` can't set it), behind the `pximg://` protocol.

const PREFIX: &str = "pximg://localhost/";

/// `uri` looks like `pximg://localhost/<percent-encoded https url>`.
/// Returns (bytes, content-type).
pub async fn fetch_image(
    client: &reqwest::Client,
    uri: &str,
) -> Result<(Vec<u8>, String), String> {
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

    let resp = client
        .get(&real)
        .header("Referer", "https://www.pixiv.net/")
        .header("User-Agent", crate::auth::USER_AGENT)
        .send()
        .await
        .map_err(|e| format!("image fetch failed: {e}"))?;

    if !resp.status().is_success() {
        return Err(format!("image fetch {}: {real}", resp.status()));
    }

    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();

    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("image body read failed: {e}"))?
        .to_vec();

    Ok((bytes, content_type))
}
