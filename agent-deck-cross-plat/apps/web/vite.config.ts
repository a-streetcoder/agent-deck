import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// In dev, the API/WS live on the Node server (default :4200); the built app is
// served BY that server, so all paths are same-origin in production.
const serverTarget = process.env.AGENT_DECK_SERVER_URL ?? "http://127.0.0.1:4200";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5199,
    proxy: {
      "/ws": { target: serverTarget, ws: true },
      "/sessions": { target: serverTarget },
      "/health": { target: serverTarget },
    },
  },
});
