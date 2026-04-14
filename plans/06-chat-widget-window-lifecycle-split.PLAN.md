# ChatWidget Window Lifecycle Split

## Summary

Reduce `lua/agentic/ui/chat_widget.lua` to a façade over window lifecycle,
input flow, and header control while preserving current widget behavior.

Depends on: `plans/00-ui-sync-scopes.PLAN.md`

Can run in parallel with:

- `03-message-writer-renderer-split`
- `04-inline-chat-runtime-renderer-split`
- `05-diff-preview-review-split`

## Goal

Keep `ChatWidget` UI-only, but make edits local: layout and fallback-window
changes should not require touching input flow or header hint logic.

## Target Structure

### `lua/agentic/ui/chat_widget/window_controller.lua`

Owns:

- widget show/hide/refresh lifecycle
- fallback-window creation
- find-first-editor-window and non-widget-window logic
- buffer ownership checks
- optional-panel close/resize plumbing

### `lua/agentic/ui/chat_widget/input_controller.lua`

Owns:

- input text read/write
- submit flow
- prompt-related keymaps
- prompt focus restore and insert-mode behavior
- jump-back-to-input behavior from auxiliary panels

### `lua/agentic/ui/chat_widget/header_controller.lua`

Owns:

- header context and overlay state
- mode-dependent suffix refresh
- `render_header()` plumbing into `WindowDecoration`
- chat/input header refresh autocmds

### `lua/agentic/ui/chat_widget.lua`

Remains the façade and public require path.

## Scope Rules

- Widget buffers and windows remain tab-local.
- Chat follow/unread state remains window-local via `ChatViewport`.
- Header state remains tab-local and must not become session-global.

## Public Interface Rules

- Preserve current public methods used elsewhere:
  - `show`
  - `rotate_layout`
  - `refresh_layout`
  - `hide`
  - `clear`
  - `destroy`
  - `bind_message_writer`
  - `unbind_message_writer`
  - `set_submit_input_handler`
  - `move_cursor_to`
  - `focus_input`
  - `set_input_text`
  - `get_input_text`
  - `render_header`
  - `close_optional_window`
  - `resize_optional_window`
  - `find_first_non_widget_window`
  - `find_first_editor_window`
  - `owns_buffer`
  - `open_left_window`

## Test Plan

- Keep `lua/agentic/ui/chat_widget.test.lua` as the main behavior suite.
- Add focused tests for:
  - header isolation across tabpages
  - hide/show and refresh-layout window recreation
  - queue/input focus restoration when optional panels close
  - fallback-window creation when hiding the last widget window
  - correct detection of widget buffers versus editor buffers

## Acceptance Criteria

- Header logic is isolated from window lifecycle code.
- Input flow changes do not require editing fallback-window code.
- Widget behavior remains tab-local and multi-tab safe.
- Existing user-visible widget behavior stays the same.

## Out of Scope

- Redesigning layouts
- Refactoring `WidgetLayout`, `ChatViewport`, or `WindowDecoration` beyond
  wiring adjustments needed for the split
