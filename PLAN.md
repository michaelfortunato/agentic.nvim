# Agentic.nvim Rewrite Plan

## Why This Exists

`agentic.nvim` already does a lot, but too much of it still feels like protocol plumbing
showing through the UI. The codebase has accumulated features faster than it has
accumulated product judgment.

This plan is not a list of small fixes. It is a rewrite brief for turning the plugin into
something that feels deliberate, stable, calm, and fast.

The target is not literal parity with Cursor or Zed. Neovim will always impose real limits:

- split/window primitives are harsher than a native custom layout engine
- extmarks and virtual text are powerful but not the same as a real scene graph
- animation and motion polish will always be weaker
- picker/index performance has a lower ceiling unless a helper binary is introduced
- provider behavior varies and ACP is still young enough that clients need defensive design

But the practical ceiling is still high.

The real goal is:

- 1 coherent workflow instead of many overlapping ones
- stable focus behavior
- clear review flow
- strong keyboard ergonomics
- no obvious redraw churn or UI panic
- compact transcript summaries instead of raw protocol output
- provider-aware behavior instead of one-size-fits-none logic

If this plan is executed well, the plugin should stop feeling "AI assembled" and start
feeling "productized Neovim software."

## Product Position

### The Product To Build

Agentic should be a sidebar-driven agent client for Neovim with this dominant workflow:

1. User prompts in a compact sidebar input.
2. Transcript gives compact narrative status, not full review detail.
3. Real code/file review happens in the target buffer or a dedicated review pane.
4. Permission requests stay anchored and calm.
5. Follow mode is explicit and predictable.
6. Selectors and pickers all speak the same interaction language.

That is the product shape.

Anything that fights this shape should be cut or simplified.

### The Product To Avoid

Do not build:

- a transcript that tries to be both chat log and full diff viewer
- a maze of generic panes that all compete for screen space
- a UI where every ACP event directly mutates windows and buffers in ad hoc ways
- a client that assumes all ACP providers behave like one provider
- a feature surface that keeps expanding while the core workflows stay mediocre

## Product Principles

1. One detailed review surface, not two.
2. Chat is a status surface, not a second code view.
3. No focus stealing without a very strong reason.
4. No expensive work on interactive input paths.
5. Stable UI state beats teardown-and-rebuild hacks.
6. Provider capability differences must be modeled explicitly.
7. Multi-tab safety is non-negotiable.
8. Keyboard-first interaction quality is a core feature.
9. Dense and calm beats roomy and vague.
10. Favor fewer excellent workflows over many mediocre ones.

## Hard Limits And Honest Ceiling

### What This Can Get Close To

- workflow clarity
- keyboard efficiency
- review legibility
- responsiveness in typical repos
- transcript discipline
- permission UX
- selector/picker cohesion

### What Will Still Lag Native Editors

- motion polish
- visual smoothness
- giant-repo indexing without native help
- custom layout richness
- broad rendering flexibility

### Practical Ambition

Aim for:

- Cursor-like workflow quality in the core loop
- stronger explicitness and keyboard ergonomics than Cursor
- weaker motion/visual finish than Cursor
- much stronger calmness and determinism than the current plugin

That is realistic and worth doing.

## Current Repository Diagnosis

The main issue is not any one ugly widget. It is that responsibilities are spread across
too many modules without a clear product model.

The biggest structural problems are:

### 1. Session logic is too imperative

`session_manager.lua` still mixes:

- ACP event handling
- permission orchestration
- diff preview decisions
- file mutation cleanup
- UI timing
- session lifecycle

It should not own all of that directly.

### 2. Rendering is too close to raw events

`message_writer.lua`, `permission_manager.lua`, `diff_preview.lua`, and `chat_widget.lua`
still behave too much like event handlers with side effects instead of renderers for stable
state.

### 3. Transcript still carries too much machinery

Even after recent cleanup, the chat transcript is still too close to protocol data:

- tool call details remain too prominent
- permission flow is still transcript-adjacent rather than a first-class surface
- review information is still too tied to tool call rendering

