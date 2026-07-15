mod auth;
mod bookmark;
mod cache;
mod config;
mod follow;
mod image;
mod pixiv;
mod save;
mod system;

use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

#[derive(Default)]
struct VersionedIds {
    next_generation: u64,
    entries: HashMap<u64, u64>,
}

impl VersionedIds {
    fn contains(&self, id: u64) -> bool {
        self.entries.contains_key(&id)
    }

    fn remember(&mut self, id: u64) {
        self.next_generation = self.next_generation.wrapping_add(1);
        if self.next_generation == 0 {
            self.next_generation = 1;
        }
        self.entries.insert(id, self.next_generation);
    }

    fn snapshot(&self) -> HashMap<u64, u64> {
        self.entries.clone()
    }

    fn forget_if_unchanged(&mut self, id: u64, generation: u64) -> bool {
        if self.entries.get(&id) != Some(&generation) {
            return false;
        }
        self.entries.remove(&id);
        true
    }
}

#[derive(Default)]
struct FollowedAuthors(Mutex<VersionedIds>);

impl FollowedAuthors {
    fn contains(&self, user_id: u64) -> bool {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(user_id)
    }

    fn remember(&self, user_id: u64) {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remember(user_id);
    }

    fn snapshot(&self) -> HashMap<u64, u64> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .snapshot()
    }

    fn forget_if_unchanged(&self, user_id: u64, generation: u64) -> bool {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .forget_if_unchanged(user_id, generation)
    }
}

#[derive(Default)]
struct BookmarkedIllustrations(Mutex<VersionedIds>);

impl BookmarkedIllustrations {
    fn contains(&self, illust_id: u64) -> bool {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(illust_id)
    }

    fn remember(&self, illust_id: u64) {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remember(illust_id);
    }

    fn snapshot(&self) -> HashMap<u64, u64> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .snapshot()
    }

    fn forget_if_unchanged(&self, illust_id: u64, generation: u64) -> bool {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .forget_if_unchanged(illust_id, generation)
    }
}

#[derive(Serialize)]
pub struct SlideShow {
    slides: Vec<pixiv::Slide>,
    interval_secs: u64,
    /// The day the slides are from (yesterday, local), for the caption.
    day: String,
    /// The configured feed mode, for frontend copy and status text.
    feed_mode: String,
    /// Human-readable range/source label for empty states.
    label: String,
    help: HelpInfo,
}

#[derive(Serialize)]
pub struct HelpInfo {
    configured_feed_mode: String,
    slide_interval_secs: u64,
    max_pages_per_post: usize,
    avoid_nsfw: bool,
    bookmark_on_save: bool,
    bookmark_restrict: String,
    bookmark_tags: Vec<String>,
    following_daily: FollowingDailyHelp,
    tag_search: TagSearchHelp,
}

#[derive(Serialize)]
pub struct ApplicationInfo {
    version: String,
    build_date: String,
}

#[derive(Serialize)]
pub struct SaveIllustrationResult {
    message: String,
    is_bookmarked: Option<bool>,
    is_followed: Option<bool>,
}

impl SaveIllustrationResult {
    fn new(message: String, is_bookmarked: Option<bool>, is_followed: Option<bool>) -> Self {
        Self {
            message,
            is_bookmarked,
            is_followed,
        }
    }
}

#[derive(Serialize)]
pub struct FollowingDailyHelp {
    day: String,
    empty_day_fallback: bool,
}

#[derive(Serialize)]
pub struct TagSearchHelp {
    follow_when_bookmark: bool,
    tags: Vec<String>,
    range_days: i64,
    search_target: String,
    sort: String,
    max_results_per_tag: usize,
    min_bookmarks: u64,
    max_search_pages_per_tag: usize,
    max_slides: usize,
    fallback_without_popular_sort: String,
    merge_strategy: String,
    recency_decay_lambda: f64,
}

fn build_date_from_epoch(epoch: i64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(epoch, 0)
        .expect("embedded build timestamp is outside the supported range")
        .format("%Y-%m-%d")
        .to_string()
}

/// Version and build information embedded in this application binary.
#[tauri::command]
fn application_info(app: tauri::AppHandle) -> ApplicationInfo {
    let build_epoch = env!("PIXIV_SLIDES_BUILD_EPOCH")
        .parse::<i64>()
        .expect("PIXIV_SLIDES_BUILD_EPOCH must be a Unix timestamp");

    ApplicationInfo {
        version: app.package_info().version.to_string(),
        build_date: build_date_from_epoch(build_epoch),
    }
}

