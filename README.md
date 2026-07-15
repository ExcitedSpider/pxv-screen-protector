# pixiv-slides

A full-screen Pixiv slideshow for a desktop display. It can show either:

- yesterday's uploads from artists you follow, or
- a tag-based feed sampled over a configurable date range.

The app is built with [Tauri](https://tauri.app/): Rust owns Pixiv auth, API
calls, image proxying, caching, saving, and system stats; React + Vite +
TypeScript renders the slideshow UI.

> Status: proof-of-concept desktop app for Linux / Fedora / KDE. It works end to
> end, but there is still no in-app login or general bookmark, follow, or
> account management.

## Features

- Full-screen slideshow with smooth image transitions.
- Two feed modes:
  - `following_daily`: yesterday's uploads from followed artists.
  - `tag_search`: configured tags over a configurable recent date range.
- In-app feed switching with `m`.
- In-app help overlay with `?`, showing shortcuts and current mode config.
- Configurable slide interval, multi-page cap, NSFW filtering, save folder, and
  cache size.
- Tag-feed merge strategies:
  - `raw_bookmarks`: globally sort by Pixiv bookmark count.
  - `per_tag_rank`: interleave tags by each work's rank within its own tag.
  - `median_like_ratio`: normalize by tag median and optionally apply recency
    decay.
- Status bar with artist/title, slide position, feed mode, tag metadata, rank or
  score where available, CPU, RAM, disk, network type, and local clock.
- Saves the current illustration with `s`; optionally also adds a Pixiv
  bookmark and, in tag mode, publicly follows its author.
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
When both `bookmark_on_save` and `follow_when_bookmark` are enabled, a successful
tag-feed save and bookmark also publicly follows the work's author.

**Content filter:** by default, both feeds include all content returned by
Pixiv. Set `avoid_nsfw = true` to exclude works that Pixiv does not explicitly
mark as general content before they are expanded into slides.

**Images:** Pixiv's CDN rejects normal webview image loads without a Pixiv
`Referer`. The frontend therefore renders `pximg://...` URLs; Rust handles that
custom protocol, downloads from `i.pximg.net` with the required headers, caches
the bytes, and returns the image to the webview.

**System stats:** the status bar uses `/proc`, `/sys`, and `statvfs`; it does
not shell out.

## Requirements

For a release build, the host needs [Podman](https://podman.io/) plus the
standard Linux command-line tools used by `dev.sh` (Bash, coreutils, Git, and
`flock`). The default `./dev.sh build` uses the project's Ubuntu builder image,
which supplies Rust, Node.js, Tauri, WebKitGTK, and the Linux packaging tools.
Publishing with `./dev.sh release` additionally requires the GitHub CLI (`gh`)
authenticated to `github.com` with push access to the upstream repository.

Host development additionally requires:

- Linux with a graphical Wayland or X11 session.
- Rust stable and the Tauri CLI.
- WebKitGTK system libraries for Tauri.
- Podman for the frontend toolchain. Node/Vite run in a container, so Node does
  not need to be installed on the host.

Fedora host-development packages:

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
avoid_nsfw = true
save_dir = "~/Pictures/pixiv-slides"
bookmark_on_save = true
bookmark_restrict = "private"
bookmark_tags = ["pixiv-slides"]
cache_max_mb = 512

[tag_feed]
tags = ["landscape", "original"]
follow_when_bookmark = true
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

List the project commands (this does not launch the app):

```bash
./dev.sh
./dev.sh help
```

Launch the development app:

```bash
./dev.sh dev
```

The Tauri `beforeDevCommand` starts Vite through
`tools/frontend/fe.sh dev`, which runs the frontend in a Podman container named
`pixiv-slides-vite`. If a previous dev container was left behind, the script
uses `--replace`.

The wrapper also exposes the common build and validation commands. Additional
arguments are forwarded to Tauri for `dev` and `build-host`, or to Cargo for
`check` and `test`. The controlled `build` command forwards release-compatible
Tauri options but rejects debug builds, alternate configs/runners, non-x86-64
targets, and no-bundle invocations so its output contract stays stable:

```bash
./dev.sh build [TAURI_BUILD_ARGS...]
./dev.sh release [TAURI_BUILD_ARGS...]
./dev.sh build-image
./dev.sh build-clean
./dev.sh build-host [TAURI_BUILD_ARGS...]
./dev.sh check [CARGO_CHECK_ARGS...]
./dev.sh test [CARGO_TEST_ARGS...]
./dev.sh frontend-build
```

### Controlled Linux Release Builds

`./dev.sh build` packages the application inside the pinned Ubuntu 22.04
builder. The repository is mounted read-only, copied to a disposable container
workspace, and built without access to the host's Podman socket. The build is
staged and published only after validation, so a failed attempt does not
overwrite the previous successful artifacts.

`./dev.sh release` turns that controlled build into a complete GitHub release.
It requires a clean checked-out branch that exactly matches its fetched
upstream, a configured Git author, and an authenticated GitHub CLI with push
access (`gh auth login -h github.com`). After verifying the forwarded build
arguments and synchronized npm, Cargo, lockfile, and Tauri versions, it:

1. increments the patch version (for example, `0.1.1` to `0.1.2`);
2. commits only the five application version files as `chore: release v0.1.2`;
3. exports that commit with `git archive`, then builds and validates the
   packages from the immutable tracked snapshot (ignored local files such as
   `.env.production` cannot enter the release build, and a pre/post fingerprint
   rejects snapshot changes during packaging);
4. creates an annotated `v0.1.2` tag and atomically pushes the branch and tag;
5. creates a draft GitHub release with generated notes, uploads the packages,
   `SHA256SUMS`, and `build-info.txt`, then publishes it.

Release assets come from the verified `SHA256SUMS` manifest, never from a broad
file glob. This prevents stale files from being uploaded. Before the draft is
made public, the workflow also compares every remote asset's byte size and
GitHub-reported SHA-256 digest with the local package or metadata file. The tag
is created only after the packages pass validation, and `gh` must verify the
pushed tag rather than creating one implicitly. A retry repairs the assets of
an incomplete draft with `--clobber`; it never modifies an already-published
release.

The version helper fingerprints the complete deterministic patch result before
changing the worktree. The Git workflow verifies that fingerprint both before
the commit and on every resume, so unrelated edits hidden inside one of the
five version files cannot ride along with a release commit. Remote branch and
annotated-tag identities are also checked immediately before and after making
the draft public; if they change during publication, the workflow attempts to
return the release to draft state and stops. Repository rules should still
forbid force-updating release tags, since no client-side workflow can remove
every external race window.

If any step fails, rerun the same `./dev.sh release` command after correcting
the problem, including the same Tauri build arguments. The ignored
`builds/.release-state` file records the exact version, build-argument and
deterministic-bump fingerprints, commit, annotated tag object, artifact
directory, and publication stage, so a retry resumes the same release instead
of incrementing the version again. If
upstream advances during
the build without changing a version file, the next retry replays the unpushed
release commit on that new tip and asks for one more retry, ensuring any changed
build tooling is loaded before its packages are rebuilt. It stops for manual
resolution if upstream changed a version file, and it never force-pushes or
deletes published refs.

The default Tauri target is `all`. On Linux, that means all configured package
formats: DEB, RPM, and AppImage. It does not mean all CPU architectures. The
current controlled builder is intentionally pinned to native x86-64 and
publishes under:

```text
builds/<app-version>/linux-x86_64/
```

That directory contains the `.deb`, `.rpm`, and `.AppImage` packages plus
`SHA256SUMS` and `build-info.txt`. The top-level `dist/` directory is only the
Vite frontend output; installable desktop packages are always under `builds/`.

Tauri prints paths under `/cache/target` while it compiles and bundles. Those
are intermediate paths inside the build environment, not the paths consumers
should use. After validation, the host workflow publishes each package into
the repository directory above, prints every repository-relative package path,
and stops and removes the temporary build container. Consume packages only
from `builds/<app-version>/linux-<arch>/`.

The first build needs network access to create the builder image and download
the Rust, npm, Cargo, and Tauri build inputs. AppImage helper binaries and
scripts are checksum-pinned in that image instead of being taken directly from
Tauri's moving upstream tags on each cold build. Later builds reuse Podman
image layers and project-scoped package/compilation caches. The related
commands are:

- `./dev.sh build-image` — explicitly build or refresh the controlled builder.
- `./dev.sh release` — increment and commit the patch version, create the
  controlled Linux packages, atomically push the release tag, and publish the
  checksum-selected assets as a GitHub release.
- `./dev.sh build-clean` — remove only this project's builder image, named
  build-cache volumes, and stale staging directories. It does not remove a
  successful `builds/<app-version>/` directory or perform a global Podman
  prune.
- `./dev.sh build-host` — run Tauri packaging directly on the host, using the
  host-development dependencies listed above.

Tauri invokes `linuxdeploy` because its AppImage bundler uses it to assemble
the AppDir and collect Linux desktop libraries; DEB and RPM packaging do not
use it. Keeping that step in Ubuntu 22.04 avoids depending on a newer host
distribution's binary utilities and development packages—the source of common
`failed to run linuxdeploy` errors. If the controlled AppImage step fails,
rebuild the pinned tool image with `./dev.sh build-image` and rerun
`./dev.sh build`; the terminal log identifies the failed packaging stage.

The Rust backend logs save, bookmark, and follow decisions and API durations at
info level. Logs appear in the launch terminal and, through `tauri-plugin-log`,
under `$XDG_DATA_HOME/net.pixiv.slides/logs` (normally
`~/.local/share/net.pixiv.slides/logs`).

## Controls

| Key | Action |
|-----|--------|
| `Left` / `Right` | previous / next slide |
| `Page Up` / `Page Down` | jump back / forward 10 slides |
| `Home` / `End` | first / last slide |
| `Space` | pause / resume |
| `S` | save the current illustration; optionally bookmark it and, in tag mode, follow its author |
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
avoid_nsfw = false                   # exclude works not marked as general content
save_dir = "~/Pictures/pixiv-slides" # where `s` saves images
bookmark_on_save = false             # if true, `s` also adds a Pixiv bookmark
bookmark_restrict = "private"        # "private" or "public"
bookmark_tags = []                   # optional Pixiv bookmark tags
cache_max_mb = 512                   # 0 disables image caching
```

Tag feed config:

```toml
[tag_feed]
tags = ["landscape", "original"]     # searched independently, then merged
follow_when_bookmark = false         # publicly follow after a successful tag-feed bookmark
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

the app keeps up to 150 tag-results across the five per-tag samples. With
`avoid_nsfw` enabled, filtered works do not consume a per-tag result cap, so the
app can scan additional results up to `max_search_pages_per_tag`. It then
filters out anything below `min_bookmarks`, deduplicates the survivors, sorts
them, expands multi-page posts up to `max_pages_per_post`, and stops at 120
slides. Because `max_slides` counts slides, not illustrations, multi-page posts
can reduce the number of distinct works shown.

Configuration is read each time the feed loads. After changing `avoid_nsfw`,
press `r` to reload the active feed; restarting the app is not required.

## Privacy

Your refresh token stays on your machine in
`~/.config/pixiv-slides/config.toml`. It is sent only to Pixiv's OAuth endpoint.
The file is outside the repo by default, and repo-local token/config copies are
ignored by `.gitignore`.

The only credentials in source are Pixiv's public mobile-app client constants,
the same style used by pixivpy-based tools.

When `bookmark_on_save = true`, pressing `s` writes the local file first, then
adds a Pixiv bookmark through the app API. Bookmarks are private by default.

When `[tag_feed].follow_when_bookmark = true` as well, a successful bookmark
made from the active tag feed is followed by a public follow of the work's
author. Following is skipped in following-feed mode and when saving or
bookmarking fails. These automatic follows use public visibility and may be
visible to other Pixiv users.

## Limitations

- Linux desktop app only; tested on Fedora / KDE.
- Requires a live graphical Wayland or X11 session. On SSH/headless runs, the
  app exits early with a clearer message instead of a GTK initialization panic.
- No in-app login or token editor.
- No in-app bookmark browsing, unbookmarking, liking, unfollowing, follow
  visibility controls, or persistent browsing history.
- Automatic following is public-only and is available only through the
  tag-feed save-and-bookmark flow.
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
