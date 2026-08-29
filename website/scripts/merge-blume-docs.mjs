import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, posix, relative, resolve, sep } from "node:path";
import { execFileSync } from "node:child_process";

const websiteRoot = resolve(import.meta.dirname, "..");
const repoRoot = resolve(websiteRoot, "..");
const docsOutput = resolve(repoRoot, "dist");
const publicDocs = resolve(websiteRoot, "public/docs");
const SITE_ORIGIN = "https://heypace.app";
const DOC_URL_PATTERN = /(?:https:\/\/heypace\.app)?\/docs(?:\/[A-Za-z0-9._~!$&'*+,;=:@%/-]*)?(?:\?[A-Za-z0-9._~!$&'*+,;=:@%/?-]*)?(?:#[A-Za-z0-9._~!$&'*+,;=:@%/?-]*)?/g;
const STATIC_FILE_PATTERN = /\.(?:html?|mdx?|json|xml|txt|png|jpe?g|webp|avif|gif|svg|ico|css|m?js|map|woff2?|ttf|otf|wasm|pdf|zip|dmg|exe|deb|appimage)$/i;
const TEXT_OUTPUT_PATTERN = /\.(?:html?|mdx?|json|xml|txt|css|m?js)$/i;
const RENDERED_MARKDOWN_HREF_PATTERN =
  /href=(['"])([^'"?#]*\.md)([?#][^'"]*)?\1/gi;
const RENDERED_HREF_PATTERN = /href=(['"])([^'"]+)\1/gi;

function rewriteRenderedMarkdownLinks(target, html) {
  const relativeHTML = relative(publicDocs, target).split(sep).join("/");
  const outputDirectory = posix.dirname(relativeHTML);
  // Blume turns `architecture/overview.md` into
  // `architecture/overview/index.html`. Browser-relative links would then be
  // resolved one directory too deep unless we restore the source Markdown
  // page's directory before turning the target into a public route.
  const sourceDirectory =
    relativeHTML === "index.html" ? "" : posix.dirname(outputDirectory);

  return html.replace(
    RENDERED_MARKDOWN_HREF_PATTERN,
    (match, quote, hrefPath, suffix = "") => {
      if (/^(?:[a-z]+:|\/\/)/i.test(hrefPath)) return match;
      const sourcePath = hrefPath.startsWith("/docs/")
        ? hrefPath.slice("/docs/".length)
        : posix.normalize(posix.join(sourceDirectory, hrefPath));
      if (sourcePath.startsWith("../")) return match;
      if (!existsSync(resolve(publicDocs, sourcePath))) return match;
      const route = sourcePath.replace(/\.md$/i, "");
      return `href=${quote}/docs/${route}/${suffix}${quote}`;
    },
  );
}

function canonicalDocsURL(value) {
  const prefix = value.startsWith(SITE_ORIGIN) ? SITE_ORIGIN : "";
  const relative = prefix ? value.slice(prefix.length) : value;
  const suffixIndex = relative.search(/[?#]/);
  const pathname = suffixIndex === -1 ? relative : relative.slice(0, suffixIndex);
  const suffix = suffixIndex === -1 ? "" : relative.slice(suffixIndex);
  if (pathname === "/docs/index" || pathname === "/docs/index/") {
    return `${prefix}/docs/${suffix}`;
  }
  if (pathname.endsWith("/") || STATIC_FILE_PATTERN.test(pathname)) return value;
  return `${prefix}${pathname}/${suffix}`;
}

function normalizeDocsURLs(directory) {
  let replacements = 0;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const target = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      replacements += normalizeDocsURLs(target);
      continue;
    }
    if (!TEXT_OUTPUT_PATTERN.test(entry.name)) continue;
    const before = readFileSync(target, "utf8");
    const withRenderedLinks = entry.name.endsWith(".html")
      ? rewriteRenderedMarkdownLinks(target, before)
      : before;
    const after = withRenderedLinks.replace(DOC_URL_PATTERN, (value) => {
      const canonical = canonicalDocsURL(value);
      if (canonical !== value) replacements += 1;
      return canonical;
    });
    if (after !== before) writeFileSync(target, after);
  }
  return replacements;
}

function assertInternalDocsLinks(directory) {
  const brokenLinks = [];

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const target = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      brokenLinks.push(...assertInternalDocsLinks(target));
      continue;
    }
    if (!entry.name.endsWith(".html")) continue;

    const relativeHTML = relative(publicDocs, target).split(sep).join("/");
    const currentRoute =
      relativeHTML === "index.html"
        ? "/docs/"
        : `/docs/${relativeHTML.replace(/index\.html$/, "")}`;
    const html = readFileSync(target, "utf8");

    for (const match of html.matchAll(RENDERED_HREF_PATTERN)) {
      const rawHref = match[2];
      if (
        rawHref.startsWith("#") ||
        rawHref.startsWith("//") ||
        /^(?:[a-z]+:)/i.test(rawHref)
      ) {
        continue;
      }

      const href = rawHref.split(/[?#]/, 1)[0];
      const route = href.startsWith("/")
        ? href
        : posix.resolve(posix.dirname(currentRoute), href);
      if (!route.startsWith("/docs/")) continue;

      const docsPath = route.slice("/docs/".length);
      const candidate = route.endsWith("/")
        ? resolve(publicDocs, docsPath, "index.html")
        : resolve(publicDocs, docsPath);
      if (!existsSync(candidate)) {
        brokenLinks.push(`${relativeHTML}: ${rawHref}`);
      }
    }
  }

  if (directory === publicDocs && brokenLinks.length > 0) {
    throw new Error(
      `[pace] broken internal docs links:\n${brokenLinks.map((link) => `- ${link}`).join("\n")}`,
    );
  }

  return brokenLinks;
}

// Blume is pinned in the repository root. Building it here keeps the local
// deploy, GitHub Actions deploy, and docs integrity workflow on one path.
execFileSync("pnpm", ["install", "--frozen-lockfile"], {
  cwd: repoRoot,
  stdio: "inherit",
});
execFileSync("pnpm", ["run", "docs:build"], {
  cwd: repoRoot,
  stdio: "inherit",
});

mkdirSync(dirname(publicDocs), { recursive: true });
rmSync(publicDocs, { recursive: true, force: true });
cpSync(docsOutput, publicDocs, { recursive: true });

const normalizedURLs = normalizeDocsURLs(publicDocs);
assertInternalDocsLinks(publicDocs);
console.log(
  `[pace] merged Blume docs into website/public/docs, normalized ${normalizedURLs} document URLs, and verified internal links`,
);