/// Load config, refresh the token, and fetch the configured feed.
#[tauri::command]
async fn load_slideshow(
    mode: Option<String>,
    followed_authors: tauri::State<'_, FollowedAuthors>,
    bookmarked_illustrations: tauri::State<'_, BookmarkedIllustrations>,
) -> Result<SlideShow, String> {
    let followed_at_load = followed_authors.snapshot();
    let bookmarked_at_load = bookmarked_illustrations.snapshot();
    let cfg = config::load()?;
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("http client build failed: {e}"))?;

    let token = auth::refresh(&client, &cfg.refresh_token).await?;
    let yesterday = (chrono::Local::now().date_naive() - chrono::Duration::days(1)).to_string();
    let configured_feed_mode = cfg.feed_mode.trim().to_string();
    let feed_mode = mode
        .as_deref()
        .map(str::trim)
        .filter(|mode| !mode.is_empty())
        .unwrap_or(configured_feed_mode.as_str());

    let (slides, label, canonical_feed_mode) = match feed_mode {
        "following_daily" | "daily" => {
            let slides = pixiv::fetch_yesterday_slides(
                &client,
                &token.access_token,
                cfg.max_pages_per_post,
                cfg.empty_day_fallback,
                cfg.avoid_nsfw,
            )
            .await?;
            (slides, yesterday.clone(), "following_daily")
        }
        "tag_search" | "tags" => {
            let slides = pixiv::fetch_tag_slides(
                &client,
                &token.access_token,
                &cfg.tag_feed,
                cfg.max_pages_per_post,
                cfg.avoid_nsfw,
            )
            .await?;
            let range_days = cfg.tag_feed.range_days.clamp(1, 366);
            let today = chrono::Local::now().date_naive();
            let start = today - chrono::Duration::days(range_days.saturating_sub(1));
            let tags = cfg
                .tag_feed
                .tags
                .iter()
                .map(|tag| tag.trim())
                .filter(|tag| !tag.is_empty())
                .collect::<Vec<_>>()
                .join(", ");
            (slides, format!("{tags} · {start}..{today}"), "tag_search")
        }
        other => {
            return Err(format!(
                "unsupported feed_mode={other:?}; use \"following_daily\" or \"tag_search\""
            ));
        }
    };

    reconcile_session_state(
        &slides,
        &followed_authors,
        &bookmarked_illustrations,
        &followed_at_load,
        &bookmarked_at_load,
    );

    Ok(SlideShow {
        slides,
        interval_secs: cfg.slide_interval_secs,
        day: yesterday.clone(),
        feed_mode: canonical_feed_mode.to_string(),
        label,
        help: HelpInfo {
            configured_feed_mode,
            slide_interval_secs: cfg.slide_interval_secs,
            max_pages_per_post: cfg.max_pages_per_post,
            avoid_nsfw: cfg.avoid_nsfw,
            bookmark_on_save: cfg.bookmark_on_save,
            bookmark_restrict: cfg.bookmark_restrict,
            bookmark_tags: cfg.bookmark_tags,
            following_daily: FollowingDailyHelp {
                day: yesterday,
                empty_day_fallback: cfg.empty_day_fallback,
            },
            tag_search: TagSearchHelp {
                follow_when_bookmark: cfg.tag_feed.follow_when_bookmark,
                tags: cfg.tag_feed.tags,
                range_days: cfg.tag_feed.range_days.clamp(1, 366),
                search_target: cfg.tag_feed.search_target,
                sort: cfg.tag_feed.sort,
                max_results_per_tag: cfg.tag_feed.max_results_per_tag,
                min_bookmarks: cfg.tag_feed.min_bookmarks,
                max_search_pages_per_tag: cfg.tag_feed.max_search_pages_per_tag,
                max_slides: cfg.tag_feed.max_slides,
                fallback_without_popular_sort: cfg.tag_feed.fallback_without_popular_sort,
                merge_strategy: cfg.tag_feed.merge_strategy,
                recency_decay_lambda: cfg.tag_feed.recency_decay_lambda,
            },
        },
    })
}

