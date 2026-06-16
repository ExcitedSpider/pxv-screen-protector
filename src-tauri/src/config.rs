//! Loads the user's config from ~/.config/pixiv-slides/config.toml

use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// Pixiv OAuth refresh token (the only required field).
    pub refresh_token: String,
    /// Seconds between slides.
    #[serde(default = "default_interval")]
    pub slide_interval_secs: u64,
    /// Max images shown per multi-page post.
    #[serde(default = "default_max_pages")]
    pub max_pages_per_post: usize,
    /// If yesterday's feed is empty, fall back to today-so-far.
    #[serde(default = "default_true")]
    pub empty_day_fallback: bool,
    /// Folder to save illustrations into (supports a leading `~/`).
    #[serde(default = "default_save_dir")]
    pub save_dir: String,
    /// On-disk image cache cap in MB (`0` disables caching).
    #[serde(default = "default_cache_mb")]
    pub cache_max_mb: u64,
}

fn default_interval() -> u64 {
    300
}
fn default_max_pages() -> usize {
    3
}
fn default_true() -> bool {
    true
}
fn default_save_dir() -> String {
    "~/Pictures/pixiv-slides".to_string()
}
fn default_cache_mb() -> u64 {
    512
}

/// `$XDG_CONFIG_HOME/pixiv-slides/config.toml`, falling back to `~/.config`.
pub fn config_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
            home.join(".config")
        });
    base.join("pixiv-slides").join("config.toml")
}

pub fn load() -> Result<Config, String> {
    let path = config_path();
    let text = std::fs::read_to_string(&path).map_err(|e| {
        format!(
            "Could not read config at {}: {e}.\nCreate it with at least: refresh_token = \"...\"",
            path.display()
        )
    })?;
    toml::from_str(&text).map_err(|e| format!("Invalid config {}: {e}", path.display()))
}
