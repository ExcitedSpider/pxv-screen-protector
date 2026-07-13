//! Pixiv bookmark operations used by the save action.

const BOOKMARK_ADD_URL: &str = "https://app-api.pixiv.net/v2/illust/bookmark/add";

pub async fn add(
    client: &reqwest::Client,
    access_token: &str,
    illust_id: u64,
    restrict: &str,
    tags: &[String],
) -> Result<String, String> {
    let restrict = bookmark_restrict(restrict)?;
    let mut data = vec![
        ("illust_id", illust_id.to_string()),
        ("restrict", restrict.to_string()),
    ];
    let tag_text = bookmark_tags(tags);
    if let Some(tags) = &tag_text {
        data.push(("tags[]", tags.clone()));
    }

    let resp = client
        .post(BOOKMARK_ADD_URL)
        .header("User-Agent", crate::auth::USER_AGENT)
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Accept-Language", "en-US")
        .form(&data)
        .send()
        .await
        .map_err(|e| format!("bookmark request failed: {e}"))?;

    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("bookmark response read failed: {e}"))?;
    if !status.is_success() {
        return Err(format!("bookmark failed ({status}): {body}"));
    }

    Ok(format!("Bookmarked {restrict}"))
}

fn bookmark_restrict(raw: &str) -> Result<&'static str, String> {
    match raw.trim() {
        "" | "private" => Ok("private"),
        "public" => Ok("public"),
        other => Err(format!(
            "unsupported bookmark_restrict={other:?}; use \"private\" or \"public\""
        )),
    }
}

fn bookmark_tags(raw: &[String]) -> Option<String> {
    let tags = raw
        .iter()
        .map(|tag| tag.trim())
        .filter(|tag| !tag.is_empty())
        .collect::<Vec<_>>();
    if tags.is_empty() {
        None
    } else {
        Some(tags.join(" "))
    }
}
