import { defineConfig } from "astro/config";
import tailwind from "@astrojs/tailwind";
import node from "@astrojs/node";

// Server-rendered (we need API routes that shell out to ludus/tailscale).
export default defineConfig({
  output: "server",
  adapter: node({ mode: "standalone" }),
  integrations: [tailwind({ applyBaseStyles: false })],
  server: { host: "0.0.0.0", port: 4321 },
  vite: {
    server: {
      // Allow the UI to talk to the patched Attack Range REST API at :4000
      // when we run them together via docker compose.
      proxy: {},
    },
  },
});
