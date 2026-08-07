//! Pixiv app-API client: fetch the "following" feed and reduce it to slides.

use chrono::{DateTime, Duration, Local};
use serde::{Deserialize, Serialize};
use std::time::Instant;
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
    #[serde(default)]
    caption: String,
    #[serde(default)]
    tags: Vec<SlideTag>,
    #[serde(default)]
    width: Option<u32>,
    #[serde(default)]
    height: Option<u32>,
    page_count: u32,
    user: User,
    #[serde(default)]
    is_bookmarked: Option<bool>,
    #[serde(default)]
    meta_single_page: MetaSinglePage,
    #[serde(default)]
    meta_pages: Vec<MetaPage>,
    #[serde(default)]
    total_bookmarks: Option<u64>,
    #[serde(default)]
    total_view: Option<u64>,
    /// Pixiv content restriction: 0 is general, nonzero is age-restricted.
    #[serde(default)]
    x_restrict: Option<u8>,
}

#[derive(Debug, Deserialize, Clone)]
struct User {
    id: u64,
    name: String,
    #[serde(default)]
    is_followed: Option<bool>,
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

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct SlideTag {
    pub name: String,
    #[serde(default)]
    pub translated_name: Option<String>,
}

/// One image to display. `image_url` is the raw i.pximg.net URL; the frontend
/// wraps it in the `pximg://` protocol so the Referer header gets attached.
#[derive(Debug, Serialize, Clone)]
pub struct Slide {
    pub illust_id: u64,
    pub title: String,
    pub artist: String,
    pub user_id: u64,
    pub create_date: String,
    pub caption: String,
    pub tags: Vec<SlideTag>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub total_views: Option<u64>,
    pub x_restrict: Option<u8>,
    pub is_followed: Option<bool>,
    pub is_bookmarked: Option<bool>,
    pub image_url: String,
    pub page: u32,
    pub page_count: u32,
    pub total_bookmarks: Option<u64>,
    pub source_tags: Vec<String>,
    pub best_tag_rank: Option<usize>,
    pub median_like_score: Option<f64>,
    pub ranking_score: Option<f64>,
}

#[derive(Debug, Clone)]
struct SearchCandidate {
    illust: Illust,
    source_tags: Vec<String>,
    best_tag_rank: usize,
    median_like_score: f64,
    ranking_score: f64,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct SearchFilterCounts {
    nsfw: usize,
    excluded_tag: usize,
    aspect_ratio: usize,
}

fn normalize_tags(raw: &[String]) -> Vec<String> {
    let mut normalized: Vec<String> = Vec::new();
    for raw_tag in raw {
        let tag = raw_tag.trim();
        if !tag.is_empty() && !normalized.iter().any(|existing| existing == tag) {
            normalized.push(tag.to_string());
        }
    }
    normalized
}

fn normalize_tag_filters(
    raw_tags: &[String],
    raw_exclude_tags: &[String],
) -> Result<(Vec<String>, Vec<String>), String> {
    let tags = normalize_tags(raw_tags);
    let exclude_tags = normalize_tags(raw_exclude_tags);
    if tags.is_empty() {
        return Err("feed_mode=tag_search requires at least one [tag_feed].tags entry".to_string());
    }
    if let Some(overlap) = tags.iter().find(|tag| exclude_tags.contains(tag)) {
        return Err(format!(
            "tag_feed tag {overlap:?} cannot appear in both tags and exclude_tags"
        ));
    }
    Ok((tags, exclude_tags))
}

fn should_filter_excluded_tag(illust: &Illust, exclude_tags: &[String]) -> bool {
    illust.tags.iter().any(|illust_tag| {
        exclude_tags
            .iter()
            .any(|excluded| excluded == &illust_tag.name)
    })
}

fn should_filter_aspect_ratio(
    illust: &Illust,
    aspect_ratio: &crate::config::AspectRatioFilter,
) -> bool {
    use crate::config::AspectRatioFilter;

    match aspect_ratio {
        AspectRatioFilter::Any => false,
        AspectRatioFilter::Horizontal => !matches!(
            (illust.width, illust.height),
            (Some(width), Some(height)) if width > 0 && height > 0 && width > height
        ),
        AspectRatioFilter::Vertical => !matches!(
            (illust.width, illust.height),
            (Some(width), Some(height)) if width > 0 && height > 0 && height > width
        ),
    }
}

fn should_filter_nsfw(illust: &Illust, avoid_nsfw: bool) -> bool {
    avoid_nsfw && illust.x_restrict != Some(0)
}

fn bookmark_count(illust: &Illust) -> u64 {
    illust.total_bookmarks.unwrap_or(0)
}

fn push_slides(
    out: &mut Vec<Slide>,
    illust: &Illust,
    max_pages: usize,
    source_tags: &[String],
    best_tag_rank: Option<usize>,
    median_like_score: Option<f64>,
    ranking_score: Option<f64>,
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
            user_id: illust.user.id,
            create_date: illust.create_date.clone(),
            caption: illust.caption.clone(),
            tags: illust.tags.clone(),
            width: illust.width,
            height: illust.height,
            total_views: illust.total_view,
            x_restrict: illust.x_restrict,
            is_followed: illust.user.is_followed,
            is_bookmarked: illust.is_bookmarked,
            image_url: url,
            page: i as u32 + 1,
            page_count: illust.page_count,
            total_bookmarks: illust.total_bookmarks,
            source_tags: source_tags.to_vec(),
            best_tag_rank,
            median_like_score,
            ranking_score,
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
    avoid_nsfw: bool,
) -> Result<Vec<Slide>, String> {
    let today = Local::now().date_naive();
    let yesterday = today - Duration::days(1);

    let mut slides: Vec<Slide> = Vec::new();
    let mut fallback: Vec<Slide> = Vec::new();
    let mut url = FOLLOW_URL.to_string();
    let mut page = 1usize;

    loop {
        let started = Instant::now();
        let host = url_host(&url);
        let response = client
            .get(&url)
            .header("User-Agent", crate::auth::USER_AGENT)
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept-Language", "en-US")
            .send()
            .await;
        let response = match response {
            Ok(response) => response,
            Err(err) => {
                log::error!(
                    "event=api_timing operation=following_feed_page outcome=failure stage=request page={} url_host={:?} duration_ms={} error={:?}",
                    page,
                    host,
                    started.elapsed().as_millis(),
                    err.to_string()
                );
                return Err(format!("feed request failed: {err}"));
            }
        };
        let status = response.status();
        let body = match response.text().await {
            Ok(body) => body,
            Err(err) => {
                log::error!(
                    "event=api_timing operation=following_feed_page outcome=failure stage=body page={} url_host={:?} status={} duration_ms={} error={:?}",
                    page,
                    host,
                    status.as_u16(),
                    started.elapsed().as_millis(),
                    err.to_string()
                );
                return Err(format!("feed body read failed: {err}"));
            }
        };
        if !status.is_success() {
            log::error!(
                "event=api_timing operation=following_feed_page outcome=failure stage=response page={} url_host={:?} status={} duration_ms={}",
                page,
                host,
                status.as_u16(),
                started.elapsed().as_millis()
            );
            return Err(format!("feed request failed ({status})"));
        }
        let resp: IllustResponse = match serde_json::from_str(&body) {
            Ok(resp) => resp,
            Err(err) => {
                log::error!(
                    "event=api_timing operation=following_feed_page outcome=failure stage=parse page={} url_host={:?} status={} duration_ms={} error={:?}",
                    page,
                    host,
                    status.as_u16(),
                    started.elapsed().as_millis(),
                    err.to_string()
                );
                return Err(format!("feed parse failed: {err}"));
            }
        };
        log::info!(
            "event=api_timing operation=following_feed_page outcome=success page={} url_host={:?} status={} items={} duration_ms={}",
            page,
            host,
            status.as_u16(),
            resp.illusts.len(),
            started.elapsed().as_millis()
        );

        if resp.illusts.is_empty() {
            break;
        }

        let mut reached_older = false;
        let mut filtered_nsfw = 0usize;
        for illust in &resp.illusts {
            let dt = DateTime::parse_from_rfc3339(&illust.create_date)
                .map_err(|e| format!("bad create_date {}: {e}", illust.create_date))?;
            let date = dt.with_timezone(&Local).date_naive();

            if date < yesterday {
                reached_older = true;
                break;
            }
            if should_filter_nsfw(illust, avoid_nsfw) {
                filtered_nsfw += 1;
                continue;
            }

            if date == yesterday {
                push_slides(
                    &mut slides,
                    illust,
                    max_pages_per_post,
                    &[],
                    None,
                    None,
                    None,
                );
            } else if date >= today {
                push_slides(
                    &mut fallback,
                    illust,
                    max_pages_per_post,
                    &[],
                    None,
                    None,
                    None,
                );
            }
        }
        if filtered_nsfw > 0 {
            log::info!(
                "event=nsfw_filter feed_mode=following_daily page={} filtered={} policy=explicit_general_only",
                page,
                filtered_nsfw
            );
        }

        if reached_older {
            break;
        }
        match resp.next_url {
            Some(next) => {
                url = next;
                page += 1;
            }
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
    avoid_nsfw: bool,
) -> Result<Vec<Slide>, String> {
    let (tags, exclude_tags) = normalize_tag_filters(&tag_cfg.tags, &tag_cfg.exclude_tags)?;

    let range_days = tag_cfg.range_days.clamp(1, 366);
    let today = Local::now().date_naive();
    let start = today - Duration::days(range_days.saturating_sub(1));
    let end = today;
    let max_results_per_tag = tag_cfg.max_results_per_tag.max(1);
    let max_search_pages = tag_cfg.max_search_pages_per_tag.max(1);
    let recency_decay_lambda = valid_recency_decay_lambda(tag_cfg.recency_decay_lambda);

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
            avoid_nsfw,
            &exclude_tags,
            &tag_cfg.aspect_ratio,
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
                            avoid_nsfw,
                            &exclude_tags,
                            &tag_cfg.aspect_ratio,
                        )
                        .await?;
                        local.sort_by(|a, b| {
                            bookmark_count(&b.illust)
                                .cmp(&bookmark_count(&a.illust))
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
        candidates.retain(|candidate| bookmark_count(&candidate.illust) >= tag_cfg.min_bookmarks);
        assign_tag_metrics(tag, &mut candidates, recency_decay_lambda);

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
                    existing.ranking_score = existing.ranking_score.max(candidate.ranking_score);
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
                .then_with(|| bookmark_count(&b.illust).cmp(&bookmark_count(&a.illust)))
                .then_with(|| b.illust.id.cmp(&a.illust.id))
        }),
        "median_like_ratio" => candidates.sort_by(|a, b| {
            b.ranking_score
                .partial_cmp(&a.ranking_score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| bookmark_count(&b.illust).cmp(&bookmark_count(&a.illust)))
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
            Some(candidate.ranking_score),
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
    avoid_nsfw: bool,
    exclude_tags: &[String],
    aspect_ratio: &crate::config::AspectRatioFilter,
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
    for page in 1..=page_limit {
        let resp = get_search_page(client, access_token, &url, tag, sort, page).await?;
        let filtered = append_search_candidates(
            &mut out,
            resp.illusts,
            result_limit,
            avoid_nsfw,
            exclude_tags,
            aspect_ratio,
        );
        if filtered.nsfw > 0 {
            log::info!(
                "event=nsfw_filter feed_mode=tag_search tag={:?} sort={:?} page={} filtered={} policy=explicit_general_only",
                tag,
                sort,
                page,
                filtered.nsfw
            );
        }
        if filtered.excluded_tag > 0 {
            log::info!(
                "event=tag_exclusion_filter feed_mode=tag_search tag={:?} sort={:?} page={} filtered={} configured_exclusions={}",
                tag,
                sort,
                page,
                filtered.excluded_tag,
                exclude_tags.len()
            );
        }
        if filtered.aspect_ratio > 0 {
            log::info!(
                "event=aspect_ratio_filter feed_mode=tag_search tag={:?} sort={:?} page={} filtered={} configured_filter={:?}",
                tag,
                sort,
                page,
                filtered.aspect_ratio,
                aspect_ratio
            );
        }
        if out.len() >= result_limit {
            return Ok(out);
        }
        match resp.next_url {
            Some(next) => url = next,
            None => break,
        }
    }
    Ok(out)
}

fn append_search_candidates(
    out: &mut Vec<SearchCandidate>,
    illusts: Vec<Illust>,
    result_limit: usize,
    avoid_nsfw: bool,
    exclude_tags: &[String],
    aspect_ratio: &crate::config::AspectRatioFilter,
) -> SearchFilterCounts {
    if out.len() >= result_limit {
        return SearchFilterCounts::default();
    }
    let mut filtered = SearchFilterCounts::default();
    for illust in illusts {
        if should_filter_nsfw(&illust, avoid_nsfw) {
            filtered.nsfw += 1;
            continue;
        }
        if should_filter_excluded_tag(&illust, exclude_tags) {
            filtered.excluded_tag += 1;
            continue;
        }
        if should_filter_aspect_ratio(&illust, aspect_ratio) {
            filtered.aspect_ratio += 1;
            continue;
        }
        out.push(SearchCandidate {
            illust,
            source_tags: Vec::new(),
            best_tag_rank: usize::MAX,
            median_like_score: 0.0,
            ranking_score: 0.0,
        });
        if out.len() >= result_limit {
            break;
        }
    }
    filtered
}

fn assign_tag_metrics(tag: &str, candidates: &mut [SearchCandidate], recency_decay_lambda: f64) {
    let sample_median = sample_median_bookmarks(candidates);
    for (idx, candidate) in candidates.iter_mut().enumerate() {
        candidate.source_tags = vec![tag.to_string()];
        candidate.best_tag_rank = idx + 1;
        candidate.median_like_score =
            median_like_score(bookmark_count(&candidate.illust), sample_median);
        candidate.ranking_score =
            candidate.median_like_score * recency_decay(&candidate.illust, recency_decay_lambda);
    }
}

fn valid_recency_decay_lambda(raw: f64) -> f64 {
    if raw.is_finite() && raw > 0.0 {
        raw
    } else {
        0.0
    }
}

fn recency_decay(illust: &Illust, lambda: f64) -> f64 {
    if lambda <= 0.0 {
        return 1.0;
    }
    let age_days = DateTime::parse_from_rfc3339(&illust.create_date)
        .ok()
        .map(|dt| {
            Local::now()
                .signed_duration_since(dt.with_timezone(&Local))
                .num_seconds()
                .max(0) as f64
                / 86_400.0
        })
        .unwrap_or(0.0);
    (-lambda * age_days).exp()
}

fn sample_median_bookmarks(candidates: &[SearchCandidate]) -> f64 {
    if candidates.is_empty() {
        return 0.0;
    }
    let mut likes: Vec<u64> = candidates
        .iter()
        .map(|c| bookmark_count(&c.illust))
        .collect();
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
        bookmark_count(&b.illust)
            .cmp(&bookmark_count(&a.illust))
            .then_with(|| b.illust.id.cmp(&a.illust.id))
    });
}

async fn get_search_page(
    client: &reqwest::Client,
    access_token: &str,
    url: &str,
    tag: &str,
    sort: &str,
    page: usize,
) -> Result<IllustResponse, String> {
    let started = Instant::now();
    let host = url_host(url);
    let resp = client
        .get(url)
        .header("User-Agent", crate::auth::USER_AGENT)
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Accept-Language", "en-US")
        .send()
        .await;
    let resp = match resp {
        Ok(resp) => resp,
        Err(err) => {
            log::error!(
                "event=api_timing operation=tag_search_page outcome=failure stage=request tag={:?} sort={:?} page={} url_host={:?} duration_ms={} error={:?}",
                tag,
                sort,
                page,
                host,
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("tag search request failed for {tag:?}: {err}"));
        }
    };

    let status = resp.status();
    let body = match resp.text().await {
        Ok(body) => body,
        Err(err) => {
            log::error!(
                "event=api_timing operation=tag_search_page outcome=failure stage=body tag={:?} sort={:?} page={} url_host={:?} status={} duration_ms={} error={:?}",
                tag,
                sort,
                page,
                host,
                status.as_u16(),
                started.elapsed().as_millis(),
                err.to_string()
            );
            return Err(format!("tag search body read failed for {tag:?}: {err}"));
        }
    };
    if !status.is_success() {
        log::error!(
            "event=api_timing operation=tag_search_page outcome=failure stage=response tag={:?} sort={:?} page={} url_host={:?} status={} duration_ms={}",
            tag,
            sort,
            page,
            host,
            status.as_u16(),
            started.elapsed().as_millis()
        );
        return Err(format!(
            "tag search failed ({status}) for {tag:?} with sort={sort}: {body}"
        ));
    }
    match serde_json::from_str::<IllustResponse>(&body) {
        Ok(resp) => {
            log::info!(
                "event=api_timing operation=tag_search_page outcome=success tag={:?} sort={:?} page={} url_host={:?} status={} items={} duration_ms={}",
                tag,
                sort,
                page,
                host,
                status.as_u16(),
                resp.illusts.len(),
                started.elapsed().as_millis()
            );
            Ok(resp)
        }
        Err(err) => {
            log::error!(
                "event=api_timing operation=tag_search_page outcome=failure stage=parse tag={:?} sort={:?} page={} url_host={:?} status={} duration_ms={} error={:?}",
                tag,
                sort,
                page,
                host,
                status.as_u16(),
                started.elapsed().as_millis(),
                err.to_string()
            );
            Err(format!(
                "tag search parse failed for {tag:?}: {err}; body={body}"
            ))
        }
    }
}

fn url_host(url: &str) -> String {
    reqwest::Url::parse(url)
        .ok()
        .and_then(|url| url.host_str().map(ToOwned::to_owned))
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(test)]
mod tests {
    use crate::config::AspectRatioFilter;

    use super::{
        append_search_candidates, normalize_tag_filters, push_slides, should_filter_aspect_ratio,
        should_filter_excluded_tag, should_filter_nsfw, Illust,
    };

    fn test_illust(user_extra: &str, illust_extra: &str) -> Illust {
        serde_json::from_str(&format!(
            r#"{{
                "id": 42,
                "title": "Test work",
                "create_date": "2026-07-15T12:00:00+10:00",
                "page_count": 1,
                "user": {{
                    "id": 99,
                    "name": "Test artist"
                    {user_extra}
                }},
                "meta_single_page": {{
                    "original_image_url": "https://i.pximg.net/img-original/test.jpg"
                }}
                {illust_extra}
            }}"#
        ))
        .unwrap()
    }

