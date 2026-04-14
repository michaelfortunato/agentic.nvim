# Helper Surface Cleanup

## Summary

Delete dead or low-value helper modules after the structural refactors are done.

Depends on:

- `plans/01-session-identity-vs-widget-ownership.PLAN.md`
- `plans/02-session-manager-decomposition.PLAN.md`
- `plans/03-message-writer-renderer-split.PLAN.md`
- `plans/04-inline-chat-runtime-renderer-split.PLAN.md`
- `plans/05-diff-preview-review-split.PLAN.md`
- `plans/06-chat-widget-window-lifecycle-split.PLAN.md`

This plan should land last.

## Goal

Remove dead or trivial abstraction surface that obscures ownership without
paying for itself.

## Required Changes

### Delete `lua/agentic/utils/extmark_block.lua`

- Remove the file entirely.
- Do not leave a compatibility shim.
- Verify there are still no production or test callers before deleting.

### Inline `lua/agentic/utils/list.lua`

- Replace the single `List.move_to_head()` use in
  `lua/agentic/acp/agent_config_options.lua` with local logic inside that
  module.
- Delete `lua/agentic/utils/list.lua`.

## Implementation Rules

- Make this cleanup only after the larger refactors land, so no in-flight branch
  depends on the removed helpers.
- If new call sites appear while the parallel work is happening, update this
  plan before deleting the helper.
- Do not touch `lua/agentic/utils/object.lua` in this plan.

## Test Plan

- Re-run the relevant option-selector tests to ensure the current option is
  still moved to the front.
- Re-run any test coverage that touches message rendering or diff rendering only
  if those branches briefly adopted `extmark_block.lua` during refactors.
- Run `make validate` after the final Lua cleanup lands.

## Acceptance Criteria

- `extmark_block.lua` is deleted with no remaining references.
- `list.lua` is deleted with no remaining references.
- Behavior of config option ordering is unchanged.
- No unrelated utility cleanup is bundled into this change.

## Out of Scope

- Refactoring `object.lua`
- Any additional utility consolidation not directly required by the confirmed
  findings
