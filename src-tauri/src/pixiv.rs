//! Pixiv app-API client: fetch the "following" feed and reduce it to slides.

use chrono::{DateTime, Duration, Local};
use serde::{Deserialize, Serialize};
use std::{cmp::Ordering, collections::HashMap};

const FOLLOW_URL: &str = "https://app-api.pixiv.net/v2/illust/follow?restrict=public";
const SEARCH_URL: &str = "https://app-api.pixiv.net/v1/search/illust";

#[derive(Debug, Deserialize)]
struct IllustResponse {
    illusts: Vec<Illust>,
    next_url: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
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
    #[serde(default)]
    total_bookmarks: u64,
}

#[derive(Debug, Deserialize, Clone)]
struct User {
    name: String,
}

#[derive(Debug, Deserialize, Default, Clone)]
struct MetaSinglePage {
    original_image_url: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct MetaPage {
    image_urls: ImageUrls,
}

#[derive(Debug, Deserialize, Clone)]
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
    pub total_bookmarks: Option<u64>,
    pub source_tags: Vec<String>,
    pub best_tag_rank: Option<usize>,
    pub median_like_score: Option<f64>,
}

#[derive(Debug, Clone)]
struct SearchCandidate {
    illust: Illust,
    source_tags: Vec<String>,
    best_tag_rank: usize,
    median_like_score: f64,
}

