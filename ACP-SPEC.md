# ACP Type-System Gap Report

Date: 2026-03-26

Scope:
- Local implementation reviewed in `lua/agentic/acp/acp_client.lua`
- Local types reviewed in `lua/agentic/acp/acp_client_types.lua`
- Local content model reviewed in `lua/agentic/acp/acp_payloads.lua`
- Upstream source of truth reviewed from the official ACP schema and Rust SDK:
  - `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/schema.json`
  - `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/src/lib.rs`
  - `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/src/tool_call.rs`

## Summary

This repository does not consume an official Lua ACP type system. The current LuaCATS layer is handwritten and only partially aligned with the current ACP schema.

The biggest gaps are not cosmetic:
- the local type model is incomplete relative to the current ACP schema
- several local annotations do not match the runtime payload shapes
- several upstream ACP request/response paths are not implemented at all
- the client currently treats some agent requests as ignorable notifications

## High-Severity Gaps

### 1. Agent-to-client ACP requests are not implemented beyond permission requests

Upstream ACP includes client-side requests for:
- `fs/read_text_file`
- `fs/write_text_file`
- `terminal/create`
- `terminal/output`
- `terminal/release`
- `terminal/wait_for_exit`
- `terminal/kill`
- extension requests

Local behavior in `lua/agentic/acp/acp_client.lua`:
- `_handle_message()` routes any inbound message with `method` and without `result`/`error` into `_handle_notification()`
- `_handle_notification()` only handles:
  - `session/update`
  - `session/request_permission`
  - `fs/read_text_file` / `fs/write_text_file` by logging and ignoring them
- terminal methods are not handled at all

Impact:
- the local client is not a conforming ACP client for agents that rely on filesystem or terminal requests
- `clientCapabilities.fs` and `clientCapabilities.terminal` cannot safely be advertised unless the corresponding request handlers exist

Invariant:
- if a capability is advertised in `initialize.clientCapabilities`, the corresponding ACP request path must be implemented and must reply with a JSON-RPC result or error

### 2. Session mode support is partial and behind the current schema

Upstream ACP now models:
- `SessionMode`
- `SessionModeState`
- `session/set_mode`
- initial `modes` on `session/new` and `session/load`

Local state:
- `CurrentModeUpdate` exists in `acp_client_types.lua`
- `session/set_mode` is not implemented in `acp_client.lua`
- `SessionMode` and `SessionModeState` are not modeled
- `SessionCreationResponse` does not include `modes`
- `load_session()` ignores `LoadSessionResponse`

Impact:
- the type layer cannot faithfully represent the upstream mode system
- the transport layer cannot drive the full session-mode protocol

Invariant:
- if mode changes are surfaced in UI, the local type system must model the same mode state carried by `session/new`, `session/load`, `current_mode_update`, and `session/set_mode`

### 3. Session configuration options are under-modeled

Upstream ACP uses a discriminated `SessionConfigOption` model:
- `type` discriminator, currently `select`
- select options may be:
  - ungrouped option arrays
  - grouped option arrays with `group` and `name`

Local model:
- `ConfigOption` has no `type`
- `ConfigOption.options` assumes a flat array only
- grouped option sets are not representable

Impact:
- current Lua types cannot represent valid ACP config option payloads
- providers that use grouped config values are not model-safe in this repo

Invariant:
- local config option types must be able to represent every valid `SessionConfigOption` shape from the schema, including grouped selectors

### 4. `RequestPermissionOutcome` local type does not match the actual ACP response shape

Upstream ACP:
- `session/request_permission` response is:
  - `{ outcome = { outcome = "selected", optionId = "..." } }`
  - or `{ outcome = { outcome = "cancelled" } }`

Local annotations:
- `RequestPermissionOutcome` is flattened as:
  - `outcome`
  - `optionId?`

Local runtime:
- `__handle_request_permission()` actually sends the nested upstream shape

Impact:
- the code is closer to correct than the annotation
- LuaLS assistance is misleading around permission response payloads

Invariant:
- annotations must match the serialized wire shape, not an internal convenience shape

### 5. Inbound ACP request/notification modeling is too weak for JSON-RPC correctness

Upstream ACP distinguishes:
- requests: have `id`, need a response
- notifications: no `id`, no response

Local `ResponseRaw` and handler flow:
- uses a single broad message type
- routes all inbound `method` messages through `_handle_notification()`
- comments explicitly describe messages with `method` and `id` as notifications

Impact:
- protocol semantics are blurred
- request-only methods are easier to accidentally ignore

Invariant:
- inbound messages with `method` and `id` must be modeled and handled as requests, not notifications

## Type-Level Gaps

### 6. `AgentCapabilities` is missing current schema fields

Upstream `AgentCapabilities` includes:
- `loadSession`
- `promptCapabilities`
- `mcpCapabilities`
- `sessionCapabilities`
- optional `_meta`

Local `AgentCapabilities` includes only:
- `loadSession`
- `promptCapabilities`

Impact:
- missing `mcpCapabilities`
- missing `sessionCapabilities`, including `session/list` capability signaling

Invariant:
- negotiated capabilities must preserve the full upstream shape; missing capability fields should be representable even if unused

### 7. `SessionCreationResponse` is incomplete

Upstream `NewSessionResponse` includes:
- `sessionId`
- `configOptions?`
- `modes?`
- optional `_meta`

Local `SessionCreationResponse` includes only:
- `sessionId`
- `configOptions?`

Invariant:
- session creation and session load responses should share a typed representation for the common optional state they return

### 8. `LoadSessionResponse` and `ListSessionsResponse` are not modeled

Upstream includes:
- `session/load` response
- `session/list` request/response
- `SessionInfo`

