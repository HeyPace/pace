## 1. Observation Primitive

- [x] 1.1 Add the generic bounded action-observation configuration, outcomes, and cancellation-aware waiter.
- [x] 1.2 Add deterministic unit tests for immediate change, delayed change, timeout, and cancellation.

## 2. Runtime Integration

- [x] 2.1 Replace candidate-click fixed verification sleep with the shared click observation configuration.
- [x] 2.2 Capture a pre-execution loop baseline and replace the legacy fixed settle sleep with the shared agent-loop observation configuration.

## 3. Documentation And Verification

- [x] 3.1 Add the new source file to `docs/development/key-files.md` and keep the FastPath architecture article aligned with the implemented first slice.
- [x] 3.2 Validate the OpenSpec change, run the focused isolated tests, run documentation validation, and run `git diff --check`. (`validate-docs.sh` still reports six pre-existing broken links in the generated `website/public/docs` mirror; no FastPath link failed.)
