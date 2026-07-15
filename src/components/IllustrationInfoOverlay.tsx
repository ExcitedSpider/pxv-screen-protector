import type { FeedMode, Slide } from "../lib/api";

const numberText = (value?: number | null) =>
  value == null ? "Unknown" : value.toLocaleString();

const stateText = (value?: boolean | null) =>
  value == null ? "Unknown" : value ? "Yes" : "No";

const ratingText = (value?: number | null) => {
  switch (value) {
    case 0:
      return "General";
    case 1:
      return "R-18";
    case 2:
      return "R-18G";
    default:
      return "Unknown";
  }
};

const dateText = (value?: string | null) => {
  if (!value) return "Unknown";

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Unknown";

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
};

const plainTextCaption = (caption?: string | null) => {
  if (!caption) return "";

  const withLineBreaks = caption
    .replace(/<\s*br\s*\/?\s*>/gi, "\n")
    .replace(/<\/\s*(?:div|p|li|h[1-6])\s*>/gi, "\n");

  let text: string;
  if (typeof DOMParser !== "undefined") {
    const document = new DOMParser().parseFromString(withLineBreaks, "text/html");
    text = document.body.textContent ?? "";
  } else {
    text = withLineBreaks
      .replace(/<[^>]*>/g, "")
      .replace(/&nbsp;/gi, " ")
      .replace(/&amp;/gi, "&")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">")
      .replace(/&quot;/gi, '"')
      .replace(/&#39;|&apos;/gi, "'");
  }

  return text
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
};

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-[130px_minmax(0,1fr)] gap-4 border-t border-white/10 py-2 first:border-t-0">
      <dt className="text-white/55">{label}</dt>
      <dd className="min-w-0 break-words text-white/90">{value}</dd>
    </div>
  );
}

function scoreText(value?: number | null) {
  return value == null ? "Unknown" : `${value.toFixed(2)}×`;
}

export function IllustrationInfoOverlay({
  open,
  slide,
  feedMode,
}: {
  open: boolean;
  slide?: Slide;
  feedMode: FeedMode | null;
}) {
  if (!open) return null;

  const caption = plainTextCaption(slide?.caption);
  const dimensions =
    slide?.width == null || slide.height == null
      ? "Unknown"
      : `${slide.width.toLocaleString()} × ${slide.height.toLocaleString()} px`;
  const pixivUrl = slide
    ? `https://www.pixiv.net/artworks/${slide.illust_id}`
    : "";

  return (
    <div
      aria-label="Illustration information"
      aria-modal="true"
      className="fixed inset-0 z-[80] cursor-auto select-text bg-black/[0.88] px-6 py-8 text-white backdrop-blur-md"
      role="dialog"
    >
      <div className="mx-auto flex h-full max-w-[980px] flex-col overflow-hidden">
        <header className="mb-6 flex items-start justify-between gap-6">
          <div className="min-w-0">
            <h1 className="text-[30px] font-semibold tracking-normal">
              Illustration Information
            </h1>
            {slide && (
              <p className="mt-1 break-words text-[16px] text-white/85">
                {slide.title || "Untitled"}
                <span className="text-white/45"> · </span>
                <span className="text-white/65">{slide.artist || "Unknown artist"}</span>
              </p>
            )}
          </div>
          <div className="shrink-0 pt-2 text-[13px] text-white/50">
            Press I or Esc to close
          </div>
        </header>

        <div className="min-h-0 flex-1 overflow-y-auto pb-2 pr-1">
          {!slide ? (
            <div className="rounded-lg bg-white/[0.06] p-5 text-white/70 ring-1 ring-white/10">
              No illustration is selected.
            </div>
          ) : (
            <div className="grid gap-6 md:grid-cols-2">
              <section>
                <h2 className="mb-3 text-[15px] font-semibold uppercase tracking-[0.12em] text-white/55">
                  Illustration
                </h2>
                <dl className="rounded-lg bg-white/[0.06] p-4 ring-1 ring-white/10">
                  <InfoRow label="Illustration ID" value={`${slide.illust_id}`} />
                  <InfoRow label="Pixiv URL" value={pixivUrl} />
                  <InfoRow label="User ID" value={`${slide.user_id}`} />
                  <InfoRow
                    label="Page"
                    value={`${slide.page.toLocaleString()} / ${slide.page_count.toLocaleString()}`}
                  />
                  <InfoRow label="Created" value={dateText(slide.create_date)} />
                  <InfoRow label="Dimensions" value={dimensions} />
                  <InfoRow label="Rating" value={ratingText(slide.x_restrict)} />
                  <InfoRow label="Views" value={numberText(slide.total_views)} />
                  <InfoRow
                    label="Bookmarks"
                    value={numberText(slide.total_bookmarks)}
                  />
                  <InfoRow
                    label="Bookmarked"
                    value={stateText(slide.is_bookmarked)}
                  />
                  <InfoRow
                    label="Following author"
                    value={stateText(slide.is_followed)}
                  />
                </dl>
              </section>

              <section>
                <h2 className="mb-3 text-[15px] font-semibold uppercase tracking-[0.12em] text-white/55">
                  Pixiv Tags
                </h2>
                <div className="rounded-lg bg-white/[0.06] p-4 ring-1 ring-white/10">
                  {slide.tags.length ? (
                    <ul className="flex flex-wrap gap-2">
                      {slide.tags.map((tag, index) => (
                        <li
                          className="max-w-full rounded-md bg-white/[0.07] px-3 py-2 ring-1 ring-white/10"
                          key={`${tag.name}-${index}`}
                        >
                          <span className="break-all text-white/90">#{tag.name}</span>
                          {tag.translated_name && tag.translated_name !== tag.name && (
                            <span className="ml-2 break-words text-white/50">
                              {tag.translated_name}
                            </span>
                          )}
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="text-white/55">No tags provided.</p>
                  )}
                </div>
              </section>

              {feedMode === "tag_search" && (
                <section>
                  <h2 className="mb-3 text-[15px] font-semibold uppercase tracking-[0.12em] text-white/55">
                    Tag Feed Match
                  </h2>
                  <dl className="rounded-lg bg-white/[0.06] p-4 ring-1 ring-white/10">
                    <InfoRow
                      label="Matched tags"
                      value={
                        slide.source_tags.length
                          ? slide.source_tags.map((tag) => `#${tag}`).join(", ")
                          : "None"
                      }
                    />
                    <InfoRow
                      label="Best rank"
                      value={
                        slide.best_tag_rank == null
                          ? "Unknown"
                          : `#${slide.best_tag_rank.toLocaleString()}`
                      }
                    />
                    <InfoRow
                      label="Ranking score"
                      value={scoreText(slide.ranking_score)}
                    />
                    <InfoRow
                      label="Median score"
                      value={scoreText(slide.median_like_score)}
                    />
                  </dl>
                </section>
              )}

              <section className={feedMode === "tag_search" ? "" : "md:col-span-2"}>
                <h2 className="mb-3 text-[15px] font-semibold uppercase tracking-[0.12em] text-white/55">
                  Caption
                </h2>
                <div className="rounded-lg bg-white/[0.06] p-4 ring-1 ring-white/10">
                  {caption ? (
                    <p className="whitespace-pre-wrap break-words leading-6 text-white/85">
                      {caption}
                    </p>
                  ) : (
                    <p className="text-white/55">No caption provided.</p>
                  )}
                </div>
              </section>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
