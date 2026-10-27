import { competitors, type Competitor } from "./competitors";
export const groups: { label: string; blurb: string; items: Competitor[] }[] = [
  {
    label: "Cloud",
    blurb:
      "Every turn hits someone else's data center. Fast to ship, costs per turn, needs an account.",
    items: competitors.filter((c) => c.posture === "cloud"),
  },
  {
    label: "Hybrid",
    blurb:
      "Local by default, cloud when you ask for it. The middle path — flexible, but the privacy posture depends on which tier you picked.",
    items: competitors.filter((c) => c.posture === "hybrid"),
  },
  {
    label: "On-device",
    blurb:
      "Fully local. The cluster Pace lives in. Zero bytes off the machine, zero per-turn cost, works on a plane.",
    items: competitors.filter((c) => c.posture === "on-device"),
  },
];

export const postureLine: Record<string, string> = {
  "on-device": "runs fully on-device",
  cloud: "runs in the cloud",
  hybrid: "is local-by-default, cloud when you ask",
};
