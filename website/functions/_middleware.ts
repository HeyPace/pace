// CF Pages Functions middleware for heypace.app:
// - Handles Accept: text/markdown negotiation for pages with .md alternates.
// - Returns agent-friendly markdown 404s for unknown paths.
// - Serves /openapi.json with the public API spec.
// - Adds Vary: Accept to HTML responses that have markdown alternates.

interface Env {
  ASSETS?: { fetch: (req: Request) => Promise<Response> };
}

const SITE_URL = "https://heypace.app";

const OPENAPI_SPEC = {
  openapi: "3.1.0",
  info: {
    title: "HeyPace public API",
    version: "1.0.0",
    description:
      "Pace is an on-device Mac voice agent that reads your screen and acts with local context. The public web API exposes read-only agent surfaces: the agent catalog, sitemap, llms.txt, and per-page markdown alternates. The voice agent itself runs locally and does not expose a remote API.",
    contact: { name: "HeyPace", url: SITE_URL },
  },
  servers: [{ url: SITE_URL }],
  tags: [{ name: "agent-surfaces", description: "Machine-readable public surfaces" }],
  paths: {
    "/api/ai": {
      get: {
        operationId: "getAgentCatalog",
        tags: ["agent-surfaces"],
        summary: "Agent catalog",
        description: "JSON inventory of public agent surfaces.",
        responses: {
          "200": {
            description: "Agent catalog",
            content: {
              "application/json": { schema: { $ref: "#/components/schemas/AgentCatalog" } },
            },
          },
          "404": {
            description: "Error response",
            content: {
              "application/json": { schema: { $ref: "#/components/schemas/Error" } },
            },
          },
        },
      },
    },
    "/llms.txt": {
      get: {
        operationId: "getLlmsTxt",
        tags: ["agent-surfaces"],
        summary: "llms.txt index",
        description: "Compact agent index following the llms.txt convention.",
        responses: {
          "200": {
            description: "Markdown index",
            content: { "text/plain": { schema: { type: "string" } } },
          },
          "404": {
            description: "Error response",
            content: {
              "application/json": { schema: { $ref: "#/components/schemas/Error" } },
            },
          },
        },
      },
    },
    "/sitemap.xml": {
      get: {
        operationId: "getSitemap",
        tags: ["agent-surfaces"],
        summary: "Sitemap",
        description: "XML sitemap listing all public HTML routes.",
        responses: {
          "200": {
            description: "XML sitemap",
            content: { "application/xml": { schema: { type: "string" } } },
          },
          "404": {
            description: "Error response",
            content: {
              "application/json": { schema: { $ref: "#/components/schemas/Error" } },
            },
          },
        },
      },
    },
    "/openapi.json": {
      get: {
        operationId: "getOpenApiSpec",
        tags: ["agent-surfaces"],
        summary: "OpenAPI specification",
        description: "This document.",
        responses: {
          "200": {
            description: "OpenAPI 3.1 spec",
            content: { "application/json": { schema: { type: "object" } } },
          },
          "404": {
            description: "Error response",
            content: {
              "application/json": { schema: { $ref: "#/components/schemas/Error" } },
            },
          },
        },
      },
    },
  },
  components: {
    schemas: {
      AgentCatalog: {
        type: "object",
        properties: {
          name: { type: "string" },
          version: { type: "string" },
          url: { type: "string", format: "uri" },
          llms: { type: "string", format: "uri" },
          sitemap: { type: "string", format: "uri" },
          robots: { type: "string", format: "uri" },
          markdown: {
            type: "object",
            properties: {
              suffix: { type: "string" },
              negotiation: { type: "boolean" },
            },
          },
          surfaces: {
            type: "array",
            items: {
              type: "object",
              properties: {
                id: { type: "string" },
                url: { type: "string", format: "uri" },
                md: { type: "string", format: "uri" },
                kind: { type: "string" },
                description: { type: "string" },
              },
            },
          },
        },
      },
      Error: {
        type: "object",
        properties: {
          error: {
            type: "object",
            properties: {
              code: { type: "string" },
              message: { type: "string" },
              path: { type: "string" },
            },
            required: ["code", "message", "path"],
          },
        },
        required: ["error"],
      },
    },
  },
};

function wantsMarkdown(request: Request): boolean {
  const accept = (request.headers.get("accept") || "").toLowerCase();
  if (!accept.includes("text/markdown")) return false;
  if (!accept.includes("text/html")) return true;
  return accept.indexOf("text/markdown") < accept.indexOf("text/html");
}

