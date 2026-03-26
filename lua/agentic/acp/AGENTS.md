# Provider system

## ACP providers (Agent Client Protocol)

This plugin spawns **external CLI tools** as subprocesses and communicates via
the Agent Client Protocol:

- **Requirements**: External CLI tools must be installed by the user, we don't
  install them for security reasons.
  - `claude-agent-acp` for Claude
  - `gemini` for Gemini
  - `codex-acp` for Codex
  - `opencode` for OpenCode
  - `cursor-agent-acp` for Cursor Agent
  - `auggie` for Augment Code
  - `vibe-acp` for Mistral Vibe

NOTE: Install instructions are in the README.md

## Generic ACPClient (no per-provider adapters)

All providers use a **single generic `ACPClient`** (`acp_client.lua`). There are
no per-provider adapter files.

The client parses standard ACP protocol fields only. Provider-specific metadata
is not treated as an alternate render source.
itself.

Exception: we still allow narrow provider-specific normalization above the
transport/parser layer when a common ACP provider exposes the same user-facing
concept under a different config shape. Example: `codex-acp` exposes approval
presets through the ACP `mode` config option, so higher-level config handling
may alias that to Agentic's approval preset concept. Keep these exceptions small
and explicit, and prefer them in config/session handling instead of in
`ACPClient` message parsing.

**Adding a new provider** only requires a config entry in `config_default.lua`
under `acp_providers` — no adapter code needed unless the provider deviates from
ACP in ways not yet handled.

## ACP provider configuration

```lua
acp_providers = {
  ["claude-agent-acp"] = {
    name = "Claude Agent ACP",
    command = "claude-agent-acp",
    env = {
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
  ["gemini-acp"] = {
    name = "Gemini ACP",
    command = "gemini",
    args = { "--acp" },
    env = {
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
}
```

## Event pipeline (top to bottom)

```
Provider subprocess (external CLI)
  | stdio: newline-delimited JSON-RPC
  v
ACPTransport      -- parses JSON, calls callbacks.on_message()
  |
  v
ACPClient         -- routes by message type (notification vs response)
  |  protected methods: __handle_tool_call,
  |  __handle_tool_call_update, __build_tool_call_message
  v
SessionManager    -- registered as subscriber per session_id
  |  dispatches ACP-shaped events into SessionState
  v
SessionState      -- canonical runtime model
  |
  v
InteractionModel  -- synthesizes turn/request/response tree from state
  |
  v
MessageWriter     -- renders AgenticChat from InteractionSession
PermissionManager -- queues permission prompts, manages keymaps
PersistedSession  -- stores persisted session turns for save/restore
```

## Session update routing

`ACPClient` receives `session/update` notifications. The `sessionUpdate` field
determines routing:

| `sessionUpdate` value   | Routed to                                               |
| ----------------------- | ------------------------------------------------------- |
| `"tool_call"`           | `__handle_tool_call` → subscriber → `SessionState`      |
| `"tool_call_update"`    | `__handle_tool_call_update` → subscriber → `SessionState` |
| `"agent_message_chunk"` | subscriber → `SessionState` transcript event log        |
| `"agent_thought_chunk"` | subscriber → `SessionState` transcript event log        |
| `"plan"`                | subscriber → `SessionState` plan state                  |
| `"request_permission"`  | `PermissionManager` (queued, sequential)                |
| others                  | `subscriber.on_session_update()`                        |

## Tool call lifecycle

Tool calls go through **3 phases**. Runtime state tracks them first, and
`MessageWriter` derives renderable tool cards from the interaction tree.

**Phase 1 — `tool_call` (initial)**

```
Provider sends "tool_call"
  -> ACPClient builds ToolCallBlock via __build_tool_call_message
     { tool_call_id, kind, argument, status, body?, diff? }
  -> subscriber.on_tool_call(block)
  -> SessionState stores tool call event
  -> InteractionModel exposes tool-call node in the active turn response
  -> MessageWriter rerenders AgenticChat from InteractionSession
```

**Phase 2 — `tool_call_update` (one or more)**

```
Provider sends "tool_call_update"
  -> ACPClient builds ToolCallBase via __build_tool_call_message
     (only changed fields needed)
  -> subscriber.on_tool_call_update(partial)
  -> SessionState merges the update into the tool lifecycle state
  -> InteractionModel exposes updated tool-call content/status
  -> MessageWriter rerenders the affected card from the tree
```

**Phase 3 — final `tool_call_update` with terminal status**

```
Same as Phase 2, but status = "completed" | "failed"
  -> Visual card state updates to final state
  -> If "failed": PermissionManager removes pending request
```

## Key design rules

- **Updates are partial:** Only send what changed. State is the merge point.
- **Interaction tree is canonical:** `MessageWriter` renders from
  `InteractionSession`, not from ad hoc event-stream writes.
- **Tool output stays hierarchical:** output/diff/terminal content remains a
  child of the tool-call node until the renderer chooses how to present it.
- **Extmarks are view state only:** `NS_TOOL_BLOCKS` tracks rendered fold ranges,
  not protocol truth.

## Provider parsing

`ACPClient` parses only formal ACP fields:

- `content` drives tool output rendering
- `locations` and `rawInput` remain available as opaque ACP metadata
- unknown `kind` values still log a warning so users report them as issues

Do not add provider-specific fallback parsing in `__build_tool_call_message`.
If a provider needs a UX-level alias for a common concept, normalize it after
parsing in session/config code instead of changing ACP field parsing.

## Permission flow (interleaved with tool calls)

```
Provider sends "session/request_permission"
  -> SessionManager: opens diff preview (if the request carries a diff)
  -> PermissionManager:add_request(request, callback)
     -> Queues request (sequential — one prompt at a time)
     -> Renders permission buttons in chat buffer
     -> Sets up buffer-local keymaps (1,2,3,4)
  -> User presses key
     -> Sends result back to provider via callback
     -> Clears diff preview
     -> Dequeues next permission if any
```

## Protected methods in ACPClient

These protected methods can be overridden by subclasses if a future provider
requires it, but currently all providers use the default implementations:

| Method                        | Behavior                                  |
| ----------------------------- | ----------------------------------------- |
| `__handle_tool_call`          | Builds ToolCallBlock, notifies subscriber |
| `__build_tool_call_message`   | Parses formal ACP tool call fields        |
| `__handle_tool_call_update`   | Builds partial, notifies subscriber       |
| `__handle_request_permission` | Sends result back to provider             |
| `__handle_session_update`     | Routes by `sessionUpdate` type            |
