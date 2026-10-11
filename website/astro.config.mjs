// @ts-check
import { defineConfig } from "astro/config";
import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";

// Fleet web-stack standard (AGENTS.md):
//   - Astro for marketing / landing surfaces
//   - Tailwind v4 via @tailwindcss/vite
//   - Lightning CSS as transformer + minifier
//   - Cache substantial CSS in external stylesheets
//
// Cloudflare Pages deployment: `pages_build_output_dir: dist`.
export default defineConfig({
  site: "https://heypace.app",
  output: "static",
  compressHTML: true,
  integrations: [react()],
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
