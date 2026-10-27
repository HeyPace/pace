import { paceCheckoutURL, paceCheckoutIsMailto, studioInterestURL } from "./commerce";
export const tiers = [
  {
    name: "Try",
    price: "Free",
    cadence: "",
    blurb:
      "Runs against Apple's Foundation Models tier on any Mac with Apple Intelligence. The full app — voice, screen reading, actions, meeting notes — at no cost. You'll know within a week if the bundled stack is worth $29.",
    cta: { label: "Download Pace", href: "/download" },
    features: [
      "Apple Foundation Models planner (in-process, zero install)",
      "Push-to-talk voice loop with on-device ASR + TTS",
      "Optional local VLM screen reading (LM Studio)",
      "Action executor — clicks, typing, app/URL opens, calendar, reminders",
      "Meeting notes (pinned local, on-device synthesis)",
      "Thread + episodic memory, screen-watch & app-usage journals",
      "Recipe library + teachable skills",
      "MCP stdio tool bridge (you host the servers)",
    ],
    limits: [
      "No bundled Pace-tuned local model — uses Apple FM or your own LM Studio",
      "Apple Intelligence and macOS 26 required for Apple Foundation Models",
    ],
  },
  {
    name: "Pace",
    price: "$29",
    cadence: "one-time",
    blurb:
      "The current bundled local model stack — Qwen3-4B planner, Qwen3-VL-4B vision, Qwen3 TTS, and Kokoro-82M sidecar — all in-process, with no LM Studio requirement.",
    cta: { label: paceCheckoutIsMailto ? "Email to buy Pace — $29" : "Buy Pace — $29", href: paceCheckoutURL },
    features: [
      "Everything in Try, plus:",
      "Bundled MLX planner (Qwen3-4B) — no external install",
      "Bundled MLX-VLM (Qwen3-VL-4B) for screen reading",
      "Bundled Qwen3 TTS + Kokoro-82M sidecar",
      "WhisperKit ASR scaffold (opt-in)",
      "Sparkle app-update support",
      "Purchase terms confirmed before payment",
    ],
    limits: [
      "Current 0.3.19 preview requires macOS 26, Apple Silicon, and 16 GB RAM minimum (32 GB for bf16)",
      "~8 GB one-time model download into HuggingFace cache",
    ],
  },
  {
    name: "Studio (planned)",
    price: "$5",
    cadence: "/month",
    blurb:
      "A proposed managed-routing convenience for people who do not want to configure Composio themselves. It is not available for purchase yet.",
    cta: { label: "Get Studio updates", href: studioInterestURL },
    features: [
      "Everything in Pace, plus:",
      "Planned managed Composio routing",
      "Planned connector setup and authentication",
      "Price target: $5/month when available",
    ],
    limits: [
      "Not live and not currently sold",
      "Today's Composio integration uses your own API key",
      "Off-device tool calls route through Composio when you enable it",
    ],
  },
];

export const checkoutText = paceCheckoutIsMailto ? "Pace is paid, but checkout is manual today. Email confirms the payment method and delivery before any money changes hands." : "The configured hosted checkout is live.";
