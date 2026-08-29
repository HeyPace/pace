import type { APIRoute, GetStaticPaths } from "astro";
import {
  canonicalPublicPagePath,
  generatedMarkdownSurfaces,
  type PublicSurface,
} from "../config/public-surfaces";

export const getStaticPaths: GetStaticPaths = () =>
  generatedMarkdownSurfaces.map((surface) => ({
    params: {
      path: surface.markdownPath.replace(/^\//, "").replace(/\.md$/, ""),
    },
    props: { surface },
  }));

export const GET: APIRoute = ({ props }) => {
  const surface = props.surface as PublicSurface;
  const canonical = new URL(
    canonicalPublicPagePath(surface.path),
    "https://heypace.app",
  ).toString();
  const frontmatter = [
    "---",
    `title: ${JSON.stringify(surface.title)}`,
    `description: ${JSON.stringify(surface.description)}`,
    `canonical: ${canonical}`,
    "last-updated: 2026-08-27",
    "---",
    "",
  ].join("\n");

  return new Response(`${frontmatter}${surface.markdown}`, {
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "Cache-Control": "public, max-age=300",
    },
  });
};
