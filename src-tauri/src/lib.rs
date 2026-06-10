mod auth;
mod config;
mod image;
mod pixiv;
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
            let uri = request.uri().to_string();
            tauri::async_runtime::spawn(async move {
                let response = match image::fetch_image(&client, &uri).await {
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
        .invoke_handler(tauri::generate_handler![load_slideshow, system_stats, quit])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