fn reconcile_session_state(
    slides: &[pixiv::Slide],
    followed_authors: &FollowedAuthors,
    bookmarked_illustrations: &BookmarkedIllustrations,
    followed_at_load: &HashMap<u64, u64>,
    bookmarked_at_load: &HashMap<u64, u64>,
) {
    for slide in slides {
        let removed_bookmark = bookmarked_at_load
            .get(&slide.illust_id)
            .is_some_and(|generation| {
                slide.is_bookmarked == Some(false)
                    && bookmarked_illustrations.forget_if_unchanged(slide.illust_id, *generation)
            });
        if removed_bookmark {
            log::info!(
                "event=bookmark_state_reconciled illust_id={} state=not_bookmarked source=pixiv",
                slide.illust_id
            );
        }
        let removed_follow = followed_at_load
            .get(&slide.user_id)
            .is_some_and(|generation| {
                slide.is_followed == Some(false)
                    && followed_authors.forget_if_unchanged(slide.user_id, *generation)
            });
        if removed_follow {
            log::info!(
                "event=follow_state_reconciled user_id={} state=not_followed source=pixiv",
                slide.user_id
            );
        }
    }
}

/// System stats for the status bar (polled periodically by the frontend).
#[tauri::command]
fn system_stats() -> system::SystemStats {
    system::collect()
}

