---
name: "Coding Session"
slug: "coding-session"
description: "Start or continue retained coding work in an explicitly approved workspace"
category: "work"
requiredPreferences: []
trigger: "manage coding"
---

## Steps

1. Identify the workspace and task in the current request or an explicit follow-up. If the user only invokes this skill by name, ask what they want to build or change. Preserve literal text, punctuation and file-content requirements; do not add requirements they did not ask for.
2. Use the installed Coding power to inspect owned session status. Resume an unambiguous matching session instead of creating another writer for the same workspace.
3. Start or resume through Pace's workspace-scoped approval path. Show the actual workspace and task. An existing session does not grant approval for a new task.
4. Let the retained Codex session perform the coding work. Keep progress and final results correlated with this request in the shared conversation.
5. Use local status or cancellation controls when requested. Do not wait for another model to stop a session.
6. Report completed changes and actual checks. Distinguish interrupted, failed, running and completed work, and retain the session for a later explicit continuation.

## Notes

The Coding power owns sandboxing, network policy, reservations and process cleanup. This skill cannot broaden those permissions, change security settings, grant session-wide approvals or run another coding process around the managed session.
