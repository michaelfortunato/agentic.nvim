# UI Sync Scope Contract

## Summary

Define the synchronization and state-ownership contract that every later
refactor must follow. The goal is to stop session, widget, and editor-window
state from bleeding into each other, while preserving the plugin's multi-tab
architecture.

This file is a prerequisite for every other plan in `plans/`.

## Scope Contract

### Global UI Sync

Global UI sync is allowed only for coordination that is truly process-wide and
must remain coherent across every tabpage and widget instance.

Allowed global state:

- ACP provider instance readiness and provider-level capabilities
- Global highlight group definitions and shared namespace ids
- Permission/review turn ownership when only one interactive approval flow may
  be active at a time
- Process lifecycle cleanup that is not tab-specific

Forbidden global state:

- Active session selection for a specific editor window
- Widget header state
- Diff preview state for a specific tabpage
- Inline thread state
- Queue visibility, unread output state, or prompt content

### Tab-Local UI Sync

Tab-local sync owns view state for one widget binding inside one tabpage.
Tab-local sync must never define ACP session identity.

Tab-local responsibilities:

- Chat widget buffer and window set for that tabpage
- Header state and rendered header contexts for that tabpage
- Diff preview state and diff split state for that tabpage
- Which session is currently bound into the tab's widget
- Tab-local layout recovery and widget cleanup on `TabClosed`

Storage rules:

- Prefer tabpage-scoped instances
- Use `vim.t[tabpage]` only for lightweight tab-local state that must survive
  indirect access
- Continue treating namespaces as global ids with tab isolation provided by
  per-buffer usage

### Window-Local UI Sync

Window-local sync owns editor-window affinity and view behavior. It decides
which live session a non-widget editor window should resolve to and keeps that
resolution independent from tab-level widget ownership.

Window-local responsibilities:

- Active session affinity for editor windows
- Chat follow-output and unread-output behavior for a concrete chat window
- Anchor-window and focus-restore bookkeeping
- Review-focus targeting and window-specific cursor restoration

Storage rules:

- Prefer `vim.w[winid]` when the value belongs to one real window
- Module maps keyed by valid `winid` are allowed only when `vim.w` is not
  practical and cleanup is explicit
- Window-local state must be cleared when windows become invalid

### Buffer-Local UI Sync

Buffer-local sync remains buffer-scoped. This plan does not change that rule,
but later refactors must respect it.

Buffer-local responsibilities:

- Inline thread store on `vim.b[bufnr][InlineChat.THREAD_STORE_KEY]`
- Diff preview restoration flags such as previous `modifiable`
- Chat-context overlay line counts and extmarks

## Required Invariants

- ACP session identity is never derived from tabpage membership.
- Closing a tabpage cleans up only widget/view state bound to that tabpage.
- Resolving the "current session" checks widget buffer ownership first, then
  editor-window affinity.
- Any module that touches more than one sync scope must expose the boundary
  explicitly in its API instead of mutating foreign scope state directly.
- New module-level runtime tables must declare which sync scope they belong to.

## Required Code Adjustments

- Update comments and type annotations that currently imply tabs own sessions.
- Add a short "UI Sync Scopes" section to the relevant internal planning docs or
  module comments when a refactor introduces new runtime state.
- Review every module-level table introduced by follow-up plans and classify it
  as global, tab-local, window-local, or buffer-local.

## Test Plan

- Add or update tests proving header state is isolated per tabpage.
- Add or update tests proving diff preview state is isolated per tabpage.
- Add or update tests proving editor-window session affinity is isolated per
  window.
- Add or update tests proving inline thread state remains buffer-local.
- Add or update tests covering tab close cleanup so only tab-local widget state
  is destroyed.

## Acceptance Criteria

- No plan implemented after this one introduces new ambiguous shared runtime
  state.
- A reviewer can classify every new runtime field or storage location by sync
  scope.
- The multi-tab architecture remains intact: one widget binding per tabpage, one
  ACP session per live local session, and no tab-scoped session ownership rule.

## Assumptions

- The current single-provider-instance model remains unchanged.
- The current public user commands remain unchanged.
- ACP `session/list` and `session/load` typing debt is intentionally out of
  scope for this plan pack.
