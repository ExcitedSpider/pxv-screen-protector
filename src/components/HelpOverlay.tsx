import type { FeedMode, HelpInfo } from "../lib/api";

const modeName = (mode?: string | null) =>
  mode === "tag_search" || mode === "tags" ? "Tag feed" : "Following feed";

const boolText = (value?: boolean) => (value ? "enabled" : "disabled");

const decayText = (lambda?: number) => {
  const value = lambda ?? 0.15;
  if (value <= 0) return "disabled";
  return `${value.toFixed(3)} (${(Math.log(2) / value).toFixed(1)}d half-life)`;
};

const shortcutRows = (help: HelpInfo | null, activeMode: FeedMode | null) => [
  ["Left / Right", "previous / next slide"],
  ["Page Up / Down", "jump back / forward 10 slides"],
  ["Home / End", "first / last slide"],
  ["Space", "pause / resume"],
  [
    "S",
    help?.bookmark_on_save &&
    help.tag_search.follow_when_bookmark &&
    activeMode === "tag_search"
      ? "save, bookmark, and follow the author"
      : help?.bookmark_on_save
        ? "save current illustration and bookmark it"
        : "save current illustration",
  ],
  ["R", "reload current feed"],
  ["M", "switch feed mode"],
  ["?", "show / hide help"],
  ["Esc", "close help, otherwise quit"],
];

function ConfigRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-[150px_minmax(0,1fr)] gap-4 border-t border-white/10 py-2 first:border-t-0">
      <dt className="text-white/55">{label}</dt>
      <dd className="min-w-0 break-words text-white/90">{value}</dd>
    </div>
  );
}

export function HelpOverlay({
  open,
  activeMode,
  help,
}: {
  open: boolean;
  activeMode: FeedMode | null;
  help: HelpInfo | null;
}) {
  if (!open) return null;

  const tagTags = help?.tag_search.tags.length
    ? help.tag_search.tags.join(", ")
    : "not configured";
  const bookmarkTags = help?.bookmark_tags.length
    ? help.bookmark_tags.join(", ")
    : "none";

  return (
    <div className="fixed inset-0 z-[80] bg-black/[0.88] px-6 py-8 text-white backdrop-blur-md">
      <div className="mx-auto flex h-full max-w-[980px] flex-col overflow-hidden">
        <div className="mb-6 flex items-baseline justify-between gap-6">
          <div>
            <h1 className="text-[30px] font-semibold tracking-normal">Help</h1>
            <p className="mt-1 text-[14px] text-white/60">
              Active: {modeName(activeMode)}
            </p>
          </div>
          <div className="text-[13px] text-white/50">Press ? to close</div>
        </div>

        <div className="grid min-h-0 flex-1 gap-6 overflow-y-auto pb-2 md:grid-cols-[0.85fr_1.15fr]">
          <section>
            <h2 className="mb-3 text-[15px] font-semibold uppercase tracking-[0.12em] text-white/55">
              Shortcuts
            </h2>
            <dl className="rounded-lg bg-white/[0.06] p-4 ring-1 ring-white/10">
              {shortcutRows(help, activeMode).map(([key, action]) => (
                <div
                  key={key}
                  className="grid grid-cols-[104px_minmax(0,1fr)] gap-4 border-t border-white/10 py-2 first:border-t-0"
                >
                  <dt className="font-semibold text-white">{key}</dt>
                  <dd className="text-white/75">{action}</dd>
                </div>
              ))}
            </dl>
          </section>

          <section>
            <h2 className="mb-3 text-[15px] font-semibold uppercase tracking-[0.12em] text-white/55">
              Mode Config
            </h2>
            <div className="rounded-lg bg-white/[0.06] p-4 ring-1 ring-white/10">
              <dl>
                <ConfigRow
                  label="Startup mode"
                  value={modeName(help?.configured_feed_mode)}
                />
                <ConfigRow
                  label="Slide interval"
                  value={`${help?.slide_interval_secs ?? 300}s`}
                />
                <ConfigRow
                  label="Page cap"
                  value={`${help?.max_pages_per_post ?? 3} per post`}
                />
                <ConfigRow
                  label="Bookmark on save"
                  value={boolText(help?.bookmark_on_save)}
                />
                <ConfigRow
                  label="Bookmark visibility"
                  value={help?.bookmark_restrict ?? "private"}
                />
                <ConfigRow label="Bookmark tags" value={bookmarkTags} />
              </dl>

              <h3 className="mt-5 text-[14px] font-semibold text-white">
                Following Feed
              </h3>
              <dl className="mt-2">
                <ConfigRow
                  label="Range"
                  value={help ? `yesterday (${help.following_daily.day})` : "yesterday"}
                />
                <ConfigRow
                  label="Empty fallback"
                  value={boolText(help?.following_daily.empty_day_fallback)}
                />
              </dl>

              <h3 className="mt-5 text-[14px] font-semibold text-white">
                Tag Feed
              </h3>
              <dl className="mt-2">
                <ConfigRow label="Tags" value={tagTags} />
                <ConfigRow
                  label="Public follow on bookmark"
                  value={boolText(help?.tag_search.follow_when_bookmark)}
                />
                <ConfigRow
                  label="Range"
                  value={`${help?.tag_search.range_days ?? 30} days`}
                />
                <ConfigRow
                  label="Search target"
                  value={help?.tag_search.search_target ?? "exact_match_for_tags"}
                />
                <ConfigRow
                  label="Sort"
                  value={help?.tag_search.sort ?? "popular_desc"}
                />
                <ConfigRow
                  label="Per tag cap"
                  value={`${help?.tag_search.max_results_per_tag ?? 30} results`}
                />
                <ConfigRow
                  label="Min bookmarks"
                  value={`${help?.tag_search.min_bookmarks ?? 0}`}
                />
                <ConfigRow
                  label="Page scan cap"
                  value={`${help?.tag_search.max_search_pages_per_tag ?? 10} pages`}
                />
                <ConfigRow
                  label="Slide cap"
                  value={`${help?.tag_search.max_slides ?? 120} slides`}
                />
                <ConfigRow
                  label="Fallback"
                  value={help?.tag_search.fallback_without_popular_sort ?? "error"}
                />
                <ConfigRow
                  label="Merge"
                  value={help?.tag_search.merge_strategy ?? "raw_bookmarks"}
                />
                <ConfigRow
                  label="Recency decay"
                  value={decayText(help?.tag_search.recency_decay_lambda)}
                />
              </dl>
            </div>
          </section>
        </div>
      </div>
    </div>
  );
}
