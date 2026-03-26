# ACP Rendering Matrix

This document is the rendering contract for `agentic.nvim` on top of ACP.

It answers three questions:

1. What stable ACP update and content types can arrive?
2. Which UI surface should render each type?
3. Where is provider-specific behavior acceptable?

The intent is to keep the client spec-truthful by default, while still allowing
custom behavior when a specific provider really does behave differently.

## Sources

- [ACP schema](https://agentclientprotocol.com/protocol/schema)
- [ACP prompt turn](https://agentclientprotocol.com/protocol/prompt-turn)
- [ACP tool calls](https://agentclientprotocol.com/protocol/tool-calls)
- [ACP session config options](https://agentclientprotocol.com/protocol/session-config-options)

Local seams this maps onto:

- [acp_client_types.lua](/Users/michaelfortunato/projects/neovim-plugins/agentic.nvim/lua/agentic/acp/acp_client_types.lua)
- [session_manager.lua](/Users/michaelfortunato/projects/neovim-plugins/agentic.nvim/lua/agentic/session_manager.lua)
- [message_writer.lua](/Users/michaelfortunato/projects/neovim-plugins/agentic.nvim/lua/agentic/ui/message_writer.lua)
- [review_controller.lua](/Users/michaelfortunato/projects/neovim-plugins/agentic.nvim/lua/agentic/ui/review_controller.lua)

## First Principles

Render by payload shape first, not by raw protocol noun and not by arbitrary
color.

- The main answer should look like normal text.
- Tool work should look like structured action cards.
- Review should look like file cards and hunk cards.
- Approval should look like a decision surface tied to a tool call.
- Session state should look like pinned context, not chat content.

Do not make everything grey.

- Grey is for one narrow class of secondary information:
  - streamed thought text
  - quiet transcript meta
  - non-primary helper copy
- Tool results, review summaries, and actionable state should use normal text
  with small accents, not a universal washed-out style.

One protocol entity should map to one mutable UI entity.

- One `toolCallId` => one card that is updated in place.
- One active review target => one detailed review surface.
- One permission request => one approval surface.

Do not duplicate the same detail in multiple places.

- If a diff is visible in the file buffer, the chat should only show the file
  summary and review hint.
- The transcript is a narrative index, not a second full renderer for the same
  payload.

## Stable ACP Session Updates

Per the current ACP schema, the stable `session/update` variants are:

- `user_message_chunk`
- `agent_message_chunk`
- `agent_thought_chunk`
- `tool_call`
- `tool_call_update`
- `plan`
- `available_commands_update`
- `current_mode_update`
- `config_option_update`
- `session_info_update`

Notably, `usage_update` does not appear in the current published schema even
though this repo still models it locally in
[acp_client_types.lua](/Users/michaelfortunato/projects/neovim-plugins/agentic.nvim/lua/agentic/acp/acp_client_types.lua).
Treat that as provider-specific or legacy until the spec says otherwise.

## Render Matrix

### `user_message_chunk`

Meaning:
- User-authored prompt content in session history.

Primary surface:
- Transcript.

Rendering:
- Plain user message block.
- If the prompt represents a structured intent like `/review`, render the
  intent, not the raw slash command.

Avoid:
- Rendering raw protocol scaffolding.
- Loud heading chrome.

### `agent_message_chunk`

Meaning:
- The main assistant response stream.

Primary surface:
- Transcript.

Rendering:
- Append to a single active streamed answer block.
- Render according to content block shape:
  - text => normal prose
  - resource link => compact source row
  - image/audio/resource => attachment row or preview block

Avoid:
- Re-starting the answer block on every chunk.
- Treating ordinary answer text like system meta.

### `agent_thought_chunk`

Meaning:
- Streamed internal reasoning.

Primary surface:
- Transcript, but as a secondary stream.

Rendering:
- Interstitial thought block between cards.
- Low-contrast and compact.
- Merge consecutive thought chunks into one block.

Avoid:
- Styling thoughts the same as the final answer.
- Making every other kind of metadata also grey until the transcript loses all
  hierarchy.

### `tool_call`

Meaning:
- A new tool action has started.

Primary surface:
- Action card in the transcript.

Rendering:
- Create one card keyed by `toolCallId`.
- Show title, kind, target summary, and status.
- Use `kind` to choose icon/verb only.

Avoid:
- Dumping `read(Read /foo/bar)` or `execute(cmd)` as the principal UI.
- Appending a fresh card for the same tool every time an update arrives.

### `tool_call_update`

Meaning:
- Incremental mutation of an existing tool call.

Primary surface:
- Update the existing action card.
- If the payload is reviewable, also update the review surface.

Rendering by payload shape:

- `content.type == "diff"`
  - principal surface: file card, then nested hunk cards
  - secondary surface: in-buffer review
- `content.type == "content"` with text
  - principal surface: compact tool result preview
  - expandable details for long output
- `content.type == "terminal"`
  - principal surface: terminal-backed pane or embedded terminal surface
  - chat should show summary only

Status treatment:

- `pending`
  - quiet waiting state
  - often approval-gated or input-streaming
- `in_progress`
  - active state, but still compact
- `completed`
  - successful summary row
- `failed`
  - failure summary plus expandable details

Avoid:
- Treating every tool update as plain transcript text.
- Showing full command output inline by default.
- Duplicating diff detail in both chat and file buffer.

### `plan`

Meaning:
- The agent’s current execution plan. The agent sends the full plan each time.

Primary surface:
- Todo/plan panel.

Secondary surface:
- Optional compact transcript note like `Plan updated`.

Rendering:
- Replace the full plan each update.
- Render entries as tasks with status, not chat prose.

Avoid:
- Appending successive plan dumps to the transcript.

### `available_commands_update`

Meaning:
- Slash commands changed.

Primary surface:
- Completion and palette state only.

Rendering:
- No transcript entry by default.

Avoid:
- Logging command-list churn in chat.

### `current_mode_update`

Meaning:
- Legacy session mode changed.

Primary surface:
- Pinned session context chrome.

Rendering:
- Only for providers still using legacy modes instead of config options.

Avoid:
- Duplicating legacy mode and config options if both exist.

### `config_option_update`

Meaning:
- Full config option set changed.

Primary surface:
- Pinned session context.
- Config chooser surfaces.

Rendering:
- Preserve provider order.
- Show the current values as session state, not as chat content.
- Use grouped presentation where the provider sends groups.
- Handle missing or unknown categories gracefully.

Avoid:
- Inventing synthetic config labels when the provider already names them.
- Treating all config changes as prose notifications unless they are actually
  important to the user.

### `session_info_update`

Meaning:
- Session title or metadata changed.

Primary surface:
- Thread/session identity chrome.

Rendering:
- Update title and timestamp affordances.
- Keep it out of the main transcript body unless the user explicitly needs a
  timeline event.

Avoid:
- Loud “session renamed” transcript spam.

## Permission Requests

`session/request_permission` is not a `session/update`. It is its own client
request carrying:

- `sessionId`
- `toolCall`
- `options`

Primary surface:
- Approval UI attached to the relevant tool call and review context.

Rendering:
- Show the action being approved.
- Prefer a direct menu over “type 1 or 2”.
- Approval should not be buried in raw transcript prose.

Avoid:
- Rendering approval as just another chat message.
- Re-creating multiple approval affordances for the same pending tool.

## Stable Content Shapes

ACP content is more important than the raw event name. The client should branch
on these content shapes first.

### Content blocks

Stable prompt/message content block shapes in the schema:

- `text`
- `image`
- `audio`
- `resource_link`
- `resource`

Rules:

- `text`
  - render as ordinary prose
- `resource_link`
  - render as a compact file or URL row
- `resource`
  - render as an expandable embedded artifact
- `image`
  - render as an attachment preview, not a wall of metadata
- `audio`
  - render as an attachment row or player affordance

Baseline ACP guarantee:

- agents must support `text`
- agents must support `resource_link`
- other content shapes depend on `promptCapabilities`

### Tool call content

Stable tool-call content shapes in the schema:

- `content`
- `diff`
- `terminal`

Rules:

- `content`
  - render as structured result content
- `diff`
  - render as review content, not raw text
- `terminal`
  - render as a live terminal surface or embedded terminal summary

Current repo gap:

- the local type model in
  [acp_client_types.lua](/Users/michaelfortunato/projects/neovim-plugins/agentic.nvim/lua/agentic/acp/acp_client_types.lua)
  models `content` and `diff`, but not `terminal`

## Tool Kinds Are Modifiers, Not Layout Owners

ACP `kind` helps the client choose icons and verbs, but it should not dictate
the full rendering strategy.

Stable tool kinds in the schema:

- `read`
- `edit`
- `delete`
- `move`
- `search`
- `execute`
- `think`
- `fetch`
- `switch_mode`
- `other`

Local repo divergence:

- this repo still carries provider/local kinds like `create`, `write`,
  `WebSearch`, `SlashCommand`, `SubAgent`, `Skill`

Rendering rule:

- `kind` controls wording and iconography
- payload shape controls the main surface

Examples:

- `read` with text output
  - compact evidence card
- `execute` with text output
  - command card with status + expandable output
- `edit` with diff output
  - file card + hunk cards + review surface
- `search` with resource links
  - results list, not monospaced raw blobs

## Provider-Specific Behavior

Provider-specific behavior is acceptable when one of these is true:

1. The provider sends stable ACP data that deserves custom presentation.
2. The provider uses custom `_meta` or extension payloads.
3. The provider has real behavioral semantics not captured by baseline ACP.

Provider-specific behavior is not acceptable when it merely papers over a weak
generic renderer.

Good provider-specific examples:

- Codex-like queued-message steering if the provider really supports non-
  interruptive queued follow-ups as a semantic feature.
- Provider-specific config ordering or grouping if those options come from ACP.
- Provider-specific terminal or review affordances when the payload shape is
  richer than the generic client path.

Bad provider-specific examples:

- Hardcoding transcript chrome because one provider’s output looked messy.
- Duplicating a second rendering system for the same payload instead of fixing
  the generic surface.

## Color And Hierarchy Rules

Use a small visual vocabulary:

- normal text
  - final answer content
  - primary tool summaries
  - review summaries
- quiet text
  - thought stream
  - transcript metadata
  - helper hints
- positive accent
  - success
  - additions
- negative accent
  - failure
  - deletions
- neutral accent
  - pending or in-progress state

Do not map every system-rendered thing to the same grey comment style.

Specific rule:

- only one class of transcript blocks should look like the current nice grey
  text: thoughts and truly secondary meta

## Current Repo Drift

The repo should be aware of these mismatches:

1. `usage_update` is modeled locally but not present in the current stable ACP
   schema.
2. The local tool kind alias includes several provider/local values outside the
   stable schema.
3. The local tool-call content alias does not yet model ACP `terminal` content.
4. The local config-option category alias is too narrow for the current schema,
   which also includes `other` and permits custom categories beginning with
   `_`.
5. Transcript rendering still thinks too much in terms of raw tool call blocks
   instead of file cards and hunk cards.
6. Some session/config state still appears as transcript content instead of
   pinned context.

## Recommended Next Implementation Order

1. Normalize incoming ACP payloads to stable render intents.
2. Add `terminal` to the local tool-call content model.
3. Refactor tool rendering to be shape-first:
   - result card
   - file card
   - hunk card
   - approval surface
4. Keep thought rendering as the one major quiet-text stream.
5. Move remaining session/config noise out of the transcript.

## Practical Mapping For `agentic.nvim`

If a future refactor needs a compact rule set, use this:

- `agent_message_chunk`
  - transcript prose
- `agent_thought_chunk`
  - subdued interstitial thought block
- `tool_call` / `tool_call_update` with text
  - action card with expandable details
- `tool_call` / `tool_call_update` with diff
  - file card + hunk cards + in-buffer review
- `tool_call` / `tool_call_update` with terminal
  - terminal pane or embedded terminal surface
- `request_permission`
  - approval menu anchored to the relevant tool/review item
- `plan`
  - todo panel
- `available_commands_update`
  - completion source only
- `config_option_update` / `current_mode_update`
  - pinned session context
- `session_info_update`
  - thread identity chrome

That is the rendering contract this repo should move toward.
