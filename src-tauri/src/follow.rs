//! Pixiv author-follow operations used by tag-feed saves.

use std::time::Instant;

const FOLLOW_ADD_URL: &str = "https://app-api.pixiv.net/v1/user/follow/add";

pub async fn add(
    client: &reqwest::Client,
    access_token: &str,
    user_id: u64,
) -> Result<String, String> {
    let data = follow_form(user_id);
    let started = Instant::now();
    let resp = client
        .post(FOLLOW_ADD_URL)
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
                "event=api_timing operation=follow_add outcome=failure user_id={} duration_ms={} error={:?}",
                user_id,
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("request failed: {err}"));
        }
    };

    let status = resp.status();
    let body = match resp.text().await {
        Ok(body) => body,
        Err(err) => {
            log::error!(
                "event=api_timing operation=follow_add outcome=failure user_id={} status={} duration_ms={} error={:?}",
                user_id,
                status.as_u16(),
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("response read failed: {err}"));
        }
    };
    if !status.is_success() {
        log::error!(
            "event=api_timing operation=follow_add outcome=failure user_id={} status={} duration_ms={}",
            user_id,
            status.as_u16(),
            started.elapsed().as_millis()
        );
        return Err(format!("request returned {status}: {body}"));
    }

    log::info!(
        "event=api_timing operation=follow_add outcome=success user_id={} status={} duration_ms={}",
        user_id,
        status.as_u16(),
        started.elapsed().as_millis()
    );

    Ok("Followed artist".to_string())
}

fn follow_form(user_id: u64) -> [(&'static str, String); 2] {
    [
        ("user_id", user_id.to_string()),
        ("restrict", "public".to_string()),
    ]
}

#[cfg(test)]
mod tests {
    use super::{follow_form, FOLLOW_ADD_URL};

    #[test]
    fn follow_request_uses_public_restriction() {
        assert_eq!(
            follow_form(123),
            [
                ("user_id", "123".to_string()),
                ("restrict", "public".to_string()),
            ]
        );
        assert_eq!(
            FOLLOW_ADD_URL,
            "https://app-api.pixiv.net/v1/user/follow/add"
        );
    }
}
