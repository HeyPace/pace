import { competitors, type Competitor } from "./competitors";
export const groups: { label: string; blurb: string; items: Competitor[] }[] = [
  {
    label: "Cloud",
    blurb:
      "Reasoning uses an external provider. Check the selected model, account requirements and which context is sent.",
    items: competitors.filter((c) => c.posture === "cloud"),
  },
  {
    label: "Hybrid",
    blurb:
      "Local components and external model paths. Check routing separately for speech, screen context, planning and tools.",
    items: competitors.filter((c) => c.posture === "hybrid"),
  },
  {
    label: "On-device",
    blurb:
      "Documents an on-device model path. Model downloads, optional tools and integrations can still require a network connection.",
    items: competitors.filter((c) => c.posture === "on-device"),
  },
];

export const postureLine: Record<string, string> = {
  "on-device": "runs fully on-device",
  cloud: "runs in the cloud",
  hybrid: "documents local components and external model paths",
};
