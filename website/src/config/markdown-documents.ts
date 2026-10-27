import home from "../content/home.json";
import { publicSurfaces, canonicalPublicPagePath } from "./public-surfaces";
import { createAgentSurfaceManifest } from "../lib/agent-surfaces/manifest.mjs";
import { createAgentSurfaceHandler } from "../lib/agent-surfaces/handler.mjs";
import { listMarkdownRoutes } from "../lib/agent-surfaces/documents.mjs";
export const markdownIdentity = { name: "HeyPace", url: "https://heypace.app", summary: home.page.description, contact: "mailto:sarthakagrawal927@gmail.com", trainingAllowed: true, excludedPaths: ["/admin", "/auth", "/dashboard", "/api"], openapi: "https://heypace.app/openapi.json" };
const manifest = createAgentSurfaceManifest({ ...markdownIdentity, pages: Object.fromEntries(publicSurfaces.map((surface) => [canonicalPublicPagePath(surface.path), surface.markdown])) });
export const markdownRoutes = listMarkdownRoutes(manifest).map((route) => ({ ...route, assetPath: publicSurfaces.find((surface) => canonicalPublicPagePath(surface.path) === route.path)?.markdownPath, ...(route.path === "/docs/" ? { aliases: ["/docs/index.md"] } : {}) }));
export const markdownHandler = createAgentSurfaceHandler({ manifest, listMarkdownRoutes: () => markdownRoutes });
