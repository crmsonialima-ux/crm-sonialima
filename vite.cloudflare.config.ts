// Dedicated Cloudflare Workers build. The regular vite.config.ts remains the
// Netlify target so both providers can run in parallel during migration.
import { defineConfig } from "@lovable.dev/vite-tanstack-config";

export default defineConfig({
  nitro: {
    preset: "cloudflare-module",
    output: {
      dir: ".output",
      serverDir: ".output/server",
      publicDir: ".output/public",
    },
    cloudflare: {
      nodeCompat: true,
      // Keep the root wrangler.jsonc as the single deployment source of truth.
      deployConfig: false,
    },
  },
  tanstackStart: {
    // Preserve the existing SSR error wrapper on Workers.
    server: { entry: "server" },
  },
});