/// Save the currently-viewed illustration to the configured folder, and
/// optionally add a Pixiv bookmark and follow its author when configured.
#[tauri::command]
async fn save_illustration(
    slide: save::SaveRequest,
    followed_authors: tauri::State<'_, FollowedAuthors>,
    bookmarked_illustrations: tauri::State<'_, BookmarkedIllustrations>,
) -> Result<SaveIllustrationResult, String> {
    let cfg = config::load()?;
    let dir = save::resolve_dir(&cfg.save_dir);
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("http client build failed: {e}"))?;
    let save_status = match save::save(&client, &slide, &dir).await {
        Ok(status) => status,
        Err(err) => {
            log::info!(
                "event=bookmark_skipped illust_id={} reason=save_failure",
                slide.illust_id
            );
            log::info!(
                "event=follow_skipped user_id={} illust_id={} reason=save_failure",
                slide.user_id,
                slide.illust_id
            );
            return Err(err);
        }
    };

    let pixiv_bookmarked = slide.is_bookmarked == Some(true);
    let session_bookmarked = bookmarked_illustrations.contains(slide.illust_id);
    let mut is_bookmarked = if pixiv_bookmarked || session_bookmarked {
        Some(true)
    } else {
        slide.is_bookmarked
    };
    let pixiv_followed = slide.is_followed == Some(true);
    let session_followed = followed_authors.contains(slide.user_id);
    let mut is_followed = if pixiv_followed || session_followed {
        Some(true)
    } else {
        slide.is_followed
    };

    if !cfg.bookmark_on_save {
        log::info!(
            "event=bookmark_skipped illust_id={} reason=disabled",
            slide.illust_id
        );
        log::info!(
            "event=follow_skipped user_id={} illust_id={} reason=bookmark_disabled",
            slide.user_id,
            slide.illust_id
        );
        return Ok(SaveIllustrationResult::new(
            save_status,
            is_bookmarked,
            is_followed,
        ));
    }

    let already_bookmarked = pixiv_bookmarked || session_bookmarked;
    let follow_configured = should_follow_author(
        &slide.feed_mode,
        cfg.bookmark_on_save,
        cfg.tag_feed.follow_when_bookmark,
        false,
    );
    let unconfigured_follow_reason = if follow_configured {
        None
    } else if slide.feed_mode.trim() != "tag_search" {
        Some("non_tag_feed")
    } else {
        Some("disabled")
    };
    let mut token = None;

    let bookmark_status = if already_bookmarked {
        is_bookmarked = Some(true);
        let source = if pixiv_bookmarked { "pixiv" } else { "session" };
        log::info!(
            "event=bookmark_already_bookmarked illust_id={} source={}",
            slide.illust_id,
            source
        );
        "Already bookmarked".to_string()
    } else {
        let started = Instant::now();
        log::info!(
            "event=bookmark_start illust_id={} restrict={:?} tags_count={}",
            slide.illust_id,
            cfg.bookmark_restrict,
            cfg.bookmark_tags.len()
        );
        let refreshed = match auth::refresh(&client, &cfg.refresh_token).await {
            Ok(token) => token,
            Err(err) => {
                log::error!(
                    "event=bookmark_failure illust_id={} stage=oauth_refresh duration_ms={}",
                    slide.illust_id,
                    started.elapsed().as_millis()
                );
                log::info!(
                    "event=follow_skipped user_id={} illust_id={} reason={}",
                    slide.user_id,
                    slide.illust_id,
                    unconfigured_follow_reason.unwrap_or("bookmark_failure")
                );
                return Ok(SaveIllustrationResult::new(
                    format!("{save_status} · Bookmark failed: {err}"),
                    is_bookmarked,
                    is_followed,
                ));
            }
        };
        let result = bookmark::add(
            &client,
            &refreshed.access_token,
            slide.illust_id,
            &cfg.bookmark_restrict,
            &cfg.bookmark_tags,
        )
        .await;
        match result {
            Ok(bookmark_status) => {
                bookmarked_illustrations.remember(slide.illust_id);
                is_bookmarked = Some(true);
                log::info!(
                    "event=bookmark_success illust_id={} restrict={:?} duration_ms={}",
                    slide.illust_id,
                    cfg.bookmark_restrict,
                    started.elapsed().as_millis()
                );
                token = Some(refreshed);
                bookmark_status
            }
            Err(err) => {
                log::error!(
                    "event=bookmark_failure illust_id={} stage=api duration_ms={} error={:?}",
                    slide.illust_id,
                    started.elapsed().as_millis(),
                    err
                );
                log::info!(
                    "event=follow_skipped user_id={} illust_id={} reason={}",
                    slide.user_id,
                    slide.illust_id,
                    unconfigured_follow_reason.unwrap_or("bookmark_failure")
                );
                return Ok(SaveIllustrationResult::new(
                    format!("{save_status} · Bookmark failed: {err}"),
                    is_bookmarked,
                    is_followed,
                ));
            }
        }
    };
    let status = format!("{save_status} · {bookmark_status}");

    if let Some(reason) = unconfigured_follow_reason {
        log::info!(
            "event=follow_skipped user_id={} illust_id={} reason={}",
            slide.user_id,
            slide.illust_id,
            reason
        );
        return Ok(SaveIllustrationResult::new(
            status,
            is_bookmarked,
            is_followed,
        ));
    }

    if pixiv_followed || session_followed {
        is_followed = Some(true);
        let source = if pixiv_followed { "pixiv" } else { "session" };
        log::info!(
            "event=follow_already_followed user_id={} illust_id={} source={}",
            slide.user_id,
            slide.illust_id,
            source
        );
        return Ok(SaveIllustrationResult::new(
            status,
            is_bookmarked,
            is_followed,
        ));
    }

    let started = Instant::now();
    log::info!(
        "event=follow_start user_id={} illust_id={} artist={:?} restrict=public",
        slide.user_id,
        slide.illust_id,
        slide.artist
    );
    if token.is_none() {
        token = match auth::refresh(&client, &cfg.refresh_token).await {
            Ok(token) => Some(token),
            Err(err) => {
                log::error!(
                    "event=follow_failure user_id={} illust_id={} stage=oauth_refresh duration_ms={}",
                    slide.user_id,
                    slide.illust_id,
                    started.elapsed().as_millis()
                );
                return Ok(SaveIllustrationResult::new(
                    format!("{status} · Follow failed: {err}"),
                    is_bookmarked,
                    is_followed,
                ));
            }
        };
    }
    let token = token.expect("access token must be available before following");
    match follow::add(&client, &token.access_token, slide.user_id).await {
        Ok(follow_status) => {
            followed_authors.remember(slide.user_id);
            is_followed = Some(true);
            log::info!(
                "event=follow_success user_id={} illust_id={} restrict=public duration_ms={}",
                slide.user_id,
                slide.illust_id,
                started.elapsed().as_millis()
            );
            Ok(SaveIllustrationResult::new(
                format!("{status} · {follow_status}"),
                is_bookmarked,
                is_followed,
            ))
        }
        Err(err) => {
            log::error!(
                "event=follow_failure user_id={} illust_id={} stage=api duration_ms={} error={:?}",
                slide.user_id,
                slide.illust_id,
                started.elapsed().as_millis(),
                err
            );
            Ok(SaveIllustrationResult::new(
                format!("{status} · Follow failed: {err}"),
                is_bookmarked,
                is_followed,
            ))
        }
    }
}

