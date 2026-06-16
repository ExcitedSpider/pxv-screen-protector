# pxv-screen-protector

A dead-simple full-screen slideshow of the illustrations your followed
[Pixiv](https://www.pixiv.net/) artists posted **yesterday**. Point it at your
account, go full-screen, and let it cycle — a pleasant "screen protector" built
from your own following feed instead of fighting Pixiv's website.

Built with [Tauri](https://tauri.app/) — a Rust backend and a React + Vite +
TypeScript + Tailwind frontend — for Linux / Fedora / KDE.

> **Status:** proof-of-concept. It works end to end but is intentionally
> minimal — no in-app login, bookmarking, or history beyond yesterday.

<!-- Add a screenshot here, e.g.:
![screenshot](docs/screenshot.png)
-->

## Features

- Slideshows yesterday's uploads from the artists you follow (`illust/follow`).
- Full-screen, with a smooth cross-fade between slides.
- Advances every 5 minutes (configurable).
- A bottom status bar: artist · title, slide position, CPU %, RAM, disk, network
  type (Wi-Fi / Ethernet / VPN), and a local clock.
- Multi-page posts are capped (default 3 pages) so one big post doesn't dominate.
- Falls back to "today so far" if yesterday's feed is empty.

## How it works

- **Auth** — your Pixiv OAuth *refresh token* is exchanged for a short-lived
  access token (the same flow pixivpy/the mobile app use).
- **Feed** — the `v2/illust/follow` endpoint is paginated newest-first and
  filtered to yesterday in your **local** timezone.
- **Images** — `i.pximg.net` blocks hotlinking, so the Rust side proxies every
  image through a custom `pximg://` protocol that attaches the required
  `Referer` header. The webview never talks to Pixiv directly.
- **Status bar** — system stats come from pure `/proc` reads and a `statvfs`
  call; nothing shells out.

## Requirements

- Fedora / KDE (or any Linux with a Wayland or X11 session)
- [Rust](https://rustup.rs/) (stable) and the Tauri CLI
- System libraries for the WebKit webview
- [Podman](https://podman.io/) — the frontend toolchain (Node/Vite) runs in a
  container, so **no Node is needed on the host**

## Setup

### 1. Install dependencies

System libraries (Fedora):

```bash
sudo dnf install webkit2gtk4.1-devel libsoup3-devel openssl-devel \
    curl wget file gcc
```

Rust + the Tauri CLI:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install tauri-cli --version "^2.0" --locked
```

### 2. Get your Pixiv refresh token

The refresh token isn't shown anywhere in Pixiv's UI, so it has to be extracted
once via the OAuth flow. The easiest path reuses your already-logged-in browser
(no password typing, no headless captcha):

```bash
./tools/pixiv-token/browser-login.sh
```

It prints a login URL, you open it in the browser where you're logged into
Pixiv, copy a short-lived `code` from the DevTools Network tab (the script tells
you exactly what to grab), paste it back, and it writes your config file.

<details>
<summary>Alternative: fully automated, containerized (Podman + gppt)</summary>

```bash
./tools/pixiv-token/get-token.sh
```

Runs [`gppt`](https://github.com/eggplants/get-pixivpy-token) headlessly in a
throwaway container and logs in with your ID/password. Convenient, but Pixiv
sometimes serves the headless browser a captcha — if that happens, use the
browser method above.
</details>

Both write `~/.config/pixiv-slides/config.toml`.

### 3. Run

From the **repo root** (not `src-tauri/`):

```bash
cargo tauri dev      # development — boots the Vite container, then the app
# or
cargo tauri build    # optimized binary in src-tauri/target/release/
```

`cargo tauri dev` runs the frontend toolchain in a Podman container
(`tools/frontend/fe.sh`) via Tauri's `beforeDevCommand`, installing
`node_modules` automatically on first run. Press `esc` to quit (this also tears
down the Vite container).

## Controls

| Key | Action |
|-----|--------|
| `←` / `→` | previous / next slide |
| `space`   | pause / resume |
| `s`       | save the current illustration to `save_dir` |
| `r`       | reload the feed |
| `esc`     | quit |

## Configuration

`~/.config/pixiv-slides/config.toml`:

```toml
refresh_token = "..."                # required
slide_interval_secs = 300            # seconds between slides (default 5 min)
max_pages_per_post = 3               # cap on images shown per multi-page post
empty_day_fallback = true            # if yesterday is empty, show today-so-far
save_dir = "~/Pictures/pixiv-slides" # where pressing `s` saves illustrations
cache_max_mb = 512                   # on-disk image cache cap in MB (0 disables)
```

Viewed illustrations are cached on disk under `~/.cache/pixiv-slides/` so
revisiting one doesn't re-download it. The cache is a self-pruning size-capped
LRU (`cache_max_mb`); nothing is held in RAM, and it's safe to delete anytime.

## Privacy

Your refresh token stays on your machine in `~/.config/pixiv-slides/config.toml`
and is sent only to Pixiv's own auth endpoint. It is `.gitignore`d so it can't
be committed. The only baked-in credentials are Pixiv's public, well-known
mobile-app client constants (the same ones every pixivpy-based tool ships).

## Limitations

- Linux only; tested on Fedora / KDE (Wayland).
- "Yesterday" is a single day in local time — no longer history.
- The VPN indicator is a heuristic (detects an active `tun*`/`wg*` interface).
- Uses Pixiv's unofficial app API, which may change without notice.

## Acknowledgements

- [pixivpy](https://github.com/upbit/pixivpy) — the auth flow and API constants.
- [gppt](https://github.com/eggplants/get-pixivpy-token) — token extraction.
- [pixiv-viewer-app](https://github.com/asadahimeka/pixiv-viewer-app) — prior art.

## License

[MIT](LICENSE) © 2026 ExcitedSpider
