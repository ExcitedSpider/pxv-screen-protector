import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Runs inside the Node container; the dev server is reached from the host
// (and the Tauri webview) via the port mapping in tools/frontend/fe.sh.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  clearScreen: false,
  server: {
    host: "0.0.0.0", // bind inside the container so the host port map works
    port: 1420,
    strictPort: true,
    hmr: { host: "127.0.0.1", port: 1420 },
    // Bind-mount file events don't always propagate inotify; poll instead.
    watch: {
      usePolling: true,
      interval: 300,
      ignored: ["**/src-tauri/**", "**/*.tsbuildinfo", "**/dist/**"],
    },
  },
});