    #[test]
    fn slide_keeps_author_identity_and_follow_state() {
        let illust = test_illust(", \"is_followed\": true", ", \"is_bookmarked\": true");
        let mut slides = Vec::new();

        push_slides(&mut slides, &illust, 1, &[], None, None, None);

        assert_eq!(slides.len(), 1);
        assert_eq!(slides[0].user_id, 99);
        assert_eq!(slides[0].is_followed, Some(true));
        assert_eq!(slides[0].is_bookmarked, Some(true));
    }

    #[test]
    fn slide_keeps_populated_illustration_metadata() {
        let illust = test_illust(
            "",
            r#", "caption": "A test caption", "tags": [
                {"name": "風景", "translated_name": "scenery"},
                {"name": "空"}
            ], "width": 2400, "height": 1600, "total_bookmarks": 123,
            "total_view": 456, "x_restrict": 1"#,
        );
        let mut slides = Vec::new();

        push_slides(&mut slides, &illust, 1, &[], None, None, None);

        assert_eq!(slides[0].create_date, "2026-07-15T12:00:00+10:00");
        assert_eq!(slides[0].caption, "A test caption");
        assert_eq!(slides[0].tags.len(), 2);
        assert_eq!(slides[0].tags[0].name, "風景");
        assert_eq!(
            slides[0].tags[0].translated_name.as_deref(),
            Some("scenery")
        );
        assert_eq!(slides[0].tags[1].name, "空");
        assert_eq!(slides[0].tags[1].translated_name, None);
        assert_eq!(slides[0].width, Some(2400));
        assert_eq!(slides[0].height, Some(1600));
        assert_eq!(slides[0].total_bookmarks, Some(123));
        assert_eq!(slides[0].total_views, Some(456));
        assert_eq!(slides[0].x_restrict, Some(1));
    }