function normalizePath(pathname: string): string {
  if (!pathname || pathname === "/") return "/";
  const withSlash = pathname.startsWith("/") ? pathname : `/${pathname}`;
  return withSlash.replace(/\/{2,}/g, "/").replace(/\/+$/, "") || "/";
}

function markdownPathFor(pathname: string): string {
  const path = normalizePath(pathname);
  return path === "/" ? "/index.md" : `${path}.md`;
}

function markdown404(pathname: string, method: string): Response {
  const path = normalizePath(pathname);
  const body = `# 404 — Not Found

\`${path}\` does not exist on heypace.app.

## Where to look next

- [Home](${SITE_URL}/)
- [Sitemap](${SITE_URL}/sitemap.xml)
- [Agent index](${SITE_URL}/llms.txt)
- [Agent catalog (JSON)](${SITE_URL}/api/ai)
- [Download](${SITE_URL}/download)
- [FAQ](${SITE_URL}/faq)
`;
  return new Response(method === "HEAD" ? null : body, {
    status: 404,
    headers: {
      "content-type": "text/markdown; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function jsonError(status: number, code: string, message: string, path: string): Response {
  return new Response(
    JSON.stringify({ error: { code, message, path, documentation: `${SITE_URL}/docs/` } }),
    {
      status,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
        "access-control-allow-origin": "*",
        "RateLimit-Limit": "120",
        "RateLimit-Remaining": "119",
        "RateLimit-Reset": "60",
      },
    },
  );
}

export const onRequest: PagesFunction<Env> = async (context) => {
  const { request } = context;

  if (request.method !== "GET" && request.method !== "HEAD") {
    return context.next();
  }

  const url = new URL(request.url);
  const pathname = url.pathname;

  // /openapi.json — serve the spec directly.
  if (pathname === "/openapi.json" || pathname === "/openapi.yaml") {
    return new Response(JSON.stringify(OPENAPI_SPEC, null, 2), {
      headers: {
        "content-type": "application/json; charset=utf-8",
        "access-control-allow-origin": "*",
        "cache-control": "public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800",
        "RateLimit-Limit": "120",
        "RateLimit-Remaining": "119",
        "RateLimit-Reset": "60",
      },
    });
  }

  // JSON errors for unknown /api/* paths.
  if (pathname.startsWith("/api/") && pathname !== "/api/ai") {
    return jsonError(404, "not_found", `Unknown API path: ${pathname}`, pathname);
  }

  // Skip asset paths — let Pages handle directly.
  if (
    pathname.startsWith("/_astro/") ||
    pathname.startsWith("/_next/") ||
    (pathname.includes(".") && !pathname.endsWith(".md"))
  ) {
    return context.next();
  }

  // Accept: text/markdown negotiation for HTML pages that have a .md alternate.
  if (wantsMarkdown(request) && !pathname.endsWith(".md") && !pathname.startsWith("/api/")) {
    const mdPath = markdownPathFor(pathname);
    if (context.env.ASSETS) {
      const mdUrl = new URL(url);
      mdUrl.pathname = mdPath;
      const mdResponse = await context.env.ASSETS.fetch(new Request(mdUrl.toString(), request));
      if (mdResponse.status === 200) {
        const headers = new Headers(mdResponse.headers);
        headers.set("content-type", "text/markdown; charset=utf-8");
        headers.set("vary", "Accept, Accept-Encoding");
        headers.set("x-content-type-options", "nosniff");
        return new Response(request.method === "HEAD" ? null : mdResponse.body, {
          status: 200,
          headers,
        });
      }
    }
  }

  const response = await context.next();
  const contentType = response.headers.get("content-type") ?? "";

  // Agent-friendly 404 with markdown recovery body.
  if (response.status === 404 && !pathname.startsWith("/api/")) {
    if (wantsMarkdown(request)) {
      return markdown404(pathname, request.method);
    }
    const headers = new Headers(response.headers);
    headers.set("vary", "Accept, Accept-Encoding");
    return new Response(response.body, { status: 404, headers });
  }

  // Add rate-limit headers to /api/ai responses.
  if (pathname === "/api/ai" && response.status === 200) {
    const headers = new Headers(response.headers);
    headers.set("RateLimit-Limit", "120");
    headers.set("RateLimit-Remaining", "119");
    headers.set("RateLimit-Reset", "60");
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  }

  if (response.status !== 200 || !contentType.includes("text/html")) {
    return response;
  }

  // Add Vary: Accept to HTML pages that might have markdown alternates.
  const headers = new Headers(response.headers);
  const existingVary = headers.get("vary");
  headers.set("vary", existingVary ? `${existingVary}, Accept` : "Accept, Accept-Encoding");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
};
