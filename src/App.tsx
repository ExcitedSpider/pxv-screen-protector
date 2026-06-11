import { useCallback, useEffect, useState } from "react";
import { Slideshow } from "./components/Slideshow";
import { StatusBar } from "./components/StatusBar";
import { StatusOverlay } from "./components/StatusOverlay";
import {
  loadSlideshow,
  systemStats,
  quit,
  pximg,
  type Slide,
  type SystemStats,
} from "./lib/api";

export default function App() {
  const [slides, setSlides] = useState<Slide[]>([]);
  const [idx, setIdx] = useState(0);
  const [paused, setPaused] = useState(false);
  const [message, setMessage] = useState<string | null>("Loading your feed…");
  const [intervalMs, setIntervalMs] = useState(300000);
  const [navTick, setNavTick] = useState(0); // bumped to reset the countdown
  const [stats, setStats] = useState<SystemStats | null>(null);
  const [clock, setClock] = useState("");

  const load = useCallback(async () => {
    try {
      setMessage("Loading your feed…");
      const data = await loadSlideshow();
      setIntervalMs(data.interval_secs * 1000);
      if (data.slides.length === 0) {
        setSlides([]);
        setMessage(`No illustrations from your follows for ${data.day}.`);
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

  // Preload the next image.
  useEffect(() => {
    if (slides.length < 2) return;
    const next = slides[(idx + 1) % slides.length];
    if (next) {
      const img = new Image();
      img.src = pximg(next.image_url);
    }
  }, [idx, slides]);

  // Keyboard controls.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
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
        case "Escape":
          quit();
          break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [slides.length, load]);

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

  return (
    <>
      <Slideshow url={current ? pximg(current.image_url) : ""} />
      <StatusOverlay message={overlay} />
      <StatusBar
        slide={current}
        idx={idx}
        total={slides.length}
        stats={stats}
        clock={clock}
      />
    </>
  );
}
