# Pace for iPad: Companion Mode V1

**Status:** Implemented in source; physical-device acceptance open
**Platforms:** macOS + iPadOS 26
**Tracking:** [GitHub issue #170](https://github.com/HeyPace/pace/issues/170)

## Product boundary

The Mac remains Pace's only brain: it owns the planner, memory, Mac context,
tools, TTS orchestration, and proactive-interruption policy. The iPad gives
Pace a permanent place in the room through a full-screen face, microphone,
speaker, front camera, and touch controls.

There is no iPad-side planner, memory system, companion backend, cloud relay,
continuous Mac screen stream, continuous camera transmission, or robotics
control in V1.

```text
Pace on Mac                     PacePad
planner + tools                 animated face
memory + context      LAN       microphone + speaker
proactivity gate      <---->    local presence detection
conversation pipeline           requested-only JPEG still
```

## V1 experience

- The iPad discovers Pace-enabled Macs with Bonjour, pairs with one Mac using
  a six-digit code, stores the generated credential in Keychain, and reconnects
  automatically after temporary loss.
- PacePad launches into an always-awake foreground ambient screen: the iPad
  itself becomes Pace's full-screen face rather than presenting the character
  inside a card. System chrome stays hidden during the ambient scene. The
  minimal status/privacy HUD remains visible, while detailed controls stay one
  tap away and return to hidden after inactivity.
- The face expresses disconnected, idle, listening, transcribing, processing,
  speaking, proactive, paused, and sleeping states. Blue means the active
  request remains local; amber discloses an off-device planner selected on the
  Mac.
- Tap-to-talk records one AAC utterance capped at 60 seconds. The Mac transcribes it locally
  and routes the transcript through the existing Pace conversation pipeline.
  The response text returns to the iPad and is spoken with system TTS. Tapping
  Pace again stops speech or locally dismisses an in-flight turn; a late reply
  for a dismissed turn is ignored.
- Existing Mac proactivity decides whether to interrupt. PacePad only renders
  and speaks an already-approved proactive message.
- Vision human-rectangle detection runs on the iPad at no more than 1 fps and
  sends only presence/absence, confidence, and time.
- A conservative local parser permits only an explicit physical-scene question
  or camera-directed request to trigger one expiring camera-frame
  request. PacePad captures the next low-resolution JPEG; the Mac analyzes it
  with the existing privacy-pinned local vision client. Neither side records
  the image.
- Microphone, camera, speaker mute, capture pause, brightness, and night mode
  remain reachable from the companion screen. Camera and microphone activity
  are always visible. Permission and reconnect failures provide an immediate
  recovery action rather than passive error text.
- Idle uses deep ocean-blue signal arcs and a darker scanlined smile on an inky
  navy canvas. A shallow screen bezel, restrained full-display raster, layered
  phosphor edges, and closer facial spacing make the expression feel like one
  persistent CRT character rather than separate UI shapes. Electric Pace blue
  remains reserved for active local work and amber for off-device work. After
  five untouched idle minutes, the
  face and nonessential chrome fade into a near-black ambient state. The face
  relocates a few pixels periodically to protect an always-on display, and a
  tap or detected return restores it. The first tap in this dimmed state only
  wakes the interface; it never starts microphone capture.

## Protocol and security

- Bonjour service: `_pace-companion._tcp`
- Transport: TLS 1.3 over TCP with a pre-shared key derived from either the
  six-digit pairing code or the 256-bit stored device credential
- Application authentication: a credential HMAC binds server, iPad, and
  session identifiers
- Framing: a bounded JSON header plus optional binary payload; 64 KiB maximum
  header and 12 MiB maximum binary payload
- Media validation: AAC utterances, requested JPEG stills, and normalized finite
  presence confidence are rejected before dispatch when their metadata is invalid
- Reliability: five-second heartbeats, 18-second timeout, bounded message-ID
  replay protection, tested exponential reconnect capped at 15 seconds, and no
  re-pair after routine loss
- Credentials: Keychain with `WhenUnlockedThisDeviceOnly`; unpair deletes the
  exact 256-bit credential and invalidates the session; successful pairing also
  rotates the one-time numeric code

## Acceptance

Source-level acceptance is complete when the shared protocol, Mac adapter,
iPad target, and focused tests/type checks are present. Product acceptance still
requires a real iPad run from Xcode proving:

1. Pairing and restart/reconnect on one Mac.
2. A complete tap-to-talk round trip with listening/processing/speaking states.
3. A proactive spoken message after the existing restraint gate approves it.
4. Presence entry/exit semantic events with no camera bytes on the wire.
5. One requested still for an explicit physical-scene question.
6. Immediate capture pause and unmistakable indicators.
7. A 12-hour foreground session without crash, manual reconnect, or
   uncomfortable heat. The ambient screen must stay awake with its controls
   hidden by default, enter its low-energy idle treatment, periodically relocate
   fixed face pixels, and remain responsive to touch throughout the run.

The 14-day personal experiment succeeds at 10 active days, two voluntary
interactions per active day, at least 95% automatic reconnection, more useful
than annoying proactive messages, and at least one improved recurring behavior.