Local ACP type surface has no corresponding typed models.

Impact:
- session restoration support is typed only around the subset already manually handled
- `session/list` cannot be added cleanly without introducing new type surfaces first

Invariant:
- every ACP method the client uses, or plans to use, should have explicit request and response annotations

### 9. Local `ToolKind` is intentionally wider than ACP

Upstream `ToolKind` includes only:
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

Local `ToolKind` also includes:
- `WebSearch`
- `SlashCommand`
- `SubAgent`
- `create`
- `write`
- `Skill`

Assessment:
- `create` and `write` appear to be ACP tool kinds the client must model explicitly
- `WebSearch`, `SlashCommand`, `SubAgent`, and `Skill` are not in the current ACP schema

Impact:
- local UI can be tolerant of provider drift
- local type names no longer mean “ACP schema exact”

Invariant:
- local UI projection types should remain separate from canonical ACP enums

### 10. `rawInput` / `rawOutput` are modeled too narrowly

Upstream schema:
- `rawInput` and `rawOutput` are arbitrary JSON values

Local model:
- `rawInput` is opaque ACP metadata, not a rendering fallback surface
- `rawOutput` is just `table`

Impact:
- local types are convenient for known providers but not schema-accurate
- non-table JSON values are not representable

Invariant:
- canonical wire types should use opaque JSON values; provider-specific convenience projections should be separate derived types

### 11. `_meta` support is inconsistent

Upstream ACP adds `_meta` widely across the schema.

Local model:
- some types expose `_meta`
- many related types do not
- content block types in `acp_payloads.lua` do not consistently include it

Impact:
- extensibility is only partially modeled

Invariant:
- `_meta` must be allowed anywhere upstream allows it, and must never drive correctness logic

## Content-Model Gaps

### 12. The local type name `Content` does not match the upstream `Content` wrapper

Upstream:
- `Content` is a wrapper object:
  - `{ content = ContentBlock, _meta? }`
- `ContentBlock` is the union of:
  - `text`
  - `image`
  - `audio`
  - `resource_link`
  - `resource`

Local `acp_payloads.lua`:
- `agentic.acp.Content` is defined as the union of block variants
- `ToolCallRegularContent.content` in `acp_client_types.lua` points to that alias
- runtime in `__build_tool_call_message()` expects upstream wrapper semantics via `content.content.text`

Impact:
- the local annotation and local runtime disagree
- this is a real type bug, not just a missing feature

Invariant:
- preserve the upstream distinction between `Content` and `ContentBlock`; do not reuse one name for both

### 13. Embedded resource types do not match upstream shape

Upstream embedded resource:
- `{ type = "resource", resource = TextResourceContents | BlobResourceContents, annotations?, _meta? }`

Local model:
- `ResourceContent.resource` points to `EmbeddedResource`
- `EmbeddedResource` is modeled as:
  - `uri`
  - `text`
  - `blob?`
  - `mimeType?`

Impact:
- the local annotation collapses two upstream layers into one
- text vs blob resource variants are not properly represented

Invariant:
- embedded resources must preserve the upstream nested shape and the text/blob union

## Method Coverage Gaps

### 14. Outbound method coverage is incomplete relative to current ACP

Implemented locally:
- `initialize`
- `authenticate`
- `session/new`
- `session/load`
- `session/prompt`
- `session/set_config_option`
- `session/cancel`

Missing relative to current upstream agent-facing method set:
- `session/list`
- `session/set_mode`
- extension methods

Invariant:
- method coverage should be explicitly tracked against the upstream schema, not inferred from current provider usage

## Runtime/Type Drift Inside This Repo

### 15. The local runtime is more accurate than some local annotations

Examples:
- permission response runtime shape is correct, annotation is not
- tool-call content runtime expects upstream wrapper `Content`, annotation does not

Invariant:
- if runtime and annotation diverge, treat the wire format as authoritative and fix the LuaCATS layer first

## Recommended Canonical Model Split

To keep this repo maintainable, the ACP model should be split into three layers:

1. Canonical wire types
- schema-faithful LuaCATS mirroring ACP exactly
- no provider-specific parse shortcuts
- no UI-specific fields

2. ACP interaction layer
- session state shaped from formal ACP requests, notifications, and responses
- synthesized interaction turns and response nodes
- no provider-specific parse adapters

3. UI projection layer
- `MessageWriter.ToolCallBlock`
- diff/body aggregation
- convenience fields such as `file_path`, `body`, `argument`

Invariant:
- UI projections must not pollute canonical ACP wire types

## Minimal Fix Order

1. Correct the `Content` vs `ContentBlock` modeling bug.
2. Correct `RequestPermissionOutcome` to match the actual response payload.
3. Add canonical types for:
   - `SessionMode`
   - `SessionModeState`
   - `LoadSessionResponse`
   - `ListSessionsRequest`
   - `ListSessionsResponse`
   - `SessionInfo`
   - `SetSessionModeRequest`
   - `SetSessionModeResponse`
4. Expand `AgentCapabilities` to include `mcpCapabilities` and `sessionCapabilities`.
5. Remodel `SessionConfigOption` as a discriminated type with grouped and ungrouped select options.
6. Separate canonical `ToolKind` from provider-extended kinds.
7. Add proper inbound request handling for filesystem and terminal methods before advertising those capabilities.

## Bottom Line

The ACP Lua layer should be treated as a formal ACP-first type system plus a
separate UI projection layer. The implementation should not rely on
provider-specific parse adapters or stale side paths.

The core invariant to enforce from here forward is:

`canonical ACP wire types must stay schema-accurate, and every provider-specific extension or UI convenience must be modeled as a separate layer.`
