import commandCenter from "../assets/command-center-960.webp";
import home from "../content/home.json";
import { qas } from "./faq-content";
import { entries } from "./changelog-content";
import { tiers, checkoutText } from "./pricing-content";
import { groups, postureLine } from "./compared-content";
import { competitors, comparisonRechecked, type Competitor } from "./competitors";
import releaseInfo from "./release-info.json";
import { fragmentMarkdown } from "./source-fragments";

const origin = "https://heypace.app";
const action = (link: { label: string; href: string }) => `[${link.label}](${new URL(link.href, origin).href})`;
export function homeMarkdown() {
  const { hero } = home;
  const lines = [hero.eyebrow, `## ${hero.title}`, hero.lede, action(hero.primary), action(hero.secondary), hero.note, `![${hero.window.alt}](${new URL(commandCenter.src, origin).href})`, hero.caption];
  for (const section of home.sections) for (const block of section.blocks) {
    lines.push(`## ${block.title}`);
    if ("eyebrow" in block && block.eyebrow) lines.push(block.eyebrow);
    if ("lede" in block && block.lede) lines.push(block.lede);
    if (block.type === "statement") {
      if ("points" in block) for (const point of block.points ?? []) lines.push(`### ${point.title}`, point.body);
    } else if (block.type === "cta") {
      if ("primary" in block && block.primary) lines.push(action(block.primary));
      if ("secondary" in block && block.secondary) lines.push(action(block.secondary));
    } else if (block.type === "faq" && "items" in block) {
      for (const item of block.items ?? []) lines.push(`### ${item.q}`, item.a);
    } else throw new Error(`Unmapped public Workbench block: ${block.type}`);
    if ("note" in block && block.note) lines.push(block.note);
  }
  lines.push(fragmentMarkdown("home-guides"));
  return lines.join("\n\n");
}
export function pricingMarkdown() {
  return [fragmentMarkdown("pricing-intro"), ...tiers.map((tier) => [
    `## ${tier.name}`, `${tier.price} ${tier.cadence}`.trim(), tier.blurb, action(tier.cta),
    "### Includes", tier.features.map((feature) => `- ${feature}`).join("\n"),
    "### Limits", tier.limits.map((limit) => `- ${limit}`).join("\n"),
  ].join("\n\n")), fragmentMarkdown("pricing-outro", { checkoutText })].join("\n\n");
}
export function faqMarkdown() {
  return [fragmentMarkdown("faq-intro"), ...qas.map((item) => `## ${item.q}\n\n${item.a}`), fragmentMarkdown("faq-outro")].join("\n\n");
}
export function changelogMarkdown() {
  return [fragmentMarkdown("changelog-intro"), ...entries.map((entry) => `## ${entry.title}\n\n${entry.date}\n\n${entry.outcomes.map((outcome) => `- ${outcome}`).join("\n")}`)].join("\n\n");
}
export function downloadMarkdown() {
  const { latest, releases, releasesPageURL } = releaseInfo;
  const lines = [fragmentMarkdown("download-intro", { version: latest?.version ?? "" })];
  if (latest) lines.push(`[Download Pace ${latest.version}](${latest.downloadURL})`, `${latest.lengthMB} MB · zip`, `macOS ${latest.minimumSystemVersion}+ · Apple Silicon`, `Released ${latest.displayDate}`, fragmentMarkdown("download-offer"));
  lines.push(fragmentMarkdown("download-install", { version: latest?.version ?? "" }));
  if (releases.length) lines.push("## Recent releases", `[All releases](${releasesPageURL})`, ...releases.map((release) => `- [${release.version}](${release.downloadURL}): ${release.displayDate}; ${release.lengthMB} MB`));
  lines.push(fragmentMarkdown("download-outro"));
  return lines.join("\n\n");
}
function analysisMarkdown(competitor: Competitor, showFullComparisonLink: boolean) {
  return [`### ${competitor.name}`, `[${competitor.url.replace(/^https?:\/\//, "").replace(/\/$/, "")}](${competitor.url})`, `${competitor.tagline} — ${competitor.author}`, `STT: ${competitor.stt} · Reasoner: ${competitor.reasoner} · TTS: ${competitor.tts} · Screen: ${competitor.screenAware ? "yes" : "no"}`, "#### What it's good at", competitor.standoutFeatures.map((feature) => `- ${feature}`).join("\n"), "#### Where Pace differs", competitor.paceDiffers, ...(showFullComparisonLink ? [`[Full comparison — Pace vs ${competitor.name}](${origin}/compared/${competitor.slug}/)`] : []), `Open source: ${competitor.openSource ? "Yes" : "No"}`, `License: ${competitor.license}`, `Posture: ${competitor.posture}`].join("\n\n");
}
export function comparedMarkdown() {
  return [fragmentMarkdown("compared-intro", { count: competitors.length }), ...groups.flatMap((group) => [`## ${group.label}`, `${group.items.length} ${group.items.length === 1 ? "product" : "products"}`, group.blurb, ...group.items.map((competitor) => analysisMarkdown(competitor, true))]), fragmentMarkdown("compared-outro", { rechecked: comparisonRechecked })].join("\n\n");
}
export function comparisonMarkdown(competitor: Competitor) {
  return [fragmentMarkdown("comparison-intro", { name: competitor.name, posture: postureLine[competitor.posture], source: competitor.openSource ? "open source" : "closed source", license: competitor.license, tagline: competitor.tagline, difference: competitor.paceDiffers }), analysisMarkdown(competitor, false), fragmentMarkdown("comparison-outro", { rechecked: comparisonRechecked, name: competitor.name })].join("\n\n");
}
export { fragmentMarkdown };
