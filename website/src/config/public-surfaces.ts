import { competitors } from "./competitors";
import { educationContent } from "./education-content";

const PRODUCTION_ORIGIN = "https://heypace.app";

export type PublicSurfaceKind = "static" | "collection" | "detail";

export interface PublicSurface {
  id: string;
  path: string;
  markdownPath: string;
  kind: PublicSurfaceKind;
  title: string;
  description: string;
  priority: string;
  markdown: string;
}

export function canonicalPublicPagePath(path: string): string {
  if (path === "/" || path.endsWith("/") || /\.[a-z0-9]+$/i.test(path)) {
    return path;
  }
  return `${path}/`;
}

function absoluteURL(path: string): string {
  return new URL(canonicalPublicPagePath(path), PRODUCTION_ORIGIN).toString();
}

function markdownDocument(
  title: string,
  description: string,
  sections: string[],
): string {
  return [`# ${title}`, "", description, "", ...sections, ""].join("\n");
}

const staticSurfaces: PublicSurface[] = [
  {
    id: "home",
    path: "/",
    markdownPath: "/index.md",
    kind: "static",
    title: "Pace",
    description:
      "On-device macOS voice agent that listens, reads the screen, and acts with local models by default.",
    priority: "1.0",
    markdown: "",
  },
  {
    id: "compared",
    path: "/compared",
    markdownPath: "/compared.md",
    kind: "collection",
    title: "Mac AI agents that see your screen — 17 compared",
    description:
      "Compare 17 macOS AI agents by screen access, inference location, actions, approval model, license, and where Pace is honestly behind.",
    priority: "0.8",
    markdown: markdownDocument(
      "Mac AI agents that see your screen — 17 compared",
      "Compare 17 macOS AI agents by screen access, inference location, actions, approval model, license, and where Pace is honestly behind.",
      [
        "## How to choose",
        "",
        "Follow the data path, separate observation from action, check the control model, inspect approval and recovery, and verify license and distribution evidence.",
        "",
        "## The field",
        "",
        ...competitors.flatMap((competitor) => [
          `- [Pace vs ${competitor.name}](${absoluteURL(`/compared/${competitor.slug}`)}): ${competitor.angle}.`,
        ]),
        "",
        `Rechecked ${absoluteURL("/compared")} against the linked product sources. No review scores or rankings are invented.`,
      ],
    ),
  },
  {
    id: "download",
    path: "/download",
    markdownPath: "/download.md",
    kind: "static",
    title: "Download Pace",
    description:
      "Download the on-device macOS voice companion and review its installation and update requirements.",
    priority: "0.9",
    markdown: markdownDocument(
      "Download Pace",
      "Download the on-device macOS voice companion and review its installation and update requirements.",
      [
        "## Requirements",
        "",
        "- Apple Silicon Mac.",
        "- The current 0.3.19 preview requires macOS 26.",
        "- Accessibility, Microphone, and Screen Recording permissions for the features that use them.",
        "",
        "## Installation",
        "",
        "Unzip Pace, open Pace.app, grant the permissions you want to use, then hold Control+Option to talk. Pace checks its GitHub-hosted Sparkle appcast for updates.",
        "",
        `Download details and current release links: ${absoluteURL("/download")}`,
      ],
    ),
  },
  {
    id: "pricing",
    path: "/pricing",
    markdownPath: "/pricing.md",
    kind: "static",
    title: "Pace pricing",
    description:
      "Pace offers a free Apple Foundation Models preview and a $29 one-time purchase. A $5 monthly Studio option is planned, not live.",
    priority: "0.9",
    markdown: markdownDocument(
      "Pace pricing",
      "Pace offers a free Apple Foundation Models preview and a $29 one-time purchase. A $5 monthly Studio option is planned, not live.",
      [
        "## Tiers",
        "",
        "- **Try — free:** Apple Foundation Models planner with the core local app.",
        "- **Pace — $29 once:** the current bundled local planner, vision, and speech models; manual terms are confirmed before payment.",
        "- **Studio — planned at $5/month:** proposed managed Composio routing; not currently sold.",
        "",
        "## At a glance",
        "",
        "| Option | Price | Available now | Planner path | Purchase path |",
        "| --- | ---: | :---: | --- | --- |",
        "| Try | Free | Yes | Apple Foundation Models | Download the current preview |",
        "| Pace | $29 once | Yes | Bundled local model stack | Hosted checkout when configured, otherwise manual email |",
        "| Studio | Target $5/month | No | Proposed managed Composio routing | Updates email only; not a checkout |",
        "",
        "## What is live today",
        "",
        "- The current Mac preview and release download are live.",
        "- The free Apple Foundation Models path is available on supported Macs.",
        "- The $29 one-time Pace purchase is available through the displayed checkout or manual email path.",
        "- The $5/month Studio service is planned and unavailable.",
        "- The current app's Composio integration is user-configured and uses the user's API key.",
        "",
        "## Commercial evidence boundary",
        "",
        "- **Intended model:** free preview, $29 one-time Pace purchase, planned $5/month Studio.",
        "- **Implemented path:** the site supports a hosted Pace checkout URL and an honest manual email fallback.",
        "- **Configured provider:** only claim hosted checkout when the public checkout URL is configured; otherwise the rendered site says purchase is manual.",
        "- **Live purchase:** Pace can be paid through the manual path even without an embedded payment script. Studio has no live purchase path.",
        "",
        "## Before choosing",
        "",
        "- Check the download page for the latest version and signing or notarization state.",
        "- Confirm the Mac is Apple Silicon and meets the memory requirements for the desired model path.",
        "- Use the free preview before purchasing the bundled local-model option.",
        "- Expect explicit network use when enabling a cloud planner or Composio connector.",
        "- Do not interpret an updates email as a Studio subscription checkout.",
        "",
        "## Hardware and distribution",
        "",
        "- The current downloadable preview targets Apple Silicon Macs.",
        "- The current 0.3.19 preview requires macOS 26.",
        "- The Apple Foundation Models path also depends on Apple Intelligence availability.",
        "- Sixteen gigabytes of RAM is the practical floor for bundled local models.",
        "- Thirty-two gigabytes is recommended for keeping the larger bf16 model resident.",
        "- The bundled model path downloads model data separately from the small app archive.",
        "- The current public preview is distributed outside the Mac App Store and is not notarized.",
        "- Follow the download page's current Gatekeeper instructions; never infer a signed or notarized state from pricing.",
        "",
        "## Purchase questions",
        "",
        "- **Is Pace free?** The current Apple Foundation Models preview is free; the bundled local-model option is $29 once.",
        "- **Is the $29 price a subscription?** No. The listed Pace purchase is one-time.",
        "- **Does manual email mean the product is not paid?** No. It is the current fallback purchase path when hosted checkout is absent.",
        "- **Is there a licence key?** The current release has no in-app licence activation system, so the site does not promise one.",
        "- **What are the support, update, and refund terms?** They are confirmed in writing before payment through the current manual purchase path.",
        "- **Can I buy Studio?** No. The updates link records interest; it is not a subscription checkout.",
        "- **Does Pace store card details?** The current site does not make that claim; payment handling depends on the confirmed hosted or manual method.",
        "- **Are model-provider fees included?** Local inference has no per-turn provider fee. Any user-selected third-party provider follows that provider's own terms.",
        "",
        "## Network boundary by option",
        "",
        "- Try and Pace can run voice, planning, screen interpretation, and speech locally when configured for local models.",
        "- Sparkle can contact the GitHub-hosted appcast to check for updates.",
        "- A user-selected cloud planner sends that turn to the selected provider and is visibly identified in the app.",
        "- User-enabled Composio connectors route tool calls through Composio; Studio does not exist yet to manage that path.",
        "",
        "## Try — free preview",
        "",
        "Uses Apple Foundation Models for planning on supported Macs with Apple Intelligence. It includes the core voice loop, approved Mac actions, meeting notes, local memory and journals, and user-configured MCP servers. Optional local screen reading can use a model the user runs on the Mac.",
        "",
        "### Includes",
        "",
        "- Push-to-talk voice loop with on-device speech recognition and speech output.",
        "- Apple Foundation Models planning on supported Macs.",
        "- Approved Mac actions, local meeting notes, memory, journals, and recipes.",
        "- User-configured local MCP servers and optional local screen reading.",
        "",
        "### Limits",
        "",
        "- Apple Intelligence is required for the free planner path.",
        "- Bundled Pace planner, vision, and speech models belong to the paid option.",
        "",
        "## Pace — $29 once",
        "",
        "Adds the bundled local planner, vision, and speech model experience. It is a one-time purchase, not a subscription. When hosted checkout is not configured, the purchase button opens a pre-filled email so payment and delivery can be confirmed manually before payment.",
        "",
        "### Includes",
        "",
        "- Everything in the free preview.",
        "- Bundled Qwen3-4B planner and Qwen3-VL-4B screen-reading path.",
        "- Bundled local speech options and Sparkle app-update support.",
        "- Payment, delivery, support, included updates, and any refund terms confirmed before payment.",
        "",
        "### Limits",
        "",
        "- Apple Silicon and macOS 26 for the current 0.3.19 preview.",
        "- At least 16 GB RAM is recommended; the larger bf16 path benefits from 32 GB.",
        "- The local model download uses roughly 8 GB in the Hugging Face cache.",
        "- Checkout is manual when a hosted payment URL is not configured.",
        "",
        "The current release has no in-app licence activation or deactivation system. The current manual purchase path confirms payment, delivery, support, included updates, and any refund terms before payment.",
        "",
        "## Studio — planned, not for sale",
        "",
        "Studio is a proposed managed Composio routing option with a $5/month target price. It is not live and is excluded from current purchasable-offer structured data. Today's app can connect to Composio only with a user-provided API key.",
        "",
        "### Planned scope and current limits",
        "",
        "- Proposed managed connector setup and authentication.",
        "- Target price of $5/month if and when the service launches.",
        "- Not currently sold; there is no hosted Studio service to buy today.",
        "- Current Composio calls are off-device and use the user's own API key.",
        "",
        "Optional cloud routing is visibly identified and is not used for pinned-local meeting transcripts.",
        "",
        `Current purchase details: ${absoluteURL("/pricing")}`,
      ],
    ),
  },
  {
    id: "faq",
    path: "/faq",
    markdownPath: "/faq.md",
    kind: "static",
    title: "Pace FAQ",
    description:
      "Answers about Pace privacy, hardware, local models, recordings, purchase terms, integrations, and action safety.",
    priority: "0.7",
    markdown: markdownDocument(
      "Pace FAQ",
      "Answers about Pace privacy, hardware, local models, recordings, purchase terms, integrations, and action safety.",
      [
        "## Key answers",
        "",
        "- Voice, screen reading, planning, and speech can run on the Mac. Network access occurs only for features or providers the user explicitly chooses.",
        "- Meeting recordings are ordinary local files under Pace's Application Support directory and follow the configured retention window.",
        "- The current 0.3.19 preview requires macOS 26 on Apple Silicon; the paid bundled-model tier recommends at least 16 GB RAM.",
        "- LM Studio is optional. Pace supports bundled local models and Apple Foundation Models.",
        "- Reversible actions expose an undo window, and failed actions are reported rather than silently treated as successful.",
        "",
        `All questions and complete answers: ${absoluteURL("/faq")}`,
      ],
    ),
  },
  {
    id: "changelog",
    path: "/changelog",
    markdownPath: "/changelog.md",
    kind: "static",
    title: "Pace changelog",
    description:
      "A curated record of verified, user-visible Pace product outcomes.",
    priority: "0.6",
    markdown: markdownDocument(
      "Pace changelog",
      "A curated record of verified, user-visible Pace product outcomes.",
      [
        "## Recent outcomes",
        "",
        "- **2026-07-25:** Retired an overlapping background-runtime proposal and kept the existing companion plan authoritative.",
        "- **2026-07-13:** Reached an opt-in Always-On Companion Mode milestone with conservative local retention and intervention rules.",
        "- **2026-07-12:** Added Codex as a planner option under the existing explicit consent and audit contract.",
        "- **2026-07-06:** Made meeting notes profile-aware and linked action items back to transcript evidence.",
        "",
        `Full curated changelog: ${absoluteURL("/changelog")}`,
        "Roadmap and planned work remain in GitHub Issues rather than this shipped-outcomes record.",
      ],
    ),
  },
  {
    id: "docs",
    path: "/docs",
    markdownPath: "/docs/index.md",
    kind: "collection",
    title: "Pace documentation",
    description:
      "Product, architecture, development, operations, and privacy documentation for Pace.",
    priority: "0.8",
    markdown: "",
  },
  {
    id: "privacy",
    path: "/privacy",
    markdownPath: "/privacy.md",
    kind: "static",
    title: "Pace privacy",
    description:
      "How Pace keeps voice, screen, meeting, and journal data local, plus the explicit exceptions that can use the network.",
    priority: "0.4",
    markdown: markdownDocument(
      "Pace privacy",
      "How Pace keeps voice, screen, meeting, and journal data local, plus the explicit exceptions that can use the network.",
      [
        "## Default",
        "",
        "Pace processes voice, screen, meeting audio, and local journals on the Mac. It does not require an account and does not include analytics or telemetry SDKs.",
        "",
        "## Explicit network use",
        "",
        "- Sparkle checks a GitHub-hosted appcast for updates.",
        "- Optional cloud or CLI planner tiers contact the provider selected by the user and visibly tint the app's status surface.",
        "- The download tool fetches only a URL the user asks it to fetch.",
        "",
        "Meeting audio is stored as local files under Pace's Application Support directory and can be deleted by the user.",
      ],
    ),
  },
  {
    id: "terms",
    path: "/terms",
    markdownPath: "/terms.md",
    kind: "static",
    title: "Pace terms",
    description:
      "Plain-language terms for Pace's MIT-licensed software and current one-time purchase path.",
    priority: "0.4",
    markdown: markdownDocument(
      "Pace terms",
      "Plain-language terms for Pace's MIT-licensed software and current one-time purchase path.",
      [
        "## Software",
        "",
        "Pace is released under the MIT License and is provided as-is. Users should keep action approval prompts enabled until they trust their configuration.",
        "",
        "## Purchases",
        "",
        "Pace is a $29 one-time purchase. A hosted checkout may be configured; otherwise purchase details are confirmed through the site's manual email path before payment.",
        "",
        "## User data",
        "",
        "Pace has no hosted account service holding user data. Uninstalling the app and deleting its local Application Support directory removes its local state.",
      ],
    ),
  },
];

