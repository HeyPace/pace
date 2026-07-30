---
name: Pace
description: A private command console for an on-device macOS voice agent.
colors:
  canvas-black: "#000000"
  surface-ink: "#0b0b0d"
  surface-raised: "#15171b"
  border-graphite: "#2a2d31"
  text-white: "#ffffff"
  text-secondary: "#9ca3af"
  text-muted: "#7c8592"
  electric-blue: "#4f8bff"
  electric-blue-hover: "#6b9fff"
  positive: "#34d399"
  warning: "#fbbf24"
typography:
  display:
    fontFamily: "Instrument Serif, Iowan Old Style, Palatino, Georgia, serif"
    fontWeight: 400
    lineHeight: 0.98
    letterSpacing: "-0.012em"
  body:
    fontFamily: "Inter, -apple-system, BlinkMacSystemFont, Helvetica Neue, sans-serif"
    lineHeight: 1.7
  mono:
    fontFamily: "JetBrains Mono, SF Mono, monospace"
rounded:
  button: "10px"
  card: "14px"
spacing:
  button-x: "22px"
  button-y: "14px"
components:
  button-primary:
    backgroundColor: "{colors.electric-blue}"
    textColor: "{colors.canvas-black}"
    rounded: "{rounded.button}"
    padding: "{spacing.button-y} {spacing.button-x}"
  button-primary-hover:
    backgroundColor: "{colors.electric-blue-hover}"
    textColor: "{colors.canvas-black}"
    rounded: "{rounded.button}"
    padding: "{spacing.button-y} {spacing.button-x}"
  card:
    backgroundColor: "{colors.surface-ink}"
    textColor: "{colors.text-white}"
    rounded: "{rounded.card}"
---

# Design System: Pace

## Overview

**Creative North Star: "The Private Command Console"**

Pace’s public surface translates the native menu-bar product into a restrained
black editorial environment. It combines a precise command-console vocabulary
with warmer serif display typography so the product reads as capable and
personal rather than as a generic infrastructure tool.

The interface is dark, dense with real product evidence, and explicit about
privacy boundaries. Electric blue is deliberately rare and carries primary
action or active-system meaning.

**Key Characteristics:**

- Pure-black canvas with graphite surface layering.
- Editorial serif display type paired with neutral sans-serif body copy.
- Command, plan, and system evidence expressed through monospace details.
- One electric-blue action accent and semantic green/yellow status colors.
- Product-shaped demonstrations rather than decorative dashboard imagery.

## Colors

The palette is neutral and high-contrast, with one electric action accent.

### Primary

- **Electric Action Blue** (`#4f8bff`): Primary calls to action and the
  product’s active cursor or listening emphasis.
- **Electric Hover Blue** (`#6b9fff`): Hover feedback for primary actions.

### Neutral

- **Canvas Black** (`#000000`): Page background.
- **Surface Ink** (`#0b0b0d`): Cards and grouped content.
- **Raised Graphite** (`#15171b`): Elevated controls and nested surfaces.
- **Border Graphite** (`#2a2d31`): Dividers and low-emphasis boundaries.
- **Primary White** (`#ffffff`): Headlines and decisive labels.
- **Secondary Silver** (`#9ca3af`): Body copy.
- **Muted Slate** (`#7c8592`): Annotations and supporting labels.

**The One Accent Rule.** Electric blue stays scarce so it retains meaning as
the active voice and primary action.

## Typography

**Display Font:** Instrument Serif with Iowan Old Style, Palatino, and Georgia
fallbacks  
**Body Font:** Inter with native system fallbacks  
**Label/Mono Font:** JetBrains Mono with SF Mono fallback

The serif display face adds an editorial, human counterweight to the product’s
technical execution evidence. Sans-serif copy stays quiet and legible;
monospace is reserved for commands, system output, and quantitative proof.

### Hierarchy

- **Display** (400, responsive, `0.98` line-height): Hero and section
  statements.
- **Headline** (tight `-0.022em` tracking): Section hierarchy.
- **Body** (regular, `1.7` line-height): Explanations with a roughly
  38-rem maximum measure.
- **Label/Mono**: Commands, specifications, and system evidence.

## Layout

The page uses a centered responsive column with full-width black bands,
contained editorial sections, and product demonstrations that become stacked
on narrow screens. Generous section spacing separates distinct claims while
tighter internal spacing keeps proof and explanation visibly related.

## Elevation & Depth

Depth is mostly tonal. Surface Ink and Raised Graphite sit above Canvas Black,
with subtle graphite borders. Cards may use a restrained inset highlight and
deep ambient shadow, but the interface must never become glossy or skeuomorphic.

### Shadow Vocabulary

- **Card Ambient** (`0 1px 0 rgba(255,255,255,.03) inset, 0 8px 24px
  rgba(0,0,0,.5)`): Quiet separation for major evidence cards.

## Shapes

Buttons use a compact 10px radius; cards use 14px. Borders are thin and
low-contrast. The form language is softly machined rather than pill-heavy:
rounded enough to feel approachable, precise enough to retain command-console
discipline.

## Components

### Buttons

- **Shape:** Compact rounded rectangle (`10px`).
- **Primary:** Electric blue, black text, `14px 22px` padding, semibold.
- **Hover / Focus:** Brighter blue and a slight one-pixel lift; keyboard focus
  must remain visible.
- **Secondary:** Transparent black, graphite border, white text, with a tonal
  hover surface.

### Cards / Containers

- **Corner Style:** `14px`.
- **Background:** Surface Ink, with Raised Graphite for nested elements.
- **Shadow Strategy:** Ambient and restrained.
- **Border:** One-pixel Border Graphite.

### Navigation

Navigation remains visually quiet beside the primary product claim. Desktop
links collapse into a compact mobile treatment, and the download or purchase
action retains the strongest emphasis.

### Product Demonstration

The plan-then-execute sequence is the signature component. It uses real-shaped
thinking, spoken response, and tool-call states to explain the product
mechanism. Its motion must stop or become static under reduced-motion
preferences.

## Do's and Don'ts

### Do:

- **Do** show actual product-shaped commands, plans, and trust boundaries.
- **Do** reserve Electric Action Blue for primary action and active state.
- **Do** keep long explanations within readable editorial measures.
- **Do** provide reduced-motion, keyboard-focus, and responsive alternatives.

### Don't:

- **Don't** add unrelated accent colors or decorative gradients.
- **Don't** replace product evidence with generic AI dashboards or stock art.
- **Don't** fabricate customer names, quantified claims, or measured accuracy.
- **Don't** hide off-device exceptions behind an absolute privacy claim.
