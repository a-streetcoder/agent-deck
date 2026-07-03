import path from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const src = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "src");

// In dev, the API/WS live on the Node server (default :4200); the built app is
// served BY that server, so all paths are same-origin in production.
const serverTarget = process.env.AGENT_DECK_SERVER_URL ?? "http://127.0.0.1:4200";

export default defineConfig({
  plugins: [react()],
  resolve: {
    // "@/…" alias matches the archived app so salvaged components port verbatim.
    alias: { "@": src },
  },
  server: {
    port: 5199,
    proxy: {
      "/ws": { target: serverTarget, ws: true },
      "/sessions": { target: serverTarget },
      "/health": { target: serverTarget },
    },
  },
});
