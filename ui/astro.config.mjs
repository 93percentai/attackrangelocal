import { defineConfig } from "astro/config";
import node from "@astrojs/node";
import tailwindcss from "@tailwindcss/vite";

// Server-rendered: the /api routes shell out to ludus/tailscale on the host.
export default defineConfig({
  output: "server",
  adapter: node({ mode: "standalone" }),
  server: { host: "0.0.0.0", port: 4321 },
  vite: {
    plugins: [tailwindcss()],
  },
});
