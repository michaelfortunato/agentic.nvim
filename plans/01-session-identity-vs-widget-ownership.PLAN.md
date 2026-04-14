# Session Identity vs Widget Ownership

## Summary

Refactor `lua/agentic/session_registry.lua` so session identity is independent
from widget/tab ownership. The registry must resolve sessions from buffer and
editor-window context, while widget inventory and tab cleanup remain tab-local
view concerns.

Depends on: `plans/00-ui-sync-scopes.PLAN.md`

## Goal

- Keep live sessions session-centric.
- Keep widgets tab-local.
- Stop tab context from behaving like the session ownership rule.

## Current Problems

- `get_widget_sessions()` is used as both a widget inventory helper and a
  session-scoping primitive.
- `destroy_widget_sessions_for_tab()` still destroys sessions through a widget
  cleanup path without making the ownership boundary explicit.
- `load_session_into_current_widget()` swaps widgets but still assumes the
  current tab is the effective session boundary.
- `_window_active_sessions` is module-global despite being window-local state.

## Implementation Decisions

### Active session resolution

- Keep lookup order:
  1. resolve by current buffer ownership
  2. resolve by current editor-window affinity
  3. otherwise return `nil`
- Editor-window affinity becomes window-local state. Prefer `vim.w[winid]` with
  a stable key such as `_agentic_active_session_instance_id`.
- `SessionRegistry.set_active_session(session, winid)` becomes a thin writer to
  that window-local state.

### Widget inventory

- Keep `get_widget_sessions(tab_page_id)` as a widget inventory helper.
- Keep `get_tab_sessions()` only as a compatibility wrapper, but document that
  it returns sessions whose current widget is in that tab, not tab-owned
  sessions.
- `destroy_widget_sessions_for_tab(tab_page_id)` remains a widget cleanup helper
  called from `TabClosed`.

### Widget swapping

- `load_session_into_current_widget(target_session)` continues to swap widget
  bindings between two sessions.
- Treat the operation as a view swap only:
  - preserve each session's ACP identity
  - preserve each session's session state
  - swap widget bindings and captured widget-local state only
- After the swap, update editor-window affinity for the editor windows returned
  by each widget.

## Required Code Changes

- Refactor `lua/agentic/session_registry.lua`
- Update callers in `lua/agentic/init.lua`
- Update restore/load flows in `lua/agentic/session_restore.lua` if comments or
  assumptions still imply tab-scoped sessions
- Update tests in:
  - `lua/agentic/session_registry.test.lua`
  - `lua/agentic/init.test.lua`

## Public Interface Rules

- Preserve existing public function names in `SessionRegistry`.
- Preserve existing user command behavior.
- Do not add ACP list/load behavior in this change.

## Test Plan

- Resolve current session from a widget buffer.
- Resolve current session from an editor window with active-session affinity.
- Ensure invalid editor windows do not leave stale active-session state behind.
- Verify `get_widget_sessions(tab)` returns only sessions currently bound to that
  tab's widget.
- Verify `destroy_widget_sessions_for_tab(tab)` only destroys sessions whose
  widgets are in that tab.
- Verify `load_session_into_current_widget()` swaps widget bindings without
  swapping ACP session ids or session state.
- Verify two tabs can host widgets for different sessions without cross-lookup
  leakage.

## Acceptance Criteria

- No registry API or comment claims sessions are tab-scoped.
- Current-session resolution is driven by buffer ownership and editor-window
  affinity only.
- Tab close still cleans up widgets correctly.
- Existing user-facing behavior remains unchanged.

## Out of Scope

- Breaking apart `SessionManager`
- ACP `session/list` and `session/load` typing support
- Message writer, inline chat, diff preview, or chat widget refactors
