//! System stats for the status bar: physical memory use and connection type.
//! Pure `/proc` + `/sys` reads — no external processes, no extra crates.

use serde::Serialize;
use std::sync::Mutex;

#[derive(Serialize)]
pub struct SystemStats {
    pub mem_used_kb: u64,
    pub mem_total_kb: u64,
    pub cpu_pct: f32,
    pub disk_used_kb: u64,
    pub disk_total_kb: u64,
    pub network: String,
}

pub fn collect() -> SystemStats {
    let (mem_used, mem_total) = meminfo();
    let (disk_used, disk_total) = disk_space();
    SystemStats {
        mem_used_kb: mem_used,
        mem_total_kb: mem_total,
        cpu_pct: cpu_percent(),
        disk_used_kb: disk_used,
        disk_total_kb: disk_total,
        network: network_kind(),
    }
}

// --- CPU --------------------------------------------------------------------

// Previous (idle, total) jiffies, so each call reports utilization over the
// interval since the last poll (~2s).
static CPU_PREV: Mutex<Option<(u64, u64)>> = Mutex::new(None);

fn cpu_percent() -> f32 {
    let Some((idle, total)) = read_cpu_times() else {
        return 0.0;
    };
    let mut prev = CPU_PREV.lock().unwrap();
    let pct = match *prev {
        Some((pidle, ptotal)) if total > ptotal => {
            let d_total = (total - ptotal) as f64;
            let d_idle = idle.saturating_sub(pidle) as f64;
            (((d_total - d_idle) / d_total) * 100.0) as f32
        }
        _ => 0.0, // first sample: no interval to diff against yet
    };
    *prev = Some((idle, total));
    pct.clamp(0.0, 100.0)
}

/// (idle_jiffies, total_jiffies) from the aggregate "cpu" line of /proc/stat.
fn read_cpu_times() -> Option<(u64, u64)> {
    let text = std::fs::read_to_string("/proc/stat").ok()?;
    let line = text.lines().next()?;
    let mut it = line.split_whitespace();
    if it.next()? != "cpu" {
        return None;
    }
    // user nice system idle iowait irq softirq steal guest guest_nice
    let vals: Vec<u64> = it.filter_map(|v| v.parse().ok()).collect();
    if vals.len() < 5 {
        return None;
    }
    let idle = vals[3] + vals[4]; // idle + iowait
    let total: u64 = vals.iter().sum();
    Some((idle, total))
}

// --- Disk -------------------------------------------------------------------

/// (used_kb, total_kb) for the root filesystem via statvfs(2).
fn disk_space() -> (u64, u64) {
    let path = match std::ffi::CString::new("/") {
        Ok(p) => p,
        Err(_) => return (0, 0),
    };
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut stat) } != 0 {
        return (0, 0);
    }
    let frsize = stat.f_frsize as u64;
    let total = stat.f_blocks as u64 * frsize;
    let free = stat.f_bfree as u64 * frsize;
    let used = total.saturating_sub(free);
    (used / 1024, total / 1024)
}

/// (used_kb, total_kb), where used = MemTotal - MemAvailable.
fn meminfo() -> (u64, u64) {
    let text = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let mut total = 0u64;
    let mut avail = 0u64;
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("MemTotal:") {
            total = parse_kb(v);
        } else if let Some(v) = line.strip_prefix("MemAvailable:") {
            avail = parse_kb(v);
        }
    }
    (total.saturating_sub(avail), total)
}

fn parse_kb(s: &str) -> u64 {
    s.split_whitespace()
        .next()
        .and_then(|n| n.parse().ok())
        .unwrap_or(0)
}

/// "Wi-Fi", "Ethernet", "VPN", "Offline" — with "· VPN" appended when a tunnel
/// rides on top of a physical link.
fn network_kind() -> String {
    let base = match default_route_iface() {
        Some(i) if is_tunnel(&i) => return "VPN".to_string(),
        Some(i) if is_wireless(&i) => "Wi-Fi",
        Some(_) => "Ethernet",
        None => return "Offline".to_string(),
    };
    if any_tunnel_up() {
        format!("{base} · VPN")
    } else {
        base.to_string()
    }
}

/// Interface of the IPv4 default route with the lowest metric.
fn default_route_iface() -> Option<String> {
    let text = std::fs::read_to_string("/proc/net/route").ok()?;
    let mut best: Option<(String, u64)> = None;
    for line in text.lines().skip(1) {
        let cols: Vec<&str> = line.split_whitespace().collect();
        // Iface Destination Gateway Flags RefCnt Use Metric ...
        if cols.len() < 7 || cols[1] != "00000000" {
            continue;
        }
        let iface = cols[0].to_string();
        let metric = cols[6].parse::<u64>().unwrap_or(u64::MAX);
        if best.as_ref().map_or(true, |(_, m)| metric < *m) {
            best = Some((iface, metric));
        }
    }
    best.map(|(i, _)| i)
}

fn is_wireless(iface: &str) -> bool {
    let base = format!("/sys/class/net/{iface}");
    std::path::Path::new(&format!("{base}/wireless")).exists()
        || std::path::Path::new(&format!("{base}/phy80211")).exists()
}

fn is_tunnel(iface: &str) -> bool {
    const PREFIXES: [&str; 7] = ["tun", "tap", "wg", "ppp", "proton", "nordlynx", "mullvad"];
    PREFIXES.iter().any(|p| iface.starts_with(p))
        || std::path::Path::new(&format!("/sys/class/net/{iface}/tun_flags")).exists()
}

fn any_tunnel_up() -> bool {
    let Ok(dir) = std::fs::read_dir("/sys/class/net") else {
        return false;
    };
    for entry in dir.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if is_tunnel(&name) && iface_up(&name) {
            return true;
        }
    }
    false
}

/// IFF_UP (0x1) from the interface flags bitmask.
fn iface_up(iface: &str) -> bool {
    std::fs::read_to_string(format!("/sys/class/net/{iface}/flags"))
        .ok()
        .and_then(|s| u64::from_str_radix(s.trim().trim_start_matches("0x"), 16).ok())
        .map(|flags| flags & 0x1 != 0)
        .unwrap_or(false)
}
