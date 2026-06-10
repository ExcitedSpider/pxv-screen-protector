# pixiv-slides — Plan

A minimal full-screen slideshow that cycles through the illustrations posted
*yesterday* by the Pixiv artists you follow. Built with Tauri (Rust + web
frontend) for Fedora/KDE.

Reference for prior art: https://github.com/asadahimeka/pixiv-viewer-app

---

## Goals (v1 prototype)

- Take a Pixiv **refresh token** as the only credential.
- On launch, fetch all illustrations posted **yesterday** by followed artists.
- Show them as a **full-screen slideshow**, advancing every **5 minutes**.
- Keep it simple: no bookmarking, search, history, or in-app login UI.

## Non-goals (v1)

- No token-entry UI (paste into a config file once).
- No browsing history beyond yesterday.
- No bookmarking / liking / following management.
- No multi-account support.

---

## Locked decisions

| Topic            | Decision                                                        |
|------------------|----------------------------------------------------------------|
| "Yesterday" TZ   | User's **local** KDE system timezone                            |
| Multi-page posts | **First page + cap**: up to **3** pages per post (configurable) |
| Content filter   | **Everything** the follows post (incl. R-18), `restrict=public` |
| Token storage    | Plaintext **config file** in `~/.config/pixiv-slides/`          |
| Slide interval   | **5 minutes** (configurable)                                    |
| Platform         | Fedora / KDE, Tauri                                             |

### Still open

- **Empty-day fallback:** if yesterday's feed is thin/empty, fall back to
  "today so far" rather than a black screen? (leaning yes)
- Page cap default of 3 — confirm.

---

## Architecture

```
pixiv-slides/
├─ src-tauri/              Rust: auth, API, image proxy
│  ├─ src/
│  │  ├─ auth.rs           refresh_token -> access_token; hourly refresh
│  │  ├─ pixiv.rs          GET /v2/illust/follow; paginate; filter to yesterday
│  │  ├─ image.rs          custom `pximg://` protocol w/ Referer header
│  │  ├─ config.rs         load ~/.config/pixiv-slides/config.toml
│  │  └─ lib.rs            tauri commands + shared state
│  ├─ Cargo.toml
│  └─ tauri.conf.json
├─ src/                    Frontend: dumb slideshow
│  ├─ index.html           full-screen <img>, preloaded next image
│  └─ main.js              5-min timer; ←/→ step; space pause; Esc quit
├─ config.example.toml
└─ PLAN.md
```

**Division of labor:** Rust owns everything that needs secrets or custom HTTP
headers (auth, API calls, image fetching). The frontend is a thin slideshow that
asks Rust for the slide list and renders images via the `pximg://` protocol.

### Runtime flow

1. Read refresh token from `~/.config/pixiv-slides/config.toml`.
2. Exchange it for an access token (refresh again ~hourly in the background).
3. Page through `GET /v2/illust/follow?restrict=public`, newest first, until a
   post's `create_date` is **before yesterday 00:00 local** time.
4. Keep posts whose `create_date` falls **within yesterday** (local).
5. Flatten posts into slides: first image + up to 3 pages per post.
6. Hand the slide list to the frontend; start the full-screen slideshow.
7. Advance every 5 min, looping back to the start at the end.

---

## Pixiv API notes

Uses the unofficial app API (same as `pixivpy` / the reference app).

- **Auth:** `POST https://oauth.secure.pixiv.net/auth/token`
  - well-known mobile `client_id` / `client_secret`
  - `grant_type=refresh_token`
  - requires `X-Client-Time` + `X-Client-Hash` (md5 of time + salt) headers
  - access token TTL ~3600s → refresh on a timer.
- **Feed:** `GET https://app-api.pixiv.net/v2/illust/follow?restrict=public`
  - returns followed artists' newest illusts, paginated via `next_url`.
  - each illust has `create_date` (ISO-8601 w/ offset), `page_count`,
    `meta_single_page` / `meta_pages`, and tag list (for R-18 detection).
- **Images — the hotlink gotcha:** `i.pximg.net` returns 403 unless the request
  carries `Referer: https://www.pixiv.net/`. A webview `<img>` can't set that, so
  images **must** flow through the Rust side via a custom `pximg://` protocol
  handler that injects the Referer. This is the one constraint that shapes the
  architecture.

### Getting the refresh token

The refresh token isn't shown in Pixiv's UI. Standard extraction is the
`gppt` / OAuth-PKCE browser capture flow. v1 ships a short doc (or tiny helper)
documenting the one-time extraction; the result is pasted into the config file.

---

## Config file

`~/.config/pixiv-slides/config.toml`:

```toml
refresh_token = "xxxxxxxx"
slide_interval_secs = 300   # 5 minutes
max_pages_per_post = 3
empty_day_fallback = true
```

---

## Toolchain / dependencies (Fedora)

No Rust toolchain is currently installed on the host. Tauri needs:

- **Rust** stable — `rustup` or `dnf install rust cargo`
- **System libs** — `sudo dnf install webkit2gtk4.1-devel libsoup3-devel \
  openssl-devel curl wget file`
- **Tauri CLI** — `cargo install tauri-cli` (or npm `@tauri-apps/cli`)

> Note: a Tauri GUI app is a poor fit for a Podman container (needs Wayland/X11
> passthrough + GPU + the webkit stack), so v1 builds and runs on the host. The
> `dnf` steps need sudo and are run by the user.

---

## Milestones

1. ✅ **Scaffold** — rustup + `cargo tauri init`; full-screen window, real icons.
2. ✅ **Auth** — refresh token → access token (`src-tauri/src/auth.rs`).
3. ✅ **Feed** — paginate `illust/follow`, filter to yesterday/local (`pixiv.rs`).
4. ✅ **Images** — `pximg://` async protocol handler w/ Referer (`image.rs`).
5. ✅ **Slideshow** — 5-min timer, preload-next, ←/→/space/r/esc (`src/main.js`).
6. ✅ **Token helper** — containerized gppt extractor (`tools/pixiv-token/`).
7. ⬜ **Run** — user extracts token + launches; verify against live feed.
8. ⬜ **Polish** — background token refresh for >1h sessions, config hot-reload.

Compiles clean (`cargo build` in `src-tauri/`). Not yet run against a live
account — needs the user's refresh token.

---

## Risks / unknowns

- Refresh-token extraction is a manual one-time step (documented).
- Unofficial API may change or rate-limit; keep the client small and tolerant.
- `webkit2gtk` version drift on Fedora can break Tauri builds — pin if needed.
