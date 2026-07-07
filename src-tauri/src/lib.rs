mod auth;
mod cache;
mod config;
mod image;
mod pixiv;
mod save;
mod system;

use serde::Serialize;

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
    following_daily: FollowingDailyHelp,
    tag_search: TagSearchHelp,
}

#[derive(Serialize)]
pub struct FollowingDailyHelp {
    day: String,
    empty_day_fallback: bool,
}

#[derive(Serialize)]
pub struct TagSearchHelp {
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

/// Load config, refresh the token, and fetch the configured feed.
#[tauri::command]
async fn load_slideshow(mode: Option<String>) -> Result<SlideShow, String> {
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
            following_daily: FollowingDailyHelp {
                day: yesterday,
                empty_day_fallback: cfg.empty_day_fallback,
            },
            tag_search: TagSearchHelp {
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

/// System stats for the status bar (polled periodically by the frontend).
#[tauri::command]
fn system_stats() -> system::SystemStats {
    system::collect()
}

/// Save the currently-viewed illustration to the configured folder.
#[tauri::command]
async fn save_illustration(slide: save::SaveRequest) -> Result<String, String> {
    let cfg = config::load()?;
    let dir = save::resolve_dir(&cfg.save_dir);
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("http client build failed: {e}"))?;
    save::save(&client, slide, &dir).await
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
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
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
            load_slideshow,
            system_stats,
            save_illustration,
            quit
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
