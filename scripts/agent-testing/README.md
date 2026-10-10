# Pace command checks with the shared runner

Uses the dependency-free core of [agent-testing](https://github.com/sarthakagrawal927/agent-testing),
observed at commit `7c0cfb2809ef244dbe2ac4936587eb5334fb5f13`.
Keep its checkout outside Pace's source; no production dependency is added.

From the Pace checkout, with Node 22+ and a full Xcode toolchain:

```sh
git clone https://github.com/sarthakagrawal927/agent-testing.git build/agent-testing
git -C build/agent-testing checkout 7c0cfb2809ef244dbe2ac4936587eb5334fb5f13
node --test scripts/agent-testing/verify-commands.test.mjs
node build/agent-testing/bin/agent-testing.mjs validate \
  --manifest scripts/agent-testing/commands.manifest.json
node build/agent-testing/bin/agent-testing.mjs run \
  --manifest scripts/agent-testing/commands.manifest.json \
  --out build/agent-testing-command-checks
```

Use a new output directory per run. Set `DEVELOPER_DIR` if needed.
Run serially with other Pace unit runs: the existing isolated test helper uses
`/tmp/pace-test-derived-data`. The verifier rejects stale result bundles,
missing command checks, skipped/failed cases, and inconsistent test counts.

This single run checks unit contracts for app routines, Chrome profiles, Codex
directories, recording, observation-only actions, and pointer coordinates.
It is not a performance comparison or native desktop acceptance.
Screen reading, visible pointer landing, real saved recording playback, and
the live Warp directory still require independent hardware observation.
