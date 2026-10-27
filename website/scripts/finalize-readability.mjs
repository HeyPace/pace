import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
const root = resolve("dist");
const routes = JSON.parse(await readFile(resolve(root, "api/md/_catalog"), "utf8"));
const escape = (value) => value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
for (const route of routes) {
  const file = resolve(root, route.path.slice(1), "index.html");
  let html = await readFile(file, "utf8");
  // Metadata only: document bodies and visual markup remain untouched.
  if (!html.includes('name="ai-summary"')) html = html.replace("</head>", `<meta name="ai-summary" content="${escape(route.description)}"></head>`);
  if (!html.includes('type="text/markdown"')) html = html.replace("</head>", `<link rel="alternate" type="text/markdown" href="${escape(route.md)}"></head>`);
  await writeFile(file, html);
}
const docs404 = resolve(root, "docs/404.html");
const notFound = await readFile(docs404, "utf8");
if (!/name="robots"[^>]*noindex/.test(notFound)) await writeFile(docs404, notFound.replace("</head>", '<meta name="robots" content="noindex, follow"></head>'));
console.log(`Public representation metadata: ${routes.length} routes`);
