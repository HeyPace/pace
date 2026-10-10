# Open-source software in Pace

Pace builds on maintained open-source components. Full copyright, license,
and bundled notice text is available in **About → Open-source credits and
licenses**, including offline. The source of that screen is
[`OpenSourceNotices.txt`](../../leanring-buddy/Resources/OpenSourceNotices.txt).

## Swift packages

Versions follow the committed Xcode `Package.resolved`; revision pins are
retained in the bundled notices. Transitive packages are attributed too.

| Project | Pinned version | License |
| --- | --- | --- |
| [eventsource](https://github.com/mattt/eventsource) | 1.5.1 | MIT |
| [gzipswift](https://github.com/1024jp/GzipSwift) | 6.0.1 | MIT |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.29.1 | MIT |
| [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) | 2.29.1 | MIT |
| [silero-vad-swift](https://github.com/paean-ai/silero-vad-swift) | 1.0.0 | MIT |
| [sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.0 | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.1 | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | 2.3.6 | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log) | 1.15.1 | Apache-2.0 |
| [swift-nio](https://github.com/apple/swift-nio) | 2.103.0 | Apache-2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 |
| [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | a0ae212ebf6e | Apache-2.0 |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.0.0 | Apache-2.0 |
| [whisperkit](https://github.com/argmaxinc/WhisperKit) | 1.0.0 | MIT |

## Optional external helpers

These are installed separately when selected; Pace does not bundle their
executables or require them for local-only use.

| Project | Pin | Role | License |
| --- | --- | --- | --- |
| [Peekaboo](https://github.com/steipete/Peekaboo) | 4.9.0 | macOS observation and computer control | MIT |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | 0.0.83 | Stateful browser tools | Apache-2.0 |
| [mcp-remote](https://github.com/punkpeye/mcp-remote) | 0.14.3 | Stdio bridge for Linear's OAuth MCP endpoint | MIT |

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
