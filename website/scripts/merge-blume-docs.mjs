import {
  cpSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { execFileSync } from "node:child_process";

const websiteRoot = resolve(import.meta.dirname, "..");
const repoRoot = resolve(websiteRoot, "..");
const docsOutput = resolve(repoRoot, "dist");
const publicDocs = resolve(websiteRoot, "public/docs");
const SITE_ORIGIN = "https://heypace.app";
const DOC_URL_PATTERN = /(?:https:\/\/heypace\.app)?\/docs(?:\/[A-Za-z0-9._~!$&'*+,;=:@%/-]*)?(?:\?[A-Za-z0-9._~!$&'*+,;=:@%/?-]*)?(?:#[A-Za-z0-9._~!$&'*+,;=:@%/?-]*)?/g;
const STATIC_FILE_PATTERN = /\.(?:html?|mdx?|json|xml|txt|png|jpe?g|webp|avif|gif|svg|ico|css|m?js|map|woff2?|ttf|otf|wasm|pdf|zip|dmg|exe|deb|appimage)$/i;
const TEXT_OUTPUT_PATTERN = /\.(?:html?|mdx?|json|xml|txt|css|m?js)$/i;

function canonicalDocsURL(value) {
  const prefix = value.startsWith(SITE_ORIGIN) ? SITE_ORIGIN : "";
  const relative = prefix ? value.slice(prefix.length) : value;
  const suffixIndex = relative.search(/[?#]/);
  const pathname = suffixIndex === -1 ? relative : relative.slice(0, suffixIndex);
  const suffix = suffixIndex === -1 ? "" : relative.slice(suffixIndex);
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
    const after = before.replace(DOC_URL_PATTERN, (value) => {
      const canonical = canonicalDocsURL(value);
      if (canonical !== value) replacements += 1;
      return canonical;
    });
    if (after !== before) writeFileSync(target, after);
  }
  return replacements;
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
console.log(
  `[pace] merged Blume docs into website/public/docs and normalized ${normalizedURLs} document URLs`,
);
