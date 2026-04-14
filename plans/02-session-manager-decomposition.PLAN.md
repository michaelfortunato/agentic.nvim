# SessionManager Decomposition

## Summary

Split `lua/agentic/session_manager.lua` into explicit collaborators so ACP
session lifecycle, widget binding, and submission orchestration stop living in a
single class.

Depends on:

- `plans/00-ui-sync-scopes.PLAN.md`
- `plans/01-session-identity-vs-widget-ownership.PLAN.md`

## Goal

Keep `SessionManager` as the public façade while moving real ownership into
focused modules that line up with the existing architecture.

## Target Structure

### `lua/agentic/session/session_controller.lua`

Owns ACP session identity and lifecycle:

- `agent`
- `session_id`
- `_session_starting`
- `_pending_session_callbacks`
- `_restoring`
- `_restored_turns_to_send`
- `_is_first_message`
- `new_session`, cancel, switch-provider, restore-session-data helpers
- ACP callback routing from `SessionLifecycle` and `ACPClient` into session
  state

### `lua/agentic/session/widget_binding.lua`

Owns widget-local projections and state transfer:

- widget attachment and teardown
- widget snapshot capture/restore
- `ChatWidget`, `MessageWriter`, `ReviewController`, `StatusAnimation`
- `AgentConfigOptions`, `FileList`, `CodeSelection`, `DiagnosticsList`,
  `TodoList`, `FilePicker`
- window header rendering
- queue panel visibility changes that require layout updates
- inline config refresh hooks

### `lua/agentic/session/submission_controller.lua`

Owns prompt preparation and request orchestration:

- `_prepare_submission()`
- `_handle_input_submit()`
- `_submit_inline_request()`
- `_dispatch_submission()`
- queue operations and queue draining
- inline queue sync
- prompt hooks and response-complete hooks

## Required `SessionManager` Shape After Refactor

- Keep the `SessionManager` public methods used by callers:
  - `new()`
  - `swap_widget()`
  - `new_session()`
  - `switch_provider()`
  - `restore_session_data()`
  - `add_selection_or_file_to_session()`
  - `add_selection_to_session()`
  - `add_file_to_session()`
  - `open_inline_chat()`
  - diagnostics adders
  - `destroy()`
- `SessionManager` becomes a delegating façade with minimal direct logic.
- Avoid cyclic ownership:
  - controller modules may receive `session` for façade callbacks
  - controller modules must not require each other through deep cross-calls

## Implementation Rules

- Keep current `SessionLifecycle` behavior, but move ownership to the
  `session_controller` boundary instead of exposing widget details directly.
- Reuse existing `SessionState`, `SessionEvents`, `SessionSelectors`, and
  `SubmissionQueue`.
- Keep tab-local UI sync in the widget binding module only.
- Keep ACP session identity in the session controller only.
- Keep queue state and submission flow in the submission controller only.

## Files To Touch

- `lua/agentic/session_manager.lua`
- new files under `lua/agentic/session/`
- tests next to the touched modules

## Test Plan

- Preserve `session_manager.test.lua` coverage for public behavior.
- Add focused tests for:
  - widget snapshot capture/restore during `swap_widget()`
  - queue orchestration and queue-panel sync
  - ACP lifecycle behavior during create/cancel/restore/switch-provider
  - prompt dispatch and response completion
- Keep multi-tab safety covered: widget binding state must remain tab-local after
  the split.

## Acceptance Criteria

- `SessionManager` no longer directly owns every subsystem field mutation.
- ACP lifecycle changes no longer require editing widget-specific code paths.
- Widget swap and widget restore paths do not require touching ACP lifecycle
  logic.
- Queue behavior and prompt dispatch can be changed without editing widget
  binding code.

## Out of Scope

- Redesigning the public `SessionManager` API
- ACP `session/list` or `session/load` feature work
- Refactoring large UI modules outside the wiring needed to keep this split
  working