    #[test]
    fn slide_preserves_explicit_zero_counts() {
        let illust = test_illust("", r#", "total_bookmarks": 0, "total_view": 0"#);
        let mut slides = Vec::new();

        push_slides(&mut slides, &illust, 1, &[], None, None, None);

        assert_eq!(slides[0].total_bookmarks, Some(0));
        assert_eq!(slides[0].total_views, Some(0));
    }

    #[test]
    fn missing_follow_state_is_preserved_as_unknown() {
        let illust = test_illust("", "");
        let mut slides = Vec::new();

        push_slides(&mut slides, &illust, 1, &[], None, None, None);

        assert_eq!(slides[0].is_followed, None);
        assert_eq!(slides[0].is_bookmarked, None);
        assert_eq!(slides[0].caption, "");
        assert!(slides[0].tags.is_empty());
        assert_eq!(slides[0].width, None);
        assert_eq!(slides[0].height, None);
        assert_eq!(slides[0].total_bookmarks, None);
        assert_eq!(slides[0].total_views, None);
        assert_eq!(slides[0].x_restrict, None);
    }

    #[test]
    fn multi_page_slides_share_illustration_metadata() {
        let illust: Illust = serde_json::from_str(
            r#"{
                "id": 42,
                "title": "Multi-page work",
                "create_date": "2026-07-15T12:00:00+10:00",
                "caption": "Shared caption",
                "tags": [{"name": "series", "translated_name": "Series"}],
                "width": 1200,
                "height": 1800,
                "page_count": 2,
                "total_bookmarks": 0,
                "total_view": 10,
                "x_restrict": 0,
                "user": {"id": 99, "name": "Test artist"},
                "meta_pages": [
                    {"image_urls": {"original": "https://i.pximg.net/page-1.jpg"}},
                    {"image_urls": {"large": "https://i.pximg.net/page-2.jpg"}}
                ]
            }"#,
        )
        .unwrap();
        let mut slides = Vec::new();

        assert!(!should_filter_aspect_ratio(
            &illust,
            &AspectRatioFilter::Vertical
        ));
        assert!(should_filter_aspect_ratio(
            &illust,
            &AspectRatioFilter::Horizontal
        ));
        push_slides(&mut slides, &illust, 2, &[], None, None, None);

        assert_eq!(slides.len(), 2);
        assert_eq!(slides[0].page, 1);
        assert_eq!(slides[1].page, 2);
        assert_eq!(slides[0].caption, "Shared caption");
        assert_eq!(slides[1].caption, "Shared caption");
        assert_eq!(slides[0].tags, slides[1].tags);
        assert_eq!(slides[0].width, slides[1].width);
        assert_eq!(slides[0].height, slides[1].height);
        assert_eq!(slides[0].total_bookmarks, slides[1].total_bookmarks);
        assert_eq!(slides[0].total_views, slides[1].total_views);
        assert_eq!(slides[0].x_restrict, slides[1].x_restrict);
    }

