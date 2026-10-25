import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { assertInternalDocsLinks } from "./merge-blume-docs.mjs";

function fixture(t, files) {
  const root = mkdtempSync(join(tmpdir(), "pace-docs-links-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const [path, content] of Object.entries(files)) {
    const target = join(root, path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  }
  return root;
}

test("rejects the rendered license-notices link instead of resolving above /docs", (t) => {
  const root = fixture(t, {
    "development/open-source/index.html": '<a href="../../leanring-buddy/Resources/OpenSourceNotices.txt">notices</a>',
  });
  assert.throws(() => assertInternalDocsLinks(root), /OpenSourceNotices.txt/);
});

test("rejects the rendered comparison link instead of resolving above /docs", (t) => {
  const root = fixture(t, {
    "product/prds/next-step-router-policy/index.html": '<a href="../../../evals/router-policy-20261008/local-comparison.json">summary</a>',
  });
  assert.throws(() => assertInternalDocsLinks(root), /local-comparison.json/);
});

test("resolves valid relative links from the browser's trailing-slash page URL", (t) => {
  const root = fixture(t, {
    "development/open-source/index.html": '<a href="../guide/?mode=read#intro">guide</a>',
    "development/guide/index.html": "guide",
  });
  assert.deepEqual(assertInternalDocsLinks(root), []);
});

test("checks same-origin absolute and protocol-relative docs URLs", (t) => {
  for (const origin of ["https://heypace.app", "//heypace.app"]) {
    const root = fixture(t, { "index.html": `<a href="${origin}/docs/missing/">missing</a>` });
    assert.throws(() => assertInternalDocsLinks(root), /missing/);
  }
});

test("allows repository URLs, anchors, and existing docs assets", (t) => {
  const root = fixture(t, {
    "index.html": '<a href="https://github.com/HeyPace/pace/blob/main/blume.config.ts">config</a><a href="#intro">intro</a><a href="/docs/data.json?raw=1">data</a>',
    "data.json": "{}",
  });
  assert.deepEqual(assertInternalDocsLinks(root), []);
});