fn push_slides(
    out: &mut Vec<Slide>,
    illust: &Illust,
    max_pages: usize,
    source_tags: &[String],
    best_tag_rank: Option<usize>,
    median_like_score: Option<f64>,
) {
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
            .filter_map(|p| {
                p.image_urls
                    .original
                    .clone()
                    .or_else(|| p.image_urls.large.clone())
            })
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
            total_bookmarks: (illust.total_bookmarks > 0).then_some(illust.total_bookmarks),
            source_tags: source_tags.to_vec(),
            best_tag_rank,
            median_like_score,
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
        let resp: IllustResponse = client
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
                push_slides(&mut slides, illust, max_pages_per_post, &[], None, None);
            } else if date >= today {
                push_slides(&mut fallback, illust, max_pages_per_post, &[], None, None);
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

/// Search configured tags over a local date range, merge/dedupe results, and
/// return the most-bookmarked illustrations as slideshow slides.
pub async fn fetch_tag_slides(
    client: &reqwest::Client,
    access_token: &str,
    tag_cfg: &crate::config::TagFeedConfig,
    max_pages_per_post: usize,
) -> Result<Vec<Slide>, String> {
    let tags: Vec<String> = tag_cfg
        .tags
        .iter()
        .map(|tag| tag.trim())
        .filter(|tag| !tag.is_empty())
        .map(ToOwned::to_owned)
        .collect();

    if tags.is_empty() {
        return Err("feed_mode=tag_search requires at least one [tag_feed].tags entry".to_string());
    }

    let range_days = tag_cfg.range_days.clamp(1, 366);
    let today = Local::now().date_naive();
    let start = today - Duration::days(range_days.saturating_sub(1));
    let end = today;
    let max_results_per_tag = tag_cfg.max_results_per_tag.max(1);
    let max_search_pages = tag_cfg.max_search_pages_per_tag.max(1);

    let mut by_id: HashMap<u64, SearchCandidate> = HashMap::new();
    for tag in &tags {
        let mut candidates = match search_tag(
            client,
            access_token,
            tag,
            &tag_cfg.search_target,
            &tag_cfg.sort,
            start,
            end,
            max_results_per_tag,
            max_search_pages,
        )
        .await
        {
            Ok(candidates) => candidates,
            Err(err) if tag_cfg.sort == "popular_desc" => {
                match tag_cfg.fallback_without_popular_sort.as_str() {
                    "local_bookmark_sort" => {
                        let mut local = search_tag(
                            client,
                            access_token,
                            tag,
                            &tag_cfg.search_target,
                            "date_desc",
                            start,
                            end,
                            usize::MAX,
                            max_search_pages,
                        )
                        .await?;
                        local.sort_by(|a, b| {
                            b.illust
                                .total_bookmarks
                                .cmp(&a.illust.total_bookmarks)
                                .then_with(|| b.illust.id.cmp(&a.illust.id))
                        });
                        local.truncate(max_results_per_tag);
                        local
                    }
                    "error" => {
                        return Err(format!(
                            "Pixiv tag search with sort=popular_desc failed for \"{tag}\". \
                         This sort usually requires Pixiv Premium. Set \
                         tag_feed.fallback_without_popular_sort = \"local_bookmark_sort\" \
                         to approximate it by scanning recent results. Original error: {err}"
                        ));
                    }
                    other => {
                        return Err(format!(
                            "unsupported tag_feed.fallback_without_popular_sort={other:?}; \
                         use \"error\" or \"local_bookmark_sort\""
                        ));
                    }
                }
            }
            Err(err) => return Err(err),
        };
        assign_tag_metrics(tag, &mut candidates);

        for candidate in candidates.drain(..) {
            by_id
                .entry(candidate.illust.id)
                .and_modify(|existing| {
                    for source_tag in &candidate.source_tags {
                        if !existing.source_tags.contains(source_tag) {
                            existing.source_tags.push(source_tag.clone());
                        }
                    }
                    existing.best_tag_rank = existing.best_tag_rank.min(candidate.best_tag_rank);
                    existing.median_like_score =
                        existing.median_like_score.max(candidate.median_like_score);
                })
                .or_insert(candidate);
        }
    }

    let mut candidates: Vec<SearchCandidate> = by_id.into_values().collect();
    match tag_cfg.merge_strategy.trim() {
        "raw_bookmarks" | "" => sort_by_bookmarks(&mut candidates),
        "per_tag_rank" => candidates.sort_by(|a, b| {
            a.best_tag_rank
                .cmp(&b.best_tag_rank)
                .then_with(|| b.illust.total_bookmarks.cmp(&a.illust.total_bookmarks))
                .then_with(|| b.illust.id.cmp(&a.illust.id))
        }),
        "median_like_ratio" => candidates.sort_by(|a, b| {
            b.median_like_score
                .partial_cmp(&a.median_like_score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| b.illust.total_bookmarks.cmp(&a.illust.total_bookmarks))
                .then_with(|| b.illust.id.cmp(&a.illust.id))
        }),
        other => {
            return Err(format!(
                "unsupported tag_feed.merge_strategy={other:?}; use \"raw_bookmarks\", \"per_tag_rank\", or \"median_like_ratio\""
            ));
        }
    }

    let mut slides = Vec::new();
    for candidate in &candidates {
        push_slides(
            &mut slides,
            &candidate.illust,
            max_pages_per_post,
            &candidate.source_tags,
            Some(candidate.best_tag_rank),
            Some(candidate.median_like_score),
        );
        if slides.len() >= tag_cfg.max_slides.max(1) {
            break;
        }
    }
    slides.truncate(tag_cfg.max_slides.max(1));
    Ok(slides)
}

async fn search_tag(
    client: &reqwest::Client,
    access_token: &str,
    tag: &str,
    search_target: &str,
    sort: &str,
    start: chrono::NaiveDate,
    end: chrono::NaiveDate,
    result_limit: usize,
    page_limit: usize,
) -> Result<Vec<SearchCandidate>, String> {
    let start_s = start.to_string();
    let end_s = end.to_string();
    let mut url = reqwest::Url::parse_with_params(
        SEARCH_URL,
        [
            ("word", tag),
            ("search_target", search_target),
            ("sort", sort),
            ("filter", "for_ios"),
            ("start_date", start_s.as_str()),
            ("end_date", end_s.as_str()),
        ],
    )
    .map_err(|e| format!("search url build failed for tag {tag:?}: {e}"))?
    .to_string();

    let mut out = Vec::new();
    for _ in 0..page_limit {
        let resp = get_search_page(client, access_token, &url, tag, sort).await?;
        for illust in resp.illusts {
            out.push(SearchCandidate {
                illust,
                source_tags: Vec::new(),
                best_tag_rank: usize::MAX,
                median_like_score: 0.0,
            });
            if out.len() >= result_limit {
                return Ok(out);
            }
        }
        match resp.next_url {
            Some(next) => url = next,
            None => break,
        }
    }
    Ok(out)
}

fn assign_tag_metrics(tag: &str, candidates: &mut [SearchCandidate]) {
    let sample_median = sample_median_bookmarks(candidates);
    for (idx, candidate) in candidates.iter_mut().enumerate() {
        candidate.source_tags = vec![tag.to_string()];
        candidate.best_tag_rank = idx + 1;
        candidate.median_like_score =
            median_like_score(candidate.illust.total_bookmarks, sample_median);
    }
}

fn sample_median_bookmarks(candidates: &[SearchCandidate]) -> f64 {
    if candidates.is_empty() {
        return 0.0;
    }
    let mut likes: Vec<u64> = candidates.iter().map(|c| c.illust.total_bookmarks).collect();
    likes.sort_unstable();
    let mid = likes.len() / 2;
    if likes.len() % 2 == 1 {
        likes[mid] as f64
    } else {
        (likes[mid - 1] as f64 + likes[mid] as f64) / 2.0
    }
}

fn median_like_score(likes: u64, sample_median: f64) -> f64 {
    let numerator = ((likes as f64) + 1.0).ln();
    let denominator = (sample_median + 1.0).ln();
    if denominator > f64::EPSILON {
        numerator / denominator
    } else {
        numerator
    }
}

fn sort_by_bookmarks(candidates: &mut [SearchCandidate]) {
    candidates.sort_by(|a, b| {
        b.illust
            .total_bookmarks
            .cmp(&a.illust.total_bookmarks)
            .then_with(|| b.illust.id.cmp(&a.illust.id))
    });
}

async fn get_search_page(
    client: &reqwest::Client,
    access_token: &str,
    url: &str,
    tag: &str,
    sort: &str,
) -> Result<IllustResponse, String> {
    let resp = client
        .get(url)
        .header("User-Agent", crate::auth::USER_AGENT)
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Accept-Language", "en-US")
        .send()
        .await
        .map_err(|e| format!("tag search request failed for {tag:?}: {e}"))?;

    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("tag search body read failed for {tag:?}: {e}"))?;
    if !status.is_success() {
        return Err(format!(
            "tag search failed ({status}) for {tag:?} with sort={sort}: {body}"
        ));
    }
    serde_json::from_str(&body)
        .map_err(|e| format!("tag search parse failed for {tag:?}: {e}; body={body}"))
}