    #[test]
    fn nsfw_filter_is_opt_in_and_requires_an_explicit_general_rating() {
        let general = test_illust("", ", \"x_restrict\": 0");
        let r18 = test_illust("", ", \"x_restrict\": 1");
        let r18g = test_illust("", ", \"x_restrict\": 2");
        let unknown = test_illust("", ", \"x_restrict\": 99");
        let missing = test_illust("", "");

        assert!(!should_filter_nsfw(&general, false));
        assert!(!should_filter_nsfw(&r18, false));
        assert!(!should_filter_nsfw(&r18g, false));
        assert!(!should_filter_nsfw(&unknown, false));
        assert!(!should_filter_nsfw(&missing, false));

        assert!(!should_filter_nsfw(&general, true));
        assert!(should_filter_nsfw(&r18, true));
        assert!(should_filter_nsfw(&r18g, true));
        assert!(should_filter_nsfw(&unknown, true));
        assert!(should_filter_nsfw(&missing, true));
    }

    #[test]
    fn aspect_ratio_filter_matches_work_level_orientation() {
        let horizontal = test_illust("", r#", "width": 1600, "height": 900"#);
        let vertical = test_illust("", r#", "width": 900, "height": 1600"#);
        let square = test_illust("", r#", "width": 1000, "height": 1000"#);
        let missing = test_illust("", "");
        let zero = test_illust("", r#", "width": 0, "height": 1000"#);

        assert!(!should_filter_aspect_ratio(
            &horizontal,
            &AspectRatioFilter::Any
        ));
        assert!(!should_filter_aspect_ratio(
            &missing,
            &AspectRatioFilter::Any
        ));
        assert!(!should_filter_aspect_ratio(&zero, &AspectRatioFilter::Any));

        assert!(!should_filter_aspect_ratio(
            &horizontal,
            &AspectRatioFilter::Horizontal
        ));
        assert!(should_filter_aspect_ratio(
            &vertical,
            &AspectRatioFilter::Horizontal
        ));
        assert!(should_filter_aspect_ratio(
            &square,
            &AspectRatioFilter::Horizontal
        ));
        assert!(should_filter_aspect_ratio(
            &missing,
            &AspectRatioFilter::Horizontal
        ));
        assert!(should_filter_aspect_ratio(
            &zero,
            &AspectRatioFilter::Horizontal
        ));

        assert!(!should_filter_aspect_ratio(
            &vertical,
            &AspectRatioFilter::Vertical
        ));
        assert!(should_filter_aspect_ratio(
            &horizontal,
            &AspectRatioFilter::Vertical
        ));
        assert!(should_filter_aspect_ratio(
            &square,
            &AspectRatioFilter::Vertical
        ));
        assert!(should_filter_aspect_ratio(
            &missing,
            &AspectRatioFilter::Vertical
        ));
        assert!(should_filter_aspect_ratio(
            &zero,
            &AspectRatioFilter::Vertical
        ));
    }

    #[test]
    fn filtered_search_results_do_not_consume_the_accepted_result_limit() {
        let restricted = test_illust("", ", \"x_restrict\": 1");
        let general = test_illust("", ", \"x_restrict\": 0");
        let mut candidates = Vec::new();

        let filtered = append_search_candidates(
            &mut candidates,
            vec![restricted, general],
            1,
            true,
            &[],
            &AspectRatioFilter::Any,
        );

        assert_eq!(filtered.nsfw, 1);
        assert_eq!(filtered.excluded_tag, 0);
        assert_eq!(filtered.aspect_ratio, 0);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].illust.x_restrict, Some(0));
    }

    #[test]
    fn tag_filters_are_trimmed_deduplicated_and_must_not_overlap() {
        let (tags, exclude_tags) = normalize_tag_filters(
            &[
                " landscape ".to_string(),
                String::new(),
                "original".to_string(),
                "landscape".to_string(),
            ],
            &[
                " AI生成 ".to_string(),
                "R-18".to_string(),
                "AI生成".to_string(),
            ],
        )
        .unwrap();

        assert_eq!(tags, ["landscape", "original"]);
        assert_eq!(exclude_tags, ["AI生成", "R-18"]);

        let err = normalize_tag_filters(&["landscape".to_string()], &[" landscape ".to_string()])
            .unwrap_err();
        assert!(err.contains("both tags and exclude_tags"));
    }

    #[test]
    fn excluded_tag_matching_uses_canonical_exact_names_only() {
        let illust = test_illust(
            "",
            r#", "tags": [
                {"name": "AI生成", "translated_name": "AI-generated"},
                {"name": "風景"}
            ]"#,
        );

        assert!(should_filter_excluded_tag(&illust, &["AI生成".to_string()]));
        assert!(!should_filter_excluded_tag(&illust, &["AI".to_string()]));
        assert!(!should_filter_excluded_tag(
            &illust,
            &["AI-generated".to_string()]
        ));
        assert!(!should_filter_excluded_tag(&illust, &[]));
    }

    #[test]
    fn excluded_search_results_do_not_consume_the_accepted_result_limit() {
        let excluded = test_illust(
            "",
            r#", "tags": [{"name": "AI生成", "translated_name": "AI-generated"}]"#,
        );
        let allowed = test_illust("", r#", "tags": [{"name": "風景"}]"#);
        let mut candidates = Vec::new();

        let filtered = append_search_candidates(
            &mut candidates,
            vec![excluded, allowed],
            1,
            false,
            &["AI生成".to_string()],
            &AspectRatioFilter::Any,
        );

        assert_eq!(filtered.nsfw, 0);
        assert_eq!(filtered.excluded_tag, 1);
        assert_eq!(filtered.aspect_ratio, 0);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].illust.tags[0].name, "風景");
    }

