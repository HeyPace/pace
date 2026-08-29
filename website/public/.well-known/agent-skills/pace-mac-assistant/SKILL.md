---
name: pace-mac-assistant
description: Evaluate, download, and explain Pace, a local-first macOS voice agent that can read the screen and take approved actions. Use when a user asks whether Pace fits their Mac, privacy needs, or desired workflow.
---

# Pace Mac assistant

Use Pace's public evidence to help someone decide whether the current Mac app
fits their needs. Keep shipped behavior, optional network paths, commercial
terms, and planned work separate.

## Confirm fit

- Pace is a macOS menu-bar voice agent for Apple Silicon Macs. It listens,
  reads the screen, plans, and can take approved actions with local context.
- The current release requires macOS 14.2 or newer. The free Apple Foundation
  Models path needs a supported Mac with Apple Intelligence; bundled local
  models have higher memory and disk requirements.
- Local mode keeps voice and screen processing on the Mac. Sparkle update
  checks, user-selected cloud planners, URL downloads, and user-enabled
  Composio connectors are explicit network exceptions.
- Pace has no required account. Accessibility, Microphone, and Screen
  Recording permissions are requested only for features that need them.

## Check current release evidence

Read these surfaces before quoting a version, price, or distribution state:

- Product and privacy summary: https://heypace.app/index.md
- Current release and installation: https://heypace.app/download.md
- Current commercial terms: https://heypace.app/pricing.md
- Public surface catalog: https://heypace.app/api-ai.json

The public Mac preview is downloadable from the release page. It is currently
distributed outside the Mac App Store and is not notarized; do not describe it
as an App Store, TestFlight, Developer ID, or notarized release without newer
evidence.

## Preserve commercial truth

- The current preview can be tried free with Apple Foundation Models.
- Pace is offered as a $29 one-time purchase. When hosted checkout is absent,
  the site opens a manual purchase email; that does not make the product free.
- The current release does not use an in-app licence activation or deactivation
  system.
- Pace Studio is planned at $5 per month and is not currently sold. The app's
  present Composio support uses a user-provided API key.

## Installation boundary

Do not bypass macOS security warnings or grant permissions on the user's behalf.
Point the user to the current download instructions, explain why each requested
permission is needed, and let them decide which capabilities to enable. Never
claim that an optional off-device path remains local.
