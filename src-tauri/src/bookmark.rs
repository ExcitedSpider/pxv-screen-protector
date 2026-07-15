//! Pixiv bookmark operations used by the save action.

use std::time::Instant;

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

    let started = Instant::now();
    let resp = client
        .post(BOOKMARK_ADD_URL)
        .header("User-Agent", crate::auth::USER_AGENT)
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Accept-Language", "en-US")
        .form(&data)
        .send()
        .await;
    let resp = match resp {
        Ok(resp) => resp,
        Err(err) => {
            log::error!(
                "event=api_timing operation=bookmark_add outcome=failure illust_id={} duration_ms={} error={:?}",
                illust_id,
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("bookmark request failed: {err}"));
        }
    };

    let status = resp.status();
    let body = match resp.text().await {
        Ok(body) => body,
        Err(err) => {
            log::error!(
                "event=api_timing operation=bookmark_add outcome=failure illust_id={} status={} duration_ms={} error={:?}",
                illust_id,
                status.as_u16(),
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("bookmark response read failed: {err}"));
        }
    };
    if !status.is_success() {
        log::error!(
            "event=api_timing operation=bookmark_add outcome=failure illust_id={} status={} duration_ms={}",
            illust_id,
            status.as_u16(),
            started.elapsed().as_millis()
        );
        return Err(format!("bookmark failed ({status}): {body}"));
    }

    log::info!(
        "event=api_timing operation=bookmark_add outcome=success illust_id={} status={} duration_ms={}",
        illust_id,
        status.as_u16(),
        started.elapsed().as_millis()
    );

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
