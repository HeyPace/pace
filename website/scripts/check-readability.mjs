import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { resolve, relative } from "node:path";
const root = resolve(import.meta.dirname, "../dist");
const routes = JSON.parse(await readFile(resolve(root, "api/md/_catalog"), "utf8"));
const publicPaths = new Set();
async function visit(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) { await visit(path); continue; }
    if (!entry.name.endsWith(".html")) continue;
    const html = await readFile(path, "utf8");
    if (/name="robots"[^>]*noindex/.test(html)) continue;
    const canonical = html.match(/rel="canonical"[^>]*href="([^"]+)"/)?.[1];
    assert.ok(canonical, `Missing canonical: ${relative(root,path)}`);
    publicPaths.add(new URL(canonical).pathname);
    assert.match(html, /name="ai-summary"/);
    assert.match(html, /type="text\/markdown"/);
  }
}
await visit(root);
assert.deepEqual(publicPaths, new Set(routes.map((route) => route.path)));
for (const route of routes) {
  const markdown = await readFile(resolve(root, route.assetPath.slice(1)), "utf8");
  assert.match(markdown, /^# /m);
  assert.ok(markdown.includes(`Canonical: ${route.url}`), route.path);
  assert.ok(markdown.length > 100);
}
const sitemap = await readFile(resolve(root,"sitemap.xml"),"utf8");
assert.deepEqual(new Set([...sitemap.matchAll(/<loc>(.*?)<\/loc>/g)].map((match)=>new URL(match[1]).pathname)),publicPaths);
assert.ok((await readFile(resolve(root,"llms-full.txt"),"utf8")).length < 500_000);
for (const crawler of ["GPTBot","ClaudeBot","Google-Extended","Applebot-Extended","CCBot","Bytespider"]) assert.ok((await readFile(resolve(root,"robots.txt"),"utf8")).includes(`User-agent: ${crawler}\nAllow: /`));
console.log(`Public HTML, sitemap and Markdown coverage: ${routes.length}/${publicPaths.size}`);

const robots = await readFile(resolve(root, "robots.txt"), "utf8");
assert.ok(!robots.split("\n").includes("Disallow: /api"), "Do not prefix-block the public /api-ai.json catalog");
assert.ok((await readFile(resolve(root,"llms.txt"),"utf8")).includes("No CLI tool is currently available"));
