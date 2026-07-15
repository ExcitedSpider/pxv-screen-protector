//! Loads the user's config from ~/.config/pixiv-slides/config.toml

use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// Pixiv OAuth refresh token (the only required field).
    pub refresh_token: String,
    /// Which feed to load: `following_daily` or `tag_search`.
    #[serde(default = "default_feed_mode")]
    pub feed_mode: String,
    /// Seconds between slides.
    #[serde(default = "default_interval")]
    pub slide_interval_secs: u64,
    /// Max images shown per multi-page post.
    #[serde(default = "default_max_pages")]
    pub max_pages_per_post: usize,
    /// If yesterday's feed is empty, fall back to today-so-far.
    #[serde(default = "default_true")]
    pub empty_day_fallback: bool,
    /// Exclude works that Pixiv does not explicitly mark as general content.
    #[serde(default)]
    pub avoid_nsfw: bool,
    /// Folder to save illustrations into (supports a leading `~/`).
    #[serde(default = "default_save_dir")]
    pub save_dir: String,
    /// Also add a Pixiv bookmark when pressing `s`.
    #[serde(default)]
    pub bookmark_on_save: bool,
    /// Pixiv bookmark visibility when `bookmark_on_save` is enabled.
    #[serde(default = "default_bookmark_restrict")]
    pub bookmark_restrict: String,
    /// Optional Pixiv tags to attach to bookmarks created by this app.
    #[serde(default)]
    pub bookmark_tags: Vec<String>,
    /// On-disk image cache cap in MB (`0` disables caching).
    #[serde(default = "default_cache_mb")]
    pub cache_max_mb: u64,
    /// Tag-search mode options.
    #[serde(default)]
    pub tag_feed: TagFeedConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TagFeedConfig {
    /// After a tag-feed save is bookmarked, publicly follow its author.
    #[serde(default)]
    pub follow_when_bookmark: bool,
    /// Tags to search independently, then merge by popularity.
    #[serde(default)]
    pub tags: Vec<String>,
    /// Discard search results containing any of these Pixiv tags.
    #[serde(default)]
    pub exclude_tags: Vec<String>,
    /// Search range in local days, inclusive of today.
    #[serde(default = "default_tag_range_days")]
    pub range_days: i64,
    /// Pixiv search target, usually `exact_match_for_tags`.
    #[serde(default = "default_search_target")]
    pub search_target: String,
    /// Pixiv sort, usually `popular_desc` (Premium account feature).
    #[serde(default = "default_search_sort")]
    pub sort: String,
    /// Top illustrations to keep from each tag.
    #[serde(default = "default_max_results_per_tag")]
    pub max_results_per_tag: usize,
    /// Drop tag-search works below this bookmark count before ranking/merging.
    #[serde(default)]
    pub min_bookmarks: u64,
    /// Safety cap on search pagination per tag.
    #[serde(default = "default_max_search_pages_per_tag")]
    pub max_search_pages_per_tag: usize,
    /// Overall slide cap after merging tags and expanding multi-page posts.
    #[serde(default = "default_max_tag_slides")]
    pub max_slides: usize,
    /// `error` or `local_bookmark_sort` when `popular_desc` is unavailable.
    #[serde(default = "default_popular_fallback")]
    pub fallback_without_popular_sort: String,
    /// `raw_bookmarks`, `per_tag_rank`, or `median_like_ratio` when merging tags.
    #[serde(default = "default_merge_strategy")]
    pub merge_strategy: String,
    /// Decay constant for recency in `median_like_ratio`; `0` disables it.
    #[serde(default = "default_recency_decay_lambda")]
    pub recency_decay_lambda: f64,
}

impl Default for TagFeedConfig {
    fn default() -> Self {
        Self {
            follow_when_bookmark: false,
            tags: Vec::new(),
            exclude_tags: Vec::new(),
            range_days: default_tag_range_days(),
            search_target: default_search_target(),
            sort: default_search_sort(),
            max_results_per_tag: default_max_results_per_tag(),
            min_bookmarks: 0,
            max_search_pages_per_tag: default_max_search_pages_per_tag(),
            max_slides: default_max_tag_slides(),
            fallback_without_popular_sort: default_popular_fallback(),
            merge_strategy: default_merge_strategy(),
            recency_decay_lambda: default_recency_decay_lambda(),
        }
    }
}

fn default_feed_mode() -> String {
    "following_daily".to_string()
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
fn default_bookmark_restrict() -> String {
    "private".to_string()
}
fn default_cache_mb() -> u64 {
    512
}
fn default_tag_range_days() -> i64 {
    30
}
fn default_search_target() -> String {
    "exact_match_for_tags".to_string()
}
fn default_search_sort() -> String {
    "popular_desc".to_string()
}
fn default_max_results_per_tag() -> usize {
    30
}
fn default_max_search_pages_per_tag() -> usize {
    10
}
fn default_max_tag_slides() -> usize {
    120
}
fn default_popular_fallback() -> String {
    "error".to_string()
}
fn default_merge_strategy() -> String {
    "raw_bookmarks".to_string()
}
fn default_recency_decay_lambda() -> f64 {
    0.15
}

/// `$XDG_CONFIG_HOME/pixiv-slides/config.toml`, falling back to `~/.config`.
pub fn config_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default();
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

#[cfg(test)]
mod tests {
    use super::Config;

    #[test]
    fn follow_when_bookmark_defaults_to_false() {
        let config: Config = toml::from_str("refresh_token = \"token\"").unwrap();

        assert!(!config.tag_feed.follow_when_bookmark);
    }

    #[test]
    fn exclude_tags_defaults_to_empty() {
        let config: Config = toml::from_str("refresh_token = \"token\"").unwrap();

        assert!(config.tag_feed.exclude_tags.is_empty());
    }

    #[test]
    fn exclude_tags_can_be_configured_for_tag_feed() {
        let config: Config = toml::from_str(
            "refresh_token = \"token\"\n\n[tag_feed]\nexclude_tags = [\"AI生成\", \"R-18\"]",
        )
        .unwrap();

        assert_eq!(config.tag_feed.exclude_tags, ["AI生成", "R-18"]);
    }

    #[test]
    fn avoid_nsfw_defaults_to_false() {
        let config: Config = toml::from_str("refresh_token = \"token\"").unwrap();

        assert!(!config.avoid_nsfw);
    }

    #[test]
    fn avoid_nsfw_can_be_enabled() {
        let config: Config =
            toml::from_str("refresh_token = \"token\"\navoid_nsfw = true").unwrap();

        assert!(config.avoid_nsfw);
    }

    #[test]
    fn follow_when_bookmark_can_be_enabled_for_tag_feed() {
        let config: Config =
            toml::from_str("refresh_token = \"token\"\n\n[tag_feed]\nfollow_when_bookmark = true")
                .unwrap();

        assert!(config.tag_feed.follow_when_bookmark);
    }
}
