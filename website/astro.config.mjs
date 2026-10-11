// @ts-check
import { defineConfig } from "astro/config";
import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";

// Fleet web-stack standard (AGENTS.md):
//   - Astro for marketing / landing surfaces
//   - Tailwind v4 via @tailwindcss/vite
//   - Lightning CSS as transformer + minifier
//   - Inline critical CSS on every prerendered page
//
// Cloudflare Pages deployment: `pages_build_output_dir: dist`.
export default defineConfig({
  site: "https://heypace.app",
  output: "static",
  compressHTML: true,
  integrations: [react()],
  build: {
    // Flat-inlines per-page CSS so the LCP element does not wait on a
    // separate render-blocking stylesheet (the 164 KB shared CSS delayed
    // first paint by ~2.5 s in mobile Lighthouse).
    inlineStylesheets: "always",
  },
  vite: {
    plugins: [tailwindcss()],
    css: {
      transformer: "lightningcss",
    },
    build: {
      cssMinify: "lightningcss",
    },
  },
});
