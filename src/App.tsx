import { useCallback, useEffect, useRef, useState } from "react";
import { Slideshow } from "./components/Slideshow";
import { StatusBar } from "./components/StatusBar";
import { StatusOverlay } from "./components/StatusOverlay";
import { LoadingBar } from "./components/LoadingBar";
import { Toast } from "./components/Toast";
import { HelpOverlay } from "./components/HelpOverlay";
import {
  loadSlideshow,
  systemStats,
  saveIllustration,
  quit,
  pximg,
  type FeedMode,
  type HelpInfo,
  type Slide,
  type SystemStats,
} from "./lib/api";

const feedModeLabel = (mode?: FeedMode | null) =>
  mode === "tag_search" ? "Tag feed" : "Following feed";

const nextFeedMode = (mode?: FeedMode | null): FeedMode =>
  mode === "tag_search" ? "following_daily" : "tag_search";

const isHelpKey = (e: KeyboardEvent) => e.key === "?" || (e.key === "/" && e.shiftKey);

export default function App() {
  const [slides, setSlides] = useState<Slide[]>([]);
  const [idx, setIdx] = useState(0);
  const [paused, setPaused] = useState(false);
  const [message, setMessage] = useState<string | null>("Loading your feed…");
  const [intervalMs, setIntervalMs] = useState(300000);
  const [navTick, setNavTick] = useState(0); // bumped to reset the countdown
  const [stats, setStats] = useState<SystemStats | null>(null);
  const [clock, setClock] = useState("");
  const [loading, setLoading] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [feedMode, setFeedMode] = useState<FeedMode | null>(null);
  const [helpInfo, setHelpInfo] = useState<HelpInfo | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const toastTimer = useRef<number | undefined>(undefined);
  // Latest slide, reachable from the (stable) keyboard handler.
  const currentRef = useRef<Slide | undefined>(undefined);
  const feedModeRef = useRef<FeedMode | null>(null);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 2600);
  }, []);

  const load = useCallback(async (mode?: FeedMode) => {
    const requestedMode = mode ?? feedModeRef.current ?? undefined;
    try {
      setMessage(
        requestedMode
          ? `Loading ${feedModeLabel(requestedMode).toLowerCase()}…`
          : "Loading your feed…",
      );
      const data = await loadSlideshow(requestedMode);
      feedModeRef.current = data.feed_mode;
      setFeedMode(data.feed_mode);
      setHelpInfo(data.help);
      setIntervalMs(data.interval_secs * 1000);
      if (data.slides.length === 0) {
        setSlides([]);
        const empty =
          data.feed_mode === "tag_search"
            ? "No illustrations found for tags"
            : "No illustrations from your follows";
        setMessage(`${empty} for ${data.label || data.day}.`);
        return;
      }
      setSlides(data.slides);
      setIdx(0);
      setMessage(null);
    } catch (e) {
      setMessage("Error: " + String(e));
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  // Auto-advance.
  useEffect(() => {
    if (paused || slides.length < 2) return;
    const id = setInterval(
      () => setIdx((i) => (i + 1) % slides.length),
      intervalMs,
    );
    return () => clearInterval(id);
  }, [paused, slides.length, intervalMs, navTick]);

  // Preload both neighbours so stepping either way stays instant (the webview
  // keeps them decoded in memory).
  useEffect(() => {
    if (slides.length < 2) return;
    const n = slides.length;
    for (const offset of [1, -1]) {
      const neighbour = slides[(idx + offset + n) % n];
      if (neighbour) {
        const img = new Image();
        img.src = pximg(neighbour.image_url);
      }
    }
  }, [idx, slides]);

  // Keyboard controls.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isHelpKey(e)) {
        e.preventDefault();
        setHelpOpen((open) => !open);
        return;
      }
      if (helpOpen) {
        if (e.key === "Escape") {
          setHelpOpen(false);
        }
        return;
      }

      switch (e.key) {
        case "ArrowRight":
          if (slides.length) {
            setIdx((i) => (i + 1) % slides.length);
            setNavTick((t) => t + 1);
          }
          break;
        case "ArrowLeft":
          if (slides.length) {
            setIdx((i) => (i - 1 + slides.length) % slides.length);
            setNavTick((t) => t + 1);
          }
          break;
        case " ":
          e.preventDefault();
          setPaused((p) => !p);
          break;
        case "r":
        case "R":
          load();
          break;
        case "m":
        case "M": {
          const nextMode = nextFeedMode(feedModeRef.current);
          showToast(`Switching to ${feedModeLabel(nextMode).toLowerCase()}…`);
          load(nextMode);
          break;
        }
        case "s":
        case "S": {
          const slide = currentRef.current;
          if (!slide) break;
          showToast("Saving…");
          saveIllustration(slide)
            .then(showToast)
            .catch((err) => showToast("Save failed: " + String(err)));
          break;
        }
        case "Escape":
          quit();
          break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [slides.length, load, showToast, helpOpen]);

  // System stats, every 2s.
  useEffect(() => {
    const poll = async () => {
      try {
        setStats(await systemStats());
      } catch {
        setStats(null);
      }
    };
    poll();
    const id = setInterval(poll, 2000);
    return () => clearInterval(id);
  }, []);

  // Clock, every 1s.
  useEffect(() => {
    const tick = () => {
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
      setClock(`${date} ${time}`);
    };
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, []);

  const current = slides[idx];
  const overlay = paused && slides.length ? "⏸ paused" : message;
  currentRef.current = current;

  return (
    <>
      <Slideshow
        url={current ? pximg(current.image_url) : ""}
        onLoadingChange={setLoading}
      />
      <LoadingBar active={loading} />
      <StatusOverlay message={overlay} />
      <Toast message={toast} />
      <HelpOverlay open={helpOpen} activeMode={feedMode} help={helpInfo} />
      <StatusBar
        slide={current}
        idx={idx}
        total={slides.length}
        stats={stats}
        clock={clock}
        feedMode={feedMode}
      />
    </>
  );
}
