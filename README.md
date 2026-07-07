# pixiv-slides

A full-screen Pixiv slideshow for a desktop display. It can show either:

- yesterday's uploads from artists you follow, or
- a tag-based feed sampled over a configurable date range.

The app is built with [Tauri](https://tauri.app/): Rust owns Pixiv auth, API
calls, image proxying, caching, saving, and system stats; React + Vite +
TypeScript renders the slideshow UI.

> Status: proof-of-concept desktop app for Linux / Fedora / KDE. It works end to
> end, but there is still no in-app login, bookmarking, liking, or account
> management.

## Features

- Full-screen slideshow with smooth image transitions.
- Two feed modes:
  - `following_daily`: yesterday's uploads from followed artists.
  - `tag_search`: configured tags over a configurable recent date range.
- In-app feed switching with `m`.
- In-app help overlay with `?`, showing shortcuts and current mode config.
- Configurable slide interval, multi-page cap, save folder, and cache size.
- Tag-feed merge strategies:
  - `raw_bookmarks`: globally sort by Pixiv bookmark count.
  - `per_tag_rank`: interleave tags by each work's rank within its own tag.
  - `median_like_ratio`: normalize by tag median and optionally apply recency
    decay.
- Status bar with artist/title, slide position, feed mode, tag metadata, rank or
  score where available, CPU, RAM, disk, network type, and local clock.
- Saves the current illustration with `s`.
- Proxies Pixiv CDN images through Rust so the required `Referer` header is
  attached.
- Size-capped on-disk image cache under `~/.cache/pixiv-slides/`.

## How It Works

**Auth:** the app reads your Pixiv OAuth refresh token from
`~/.config/pixiv-slides/config.toml`, exchanges it for an access token, and uses
that token for Pixiv app API calls.

**Following feed:** `following_daily` pages through
`/v2/illust/follow?restrict=public`, filters posts to yesterday in your local
timezone, and optionally falls back to today so far when yesterday is empty.

**Tag feed:** `tag_search` searches each configured tag independently through
`/v1/search/illust`, bounded by `max_results_per_tag` and
`max_search_pages_per_tag`. Results are deduplicated by illustration id, sorted
by `merge_strategy`, expanded into slides, then capped by `max_slides`.

**Images:** Pixiv's CDN rejects normal webview image loads without a Pixiv
`Referer`. The frontend therefore renders `pximg://...` URLs; Rust handles that
custom protocol, downloads from `i.pximg.net` with the required headers, caches
the bytes, and returns the image to the webview.

**System stats:** the status bar uses `/proc`, `/sys`, and `statvfs`; it does
not shell out.

## Requirements

- Linux with a graphical Wayland or X11 session.
- Rust stable and the Tauri CLI.
- WebKitGTK system libraries for Tauri.
- [Podman](https://podman.io/) for the frontend toolchain. Node/Vite run in a
  container, so Node does not need to be installed on the host.

Fedora system packages:

```bash
sudo dnf install webkit2gtk4.1-devel libsoup3-devel openssl-devel \
    curl wget file gcc
```

Rust + Tauri CLI:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install tauri-cli --version "^2.0" --locked
```

## Setup

### 1. Get a Pixiv Refresh Token

The refresh token is not exposed in Pixiv's website UI. The recommended helper
uses your already-logged-in browser session and writes the config file:

```bash
./tools/pixiv-token/browser-login.sh
```

It prints a login URL, asks you to complete Pixiv's browser flow, then asks you
to paste the short-lived OAuth `code` from the browser's DevTools Network tab.
On success it writes:

```text
~/.config/pixiv-slides/config.toml
```

Alternative, fully containerized helper:

```bash
./tools/pixiv-token/get-token.sh
```

This uses `gppt` and a headless browser inside Podman. Pixiv may show captchas
to headless browsers, so the browser-login helper is usually more reliable.

### 2. Configure the Feed

Edit:

```text
~/.config/pixiv-slides/config.toml
```

Minimal following feed:

```toml
refresh_token = "..."
feed_mode = "following_daily"
```

Tag feed example:

```toml
refresh_token = "..."
feed_mode = "tag_search"
slide_interval_secs = 300
max_pages_per_post = 3
save_dir = "~/Pictures/pixiv-slides"
cache_max_mb = 512

[tag_feed]
tags = ["landscape", "original"]
range_days = 30
search_target = "exact_match_for_tags"
sort = "popular_desc"
max_results_per_tag = 50
min_bookmarks = 50
max_search_pages_per_tag = 5
max_slides = 120
fallback_without_popular_sort = "local_bookmark_sort"
merge_strategy = "median_like_ratio"
recency_decay_lambda = 0.15
```

See [config.example.toml](config.example.toml) for all defaults.

### 3. Run

From the repo root:

```bash
./dev.sh
```

Equivalent:

```bash
cargo tauri dev
```

The Tauri `beforeDevCommand` starts Vite through
`tools/frontend/fe.sh dev`, which runs the frontend in a Podman container named
`pixiv-slides-vite`. If a previous dev container was left behind, the script
uses `--replace`.

Build:

```bash
cargo tauri build
```

## Controls

| Key | Action |
|-----|--------|
| `Left` / `Right` | previous / next slide |
| `Space` | pause / resume |
| `S` | save the current illustration to `save_dir` |
| `R` | reload the current feed |
| `M` | switch between following feed and tag feed |
| `?` | show / hide help |
| `Esc` | close help, otherwise quit |

The help overlay also shows the active mode and current mode configuration.

## Configuration Reference

Top-level config:

```toml
refresh_token = "..."                # required
feed_mode = "following_daily"        # "following_daily" or "tag_search"
slide_interval_secs = 300            # seconds between slides
max_pages_per_post = 3               # cap pages shown per multi-page post
empty_day_fallback = true            # following feed: use today if yesterday empty
save_dir = "~/Pictures/pixiv-slides" # where `s` saves images
cache_max_mb = 512                   # 0 disables image caching
```

Tag feed config:

```toml
[tag_feed]
tags = ["landscape", "original"]     # searched independently, then merged
range_days = 30                      # local days, inclusive of today
search_target = "exact_match_for_tags"
sort = "popular_desc"                # Pixiv Premium popularity sort
max_results_per_tag = 30             # sample size per tag
min_bookmarks = 0                    # drop tag results below this bookmark count
max_search_pages_per_tag = 10        # pagination safety cap
max_slides = 120                     # final slide cap after merge/page expansion
fallback_without_popular_sort = "error" # or "local_bookmark_sort"
merge_strategy = "raw_bookmarks"     # "raw_bookmarks", "per_tag_rank", "median_like_ratio"
recency_decay_lambda = 0.15          # median_like_ratio only; 0 disables
```

### Tag Merge Strategies

`raw_bookmarks` keeps the original behavior: all sampled works from all tags are
deduplicated and sorted by bookmark count descending.

`per_tag_rank` gives each sampled work a rank inside its own tag and sorts by
the best rank first. This prevents a broad, popular tag from filling the front
of the feed by raw count alone. Bookmark count is still used as a tie-breaker.

`median_like_ratio` computes a median-normalized score per tag sample:

```text
log(bookmarks + 1) / log(sample_median + 1)
```

`sample_median` is the median bookmark count among the fetched sample for that
tag, not the full Pixiv tag population. If a work appears in multiple tags, the
best score is used. It then applies recency decay:

```text
final_score = median_like_ratio * exp(-recency_decay_lambda * age_in_days)
```

The default `recency_decay_lambda = 0.15` gives a half-life of about 4.6 days.
Set it to `0` to disable recency. Bookmark count and illustration id are
tie-breakers.

### Sampling Notes

For:

```toml
tags = ["a", "b", "c", "d", "e"]
max_results_per_tag = 30
max_slides = 120
```

the app fetches up to 150 tag-results, filters out anything below
`min_bookmarks`, deduplicates the survivors, sorts them, expands multi-page
posts up to `max_pages_per_post`, then stops at 120 slides. Because `max_slides`
counts slides, not illustrations, multi-page posts can reduce the number of
distinct works shown.

## Privacy

Your refresh token stays on your machine in
`~/.config/pixiv-slides/config.toml`. It is sent only to Pixiv's OAuth endpoint.
The file is outside the repo by default, and repo-local token/config copies are
ignored by `.gitignore`.

The only credentials in source are Pixiv's public mobile-app client constants,
the same style used by pixivpy-based tools.

## Limitations

- Linux desktop app only; tested on Fedora / KDE.
- Requires a live graphical Wayland or X11 session. On SSH/headless runs, the
  app exits early with a clearer message instead of a GTK initialization panic.
- No in-app login or token editor.
- No bookmarking, liking, following management, or persistent browsing history.
- Tag feed relies on Pixiv's unofficial app API and Pixiv's search behavior.
- `popular_desc` usually requires Pixiv Premium. Non-Premium accounts can use
  `fallback_without_popular_sort = "local_bookmark_sort"`, but that only sorts
  within the bounded scanned sample.
- VPN detection is heuristic: active `tun*`, `wg*`, and common VPN interface
  names are treated as VPN indicators.

## Acknowledgements

- [pixivpy](https://github.com/upbit/pixivpy) for API/auth prior art.
- [gppt](https://github.com/eggplants/get-pixivpy-token) for token extraction.
- [pixiv-viewer-app](https://github.com/asadahimeka/pixiv-viewer-app) for prior
  app inspiration.

## License

[MIT](LICENSE) (c) 2026 ExcitedSpider
