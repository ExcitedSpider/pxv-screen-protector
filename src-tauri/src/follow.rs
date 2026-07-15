//! Pixiv author-follow operations used by tag-feed saves.

const FOLLOW_ADD_URL: &str = "https://app-api.pixiv.net/v1/user/follow/add";

pub async fn add(
    client: &reqwest::Client,
    access_token: &str,
    user_id: u64,
) -> Result<String, String> {
    let data = follow_form(user_id);
    let resp = client
        .post(FOLLOW_ADD_URL)
        .header("User-Agent", crate::auth::USER_AGENT)
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Accept-Language", "en-US")
        .form(&data)
        .send()
        .await
        .map_err(|e| format!("request failed: {e}"))?;

    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("response read failed: {e}"))?;
    if !status.is_success() {
        return Err(format!("request returned {status}: {body}"));
    }

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
