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

function absoluteURL(path: string): string {
  return new URL(path, PRODUCTION_ORIGIN).toString();
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
        "- macOS 14.2 or newer.",
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
      "Pace offers a free Apple Foundation Models tier, a $29 one-time local model tier, and an optional $5 monthly hosted routing tier.",
    priority: "0.9",
    markdown: markdownDocument(
      "Pace pricing",
      "Pace offers a free Apple Foundation Models tier, a $29 one-time local model tier, and an optional $5 monthly hosted routing tier.",
      [
        "## Tiers",
        "",
        "- **Try — free:** Apple Foundation Models planner with the core local app.",
        "- **Pace — $29 once:** bundled local planner, vision, and speech models with free upgrades.",
        "- **Studio — $5/month:** optional hosted Composio routing for connectors.",
        "",
        "The app remains usable without Studio. Optional cloud or hosted routing is visibly identified and is not used for pinned-local meeting transcripts.",
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
      "Answers about Pace privacy, hardware, local models, recordings, refunds, integrations, and action safety.",
    priority: "0.7",
    markdown: markdownDocument(
      "Pace FAQ",
      "Answers about Pace privacy, hardware, local models, recordings, refunds, integrations, and action safety.",
      [
        "## Key answers",
        "",
        "- Voice, screen reading, planning, and speech can run on the Mac. Network access occurs only for features or providers the user explicitly chooses.",
        "- Meeting recordings are ordinary local files under Pace's Application Support directory and follow the configured retention window.",
        "- Pace supports Apple Silicon Macs on macOS 14 or newer; the paid bundled-model tier recommends at least 16 GB RAM.",
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
    path: "/docs/",
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
      "Plain-language terms for Pace's MIT-licensed software and one-time purchase.",
    priority: "0.4",
    markdown: markdownDocument(
      "Pace terms",
      "Plain-language terms for Pace's MIT-licensed software and one-time purchase.",
      [
        "## Software",
        "",
        "Pace is released under the MIT License and is provided as-is. Users should keep action approval prompts enabled until they trust their configuration.",
        "",
        "## Purchases",
        "",
        "The paid tier is a one-time purchase handled by the payment processor. Pace does not store payment details.",
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

export function publicSurfaceCatalog() {
  return publicSurfaces.map((surface) => ({
    id: surface.id,
    url: absoluteURL(surface.path),
    md: absoluteURL(surface.markdownPath),
    kind: surface.kind,
    description: surface.description,
  }));
}
