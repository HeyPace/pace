import { competitors } from "./competitors";
import home from "../content/home.json";
import { absoluteMarkdownLinks } from "../lib/agent-surfaces/format.mjs";
import { homeMarkdown, comparedMarkdown, downloadMarkdown, pricingMarkdown, faqMarkdown, changelogMarkdown, comparisonMarkdown, fragmentMarkdown } from "./page-markdown";
import { documentationSurfaces } from "./documentation-surfaces";
import { educationContent } from "./education-content";

const PRODUCTION_ORIGIN = "https://heypace.app";

export type PublicSurfaceKind = "static" | "collection" | "detail";

export interface PublicSurface {
  id: string;
  path: string;
  markdownPath: string;
  kind: PublicSurfaceKind;
  title: string;
  description: string;
  priority: string;
  markdown: string;
}

export function canonicalPublicPagePath(path: string): string {
  if (path === "/" || path.endsWith("/") || /\.(?:md|txt|json|xml)$/i.test(path)) {
    return path;
  }
  return `${path}/`;
}

function absoluteURL(path: string): string {
  return new URL(canonicalPublicPagePath(path), PRODUCTION_ORIGIN).toString();
}

const staticSurfaces: PublicSurface[] = [
  {
    id: "home",
    path: "/",
    markdownPath: "/index.md",
    kind: "static",
    title: home.page.title,
    description: home.page.description,
    priority: "1.0",
    markdown: homeMarkdown(),
  },
  {
    id: "compared",
    path: "/compared",
    markdownPath: "/compared.md",
    kind: "collection",
    title: "Mac AI agents that see your screen — 17 compared",
    description:
      "Compare 17 macOS AI agents by screen access, inference location, actions, approval model, license, and where Pace is honestly behind.",
    priority: "0.8",
    markdown: comparedMarkdown(),
  },
  {
    id: "download",
    path: "/download",
    markdownPath: "/download.md",
    kind: "static",
    title: "Download Pace",
    description:
      "Download the on-device macOS voice companion and review its installation and update requirements.",
    priority: "0.9",
    markdown: downloadMarkdown(),
  },
  {
    id: "pricing",
    path: "/pricing",
    markdownPath: "/pricing.md",
    kind: "static",
    title: "Pace pricing",
    description:
      "Pace offers a free Apple Foundation Models preview and a $29 one-time purchase. A $5 monthly Studio option is planned, not live.",
    priority: "0.9",
    markdown: pricingMarkdown(),
  },
  {
    id: "faq",
    path: "/faq",
    markdownPath: "/faq.md",
    kind: "static",
    title: "Pace FAQ",
    description:
      "Answers about Pace privacy, hardware, local models, recordings, purchase terms, integrations, and action safety.",
    priority: "0.7",
    markdown: faqMarkdown(),
  },
  {
    id: "changelog",
    path: "/changelog",
    markdownPath: "/changelog.md",
    kind: "static",
    title: "Pace changelog",
    description:
      "A curated record of verified, user-visible Pace product outcomes.",
    priority: "0.6",
    markdown: changelogMarkdown(),
  },
  {
    id: "privacy",
    path: "/privacy",
    markdownPath: "/privacy.md",
    kind: "static",
    title: "Pace privacy",
    description:
      "How Pace keeps voice, screen, meeting, and journal data local, plus the explicit exceptions that can use the network.",
    priority: "0.4",
    markdown: fragmentMarkdown("privacy"),
  },
  {
    id: "terms",
    path: "/terms",
    markdownPath: "/terms.md",
    kind: "static",
    title: "Pace terms",
    description:
      "Plain-language terms for Pace's MIT-licensed software and current one-time purchase path.",
    priority: "0.4",
    markdown: fragmentMarkdown("terms"),
  },
];

const comparisonSurfaces: PublicSurface[] = competitors.map((competitor) => ({
  id: `compared-${competitor.slug}`, path: `/compared/${competitor.slug}`, markdownPath: `/compared/${competitor.slug}.md`, kind: "detail", title: `${competitor.name} vs Pace — macOS voice agent comparison`, description: `${competitor.name} vs Pace for macOS: ${competitor.paceDiffers} Screen-aware voice agents compared, including where Pace is behind.`, priority: "0.6", markdown: comparisonMarkdown(competitor),
}));
export const publicSurfaces: PublicSurface[] = [
  ...staticSurfaces,
  ...Object.values(educationContent).map((content) => ({ id: content.path.slice(1), path: content.path, markdownPath: `${content.path}.md`, kind: "static" as const, title: content.title, description: content.description, priority: "0.8", markdown: `On-device field guide\n\n${content.description}\n\n${content.markdown}\n\n## Continue through the local stack\n\n${content.internalLinks.map((href) => `- [${href.slice(1).replaceAll("-", " ")}](${href})`).join("\n")}` })),
  ...comparisonSurfaces,
  ...documentationSurfaces(),
].map((surface) => ({ ...surface, markdown: absoluteMarkdownLinks(`# ${surface.title}\n\n> ${surface.description}\n\nCanonical: ${absoluteURL(surface.path)}\n\n${surface.markdown}\n`, absoluteURL(surface.path)) }));
export const generatedMarkdownSurfaces = publicSurfaces;
export function markdownPublicPagePath(path: string): string | undefined {
  return publicSurfaces.find((surface) => canonicalPublicPagePath(surface.path) === canonicalPublicPagePath(path))?.markdownPath;
}
export function publicSurfaceCatalog() {
  return publicSurfaces.map((surface) => ({ id: surface.id, url: absoluteURL(surface.path), md: absoluteURL(surface.markdownPath), kind: surface.kind, description: surface.description }));
}
