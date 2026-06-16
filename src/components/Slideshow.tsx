import { useEffect, useState } from "react";

/**
 * A single full-screen image. Changing `url` swaps the same <img>'s src; the
 * browser keeps showing the current image until the new one decodes, then
 * swaps — no flash, no ghosting.
 *
 * `loading` is *derived* (the wanted url isn't the loaded one yet) rather than
 * set from an effect, so a fast/cached `onLoad` can't race ahead of an effect
 * and leave the indicator stuck on.
 */
export function Slideshow({
  url,
  onLoadingChange,
}: {
  url: string;
  onLoadingChange?: (loading: boolean) => void;
}) {
  const [loadedUrl, setLoadedUrl] = useState("");
  const loading = !!url && url !== loadedUrl;

  useEffect(() => {
    onLoadingChange?.(loading);
  }, [loading, onLoadingChange]);

  return (
    <img
      src={url || undefined}
      alt=""
      onLoad={() => setLoadedUrl(url)}
      onError={() => setLoadedUrl(url)}
      className="absolute inset-0 h-full w-full object-contain"
    />
  );
}
