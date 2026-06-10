const { invoke } = window.__TAURI__.core;

const layers = Array.from(document.querySelectorAll(".layer"));
let front = 0;
const statusEl = document.getElementById("status");
const sbArtist = document.getElementById("sb-artist");
const sbTitle = document.getElementById("sb-title");
const sbPos = document.getElementById("sb-pos");
const sbCpu = document.getElementById("sb-cpu");
const sbMem = document.getElementById("sb-mem");
const sbDisk = document.getElementById("sb-disk");
const sbNet = document.getElementById("sb-net");
const sbClock = document.getElementById("sb-clock");

let slides = [];
let idx = 0;
let intervalMs = 300000;
let paused = false;
let timer = null;

function pximg(url) {
  return "pximg://localhost/" + encodeURIComponent(url);
}

function showStatus(msg) {
  statusEl.textContent = msg || "";
  statusEl.style.display = msg ? "block" : "none";
}

function showImage(url) {
  const backEl = layers[1 - front];
  const frontEl = layers[front];
  // Bring the back layer in only once its image has decoded, then fade the
  // old one out. Each layer holds exactly one image, so no ghosting.
  backEl.onload = () => {
    backEl.classList.add("active");
    frontEl.classList.remove("active");
    front = 1 - front;
  };
  backEl.src = url;
}

function render() {
  if (slides.length === 0) return;
  const s = slides[idx];
  showImage(pximg(s.image_url));

  const pageInfo = s.page_count > 1 ? ` (${s.page}/${s.page_count})` : "";
  sbArtist.textContent = s.artist;
  sbTitle.textContent = `${s.title}${pageInfo}`;
  sbPos.textContent = `${idx + 1} / ${slides.length}`;

  // Preload the next image.
  const nextIdx = (idx + 1) % slides.length;
  if (slides[nextIdx]) {
    const pre = new Image();
    pre.src = pximg(slides[nextIdx].image_url);
  }
}

function next() {
  idx = (idx + 1) % slides.length;
  render();
}

function prev() {
  idx = (idx - 1 + slides.length) % slides.length;
  render();
}

function restartTimer() {
  if (timer) clearInterval(timer);
  if (!paused && slides.length > 1) {
    timer = setInterval(next, intervalMs);
  }
}

async function load() {
  try {
    showStatus("Loading your feed…");
    const data = await invoke("load_slideshow");
    slides = data.slides;
    intervalMs = data.interval_secs * 1000;

    if (slides.length === 0) {
      showStatus(`No illustrations from your follows for ${data.day}.`);
      sbArtist.textContent = "";
      sbTitle.textContent = "";
      sbPos.textContent = "";
      return;
    }

    idx = 0;
    showStatus("");
    render();
    restartTimer();
  } catch (e) {
    showStatus("Error: " + e);
  }
}

document.addEventListener("keydown", (e) => {
  switch (e.key) {
    case "ArrowRight":
      if (slides.length) {
        next();
        restartTimer();
      }
      break;
    case "ArrowLeft":
      if (slides.length) {
        prev();
        restartTimer();
      }
      break;
    case " ":
      e.preventDefault();
      paused = !paused;
      restartTimer();
      showStatus(paused ? "⏸ paused" : "");
      if (!paused) setTimeout(() => showStatus(""), 700);
      break;
    case "r":
    case "R":
      load();
      break;
    case "Escape":
      invoke("quit");
      break;
  }
});

// --- status bar: clock + system stats ---------------------------------------

function gb(kb, dp = 0) {
  return (kb / 1048576).toFixed(dp);
}

function updateClock() {
  const now = new Date();
  const date = now.toLocaleDateString(undefined, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const time = now.toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
  });
  sbClock.textContent = `${date} ${time}`;
}

async function pollStats() {
  try {
    const stats = await invoke("system_stats");
    sbCpu.textContent = `CPU ${Math.round(stats.cpu_pct)}%`;
    sbMem.textContent = stats.mem_total_kb
      ? `RAM ${gb(stats.mem_used_kb, 1)}/${gb(stats.mem_total_kb, 1)} GB`
      : "";
    sbDisk.textContent = stats.disk_total_kb
      ? `Disk ${gb(stats.disk_used_kb)}/${gb(stats.disk_total_kb)} GB`
      : "";
    sbNet.textContent = stats.network;
  } catch {
    sbCpu.textContent = "";
    sbMem.textContent = "";
    sbDisk.textContent = "";
    sbNet.textContent = "";
  }
}

updateClock();
setInterval(updateClock, 1000);
pollStats();
setInterval(pollStats, 2000);

load();