### 4. Provider behavior is under-modeled

The code knows ACP messages, but it does not yet act like a client with provider-specific
capabilities, quirks, and preferred UX paths.

### 5. Layout is still opportunistic in places

The plugin has better sizing now, but review panes and support panes still feel too
procedural in how they are opened and reused.

## Desired End State

The plugin should be organized around 4 product surfaces:

1. `Transcript Surface`
   - compact chat/status narrative
   - tool summaries
   - approval summaries
   - no full review duplication when buffer review exists

2. `Review Surface`
   - file buffer or dedicated review window
   - diff preview
   - hunk navigation
   - review banner/chrome

3. `Prompt Surface`
   - input editor
   - picker triggers
   - slash commands
   - attachment flows

4. `Transient Footer / Action Surface`
   - permission requests
   - status affordances
   - unread indicators
   - lightweight action prompts

Each surface should have one controller and one rendering strategy.

## Target Architecture

## Layer 1: ACP Transport And Provider Layer

Responsibilities:

- ACP transport and lifecycle
- raw protocol message handling
- provider capability discovery
- provider quirks and compatibility flags

Existing files:

- `lua/agentic/acp/acp_client.lua`
- `lua/agentic/acp/acp_transport.lua`
- `lua/agentic/acp/acp_client_types.lua`
- `lua/agentic/acp/agent_instance.lua`

Required additions:

- `lua/agentic/acp/provider_capabilities.lua`
- `lua/agentic/acp/provider_profiles.lua`

What this layer should expose:

- normalized provider capability object
- normalized provider identity/profile
- normalized ACP event stream

This is where "codex-acp behaves like X" should live, not inside transcript or widget code.

## Layer 2: Session State Layer

This is the highest-leverage missing layer.

Introduce a real session state store that owns:

- transcript entries
- active review state
- active permission state
- follow/unread state
- tool lifecycle state
- session metadata
- provider/config state for the tab/session

Suggested new modules:

- `lua/agentic/session/session_state.lua`
- `lua/agentic/session/session_reducer.lua`
- `lua/agentic/session/session_events.lua`
- `lua/agentic/session/session_selectors.lua`

The goal:

- ACP update arrives
- normalize into event
- reduce event into state
- renderers consume state selectors

This is the step that most reduces slop.

## Layer 3: Surface Ownership

Avoid creating controllers that only forward calls.

- Keep `review_controller.lua` because it owns real review-window policy.
- Keep layout ownership in the widget/layout modules.
- Let `session_manager.lua` handle straightforward transcript and footer flow directly.

Only extract a controller when it owns actual policy or state transitions, not just method forwarding.

## Layer 4: Rendering Primitives

Keep renderers narrow:

- extmark-backed block renderer
- review banner renderer
- footer renderer
- window/header renderer
- chooser/picker renderer

Renderers should not decide product behavior.

## Module Boundary Changes

### `session_manager.lua`

Current role is too large.

Target role:

- coordinator/bootstrapper only
- wires ACP client, state store, controllers, widget, and persistence

Move out:

- diff preview policy
- permission sequencing logic
- tool status/render policy
- session update branching that belongs in reducer/provider normalization

### `message_writer.lua`

Current role:

- transcript model and transcript rendering are mixed together

Target role:

- transcript renderer only
- consumes already-normalized transcript entries

Move out:

- diff summarization decisions
- permission layout policy
- tool lifecycle policy

### `permission_manager.lua`

Current role:

- queue + rendering + keymap ownership

Target role:

- action/approval controller with footer ownership
- permission queue lives in session state

### `diff_preview.lua`

Current role:

- review renderer plus some view policy

Target role:

- review surface renderer only
- no fragile focus choreography
- no transcript duplication decisions

### `chat_widget.lua`

Current role:

- window management + focus logic + some viewport behavior + keymaps

Target role:

- widget shell and layout attachment
- delegates viewport ownership and review-window opening policy

## Core Workflow Upgrades

