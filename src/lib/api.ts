import { invoke } from "@tauri-apps/api/core";

export type FeedMode = "following_daily" | "tag_search";

export interface Slide {
  illust_id: number;
  title: string;
  artist: string;
  image_url: string;
  page: number;
  page_count: number;
  total_bookmarks: number | null;
  source_tags: string[];
}

export interface SlideShow {
  slides: Slide[];
  interval_secs: number;
  day: string;
  feed_mode: FeedMode;
  label: string;
}

export interface SystemStats {
  mem_used_kb: number;
  mem_total_kb: number;
  cpu_pct: number;
  disk_used_kb: number;
  disk_total_kb: number;
  network: string;
}

export const loadSlideshow = (mode?: FeedMode) =>
  invoke<SlideShow>("load_slideshow", mode ? { mode } : {});
export const systemStats = () => invoke<SystemStats>("system_stats");
export const quit = () => invoke("quit");

/** Save the given illustration to the configured folder; returns a status string. */
export const saveIllustration = (slide: Slide) =>
  invoke<string>("save_illustration", { slide });

/** Wrap a raw i.pximg.net URL in the custom protocol that adds the Referer. */
export const pximg = (url: string) =>
  "pximg://localhost/" + encodeURIComponent(url);
