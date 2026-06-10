//! Pixiv app-API client: fetch the "following" feed and reduce it to slides.

use chrono::{DateTime, Duration, Local};
use serde::{Deserialize, Serialize};

const FOLLOW_URL: &str = "https://app-api.pixiv.net/v2/illust/follow?restrict=public";

#[derive(Debug, Deserialize)]
struct FollowResponse {
    illusts: Vec<Illust>,
    next_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Illust {
    id: u64,
    title: String,
    create_date: String,
    page_count: u32,
    user: User,
    #[serde(default)]
    meta_single_page: MetaSinglePage,
    #[serde(default)]
    meta_pages: Vec<MetaPage>,
}

#[derive(Debug, Deserialize)]
struct User {
    name: String,
}

#[derive(Debug, Deserialize, Default)]
struct MetaSinglePage {
    original_image_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MetaPage {
    image_urls: ImageUrls,
}

#[derive(Debug, Deserialize)]
struct ImageUrls {
    original: Option<String>,
    large: Option<String>,
}

/// One image to display. `image_url` is the raw i.pximg.net URL; the frontend
/// wraps it in the `pximg://` protocol so the Referer header gets attached.
#[derive(Debug, Serialize, Clone)]
pub struct Slide {
    pub illust_id: u64,
    pub title: String,
    pub artist: String,
    pub image_url: String,
    pub page: u32,
    pub page_count: u32,
}

fn push_slides(out: &mut Vec<Slide>, illust: &Illust, max_pages: usize) {
    let urls: Vec<String> = if illust.page_count <= 1 {
        illust
            .meta_single_page
            .original_image_url
            .clone()
            .into_iter()
            .collect()
    } else {
        illust
            .meta_pages
            .iter()
            .filter_map(|p| p.image_urls.original.clone().or_else(|| p.image_urls.large.clone()))
            .collect()
    };

    for (i, url) in urls.into_iter().take(max_pages.max(1)).enumerate() {
        out.push(Slide {
            illust_id: illust.id,
            title: illust.title.clone(),
            artist: illust.user.name.clone(),
            image_url: url,
            page: i as u32 + 1,
            page_count: illust.page_count,
        });
    }
}

/// Walk the following feed (newest first) collecting yesterday's posts in local
/// time. Stops as soon as a post predates yesterday. Falls back to today-so-far
/// if yesterday is empty and `empty_day_fallback` is set.
pub async fn fetch_yesterday_slides(
    client: &reqwest::Client,
    access_token: &str,
    max_pages_per_post: usize,
    empty_day_fallback: bool,
) -> Result<Vec<Slide>, String> {
    let today = Local::now().date_naive();
    let yesterday = today - Duration::days(1);

    let mut slides: Vec<Slide> = Vec::new();
    let mut fallback: Vec<Slide> = Vec::new();
    let mut url = FOLLOW_URL.to_string();

    loop {
        let resp: FollowResponse = client
            .get(&url)
            .header("User-Agent", crate::auth::USER_AGENT)
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept-Language", "en-US")
            .send()
            .await
            .map_err(|e| format!("feed request failed: {e}"))?
            .json()
            .await
            .map_err(|e| format!("feed parse failed: {e}"))?;

        if resp.illusts.is_empty() {
            break;
        }

        let mut reached_older = false;
        for illust in &resp.illusts {
            let dt = DateTime::parse_from_rfc3339(&illust.create_date)
                .map_err(|e| format!("bad create_date {}: {e}", illust.create_date))?;
            let date = dt.with_timezone(&Local).date_naive();

            if date == yesterday {
                push_slides(&mut slides, illust, max_pages_per_post);
            } else if date >= today {
                push_slides(&mut fallback, illust, max_pages_per_post);
            } else {
                reached_older = true;
                break;
            }
        }

        if reached_older {
            break;
        }
        match resp.next_url {
            Some(next) => url = next,
            None => break,
        }
    }

    if slides.is_empty() && empty_day_fallback {
        return Ok(fallback);
    }
    Ok(slides)
}
