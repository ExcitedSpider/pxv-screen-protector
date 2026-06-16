/** Brief auto-dismissing notification, shown just above the status bar. */
export function Toast({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-12 flex justify-center">
      <div className="max-w-[80vw] truncate rounded-lg bg-black/75 px-4 py-2 text-[14px] text-white/95 ring-1 ring-white/15 backdrop-blur-md [text-shadow:0_1px_3px_rgba(0,0,0,0.95)]">
        {message}
      </div>
    </div>
  );
}
