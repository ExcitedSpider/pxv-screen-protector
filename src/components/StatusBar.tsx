import type { Slide, SystemStats } from "../lib/api";

const gb = (kb: number, dp = 0) => (kb / 1048576).toFixed(dp);

const shadow = "[text-shadow:0_1px_3px_rgba(0,0,0,0.95)]";

export function StatusBar({
  slide,
  idx,
  total,
  stats,
  clock,
}: {
  slide?: Slide;
  idx: number;
  total: number;
  stats: SystemStats | null;
  clock: string;
}) {
  const pageInfo =
    slide && slide.page_count > 1 ? ` (${slide.page}/${slide.page_count})` : "";

  return (
    <div
      className={`pointer-events-none fixed inset-x-0 bottom-0 flex h-[34px] items-center justify-between bg-gradient-to-t from-black/70 to-transparent px-[18px] text-[13px] text-neutral-200 ${shadow}`}
    >
      <div className="flex min-w-0 items-baseline gap-2 overflow-hidden whitespace-nowrap">
        {slide && (
          <>
            <span className="font-semibold">{slide.artist}</span>
            <span className="opacity-60">—</span>
            <span className="overflow-hidden text-ellipsis opacity-90">
              {slide.title}
              {pageInfo}
            </span>
          </>
        )}
      </div>

      <div className="flex shrink-0 items-baseline gap-4 tabular-nums opacity-90">
        {total > 0 && (
          <span>
            {idx + 1} / {total}
          </span>
        )}
        {stats && <span>CPU {Math.round(stats.cpu_pct)}%</span>}
        {stats && stats.mem_total_kb > 0 && (
          <span>
            RAM {gb(stats.mem_used_kb, 1)}/{gb(stats.mem_total_kb, 1)} GB
          </span>
        )}
        {stats && stats.disk_total_kb > 0 && (
          <span>
            Disk {gb(stats.disk_used_kb)}/{gb(stats.disk_total_kb)} GB
          </span>
        )}
        {stats && <span>{stats.network}</span>}
        <span>{clock}</span>
      </div>
    </div>
  );
}
