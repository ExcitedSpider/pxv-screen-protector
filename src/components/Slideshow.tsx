import { useEffect, useRef, useState } from "react";

interface Layer {
  src: string;
  active: boolean;
}

/**
 * Two stacked image layers that cross-fade. The incoming layer only becomes
 * visible once its image has decoded, so the outgoing one stays until then —
 * no ghosting, no flash of empty space.
 */
export function Slideshow({ url }: { url: string }) {
  const [layers, setLayers] = useState<Layer[]>([
    { src: "", active: false },
    { src: "", active: false },
  ]);
  const frontRef = useRef(0);

  useEffect(() => {
    if (!url) return;
    const back = 1 - frontRef.current;
    setLayers((prev) =>
      prev.map((l, i) => (i === back ? { ...l, src: url } : l)),
    );
  }, [url]);

  const handleLoad = (i: number) => {
    // Only the freshly-loaded back layer drives the swap.
    if (i === frontRef.current) return;
    frontRef.current = i;
    setLayers((prev) => prev.map((l, idx) => ({ ...l, active: idx === i })));
  };

  return (
    <>
      {layers.map((layer, i) => (
        <img
          key={i}
          src={layer.src || undefined}
          alt=""
          onLoad={() => handleLoad(i)}
          className={`absolute inset-0 h-full w-full object-contain transition-opacity duration-[600ms] ${
            layer.active ? "opacity-100" : "opacity-0"
          }`}
        />
      ))}
    </>
  );
}
