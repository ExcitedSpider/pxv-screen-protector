import { useEffect, useState } from "react";

/**
 * Thin indeterminate progress bar along the top, shown while the next image is
 * loading. A short delay before appearing keeps it from flashing on images that
 * load instantly (e.g. the preloaded next slide).
 */
export function LoadingBar({ active }: { active: boolean }) {
  const [show, setShow] = useState(false);

  useEffect(() => {
    if (!active) {
      setShow(false);
      return;
    }
    const t = setTimeout(() => setShow(true), 120);
    return () => clearTimeout(t);
  }, [active]);

  return (
    <div
      className={`pointer-events-none fixed inset-x-0 top-0 z-50 h-[3px] overflow-hidden transition-opacity duration-200 ${
        show ? "opacity-100" : "opacity-0"
      }`}
    >
      <div className="absolute inset-0 bg-white/10" />
      <div className="absolute h-full bg-[#3ea8ff] animate-[loading-slide_1.1s_ease-in-out_infinite]" />
    </div>
  );
}
