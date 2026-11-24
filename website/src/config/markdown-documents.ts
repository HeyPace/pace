import home from "../content/home.json";
import { publicSurfaces, canonicalPublicPagePath } from "./public-surfaces";
import { createAgentSurfaceManifest } from "../lib/agent-surfaces/manifest.mjs";
import { createAgentSurfaceHandler } from "../lib/agent-surfaces/handler.mjs";
import { listMarkdownRoutes } from "../lib/agent-surfaces/documents.mjs";
export const markdownIdentity = { name: "HeyPace", url: "https://heypace.app", summary: home.page.description, contact: "mailto:sarthakagrawal927@gmail.com", trainingAllowed: true, notes: ["Public download 0.3.20 supports typed screen questions, desktop and browser actions, sourced research and local meeting notes.", "Development build 0.3.21 adds Right Option voice chat, interactive diagrams, custom Powers, Apple Reminders task management and retained coding sessions.", "Cloud planning is opt-in. A consented provider can receive the prompt and permitted screen context.", "No CLI tool is currently available for the public preview. Download the Mac menu-bar app at https://heypace.app/download."], excludedPaths: ["/admin", "/auth", "/dashboard", "/api/"], openapi: "https://heypace.app/openapi.json" };
const manifest = createAgentSurfaceManifest({ ...markdownIdentity, pages: Object.fromEntries(publicSurfaces.map((surface) => [canonicalPublicPagePath(surface.path), surface.markdown])) });
export const markdownRoutes = listMarkdownRoutes(manifest).map((route) => ({ ...route, assetPath: publicSurfaces.find((surface) => canonicalPublicPagePath(surface.path) === route.path)?.markdownPath, ...(route.path === "/docs/" ? { aliases: ["/docs/index.md"] } : {}) }));
export const markdownHandler = createAgentSurfaceHandler({ manifest, listMarkdownRoutes: () => markdownRoutes });
