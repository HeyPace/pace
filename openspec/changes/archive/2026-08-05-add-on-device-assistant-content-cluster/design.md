# Context

Pace's public site uses a black editorial command-console visual system with Instrument Serif, neutral body typography, product-shaped evidence, and one electric-blue action accent. The new guides extend that established world in Read mode.

# Approach

Create a typed editorial registry and shared Astro layout. Explicit routes select approved guide records. Extend `public-surfaces.ts` with the same canonical paths and Markdown bodies so the hand-built sitemap, `/api-ai.json`, and `[...path].md.ts` stay synchronized.

```mermaid
flowchart LR
  Registry[Editorial registry] --> Routes[Five Astro routes]
  Registry --> Public[public-surfaces.ts]
  Public --> Sitemap[sitemap.xml]
  Public --> API[/api-ai.json]
  Public --> Markdown[Markdown routes]
  Routes --> Existing[Home privacy FAQ compared download]
```

# Decisions

- Preserve the existing Pace design system and primary navigation.
- Use restrained Read-mode composition rather than five miniature landing pages.
- State local and optional off-device boundaries precisely.
- Use FAQPage structured data only for visible question-and-answer content.
- Keep all pages static, fast, and dependency-free.

# Validation

Strict OpenSpec validation, website production build, public-surface parity assertions, canonical/schema/sitemap/API/link checks, manual detector, and browser evidence at 390, 768, and 1440 pixels.