const comparisonSurfaces: PublicSurface[] = competitors.map((competitor) => {
  const path = `/compared/${competitor.slug}`;
  const sourceLabel = competitor.openSource
    ? `open source under ${competitor.license}`
    : `not open source under ${competitor.license}`;
  const capabilities = competitor.standoutFeatures.map(
    (feature) => `- ${feature}`,
  );

  return {
    id: `compared-${competitor.slug}`,
    path,
    markdownPath: `${path}.md`,
    kind: "detail",
    title: `Pace vs ${competitor.name}`,
    description: `An evidence-based comparison of Pace and ${competitor.name}: ${competitor.angle}.`,
    priority: "0.6",
    markdown: markdownDocument(
      `Pace vs ${competitor.name}`,
      `An evidence-based comparison of Pace and ${competitor.name}: ${competitor.angle}.`,
      [
        "## Product posture",
        "",
        `- **Product:** [${competitor.name}](${competitor.url})`,
        `- **Maintainer:** ${competitor.author}`,
        `- **License:** ${competitor.license}; ${sourceLabel}`,
        `- **Runtime posture:** ${competitor.posture}`,
        `- **Speech-to-text:** ${competitor.stt}`,
        `- **Reasoner:** ${competitor.reasoner}`,
        `- **Text-to-speech:** ${competitor.tts}`,
        `- **Screen-aware:** ${competitor.screenAware ? "Yes" : "No"}`,
        "",
        "## What the competing product does well",
        "",
        ...capabilities,
        "",
        "## Where Pace differs",
        "",
        competitor.paceDiffers,
        "",
        "This comparison does not claim ratings, market rank, or user-review scores.",
      ],
    ),
  };
});

export const publicSurfaces: PublicSurface[] = [
  ...staticSurfaces,
  ...Object.values(educationContent).map((content) => ({
    id: content.path.replace(/^\//, ""),
    path: content.path,
    markdownPath: `${content.path}.md`,
    kind: "static" as const,
    title: content.title,
    description: content.description,
    priority: "0.8",
    markdown: markdownDocument(content.title, content.description, [content.markdown]),
  })),
  ...comparisonSurfaces,
];

export const generatedMarkdownSurfaces = publicSurfaces.filter(
  (surface) => surface.markdown.length > 0,
);

export function markdownPublicPagePath(path: string): string | undefined {
  const canonicalPath = canonicalPublicPagePath(path);
  return publicSurfaces.find(
    (surface) => canonicalPublicPagePath(surface.path) === canonicalPath,
  )?.markdownPath;
}

export function publicSurfaceCatalog() {
  return publicSurfaces.map((surface) => ({
    id: surface.id,
    url: absoluteURL(surface.path),
    md: absoluteURL(surface.markdownPath),
    kind: surface.kind,
    description: surface.description,
  }));
}
