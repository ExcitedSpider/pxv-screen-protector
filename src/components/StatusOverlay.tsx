export function StatusOverlay({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <div className="pointer-events-none fixed inset-0 flex items-center justify-center text-[20px] opacity-80 [text-shadow:0_1px_3px_rgba(0,0,0,0.95)]">
      {message}
    </div>
  );
}