fn should_follow_author(
    feed_mode: &str,
    bookmark_on_save: bool,
    follow_when_bookmark: bool,
    already_followed: bool,
) -> bool {
    bookmark_on_save
        && follow_when_bookmark
        && feed_mode.trim() == "tag_search"
        && !already_followed
}

/// Exit cleanly (bound to Escape in the frontend).
#[tauri::command]
fn quit() {
    std::process::exit(0);
}

/// Bail out with a human-readable message when there's no graphical session to
/// draw into. Without this, GTK init fails deep inside tao with an opaque
/// `Failed to initialize GTK backend!` panic — which is baffling when the real
/// cause is simply "you're on SSH / a headless server with no desktop running".
#[cfg(target_os = "linux")]
fn ensure_display() {
    // A usable Wayland socket? WAYLAND_DISPLAY may be an absolute path or a name
    // resolved against XDG_RUNTIME_DIR. A stale env var pointing at a missing
    // socket is the common SSH footgun, so we check the file actually exists.
    let wayland_ok = std::env::var_os("WAYLAND_DISPLAY").is_some_and(|name| {
        let path = std::path::PathBuf::from(&name);
        let resolved = if path.is_absolute() {
            path
        } else {
            match std::env::var_os("XDG_RUNTIME_DIR") {
                Some(dir) => std::path::Path::new(&dir).join(&name),
                None => return false,
            }
        };
        resolved.exists()
    });
    // For X11 we trust a non-empty DISPLAY; the server socket isn't worth stat-ing.
    let x11_ok = std::env::var("DISPLAY").is_ok_and(|d| !d.is_empty());

    if wayland_ok || x11_ok {
        return;
    }

    eprintln!(
        "\n\
         pixiv-slides needs a graphical desktop session to open its window, but\n\
         none was found (no live Wayland socket and no X11 DISPLAY).\n\
         \n\
         This usually means you're on SSH or a headless server that's sitting at\n\
         the login screen. Fixes:\n\
         \n\
           • Log in to the desktop on this machine first, then run it again.\n\
           • Forward the window to your own machine over SSH:\n\
               waypipe ssh <user>@<host> \"cd {} && cargo tauri dev\"\n\
           • Or run it inside a throwaway compositor: cage -- cargo tauri dev\n",
        std::env::current_dir()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| ".".into()),
    );
    std::process::exit(1);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[cfg(target_os = "linux")]
    ensure_display();

    let image_client = reqwest::Client::builder()
        .build()
        .expect("failed to build image http client");

    let cache_dir = cache::cache_dir();
    let cache_max_bytes = config::load()
        .map(|c| c.cache_max_mb)
        .unwrap_or(512)
        .saturating_mul(1024 * 1024);

    // One-shot prune at startup (e.g. if the cap was lowered between runs).
    {
        let dir = cache_dir.clone();
        std::thread::spawn(move || cache::evict_if_over_cap(&dir, cache_max_bytes));
    }

    tauri::Builder::default()
        .manage(FollowedAuthors::default())
        .manage(BookmarkedIllustrations::default())
        .setup(|app| {
            app.handle().plugin(
                tauri_plugin_log::Builder::default()
                    .level(log::LevelFilter::Info)
                    .build(),
            )?;
            Ok(())
        })
        .register_asynchronous_uri_scheme_protocol("pximg", move |_ctx, request, responder| {
            let client = image_client.clone();
            let dir = cache_dir.clone();
            let uri = request.uri().to_string();
            tauri::async_runtime::spawn(async move {
                let response = match image::fetch_image(&client, &uri, &dir, cache_max_bytes).await
                {
                    Ok((bytes, content_type)) => tauri::http::Response::builder()
                        .header("Content-Type", content_type)
                        .header("Access-Control-Allow-Origin", "*")
                        .body(bytes)
                        .unwrap(),
                    Err(err) => tauri::http::Response::builder()
                        .status(502)
                        .body(err.into_bytes())
                        .unwrap(),
                };
                responder.respond(response);
            });
        })
        .invoke_handler(tauri::generate_handler![
            application_info,
            load_slideshow,
            system_stats,
            save_illustration,
            quit
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::{
        build_date_from_epoch, reconcile_session_state, should_follow_author,
        BookmarkedIllustrations, FollowedAuthors,
    };

    #[test]
    fn formats_embedded_build_dates_in_utc() {
        assert_eq!(build_date_from_epoch(0), "1970-01-01");
        assert_eq!(build_date_from_epoch(1_752_537_600), "2025-07-15");
    }

    #[test]
    fn follows_only_unfollowed_tag_feed_authors_after_bookmarking() {
        assert!(should_follow_author("tag_search", true, true, false));
        assert!(!should_follow_author("following_daily", true, true, false));
        assert!(!should_follow_author("tag_search", false, true, false));
        assert!(!should_follow_author("tag_search", true, false, false));
        assert!(!should_follow_author("tag_search", true, true, true));
    }

    #[test]
    fn remembers_successfully_followed_authors_for_the_session() {
        let followed_authors = FollowedAuthors::default();

        assert!(!followed_authors.contains(42));
        followed_authors.remember(42);
        assert!(followed_authors.contains(42));
        assert!(!should_follow_author(
            "tag_search",
            true,
            true,
            followed_authors.contains(42),
        ));
    }

    #[test]
    fn remembers_successfully_bookmarked_illustrations_for_the_session() {
        let bookmarked_illustrations = BookmarkedIllustrations::default();

        assert!(!bookmarked_illustrations.contains(42));
        bookmarked_illustrations.remember(42);
        assert!(bookmarked_illustrations.contains(42));
        assert!(!bookmarked_illustrations.contains(43));
    }

    #[test]
    fn an_existing_bookmark_does_not_block_a_configured_follow() {
        let bookmarked_illustrations = BookmarkedIllustrations::default();
        bookmarked_illustrations.remember(42);

        assert!(bookmarked_illustrations.contains(42));
        assert!(should_follow_author("tag_search", true, true, false));
    }

    #[test]
    fn fresh_negative_pixiv_state_clears_session_mutations() {
        let followed_authors = FollowedAuthors::default();
        let bookmarked_illustrations = BookmarkedIllustrations::default();
        followed_authors.remember(99);
        bookmarked_illustrations.remember(42);
        let followed_at_load = followed_authors.snapshot();
        let bookmarked_at_load = bookmarked_illustrations.snapshot();
        let slides = vec![crate::pixiv::Slide {
            illust_id: 42,
            title: "Work".to_string(),
            artist: "Artist".to_string(),
            user_id: 99,
            is_followed: Some(false),
            is_bookmarked: Some(false),
            create_date: String::new(),
            caption: String::new(),
            tags: Vec::new(),
            width: None,
            height: None,
            total_views: None,
            x_restrict: None,
            image_url: "https://i.pximg.net/image.jpg".to_string(),
            page: 1,
            page_count: 1,
            total_bookmarks: Some(0),
            source_tags: Vec::new(),
            best_tag_rank: None,
            median_like_score: None,
            ranking_score: None,
        }];

        reconcile_session_state(
            &slides,
            &followed_authors,
            &bookmarked_illustrations,
            &followed_at_load,
            &bookmarked_at_load,
        );

        assert!(!followed_authors.contains(99));
        assert!(!bookmarked_illustrations.contains(42));
    }

    #[test]
    fn stale_reload_preserves_mutations_recorded_after_it_started() {
        let followed_authors = FollowedAuthors::default();
        let bookmarked_illustrations = BookmarkedIllustrations::default();
        let followed_at_load = followed_authors.snapshot();
        let bookmarked_at_load = bookmarked_illustrations.snapshot();
        followed_authors.remember(99);
        bookmarked_illustrations.remember(42);
        let slides = vec![crate::pixiv::Slide {
            illust_id: 42,
            title: "Work".to_string(),
            artist: "Artist".to_string(),
            user_id: 99,
            is_followed: Some(false),
            is_bookmarked: Some(false),
            create_date: String::new(),
            caption: String::new(),
            tags: Vec::new(),
            width: None,
            height: None,
            total_views: None,
            x_restrict: None,
            image_url: "https://i.pximg.net/image.jpg".to_string(),
            page: 1,
            page_count: 1,
            total_bookmarks: Some(0),
            source_tags: Vec::new(),
            best_tag_rank: None,
            median_like_score: None,
            ranking_score: None,
        }];

        reconcile_session_state(
            &slides,
            &followed_authors,
            &bookmarked_illustrations,
            &followed_at_load,
            &bookmarked_at_load,
        );

        assert!(followed_authors.contains(99));
        assert!(bookmarked_illustrations.contains(42));
    }
}
