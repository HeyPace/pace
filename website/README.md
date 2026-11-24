# Pace website

The Astro site at [heypace.app](https://heypace.app/) publishes the product overview, download, pricing, comparisons, FAQ, changelog, and documentation. The homepage uses the shared Workbench template.

## Edit product information

| Content | Source |
| --- | --- |
| Homepage, hero metadata, FAQ answers | [home.json](src/content/home.json) |
| Public download version and assets | [Sparkle appcast](../appcast.xml), read by the release-info build step |
| Download instructions and purchase copy | [HTML fragments](src/content/fragments/) and [pricing content](src/config/pricing-content.ts) |
| Dated release and development milestones | [Changelog entries](src/config/changelog-content.ts) |
| Product reference and developer setup | [Pace README](../README.md), [product brief](../PRODUCT.md), and [documentation](../docs/index.md) |

Use the release notes to check what downloaders can run. Label newer features with their development version. Homepage and FAQ Markdown are generated from the same content as the HTML.

## Run locally

Install dependencies at both package roots. The site includes documentation built from the repository root. Each root pins its pnpm version.

```sh
# From the Pace repository root
pnpm install --frozen-lockfile
cd website
pnpm install --frozen-lockfile
pnpm run dev
```

Run `pnpm run build` in `website/` for the production site and readability checks. Run `pnpm run preview` to inspect the resulting pages. Production uses the Cloudflare Pages project `pace` and the repository’s [deployment workflow](../.github/workflows/deploy.yml).
