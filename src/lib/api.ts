import { invoke } from "@tauri-apps/api/core";

export type FeedMode = "following_daily" | "tag_search";

export interface SlideTag {
  name: string;
  translated_name: string | null;
}

export interface Slide {
  illust_id: number;
  user_id: number;
  is_followed?: boolean | null;
  is_bookmarked?: boolean | null;
  title: string;
  artist: string;
  create_date: string;
  caption: string;
  tags: SlideTag[];
  width: number | null;
  height: number | null;
  total_views: number | null;
  x_restrict: number | null;
  image_url: string;
  page: number;
  page_count: number;
  total_bookmarks: number | null;
  source_tags: string[];
  best_tag_rank: number | null;
  median_like_score: number | null;
  ranking_score: number | null;
}

export interface SaveRequest extends Slide {
  feed_mode: FeedMode;
}

export interface SaveIllustrationResult {
  message: string;
  is_bookmarked: boolean | null;
  is_followed: boolean | null;
}

export interface SlideShow {
  slides: Slide[];
  interval_secs: number;
  day: string;
  feed_mode: FeedMode;
  label: string;
  help: HelpInfo;
}

export interface HelpInfo {
  configured_feed_mode: string;
  slide_interval_secs: number;
  max_pages_per_post: number;
  avoid_nsfw: boolean;
  bookmark_on_save: boolean;
  bookmark_restrict: string;
  bookmark_tags: string[];
  following_daily: FollowingDailyHelp;
  tag_search: TagSearchHelp;
}

export interface ApplicationInfo {
  version: string;
  build_date: string;
}

export interface FollowingDailyHelp {
  day: string;
  empty_day_fallback: boolean;
}

export type AspectRatioFilter = "any" | "horizontal" | "vertical";

export interface TagSearchHelp {
  tags: string[];
  exclude_tags: string[];
  aspect_ratio: AspectRatioFilter;
  follow_when_bookmark: boolean;
  range_days: number;
  search_target: string;
  sort: string;
  max_results_per_tag: number;
  min_bookmarks: number;
  max_search_pages_per_tag: number;
  max_slides: number;
  fallback_without_popular_sort: string;
  merge_strategy: string;
  recency_decay_lambda: number;
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
export const getApplicationInfo = () =>
  invoke<ApplicationInfo>("application_info");
export const systemStats = () => invoke<SystemStats>("system_stats");
export const quit = () => invoke("quit");

/** Save the illustration and return its latest known bookmark/follow state. */
export const saveIllustration = (slide: Slide, mode: FeedMode) =>
  invoke<SaveIllustrationResult>("save_illustration", {
    slide: { ...slide, feed_mode: mode } satisfies SaveRequest,
  });

/** Wrap a raw i.pximg.net URL in the custom protocol that adds the Referer. */
export const pximg = (url: string) =>
  "pximg://localhost/" + encodeURIComponent(url);
