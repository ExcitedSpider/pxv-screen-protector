//! On-disk LRU cache for proxied images. The app holds nothing in RAM — it
//! writes fetched bytes to disk and serves later hits from there; the kernel
//! page cache gives fast reads and reclaims memory under pressure on its own.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

// Makes concurrent writes use distinct temp files.
static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// `$XDG_CACHE_HOME/pixiv-slides`, falling back to `~/.cache/pixiv-slides`.
pub fn cache_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
            home.join(".cache")
        });
    base.join("pixiv-slides")
}

/// Cache filename for an image URL: md5(url) + the original extension.
pub fn key_for(url: &str) -> String {
    let hash = format!("{:x}", md5::compute(url));
    let ext = url
        .rsplit('.')
        .next()
        .filter(|e| !e.is_empty() && e.len() <= 5 && e.chars().all(|c| c.is_ascii_alphanumeric()))
        .unwrap_or("img");
    format!("{hash}.{ext}")
}

/// Read a cached file, bumping its mtime so it counts as recently used (LRU).
pub fn get(dir: &Path, key: &str) -> Option<Vec<u8>> {
    let path = dir.join(key);
    let bytes = std::fs::read(&path).ok()?;
    if let Ok(f) = std::fs::File::options().write(true).open(&path) {
        let _ = f.set_modified(SystemTime::now());
    }
    Some(bytes)
}

/// Write bytes atomically (temp file + rename). Best-effort — failures are
/// ignored, since caching must never break serving the image.
pub fn put(dir: &Path, key: &str, bytes: &[u8]) {
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = dir.join(format!(".{key}.{seq}.tmp"));
    if std::fs::write(&tmp, bytes).is_ok() {
        let _ = std::fs::rename(&tmp, dir.join(key));
    } else {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// If the cache exceeds `cap_bytes`, delete oldest-by-mtime files until it's
/// back under ~90% of the cap (hysteresis avoids thrashing).
pub fn evict_if_over_cap(dir: &Path, cap_bytes: u64) {
    if cap_bytes == 0 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<(PathBuf, u64, SystemTime)> = rd
        .flatten()
        .filter_map(|e| {
            let meta = e.metadata().ok()?;
            if !meta.is_file() {
                return None;
            }
            let path = e.path();
            if path.extension().is_some_and(|x| x == "tmp") {
                return None;
            }
            Some((path, meta.len(), meta.modified().ok()?))
        })
        .collect();

    let total: u64 = entries.iter().map(|(_, size, _)| *size).sum();
    if total <= cap_bytes {
        return;
    }

    let target = cap_bytes / 10 * 9; // evict down to ~90%
    entries.sort_by_key(|(_, _, mtime)| *mtime); // oldest first

    let mut remaining = total;
    for (path, size, _) in entries {
        if remaining <= target {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            remaining = remaining.saturating_sub(size);
        }
    }
}
