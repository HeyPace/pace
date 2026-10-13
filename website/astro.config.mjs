// @ts-check
import { defineConfig } from "astro/config";
import { fileURLToPath } from "node:url";
import { readFile, writeFile } from "node:fs/promises";
import { transform } from "lightningcss";
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
  integrations: [
    react(),
    {
      name: "pace-home-css",
      hooks: {
        "astro:build:done": async ({ dir }) => {
          const homePath = new URL("index.html", dir);
          const homeHTML = await readFile(homePath, "utf8");
          // Preserve every class in the rendered page, including responsive,
          // hover, focus and dialog variants, before removing unused utilities.
          const usedClasses = new Set(
            [...homeHTML.matchAll(/\bclass="([^"]*)"/g)].flatMap((match) =>
              match[1].replace(/&amp;/g, "&").split(/\s+/),
            ),
          );
          // The footer toggles these when selecting a feedback anchor.
          usedClasses.add("hidden");
          usedClasses.add("flex");
          let homeHTMLWithTrimmedCSS = homeHTML.replace(
            /<style\b([^>]*)>([\s\S]*?)<\/style>/g,
            (_, attributes, stylesheet) => {
              const stylesheetClasses = new Set();
              transform({
                filename: "home.css",
                code: Buffer.from(stylesheet),
                visitor: {
                  Selector(selector) {
                    JSON.stringify(selector, (key, value) => {
                      if (value?.type === "class") stylesheetClasses.add(value.name);
                      return value;
                    });
                  },
                },
              });
              const seenFontFaces = new Set();
              const trimmedCSS = transform({
                filename: "home.css",
                code: Buffer.from(stylesheet),
                minify: true,
                unusedSymbols: [...stylesheetClasses].filter(
                  (name) => !usedClasses.has(name),
                ),
                visitor: {
                  Rule: {
                    "font-face"(rule) {
                      const family = rule.value.properties.find(
                        (property) => property.type === "font-family",
                      )?.value;
                      // Home uses Geist, Geist Mono, Instrument Serif and the
                      // footer's Figtree; other theme presets are unused here.
                      if (
                        ["Newsreader Display", "Newsreader Text", "Fraunces Variable"].includes(family)
                      ) return [];
                      const fontFace = JSON.stringify(
                        rule.value.properties,
                        (key, value) => key === "loc" ? undefined : value,
                      );
                      if (seenFontFaces.has(fontFace)) return [];
                      seenFontFaces.add(fontFace);
                    },
                  },
                },
              }).code.toString();
              return `<style${attributes}>${trimmedCSS}</style>`;
            },
          );
          // The template preloads the display font, which pulls it onto the
          // first-paint path and costs ~0.8 s of simulated mobile LCP. The
          // headline renders with a metric-matched fallback and swaps.
          homeHTMLWithTrimmedCSS = homeHTMLWithTrimmedCSS.replace(
            /<link rel="preload"[^>]*as="font"[^>]*>/g,
            "",
          );
          // Only / is trimmed; the other pages retain their complete stylesheets.
          await writeFile(homePath, homeHTMLWithTrimmedCSS);
        },
      },
    },
  ],
  build: {
    // Flat-inlines per-page CSS so the LCP element does not wait on a
    // separate render-blocking stylesheet (the 164 KB shared CSS delayed
    // first paint by ~2.5 s in mobile Lighthouse).
    inlineStylesheets: "always",
  },
  vite: {
    resolve: {
      alias: {
        // Keep Workbench's styles, but scan only its rendered component family.
        "@saas-maker/ui/source-workbench.css": fileURLToPath(
          new URL("./src/styles/home-utilities.css", import.meta.url),
        ),
      },
    },
    plugins: [tailwindcss()],
    css: {
      transformer: "lightningcss",
    },
    build: {
      cssMinify: "lightningcss",
    },
  },
});