## Workflow 1: Prompting

Current bar:

- functional
- still somewhat split-driven
- still coupled to picker/select logic

Target:

- input always feels safe to type in
- triggering pickers never pauses the editor
- input focus is sacred
- prompt buffer behaves like a tiny editor, not a command field

Work:

- finish removing synchronous trigger work
- make picker triggers feel deliberate, cancellable, and cached
- keep insert mode stable
- unify slash command and file insertion behavior

## Workflow 2: Reviewing A Proposed Edit

This is the most important workflow in the whole plugin.

Target:

- one detailed review surface only
- chat shows compact review summary
- file buffer or review pane shows actual diff
- no duplicated visual noise
- no focus steal
- no viewport surprise

Rules:

- if review is visible in a file buffer, transcript must stay summary-only
- if review is not available, transcript can degrade to a compact sample
- split review and interwoven review must be intentional modes, not fallback chaos

## Workflow 3: Permission / Approval

Target:

- request appears in a stable footer/action area
- approval does not shove transcript content around
- review summary and approval prompt are visually tied together
- number bindings and submit actions are obvious

Current direction is better than before, but still not product-finished.

## Workflow 4: Long Streaming Output

Target:

- follow mode is explicit
- scrolling up never feels punished
- unread state is visible but quiet
- transcript does not constantly recenter or fight the user

Recent work improved this, but it still needs to become part of the architectural model
instead of being scattered across widget and writer code.

## Workflow 5: Switching Modes / Models / Providers / Sessions

Target:

- all selectors use the same chooser language
- richer rows with context and current selection
- no stock `vim.ui.select` feeling

This is where the plugin starts feeling productized rather than merely integrated.

## Provider-Aware Strategy

This repo should stop pretending ACP providers are interchangeable in practice.

Introduce provider profiles for:

- transport behavior
- permission behavior
- tool call completeness
- title/session metadata support
- mode/model/config support
- review quality expectations

The client should branch by capabilities such as:

- supports config options
- supports session info updates
- emits reliable tool call diffs
- emits partial tool updates
- emits strong permission payloads

Then set behavior accordingly:

- review defaults
- transcript verbosity
- fallback strategies
- selector affordances

This matters a lot if `codex-acp` is the main target.

## Picker And Selector Strategy

The current picker work improved things, but the repo still needs a stronger target:

- one picker framework
- one chooser framework
- async, cancellable, root-aware, cached
- same row rendering style across all selector surfaces

Suggested modules:

- `lua/agentic/core/project_root.lua`
- `lua/agentic/index/file_index.lua`
- `lua/agentic/ui/picker.lua`
- `lua/agentic/ui/picker_sources/*.lua`
- `lua/agentic/ui/chooser.lua`

Important rule:

The premium interaction path should not be stock completion or stock `vim.ui.select`.

## Layout And Spatial Design Strategy

Current layout is better than before, but the full product bar is:

- chat visibly subordinate to code review when review is active
- support panes narrow enough to not waste width
- bottom layout preserves vertical breathing room
- headers and footer feel like one system
- review chrome is deliberate, not accidental

Layout controller responsibilities:

- open/reuse/retire review windows
- preserve user-owned windows when possible
- decide when a new review pane is warranted
- enforce width/height policies

This should become explicit policy, not repeated window calls.

## Transcript Strategy

The transcript must become more selective.

Desired transcript content:

- compact summaries
- tool status
- file/path references
- approval intent
- final result narrative

Undesired transcript content:

- full duplicated diff detail when review surface exists
- raw protocol-like tool payload display
- repeated low-value status churn

Longer term:

- add expandable detail rows for tool calls rather than dumping them inline
- add consistent compact cards for edit/write/create/delete/move

## Testing Strategy

The suite is already good on correctness. It now needs to protect product qualities.

Add or strengthen tests for:

- no focus steal when opening review window
- no duplicated review detail in transcript when review surface exists
- follow mode behavior
- permission stability under streaming transcript changes
- chooser/picker interaction consistency
- window reuse policy
- provider capability handling

