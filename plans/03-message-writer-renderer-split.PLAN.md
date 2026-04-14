# MessageWriter Renderer Split

## Summary

Break `lua/agentic/ui/message_writer.lua` into a façade plus dedicated rendering
and decoration modules. The goal is to separate interaction-session shaping from
Vim buffer application.

Depends on: `plans/00-ui-sync-scopes.PLAN.md`

Can run in parallel with:

- `04-inline-chat-runtime-renderer-split`
- `05-diff-preview-review-split`
- `06-chat-widget-window-lifecycle-split`

## Goal

Make render-path changes local. A transcript-format change should not require
editing extmark application code, and a fold/highlight fix should not require
editing transcript shaping logic.

## Target Structure

### `lua/agentic/ui/message_writer/transcript_renderer.lua`

Owns conversion from interaction session nodes into ordered render blocks:

- welcome/meta block shaping
- request and response transcript shaping
- request content block shaping
- hierarchy and indentation rules
- chunk-boundary metadata generation

### `lua/agentic/ui/message_writer/card_renderer.lua`

Owns tool-card and diff-card shaping:

- tool call block creation from interaction nodes
- diff grouping and aggregation
- collapse defaults
- tool output summaries
- request content collapsible card logic

### `lua/agentic/ui/message_writer/decorations.lua`

Owns buffer-application details:

- line writes
- extmarks and fold ranges
- thought highlights
- diff highlights
- transcript meta highlights
- chunk-boundary marks
- tool/request block toggling support data

### `lua/agentic/ui/message_writer.lua`

Remains the public façade:

- constructor
- `render_interaction_session()`
- content-changed listener API
- toggle methods
- destroy/reset lifecycle

## Public Interface Rules

- Preserve `agentic.ui.MessageWriter` as the require path.
- Preserve existing exported type names referenced elsewhere, or re-export them
  from the façade.
- Preserve `render_interaction_session()` behavior and toggling semantics.

## Implementation Details

- Keep extmarks and fold state buffer-scoped.
- Keep diff grouping turn-local inside a single render pass.
- Keep the façade responsible for cached last-render input only.
- Do not move provider/session semantics into these modules; the input remains
  `InteractionSession`.

## Test Plan

- Keep `lua/agentic/ui/message_writer.test.lua` behavior-complete.
- Add focused tests for:
  - diff grouping for multiple tool calls targeting the same file in one turn
  - collapse persistence across rerenders
  - transcript meta highlight classification
  - request content card rendering and toggling
  - decoration application for extmarks, folds, and chunk boundaries

## Acceptance Criteria

- Transcript/card shaping code no longer performs raw Vim buffer writes.
- Decoration code no longer owns transcript business rules.
- A render bug can be localized to shaping or decoration without editing both.
- Existing chat rendering output stays functionally identical.

## Out of Scope

- New visual design
- Session-state model changes
- Diff preview or inline chat rendering
