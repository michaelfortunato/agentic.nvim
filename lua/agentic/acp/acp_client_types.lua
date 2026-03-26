--[[
  CRITICAL: Type annotations in this file are essential for Lua Language Server support.
  DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @class agentic.acp.ClientInfo
--- @field name string
--- @field version string

--- @alias agentic.acp.Meta table<string, any>

--- @class agentic.acp.ClientCapabilities
--- @field fs agentic.acp.FileSystemCapability
--- @field terminal boolean

--- @class agentic.acp.McpCapabilities
--- @field http boolean
--- @field sse boolean

--- @class agentic.acp.SessionListCapabilities
--- @field _meta? agentic.acp.Meta|nil

--- @class agentic.acp.SessionCapabilities
--- @field list? agentic.acp.SessionListCapabilities|boolean|nil

--- @class agentic.acp.InitializeParams
--- @field protocolVersion number
--- @field clientInfo agentic.acp.ClientInfo
--- @field clientCapabilities agentic.acp.ClientCapabilities

--- @class agentic.acp.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class agentic.acp.AgentCapabilities
--- @field loadSession boolean
--- @field mcpCapabilities agentic.acp.McpCapabilities
--- @field promptCapabilities agentic.acp.PromptCapabilities
--- @field sessionCapabilities agentic.acp.SessionCapabilities

--- @class agentic.acp.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class agentic.acp.AgentInfo
--- @field name? string
--- @field version? string
--- @field title? string

--- @class agentic.acp.AuthMethod
--- @field id string
--- @field name string
--- @field description? string

--- @class agentic.acp.InitializeResponse
--- @field protocolVersion number
--- @field agentCapabilities agentic.acp.AgentCapabilities
--- @field agentInfo? agentic.acp.AgentInfo|nil
--- @field authMethods agentic.acp.AuthMethod[]

--- @class agentic.acp.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env agentic.acp.EnvVariable[]

--- @class agentic.acp.EnvVariable
--- @field name string
--- @field value string

--- @alias agentic.acp.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- @alias agentic.acp.ToolKind
--- | "read"
--- | "edit"
--- | "delete"
--- | "move"
--- | "search"
--- | "execute"
--- | "think"
--- | "fetch"
--- | "WebSearch"
--- | "SlashCommand"
--- | "SubAgent"
--- | "other"
--- | "create"
--- | "write"
--- | "Skill"
--- | "switch_mode"

--- @alias agentic.acp.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias agentic.acp.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias agentic.acp.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @alias agentic.acp.RawInput table<string, any>

--- @class agentic.acp.ToolCallRegularContent
--- @field type "content"
--- @field content agentic.acp.Content

--- @class agentic.acp.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText? string
--- @field newText string

--- @class agentic.acp.ToolCallTerminalContent
--- @field type "terminal"
--- @field terminalId string

--- @alias agentic.acp.ACPToolCallContent
--- | agentic.acp.ToolCallRegularContent
--- | agentic.acp.ToolCallDiffContent
--- | agentic.acp.ToolCallTerminalContent

--- @class agentic.acp.ToolCallLocation
--- @field path string
--- @field line? number

--- @class agentic.acp.PlanEntry
--- @field content string
--- @field priority agentic.acp.PlanEntryPriority
--- @field status agentic.acp.PlanEntryStatus

--- @class agentic.acp.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class agentic.acp.SessionMode
--- @field id string
--- @field name string
--- @field description? string|nil

--- @class agentic.acp.SessionModeState
--- @field availableModes agentic.acp.SessionMode[]
--- @field currentModeId string

--- @class agentic.acp.SessionInfo
--- @field sessionId string
--- @field cwd string
--- @field title? string|nil
--- @field updatedAt? string|nil

--- @class agentic.acp.ConfigOption.Option
--- @field description string
--- @field name string
--- @field value string

--- @class agentic.acp.ConfigOption.OptionGroup
--- @field group string
--- @field name string
--- @field options agentic.acp.ConfigOption.Option[]

--- @alias agentic.acp.ConfigOption.Options
--- | agentic.acp.ConfigOption.Option[]
--- | agentic.acp.ConfigOption.OptionGroup[]

--- @alias agentic.acp.ConfigOption.Category
--- | "mode"
--- | "model"
--- | "thought_level"
--- | "other"

--- @class agentic.acp.ConfigOption
--- @field id string
--- @field type? "select"|string|nil
--- @field category agentic.acp.ConfigOption.Category|string
--- @field currentValue string
--- @field description string
--- @field name string
--- @field options agentic.acp.ConfigOption.Options

--- @class agentic.acp.NewSessionRequest
--- @field cwd string
--- @field mcpServers agentic.acp.McpServer[]

--- @class agentic.acp.NewSessionResponse
--- @field sessionId string
--- @field configOptions? agentic.acp.ConfigOption[]
--- @field modes? agentic.acp.SessionModeState|nil

--- @alias agentic.acp.SessionCreationResponse agentic.acp.NewSessionResponse

--- @class agentic.acp.ListSessionsRequest
--- @field cursor? string|nil
--- @field cwd? string|nil

--- @class agentic.acp.ListSessionsResponse
--- @field sessions agentic.acp.SessionInfo[]
--- @field nextCursor? string|nil

--- @class agentic.acp.LoadSessionRequest
--- @field sessionId string
--- @field cwd string
--- @field mcpServers agentic.acp.McpServer[]

--- @class agentic.acp.LoadSessionResponse
--- @field configOptions? agentic.acp.ConfigOption[]
--- @field modes? agentic.acp.SessionModeState|nil

--- @class agentic.acp.PromptRequest
--- @field sessionId string
--- @field prompt agentic.acp.Content[]

--- @class agentic.acp.PromptResponse
--- @field stopReason agentic.acp.StopReason

--- @class agentic.acp.CancelNotification
--- @field sessionId string

--- @class agentic.acp.SetSessionConfigOptionRequest
--- @field sessionId string
--- @field configId string
--- @field value string

--- @class agentic.acp.SetSessionConfigOptionResponse
--- @field configOptions agentic.acp.ConfigOption[]

--- @class agentic.acp.SetSessionModeRequest
--- @field sessionId string
--- @field modeId string

--- @class agentic.acp.SetSessionModeResponse

--- @class agentic.acp.ReadTextFileRequest
--- @field sessionId string
--- @field path string
--- @field line? integer|nil
--- @field limit? integer|nil

--- @class agentic.acp.ReadTextFileResponse
--- @field content string

--- @class agentic.acp.WriteTextFileRequest
--- @field sessionId string
--- @field path string
--- @field content string

--- @class agentic.acp.WriteTextFileResponse

--- @class agentic.acp.TerminalExitStatus
--- @field exitCode integer|nil
--- @field signal string|nil

--- @class agentic.acp.CreateTerminalRequest
--- @field sessionId string
--- @field command string
--- @field args? string[]|nil
--- @field env? agentic.acp.EnvVariable[]|nil
--- @field cwd? string|nil
--- @field outputByteLimit? integer|nil

--- @class agentic.acp.CreateTerminalResponse
--- @field terminalId string

--- @class agentic.acp.KillTerminalRequest
--- @field sessionId string
--- @field terminalId string

--- @class agentic.acp.KillTerminalResponse

--- @class agentic.acp.TerminalOutputRequest
--- @field sessionId string
--- @field terminalId string

--- @class agentic.acp.TerminalOutputResponse
--- @field output string
--- @field truncated boolean
--- @field exitStatus? agentic.acp.TerminalExitStatus|nil

--- @class agentic.acp.ReleaseTerminalRequest
--- @field sessionId string
--- @field terminalId string

--- @class agentic.acp.ReleaseTerminalResponse

--- @class agentic.acp.WaitForTerminalExitRequest
--- @field sessionId string
--- @field terminalId string

--- @class agentic.acp.WaitForTerminalExitResponse
--- @field exitCode integer|nil
--- @field signal string|nil

--- @alias agentic.acp.AgentRequestMethod
--- | "initialize"
--- | "authenticate"
--- | "session/new"
--- | "session/list"
--- | "session/load"
--- | "session/prompt"
--- | "session/set_config_option"
--- | "session/set_mode"

--- @alias agentic.acp.AgentNotificationMethod
--- | "session/cancel"

--- @alias agentic.acp.ClientRequestMethod
--- | "fs/read_text_file"
--- | "fs/write_text_file"
--- | "session/request_permission"
--- | "terminal/create"
--- | "terminal/kill"
--- | "terminal/output"
--- | "terminal/release"
--- | "terminal/wait_for_exit"

--- @alias agentic.acp.ClientNotificationMethod
--- | "session/update"

--- @alias agentic.acp.JsonRpcMethod
--- | agentic.acp.AgentRequestMethod
--- | agentic.acp.AgentNotificationMethod
--- | agentic.acp.ClientRequestMethod
--- | agentic.acp.ClientNotificationMethod

--- @class agentic.acp.JsonRpcRequest
--- @field jsonrpc "2.0"
--- @field id number
--- @field method agentic.acp.JsonRpcMethod|string
--- @field params table|nil

--- @class agentic.acp.JsonRpcNotification
--- @field jsonrpc "2.0"
--- @field method agentic.acp.JsonRpcMethod|string
--- @field params table|nil

--- @class agentic.acp.JsonRpcSuccessResponse
--- @field jsonrpc "2.0"
--- @field id number
--- @field result table|nil

--- @class agentic.acp.JsonRpcErrorResponse
--- @field jsonrpc "2.0"
--- @field id number|nil
--- @field error agentic.acp.ACPError

--- @alias agentic.acp.ResponseRawParams
--- | agentic.acp.SessionNotification
--- | agentic.acp.RequestPermissionRequest
--- | agentic.acp.ReadTextFileRequest
--- | agentic.acp.WriteTextFileRequest
--- | agentic.acp.CreateTerminalRequest
--- | agentic.acp.KillTerminalRequest
--- | agentic.acp.TerminalOutputRequest
--- | agentic.acp.ReleaseTerminalRequest
--- | agentic.acp.WaitForTerminalExitRequest

--- @class agentic.acp.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method string
--- @field result? table
--- @field params? agentic.acp.ResponseRawParams
--- @field error? agentic.acp.ACPError

--- Shared base fields for ToolCall and ToolCallUpdate.
--- In the ACP spec, ToolCallUpdate is a partial version where all fields
--- except toolCallId are optional. ToolCall (initial) additionally requires title.
--- @class agentic.acp.ToolCallBase
--- @field toolCallId string
--- @field title? string
--- @field kind? agentic.acp.ToolKind
--- @field status? agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field rawInput? agentic.acp.RawInput
--- @field rawOutput? table
--- @field _meta? table<string, any>

--- Initial tool call notification (sessionUpdate="tool_call").
--- Per ACP JSON schema, only toolCallId and title are required.
--- @class agentic.acp.ToolCallMessage : agentic.acp.ToolCallBase
--- @field sessionUpdate "tool_call"

--- Tool call progress update (sessionUpdate="tool_call_update").
--- Only toolCallId is required. All other fields are optional — only changed fields are sent.
--- @class agentic.acp.ToolCallUpdate : agentic.acp.ToolCallBase
--- @field sessionUpdate "tool_call_update"

--- @class agentic.acp.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries agentic.acp.PlanEntry[]

--- @class agentic.acp.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands agentic.acp.AvailableCommand[]

--- @class agentic.acp.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string
--- @field _meta? table<string, any>|nil

--- @class agentic.acp.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number
--- @field size number
--- @field cost? { amount: number, currency: string }

--- @class agentic.acp.ConfigOptionsUpdate
--- @field sessionUpdate "config_option_update"
--- @field configOptions agentic.acp.ConfigOption[]

--- @alias agentic.acp.ConfigOptionUpdate agentic.acp.ConfigOptionsUpdate

--- @class agentic.acp.SessionInfoUpdate
--- @field sessionUpdate "session_info_update"
--- @field title? string|nil
--- @field updatedAt? string|nil
--- @field _meta? table<string, any>|nil

--- @alias agentic.acp.SessionUpdate agentic.acp.SessionUpdateMessage

--- @alias agentic.acp.SessionUpdateMessage
--- | agentic.acp.UserMessageChunk
--- | agentic.acp.AgentMessageChunk
--- | agentic.acp.AgentThoughtChunk
--- | agentic.acp.ToolCallMessage
--- | agentic.acp.ToolCallUpdate
--- | agentic.acp.PlanUpdate
--- | agentic.acp.AvailableCommandsUpdate
--- | agentic.acp.CurrentModeUpdate
--- | agentic.acp.UsageUpdate
--- | agentic.acp.ConfigOptionsUpdate
--- | agentic.acp.SessionInfoUpdate

--- @class agentic.acp.SessionNotification
--- @field sessionId string
--- @field update agentic.acp.SessionUpdate

--- @class agentic.acp.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- @class agentic.acp.RequestPermissionRequest
--- @field sessionId string
--- @field options agentic.acp.PermissionOption[]
--- @field toolCall agentic.acp.ToolCallBase

--- Permission request (session/request_permission JSON-RPC request).
--- Per ACP spec, toolCall is a ToolCallUpdate (partial) — same shape used in tool_call_update.
--- @alias agentic.acp.RequestPermission agentic.acp.RequestPermissionRequest

--- @class agentic.acp.CancelledPermissionOutcome
--- @field outcome "cancelled"

--- @class agentic.acp.SelectedPermissionOutcome
--- @field outcome "selected"
--- @field optionId string

--- @alias agentic.acp.RequestPermissionOutcome
--- | agentic.acp.CancelledPermissionOutcome
--- | agentic.acp.SelectedPermissionOutcome

--- @class agentic.acp.RequestPermissionResponse
--- @field outcome agentic.acp.RequestPermissionOutcome

--- @alias agentic.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class agentic.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias agentic.acp.ClientHandlers.on_session_update fun(update: agentic.acp.SessionUpdateMessage): nil
--- @alias agentic.acp.ClientHandlers.on_request_permission fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
--- @alias agentic.acp.ClientHandlers.on_error fun(err: agentic.acp.ACPError): nil

--- @class agentic.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field start_col? integer Starting column number (1-indexed)
--- @field end_col? integer Ending column number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class agentic.acp.ClientHandlers
--- @field on_session_update agentic.acp.ClientHandlers.on_session_update
--- @field on_request_permission agentic.acp.ClientHandlers.on_request_permission
--- @field on_error agentic.acp.ClientHandlers.on_error
--- @field on_tool_call fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock): nil
--- @field on_tool_call_update fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock): nil

--- @class agentic.acp.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? agentic.acp.TransportType
--- @field command? string Command to spawn agent (for stdio)
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field timeout? number Request timeout in milliseconds
--- @field reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts
--- @field auth_method? string Authentication method
--- @field default_mode? string Default mode ID to set on session creation
