export function StatusOverlay({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <div className="pointer-events-none fixed inset-0 flex items-center justify-center">
      <div className="rounded-xl bg-black/70 px-6 py-3 text-[20px] text-white/95 ring-1 ring-white/15 backdrop-blur-md [text-shadow:0_1px_3px_rgba(0,0,0,0.95)]">
        {message}
      </div>
    </div>
  );
}
