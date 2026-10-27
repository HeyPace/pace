import { existsSync, readFileSync, readdirSync } from "node:fs";
import { resolve, relative } from "node:path";
import { absoluteMarkdownLinks } from "../lib/agent-surfaces/format.mjs";
import type { PublicSurface } from "./public-surfaces";
// Astro bundles this module into its prerender directory; use the package cwd,
// not the bundled import.meta.url, to locate the original content.
const docsRoot = resolve("../docs");
const publicDocs = resolve("public/docs");
export function documentationSurfaces(): PublicSurface[] {
  if (!existsSync(publicDocs)) throw new Error("Build and merge the source documentation before building website representations.");
  const sources = new Map<string, string>();
  function sourceFiles(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const target = resolve(directory, entry.name);
      if (entry.isDirectory()) { sourceFiles(target); continue; }
      if (!entry.name.endsWith(".md")) continue;
      // Match pinned Blume's mapRoute: numeric ordering prefixes and index/group
      // segments do not become public URL segments.
      const slug = relative(docsRoot, target).replaceAll("\\", "/").replace(/\.md$/, "").split("/").filter((part) => !/^\(.+\)$/.test(part)).map((part) => part.replace(/^\d+[-_.]/, "")).filter((part) => part !== "index").join("/");
      if (sources.has(slug)) throw new Error(`Ambiguous public documentation source: ${slug}`);
      sources.set(slug, target);
    }
  }
  sourceFiles(docsRoot);
  const published: { path: string; source: string }[] = [];
  function visit(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const target = resolve(directory, entry.name);
      if (entry.isDirectory()) { visit(target); continue; }
      if (!entry.name.endsWith(".html") || entry.name === "404.html") continue;
      const html = relative(publicDocs, target).replaceAll("\\", "/");
      const slug = html === "index.html" ? "" : html.replace(/(?:\/index)?\.html$/, "");
      const source = sources.get(slug);
      if (!source) throw new Error(`Public documentation has no original Markdown source: ${html}`);
      published.push({ path: `/docs${slug ? `/${slug}` : ""}`, source });
    }
  }
  visit(publicDocs);
  const htmlPathsByMarkdown = Object.fromEntries(published.map(({ path, source }) => [`/docs/${relative(docsRoot, source).replaceAll("\\", "/")}`, `${path}/`]));
  return published.map(({ path, source }) => {
    const body = readFileSync(source, "utf8").replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "").trim();
    const title = body.match(/^#\s+(.+)$/m)?.[1] ?? path.split("/").at(-1) ?? "Pace documentation";
    const paragraph = body.split(/\n\s*\n/).find((paragraph) => !/^[#>|`-]/.test(paragraph) && paragraph.trim()) ?? title;
    const plain = paragraph.replace(/!?\[([^\]]+)\]\([^)]+\)/g, "$1").replace(/[`*_]/g, "").replace(/\s+/g, " ").trim();
    const description = plain.length > 180 ? `${plain.slice(0, 180).replace(/\s+\S*$/, "")}…` : plain;
    return { id: path.slice(1), path, markdownPath: `${path}.md`, kind: "detail" as const, title, description, priority: "0.5", markdown: absoluteMarkdownLinks(body, new URL(`/docs/${relative(docsRoot, source).replaceAll("\\", "/")}`, "https://heypace.app").href, { htmlPathsByMarkdown }) };
  }).sort((left, right) => left.path.localeCompare(right.path));
}
