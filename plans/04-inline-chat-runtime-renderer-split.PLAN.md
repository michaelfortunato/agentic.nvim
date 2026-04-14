# Inline Chat Runtime and Renderer Split

## Summary

Split `lua/agentic/ui/inline_chat.lua` into prompt control, runtime state, and
overlay rendering so inline request flow is easier to reason about and remains
multi-tab safe.

Depends on: `plans/00-ui-sync-scopes.PLAN.md`

Can run in parallel with:

- `03-message-writer-renderer-split`
- `05-diff-preview-review-split`
- `06-chat-widget-window-lifecycle-split`

## Goal

Separate ephemeral overlay UI from request/session control flow while preserving
the existing inline chat public API.

## Target Structure

### `lua/agentic/ui/inline_chat/prompt_controller.lua`

Owns floating prompt lifecycle:

- open prompt window
- bind prompt-local keymaps
- gather prompt text
- close prompt and restore focus
- prompt footer rendering

### `lua/agentic/ui/inline_chat/runtime_store.lua`

Owns inline request state:

- `_active_request`
- `_queued_requests`
- `_thread_runtimes`
- thread-store read/write helpers
- overlap detection
- request begin/queue/remove/complete state transitions
- applied-edit overlay hiding rules

### `lua/agentic/ui/inline_chat/overlay_renderer.lua`

Owns overlay presentation:

- virtual-line building
- extmark placement and clearing
- selection/range normalization used for rendering
- progress message updates
- close timers for stale thread overlays

### `lua/agentic/ui/inline_chat.lua`

Remains the façade and public require path.

## Scope Rules

- Buffer-local thread history stays in
  `vim.b[bufnr][InlineChat.THREAD_STORE_KEY]`.
- Source buffer and source window remain the authoritative context for inline
  overlays.
- Inline chat must remain tab-safe by never using module-global active request
  state shared across instances.

## Public Interface Rules

- Preserve methods currently used by `SessionManager`:
  - `open`
  - `queue_request`
  - `sync_queued_requests`
  - `find_overlapping_queued_submission`
  - `remove_queued_submission`
  - `begin_request`
  - `refresh`
  - `handle_session_update`
  - `handle_tool_call`
  - `handle_tool_call_update`
  - `handle_permission_request`
  - `handle_applied_edit`
  - `complete`
  - `clear`
  - `destroy`

## Test Plan

- Keep `lua/agentic/ui/inline_chat.test.lua` as the main behavior suite.
- Add focused tests for:
  - prompt close/focus restore
  - queued inline request overlap detection and removal
  - runtime persistence in buffer-local thread storage
  - overlay hiding after applied edits
  - progress status transitions across thinking/tool/waiting/completed
  - timer-driven cleanup of completed overlays

## Acceptance Criteria

- Prompt-window changes can be made without editing runtime state transitions.
- Runtime state transitions can be changed without editing virtual-line layout.
- Overlay rendering is clearly buffer-local and window-aware.
- Existing inline chat behavior remains unchanged for users.

## Out of Scope

- New inline UX
- New ACP events
- Session registry changes
