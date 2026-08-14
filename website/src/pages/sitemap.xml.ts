import type { APIRoute } from "astro";
import {
  canonicalPublicPagePath,
  publicSurfaces,
} from "../config/public-surfaces";

// Hand-rolled sitemap so we add ZERO npm dependency (fleet rule: no new
// deps without approval). It enumerates every route the static build
// emits — the fixed pages plus one /compared/<slug> per competitor,
// derived from the same competitors array that generates those pages.
//
// The production origin is the same one BaseLayout's canonical tags use:
// `Astro.site` from astro.config.mjs. We fall back to the known Pages
// origin so the sitemap is never emitted with relative URLs.
const PRODUCTION_ORIGIN = "https://heypace.app";

export const GET: APIRoute = ({ site }) => {
  const origin = (site ?? new URL(PRODUCTION_ORIGIN)).origin;

  const urlEntries = publicSurfaces
    .map(
      ({ path, priority }) =>
        `  <url>\n    <loc>${origin}${canonicalPublicPagePath(path)}</loc>\n    <priority>${priority}</priority>\n  </url>`,
    )
    .join("\n");

  const sitemap = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urlEntries}\n</urlset>\n`;

  return new Response(sitemap, {
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
    },
  });
};
