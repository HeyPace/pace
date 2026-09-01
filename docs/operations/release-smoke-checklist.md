# Release hardware smoke checklist

Walk this before every release. `scripts/release-pace.sh` prompts for it.

**Why this exists:** the unit suite (1000+ tests) injects synthetic data
through test hooks, so it is structurally blind to defects at the
hardware boundary. v0.3.17 shipped 1079-green with both meeting audio
tracks recorded at 48 kHz but labeled 16 kHz — playback ~3× slow,
corrupted ASR input. Five minutes with the real app catches what the
suite cannot.

Run the locally built Release app (not a dev build) on real hardware.

## Voice core (every release)

- [ ] Hold ctrl+option, say "what time is it" — reply speaks within ~1 s.
- [ ] Say "open Music" — app opens once (watch for double-execution).
- [ ] Press PTT twice back-to-back — second turn starts cleanly.
- [ ] After releasing PTT, the macOS orange mic indicator goes away
      within ~10 s.

## Meeting notes (any release touching audio/capture)

- [ ] Start meeting mode, play a ~30 s video with speech, talk over it
      briefly, stop.
- [ ] Open `~/Library/Application Support/Pace/meetings/<id>/` and PLAY
      both `mic.wav` and `system.wav` in QuickTime — normal speed,
      intelligible, correct duration.
- [ ] Notes card appears with a non-empty summary; "you"/"them"
      attribution roughly matches who spoke.
- [ ] Force-quit mid-meeting once, relaunch — no `.part` files remain
      in the meeting directory (crash repair ran).

## Screen actions (any release touching executor/VLM)

- [ ] "Click <a visible button>" — cursor flies to the right element.
- [ ] "Undo that" after a reversible action — restores state, runs once.

## Q real screen OCR (any release touching QBridgeScreenCapture/QBridgeVision)

Real ScreenCaptureKit + Vision recognition cannot be exercised deterministically
inside the isolated-DerivedData unit suite — Screen Recording TCC permission
cannot be assumed there. This is the one place that gap is closed.

- [ ] With Screen Recording permission granted to Pace, open a window with
      known visible text (e.g. this checklist in a text editor) and ask Q to
      read the screen — the spoken/HUD response reflects real on-screen text,
      not a placeholder or generic description.
- [ ] Revoke Screen Recording permission (System Settings → Privacy & Security
      → Screen Recording → toggle Pace off), relaunch, and ask Q to read the
      screen again — it fails closed with a clear permission-related message;
      it does not fabricate a result or crash.
- [ ] With permission granted, show text containing something secret-shaped
      (e.g. a fake `sk-`-prefixed string) on screen and ask Q to read it —
      confirm via Settings → Memory / the local audit log that the persisted
      record shows `[REDACTED_SECRET]`, not the plaintext.

## Off-device tiers (any release touching planner tiers)

- [ ] With Direct API tier active, run one turn — menu-bar capsule
      tints amber; Privacy dashboard shows bytes/target.
- [ ] Switch back to Local — dashboard returns to "0 bytes".

Record date + build + any anomaly in the release PR description.
