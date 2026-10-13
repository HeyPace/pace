# Landing font-swap evidence — issue #222

Measured 2026-10-13 against main `a7ee2e9f275f0cd03133a87305b68b60c2f977ae`.
Owner: [#222](https://github.com/HeyPace/pace/issues/222).
The historical 0.075 CLS in the issue was **not reproduced**. Do not replace
that historical observation with a claim of a current production regression.

## Demonstrated cause and bounded fix

The baseline Lighthouse layout-shifts audit identifies
`section.identity-hero > div.identity-hero-grid > div.identity-copy > h1.font-display`
and the web-font swap. With fonts blocked for diagnosis, the fallback headline
has different text widths and glyph bounds, even though its box stays 96 px tall.
The built page contains ordinary Georgia/serif fallback, not a metric-adjusted face.

Retain Base's regular Instrument Serif preload instead of deleting it in the
home build hook. Preload the matching italic face used by the hero's `em`.
The regular-only trial left 0.000553 CLS in that `em`; both faces remove the
observed shift. No CSS, image, content, dependency, or native-app change is needed.

## Same-workload comparison

Retained Lighthouse **12.8.2**, Chromium **154.0.8037.57**, Node **24.19.0**,
Astro production static build served by `astro preview` at `http://127.0.0.1:4321/`.
Three sequential fresh-Chrome runs per variant, no build/render jobs running
during the final measurements. Mobile defaults: 412 × 823, DPR 1.75, simulated
throttling, 150 ms RTT, 1638.4 Kbps throughput, 4× CPU slowdown; performance only.
Both variants use the retained runner with the sole workload addition
`blockedUrlPatterns: ['https://*']` to prevent external telemetry requests.
The unchanged retained runner was also run first and reproduced 0.011533 CLS.
The final isolated pair below is authoritative for comparison.

| Metric (three-run median) | Before | After |
| --- | ---: | ---: |
| CLS | 0.0115328848 | 0 |
| LCP | 1953.3943 ms | 1952.9092 ms |
| Performance | 99 | 99 |

The 0.4851 ms LCP difference is noise, not a speed-up claim. Individual runs,
source fingerprints, audit culprit, settings, and screenshot hashes are retained
in [issue-222.json](./issue-222.json). Raw six-run Lighthouse JSON, the runner,
and full before/after screenshots are supplied in the review handoff bundle.

## Rendering and checks

Headless full-page rendering at **390 / 768 / 1440 × 900**, DPR 1, with external
requests intercepted and blocked. Fonts were awaited and the page was scrolled
to load lazy images before returning to the top. Every before/after PNG pair
has the same SHA-256; loaded rendering is pixel-identical. No horizontal overflow,
broken images, or page exceptions were observed. Health tracking and Clarity
were blocked; tracking delivery is not accepted by these checks.

Passed locally: website `pnpm run build` (including build:docs), Markdown links,
diff check, changed-line Swift format (no Swift changes), 27 website HTTP-cache
security cases, root dependency-security and command-verifier checks, nine
router policy tests, five planner contract tests, duplication gate, dependency
risk audit. Audit: docs 19 moderate / four low, zero high/critical; website zero.
Prebuild-generated release metadata and OG image were restored; neither is part
of this change. These checks establish local source/build evidence only.

## Gates that remain open

- Human review and merge: open. This change does not close #222 itself.
- Editorial/product truth: unverified; existing screenshot/preview-version copy
  and permissioned testimonials need their owning human review.
- Production Lighthouse/performance, real-user CLS, deployed source provenance,
  tracking delivery, checkout and download correctness: **unrun**. Local 99/zero
  CLS does not pass production gates or clear any previously failing live gate.
- Real browser/device acceptance: **unrun**; headless Linux rendering is not
  Safari/iPhone/native acceptance.
- Native app, Xcode, screen permissions, release, deploy and migrations: excluded.
  [#207](https://github.com/HeyPace/pace/issues/207) remains completed/closed.
