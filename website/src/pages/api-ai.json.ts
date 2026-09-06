import type { APIRoute } from "astro";
import { publicSurfaceCatalog } from "../config/public-surfaces";

const PRODUCTION_ORIGIN = "https://heypace.app";

export const GET: APIRoute = () =>
  new Response(
    JSON.stringify(
      {
        name: "HeyPace",
        version: "1",
        url: PRODUCTION_ORIGIN,
        llms: `${PRODUCTION_ORIGIN}/llms.txt`,
        llmsFull: `${PRODUCTION_ORIGIN}/llms-full.txt`,
        sitemap: `${PRODUCTION_ORIGIN}/sitemap.xml`,
        robots: `${PRODUCTION_ORIGIN}/robots.txt`,
        markdown: {
          suffix: ".md",
          negotiation: false,
          linkedAlternates: true,
        },
        aiCatalog: `${PRODUCTION_ORIGIN}/.well-known/ai-catalog.json`,
        agentSkills: `${PRODUCTION_ORIGIN}/.well-known/agent-skills/index.json`,
        surfaces: publicSurfaceCatalog(),
        dataResources: [
          {
            id: "docs-llms",
            url: `${PRODUCTION_ORIGIN}/docs/llms.txt`,
            kind: "documentation-index",
            description: "Machine-readable index for the generated Pace documentation.",
          },
        ],
        auth: {
          public: true,
          notes:
            "Only canonical public website and documentation routes are cataloged. The local macOS application has no public authenticated web routes.",
        },
      },
      null,
      2,
    ),
    {
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "public, max-age=300",
      },
    },
  );
