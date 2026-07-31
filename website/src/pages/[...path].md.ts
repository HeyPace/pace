import type { APIRoute, GetStaticPaths } from "astro";
import {
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

  return new Response(surface.markdown, {
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "Cache-Control": "public, max-age=300",
    },
  });
};