    #[test]
    fn aspect_ratio_filtered_results_do_not_consume_the_accepted_result_limit() {
        let vertical = test_illust("", r#", "width": 900, "height": 1600"#);
        let horizontal = test_illust("", r#", "width": 1600, "height": 900"#);
        let mut candidates = Vec::new();

        let filtered = append_search_candidates(
            &mut candidates,
            vec![vertical, horizontal],
            1,
            false,
            &[],
            &AspectRatioFilter::Horizontal,
        );

        assert_eq!(filtered.nsfw, 0);
        assert_eq!(filtered.excluded_tag, 0);
        assert_eq!(filtered.aspect_ratio, 1);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].illust.width, Some(1600));
        assert_eq!(candidates[0].illust.height, Some(900));
    }

    #[test]
    fn nsfw_excluded_tag_and_aspect_ratio_filters_work_together() {
        let restricted = test_illust("", ", \"x_restrict\": 1");
        let excluded = test_illust("", r#", "tags": [{"name": "AI生成"}], "x_restrict": 0"#);
        let vertical = test_illust("", r#", "width": 900, "height": 1600, "x_restrict": 0"#);
        let allowed = test_illust("", r#", "width": 1600, "height": 900, "x_restrict": 0"#);
        let mut candidates = Vec::new();

        let filtered = append_search_candidates(
            &mut candidates,
            vec![restricted, excluded, vertical, allowed],
            1,
            true,
            &["AI生成".to_string()],
            &AspectRatioFilter::Horizontal,
        );

        assert_eq!(filtered.nsfw, 1);
        assert_eq!(filtered.excluded_tag, 1);
        assert_eq!(filtered.aspect_ratio, 1);
        assert_eq!(candidates.len(), 1);
        assert!(candidates[0].illust.tags.is_empty());
        assert_eq!(candidates[0].illust.width, Some(1600));
    }
}
