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
}

/// Load config, refresh the token, and fetch yesterday's slides.
#[tauri::command]
async fn load_slideshow() -> Result<SlideShow, String> {
    let cfg = config::load()?;
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("http client build failed: {e}"))?;

    let token = auth::refresh(&client, &cfg.refresh_token).await?;
    let slides = pixiv::fetch_yesterday_slides(
        &client,
        &token.access_token,
        cfg.max_pages_per_post,
        cfg.empty_day_fallback,
    )
    .await?;

    let yesterday = (chrono::Local::now().date_naive() - chrono::Duration::days(1)).to_string();

    Ok(SlideShow {
        slides,
        interval_secs: cfg.slide_interval_secs,
        day: yesterday,
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
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
                let response = match image::fetch_image(&client, &uri, &dir, cache_max_bytes).await {
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
