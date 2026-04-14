# Diff Preview Review Split

## Summary

Split `lua/agentic/ui/diff_preview.lua` into review-state, inline renderer, and
keymap-bridge modules so diff review behavior becomes safer to change.

Depends on: `plans/00-ui-sync-scopes.PLAN.md`

Can run in parallel with:

- `03-message-writer-renderer-split`
- `04-inline-chat-runtime-renderer-split`
- `06-chat-widget-window-lifecycle-split`

## Goal

Make review state explicit and keep tab-local diff state separate from
buffer-local rendering details and keymap save/restore logic.

## Target Structure

### `lua/agentic/ui/diff_preview/review_state.lua`

Owns review runtime state:

- review session creation
- pending/accepted/rejected hunk tracking
- per-buffer review-keymap state bookkeeping
- tab-local active diff buffer bookkeeping
- tab-local diff split bookkeeping integration

### `lua/agentic/ui/diff_preview/inline_renderer.lua`

Owns inline diff presentation:

- diff block resolution
- approximate preview fallback
- review banner rendering
- inline extmarks and highlights
- focus-target calculation for hunks

### `lua/agentic/ui/diff_preview/keymap_bridge.lua`

Owns interaction wiring:

- save/restore review keymaps
- accept/reject/accept-all/reject-all mappings
- hunk-navigation setup handoff when needed

### `lua/agentic/ui/diff_preview.lua`

Remains the façade and public require path.

## Scope Rules

- Tab-local diff state stays tab-local. Continue using `vim.t[tabpage]` or a
  tab-scoped helper for active diff buffer and split state.
- Per-buffer review keymap state remains buffer-scoped.
- Do not move widget/editor-window resolution into this module; callers still
  supply `get_winid`.

## Public Interface Rules

- Preserve:
  - `show_diff()`
  - `clear_diff()`
  - `get_active_diff_buffer()`
  - navigation keymap setup helpers
- Keep `ReviewController` behavior unchanged.

## Test Plan

- Keep existing diff preview and review controller coverage.
- Add focused tests for:
  - tab-local diff buffer tracking
  - split-preview fallback to inline preview
  - review keymap save/restore
  - rejection cleanup for unsaved new-file buffers
  - focus behavior when target hunks are offscreen
  - approximate-preview behavior when exact location drift occurs

## Acceptance Criteria

- Review session logic no longer mixes directly with raw render helpers.
- Keymap save/restore code is isolated from diff rendering.
- Tab-local diff state is explicit and documented.
- Existing review flow remains compatible with `PermissionManager` and
  `ReviewController`.

## Out of Scope

- Review controller refactor
- Split-view redesign
- Session-manager decomposition beyond wiring updates needed for compilation
