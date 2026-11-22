# Open-source software in Pace

Pace builds on maintained open-source components. Full copyright, license,
and bundled notice text is available in **About → Open-source credits and
licenses**, including offline. The source of that screen is
[`OpenSourceNotices.txt`](https://github.com/HeyPace/pace/blob/main/leanring-buddy/Resources/OpenSourceNotices.txt).

## Swift packages

Versions follow the committed Xcode `Package.resolved`; revision pins are
retained in the bundled notices. Transitive packages are attributed too.

| Project | Pinned version | License |
| --- | --- | --- |
| [eventsource](https://github.com/mattt/eventsource) | 1.6.0 | MIT |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.32.3 | MIT |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.32.3 | MIT |
| [silero-vad-swift](https://github.com/paean-ai/silero-vad-swift) | 1.0.0 | MIT |
| [sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.4 | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.6 | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 | Apache-2.0 |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | 1.0.0 | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | 3.1.0 | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log) | 1.17.0 | Apache-2.0 |
| [swift-nio](https://github.com/apple/swift-nio) | 2.105.0 | Apache-2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 |
| [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | a0ae212ebf6e | Apache-2.0 |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | 603.0.2 | Apache-2.0 |
| [swift-system](https://github.com/apple/swift-system) | 1.9.0 | Apache-2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.4.0 | Apache-2.0 |
| [ui-library](https://github.com/sass-maker/ui-library) | 0.1.35 | MIT |
| [whisperkit](https://github.com/argmaxinc/WhisperKit) | 1.1.1 | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | 0.13.0 | MIT |

## Optional external helpers

These are installed separately when selected; Pace does not bundle their
executables or require them for local-only use.

| Project | Pin | Role | License |
| --- | --- | --- | --- |
| [Peekaboo](https://github.com/openclaw/Peekaboo) | 4.9.8 | macOS observation and computer control | MIT |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | 0.0.85 | Stateful browser tools | Apache-2.0 |
| [mcp-remote](https://github.com/punkpeye/mcp-remote) | 0.16.6 | Stdio bridge for Linear's OAuth MCP endpoint | MIT |

Pace uses Linear's [official read-only MCP endpoint](https://linear.app/docs/mcp)
with explicit OAuth authorization. Other configured MCP servers retain their
own licensing and service terms. Slack's official server requires a registered
client; installing a catalog entry does not claim a connected Slack account.

## Models and development tooling

The wake-word classifier's backbone and training provenance are documented in
[the classifier attribution](../product/pace-wake-word-classifier.md); its
Apache license is bundled separately. Optional MLX Audio/Kokoro provisioning
is external to the app and retains the upstream model licenses. Downloaded
model weights have their own licenses, separate from Swift package licenses.
The copied development harness is attributed in
[agent-testing README](https://github.com/HeyPace/pace/blob/main/scripts/agent-testing/README.md).

Native PDFKit, EventKit, Vision, Spotlight, and NaturalLanguage supply the Mac
features that do not need another dependency. They are Apple frameworks rather
than open-source projects. No telemetry or third-party service is introduced
by the attribution surface.