Add benchmark coverage for:

- picker cold open
- picker warm open
- review open latency
- permission-to-review visible latency
- transcript render latency on long sessions

Add diagnostic hooks for local profiling:

- timestamps around ACP event receipt
- timestamps around review render start/finish
- timestamps around window open/reuse

## Execution Order

## Phase 0: Freeze Feature Creep

Before more features:

- stop adding new UI surfaces
- stop adding provider-specific hacks directly into UI modules
- route all new behavior through explicit state or profile boundaries

## Phase 1: Finish The Product Shape

Goal:

- one detailed review surface
- transcript summary only
- stable approval footer
- no focus steal
- no duplicated review

This phase is about behavior, not architecture purity.

## Phase 2: Introduce Session State Store

Goal:

- ACP events no longer directly mutate UI
- session state becomes the source of truth

This is the most important architectural cut.

Deliverables:

- reducer/selectors/events
- transcript model separated from renderer
- permission queue in state
- review state in state

## Phase 3: Provider Profiles And Capability-Driven Behavior

Goal:

- different ACP providers no longer force the same UX path

Deliverables:

- provider profile table
- capability checks
- behavior forks moved out of surface code

## Phase 4: Picker / Chooser Consolidation

Goal:

- one interaction language for all selectors and insertions

Deliverables:

- shared picker sources
- shared ranking model
- shared row rendering

## Phase 5: Layout Controller

Goal:

- review pane ownership and sizing become policy-driven

Deliverables:

- review window reuse strategy
- explicit split/interwoven ownership
- no ad hoc split creation from multiple places

## Phase 6: Transcript And Tool Card Upgrade

Goal:

- transcript looks like product UI, not ACP trace output

Deliverables:

- normalized tool cards
- consistent compact summary rows
- expandable details only where useful

## Phase 7: Perf And Regression Guardrails

Goal:

- stop backsliding

Deliverables:

- product-quality regression tests
- benchmarks
- opt-in instrumentation

## Concrete Refactors To Start With

If another agent picks this up immediately, the highest-leverage starting tasks are:

1. Create `session_events.lua`, `session_state.lua`, and `session_selectors.lua`.
2. Move ACP event normalization out of `session_manager.lua`.
3. Convert transcript rendering to consume normalized transcript entries.
4. Move permission queue and current request state into session state.
5. Introduce provider profiles keyed by provider name.
6. Build a review controller that owns diff preview opening and review-window policy.

If only one major refactor is allowed, do item 1-4 first.

## What To Delete Or Simplify Aggressively

- transcript-level duplicated diff detail when review exists
- focus restore/startinsert choreography in review flow
- UI decisions hidden inside low-level render helpers
- provider quirks encoded as scattered conditionals
- any selector path still relying on stock `vim.ui.select` for premium UX

Cutting code is a feature here.

## Non-Goals

Do not spend the next cycle on:

- cosmetic animation experiments
- theme bikeshedding
- adding more panes
- adding more trigger characters
- advanced prompt formatting features

None of those fix the core product shape.

## Definition Of Done

This rewrite is successful when these flows feel intentionally designed:

1. Open the chat and start typing immediately.
2. Trigger file insertion in a large repo without UI panic.
3. Review a proposed edit without duplicated diff noise.
4. Approve or reject a tool call without viewport churn.
5. Scroll during long output and never feel the UI fighting back.
6. Switch provider/model/mode/session and feel one coherent selector system.
7. Use bottom layout for real work without feeling spatially squeezed.

If those workflows still feel like "smart glue around generic Neovim primitives,"
the rewrite is not done.

## Short Version

To make this plugin feel much more polished, do not chase polish widget by widget.

Do this instead:

- choose one dominant workflow
- introduce real session state
- separate controllers from renderers
- model provider differences explicitly
- make transcript summary-only when review exists
- give layout and review panes clear ownership
- protect the result with UX tests, not just correctness tests

That is the path from "messy but impressive" to "cohesive and trustworthy."
