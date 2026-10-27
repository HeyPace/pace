import { sourceFragmentMarkdown } from "../lib/source-fragment-markdown.mjs";

// These are authored content fragments, not HTML fetched from rendered pages.
// Astro uses their original markup, while Markdown reads the same source.
const fragments = import.meta.glob<string>("../content/fragments/*.html", { eager: true, query: "?raw", import: "default" });
export function fragment(name: string, values: Record<string, string | number> = {}): string {
  const source = fragments[`../content/fragments/${name}.html`];
  if (source === undefined) throw new Error(`Unknown public source fragment: ${name}`);
  return source.replace(/\{\{(\w+)\}\}/g, (_, key: string) => {
    if (!(key in values)) throw new Error(`Missing public fragment value: ${name}.${key}`);
    return String(values[key]).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
  });
}
export function fragmentMarkdown(name: string, values: Record<string, string | number> = {}): string {
  return sourceFragmentMarkdown(fragment(name, values), "https://heypace.app");
}
