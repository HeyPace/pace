import { cpSync, mkdirSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { execFileSync } from "node:child_process";

const websiteRoot = resolve(import.meta.dirname, "..");
const repoRoot = resolve(websiteRoot, "..");
const docsOutput = resolve(repoRoot, "dist");
const publicDocs = resolve(websiteRoot, "public/docs");

// Blume is pinned in the repository root. Building it here keeps the local
// deploy, GitHub Actions deploy, and docs integrity workflow on one path.
execFileSync("npm", ["install", "--no-package-lock"], {
  cwd: repoRoot,
  stdio: "inherit",
});
execFileSync("npm", ["run", "docs:build"], {
  cwd: repoRoot,
  stdio: "inherit",
});

mkdirSync(dirname(publicDocs), { recursive: true });
rmSync(publicDocs, { recursive: true, force: true });
cpSync(docsOutput, publicDocs, { recursive: true });

console.log("[pace] merged Blume docs into website/public/docs");
