--- Synthesized ACP interaction tree used by Agentic.
---
--- ACP exposes prompt turns as one request plus a stream of `session/update`
--- notifications. Agentic's canonical interaction model is derived from the
--- live session state and its ordered transcript event log.
---
--- Persisted session data stores ACP-shaped turns for disk/restore, but the
--- public interaction model is state-first.
---
--- Session-scoped updates such as `config_option_update`,
--- `current_mode_update`, and `session_info_update` are intentionally not
--- modeled as response nodes.

--- @class agentic.session.InteractionTextContentNode
--- @field type "text_content"
--- @field text string
--- @field text_structure "plain"|"xml_wrapped"
--- @field xml_root_tag? string
--- @field content agentic.acp.TextContent

--- @class agentic.session.InteractionImageContentNode
--- @field type "image_content"
--- @field mime_type string
--- @field uri string|nil
--- @field content agentic.acp.ImageContent

--- @class agentic.session.InteractionAudioContentNode
--- @field type "audio_content"
--- @field mime_type string
--- @field content agentic.acp.AudioContent

--- @class agentic.session.InteractionResourceLinkContentNode
--- @field type "resource_link_content"
--- @field uri string
--- @field name string
--- @field title string|nil
--- @field description string|nil
--- @field mime_type string|nil
--- @field size integer|nil
--- @field content agentic.acp.ResourceLinkContent

--- @class agentic.session.InteractionResourceContentNode
--- @field type "resource_content"
--- @field uri string
--- @field mime_type string|nil
--- @field text string|nil
--- @field blob string|nil
--- @field content agentic.acp.ResourceContent

--- @class agentic.session.InteractionUnknownContentNode
--- @field type "unknown_content"
--- @field content table

--- @alias agentic.session.InteractionContentNode
--- | agentic.session.InteractionTextContentNode
--- | agentic.session.InteractionImageContentNode
--- | agentic.session.InteractionAudioContentNode
--- | agentic.session.InteractionResourceLinkContentNode
--- | agentic.session.InteractionResourceContentNode
--- | agentic.session.InteractionUnknownContentNode

--- @class agentic.session.InteractionRequestTextNode
--- @field type "request_text"
--- @field text string
--- @field content_index integer
--- @field content_node agentic.session.InteractionTextContentNode

--- @class agentic.session.InteractionRequestContentBlockNode
--- @field type "request_content"
--- @field content_index integer
--- @field content_node agentic.session.InteractionContentNode

--- @alias agentic.session.InteractionRequestNode
--- | agentic.session.InteractionRequestTextNode
--- | agentic.session.InteractionRequestContentBlockNode

--- @class agentic.session.InteractionRequest
--- @field kind "user"|"review"
--- @field text string
--- @field timestamp integer|nil
--- @field content agentic.acp.Content[]
--- @field content_nodes agentic.session.InteractionContentNode[]
--- @field nodes agentic.session.InteractionRequestNode[]

--- @class agentic.session.InteractionMessageNode
--- @field type "message"
--- @field text string
--- @field provider_name string|nil
--- @field content agentic.acp.Content[]
--- @field content_nodes agentic.session.InteractionContentNode[]

--- @class agentic.session.InteractionThoughtNode
--- @field type "thought"
--- @field text string
--- @field provider_name string|nil
--- @field content agentic.acp.Content[]
--- @field content_nodes agentic.session.InteractionContentNode[]

--- @class agentic.session.InteractionPlanNode
--- @field type "plan"
--- @field entries agentic.acp.PlanEntry[]
--- @field provider_name string|nil

--- @class agentic.session.ToolCallRegularContentNode
--- @field type "content_output"
--- @field content_node agentic.session.InteractionContentNode

--- @class agentic.session.ToolCallDiffContentNode
--- @field type "diff_output"
--- @field file_path string|nil
--- @field old_lines string[]
--- @field new_lines string[]

--- @class agentic.session.ToolCallTerminalContentNode
--- @field type "terminal_output"
--- @field terminal_id string

--- @alias agentic.session.ToolCallContentNode
--- | agentic.session.ToolCallRegularContentNode
--- | agentic.session.ToolCallDiffContentNode
--- | agentic.session.ToolCallTerminalContentNode

--- @class agentic.session.InteractionToolCallNode
--- @field type "tool_call"
--- @field tool_call_id string|nil
--- @field title string
--- @field kind agentic.acp.ToolKind|nil
--- @field status agentic.acp.ToolCallStatus|nil
--- @field file_path string|nil
--- @field permission_state "requested"|"approved"|"rejected"|"dismissed"|nil
--- @field terminal_id string|nil
--- @field content_nodes agentic.session.ToolCallContentNode[]

--- @class agentic.session.InteractionReadToolCallNode : agentic.session.InteractionToolCallNode
--- @field kind "read"

--- @class agentic.session.InteractionSearchToolCallNode : agentic.session.InteractionToolCallNode
--- @field kind "search"|"fetch"|"WebSearch"

--- @class agentic.session.InteractionExecuteToolCallNode : agentic.session.InteractionToolCallNode
--- @field kind "execute"

--- @class agentic.session.InteractionFileMutationToolCallNode : agentic.session.InteractionToolCallNode
--- @field kind "edit"|"create"|"write"|"delete"|"move"

--- @alias agentic.session.InteractionResponseNode
--- | agentic.session.InteractionMessageNode
--- | agentic.session.InteractionThoughtNode
--- | agentic.session.InteractionPlanNode
--- | agentic.session.InteractionToolCallNode

--- @class agentic.session.InteractionResponse
--- @field provider_name string|nil
--- @field nodes agentic.session.InteractionResponseNode[]

--- @class agentic.session.InteractionTurnResult
--- @field stop_reason agentic.acp.StopReason|nil
--- @field timestamp integer|nil
--- @field error_text string|nil

--- @class agentic.session.InteractionTurn
--- @field index integer
--- @field request agentic.session.InteractionRequest
--- @field response agentic.session.InteractionResponse
--- @field result agentic.session.InteractionTurnResult|nil

--- @class agentic.session.InteractionSession
--- @field session_id string|nil
--- @field title string
--- @field timestamp integer
--- @field current_mode_id string|nil
--- @field config_options agentic.acp.ConfigOption[]
--- @field available_commands agentic.acp.AvailableCommand[]
--- @field turns agentic.session.InteractionTurn[]

local InteractionModel = {}

local function is_review_request(text)
    return type(text) == "string" and text:match("^/review%s*") ~= nil
end

--- @param text string
--- @return agentic.acp.TextContent
local function make_text_content(text)
    return {
        type = "text",
        text = text,
    }
end

--- @param text string|nil
--- @return string|nil
local function get_xml_wrapped_root_tag(text)
    local trimmed = vim.trim(text or "")
    if trimmed == "" then
        return nil
    end

    local lines = vim.split(trimmed, "\n", { plain = true })
    if #lines < 2 then
        return nil
    end

    local open_tag = vim.trim(lines[1]):match("^<([%a_][%w_%-]*)>$")
    local close_tag = vim.trim(lines[#lines]):match("^</([%a_][%w_%-]*)>$")

    if open_tag and close_tag and open_tag == close_tag then
        return open_tag
    end

    return nil
end

--- @param content agentic.acp.Content|agentic.acp.Content[]|table|nil
--- @return agentic.acp.Content[]
local function normalize_content_list(content)
    if type(content) ~= "table" then
        return {}
    end

    if content.type then
        return { vim.deepcopy(content) }
    end

    return vim.deepcopy(content)
end

--- @param content agentic.acp.Content|table|nil
--- @return agentic.session.InteractionContentNode|nil
local function build_content_node(content)
    if type(content) ~= "table" or content.type == nil then
        return nil
    end

    if content.type == "text" then
        local text = content.text or ""
        local xml_root_tag = get_xml_wrapped_root_tag(text)
        return {
            type = "text_content",
            text = text,
            text_structure = xml_root_tag and "xml_wrapped" or "plain",
            xml_root_tag = xml_root_tag,
            content = vim.deepcopy(content),
        }
    end

    if content.type == "image" then
        return {
            type = "image_content",
            mime_type = content.mimeType,
            uri = content.uri,
            content = vim.deepcopy(content),
        }
    end

    if content.type == "audio" then
        return {
            type = "audio_content",
            mime_type = content.mimeType,
            content = vim.deepcopy(content),
        }
    end

    if content.type == "resource_link" then
        return {
            type = "resource_link_content",
            uri = content.uri,
            name = content.name,
            title = content.title,
            description = content.description,
            mime_type = content.mimeType,
            size = content.size,
            content = vim.deepcopy(content),
        }
    end

    if content.type == "resource" and content.resource then
        return {
            type = "resource_content",
            uri = content.resource.uri,
            mime_type = content.resource.mimeType,
            text = content.resource.text,
            blob = content.resource.blob,
            content = vim.deepcopy(content),
        }
    end

    return {
        type = "unknown_content",
        content = vim.deepcopy(content),
    }
end

--- @param contents agentic.acp.Content|agentic.acp.Content[]|nil
--- @return agentic.session.InteractionContentNode[]
local function build_content_nodes(contents)
    local content_nodes = {}

    for _, content in ipairs(normalize_content_list(contents)) do
        local node = build_content_node(content)
        if node then
            content_nodes[#content_nodes + 1] = node
        end
    end

    return content_nodes
end

--- @param request_text string
--- @param content_nodes agentic.session.InteractionContentNode[]
--- @return agentic.session.InteractionRequestNode[]
local function build_request_nodes(request_text, content_nodes)
    local nodes = {}
    local rendered_primary_text = false

    for index, content_node in ipairs(content_nodes) do
        if
            not rendered_primary_text
            and request_text ~= ""
            and content_node.type == "text_content"
            and content_node.text == request_text
        then
            nodes[#nodes + 1] = {
                type = "request_text",
                text = content_node.text,
                content_index = index,
                content_node = vim.deepcopy(content_node),
            }
            rendered_primary_text = true
        else
            nodes[#nodes + 1] = {
                type = "request_content",
                content_index = index,
                content_node = vim.deepcopy(content_node),
            }
        end
    end

    if #nodes == 0 and request_text ~= "" then
        --- @type agentic.session.InteractionTextContentNode
        local content_node = {
            type = "text_content",
            text = request_text,
            text_structure = "plain",
            content = make_text_content(request_text),
        }

        nodes[#nodes + 1] = {
            type = "request_text",
            text = request_text,
            content_index = 1,
            content_node = content_node,
        }
    end

    return nodes
end

--- @param node agentic.session.InteractionContentNode
--- @return agentic.acp.Content|table|nil
local function content_node_to_content(node)
    if not node then
        return nil
    end

    if node.type == "text_content" then
        return vim.deepcopy(node.content)
    end
    if node.type == "image_content" then
        return vim.deepcopy(node.content)
    end
    if node.type == "audio_content" then
        return vim.deepcopy(node.content)
    end
    if node.type == "resource_link_content" then
        return vim.deepcopy(node.content)
    end
    if node.type == "resource_content" then
        return vim.deepcopy(node.content)
    end
    if node.type == "unknown_content" then
        return vim.deepcopy(node.content)
    end

    return nil
end

--- @param request {kind?: "user"|"review"|nil, text?: string|nil, timestamp?: integer|nil, content?: agentic.acp.Content[]|agentic.acp.Content|nil, content_nodes?: agentic.session.InteractionContentNode[]|nil, nodes?: agentic.session.InteractionRequestNode[]|nil}
--- @return agentic.session.InteractionRequest
local function make_request(request)
    local content = normalize_content_list(request.content)
    if vim.tbl_isempty(content) and request.content_nodes then
        for _, content_node in ipairs(request.content_nodes) do
            local normalized = content_node_to_content(content_node)
            if normalized then
                content[#content + 1] = normalized
            end
        end
    end

    if vim.tbl_isempty(content) then
        content = { make_text_content(request.text or "") }
    end

    local content_nodes = build_content_nodes(content)

    return {
        kind = request.kind
            or (is_review_request(request.text or "") and "review" or "user"),
        text = request.text or "",
        timestamp = request.timestamp,
        content = content,
        content_nodes = content_nodes,
        nodes = build_request_nodes(request.text or "", content_nodes),
    }
end

--- @param content agentic.acp.Content|agentic.acp.Content[]|nil
--- @return string
local function collect_text_content(content)
    local parts = {}
    for _, item in ipairs(normalize_content_list(content)) do
        if item and item.type == "text" and item.text and item.text ~= "" then
            parts[#parts + 1] = item.text
        end
    end
    return table.concat(parts, "")
end

--- @param message {content?: agentic.acp.Content|agentic.acp.Content[]|nil, text?: string|nil}
--- @return agentic.acp.Content[]
local function normalize_agent_content(message)
    local normalized = normalize_content_list(message.content)
    if not vim.tbl_isempty(normalized) then
        return normalized
    end

    if message.text and message.text ~= "" then
        return {
            {
                type = "text",
                text = message.text,
            },
        }
    end

    return {}
end

--- @param existing agentic.session.PersistedSession.ToolCall|nil
--- @param update agentic.session.PersistedSession.ToolCall
--- @return agentic.session.PersistedSession.ToolCall merged
local function merge_tool_call_message(existing, update)
    local merged = vim.tbl_deep_extend("force", existing or {}, update)
    --- @cast merged agentic.session.PersistedSession.ToolCall

    if
        existing
        and existing.body
        and update.body
        and not vim.deep_equal(existing.body, update.body)
    then
        local body = vim.list_extend({}, existing.body)
        vim.list_extend(body, { "", "---", "" })
        vim.list_extend(body, update.body)
        merged.body = body
    end

    return merged
end

--- @param tool_call agentic.session.PersistedSession.ToolCall
--- @return agentic.session.ToolCallContentNode[]
local function build_tool_call_content_nodes(tool_call)
    local content_nodes = {}
    local saw_content_items = false

    for _, content in ipairs(tool_call.content_items or {}) do
        if content and content.type == "content" and content.content then
            local semantic_content_node = build_content_node(content.content)
            if semantic_content_node then
                content_nodes[#content_nodes + 1] = {
                    type = "content_output",
                    content_node = semantic_content_node,
                }
                saw_content_items = true
            end
        elseif content and content.type == "diff" then
            content_nodes[#content_nodes + 1] = {
                type = "diff_output",
                file_path = content.path or tool_call.file_path,
                old_lines = vim.split(content.oldText or "", "\n"),
                new_lines = vim.split(content.newText or "", "\n"),
            }
            saw_content_items = true
        elseif
            content
            and content.type == "terminal"
            and content.terminalId
        then
            content_nodes[#content_nodes + 1] = {
                type = "terminal_output",
                terminal_id = content.terminalId,
            }
            saw_content_items = true
        end
    end

    if saw_content_items then
        return content_nodes
    end

    if tool_call.body and #tool_call.body > 0 then
        content_nodes[#content_nodes + 1] = {
            type = "content_output",
            content_node = build_content_node(
                make_text_content(table.concat(tool_call.body, "\n"))
            ),
        }
    end

    if tool_call.diff then
        content_nodes[#content_nodes + 1] = {
            type = "diff_output",
            file_path = tool_call.file_path,
            old_lines = vim.deepcopy(tool_call.diff.old or {}),
            new_lines = vim.deepcopy(tool_call.diff.new or {}),
        }
    end

    if tool_call.terminal_id then
        content_nodes[#content_nodes + 1] = {
            type = "terminal_output",
            terminal_id = tool_call.terminal_id,
        }
    end

    return content_nodes
end

--- @param turns agentic.session.InteractionTurn[]
--- @return agentic.session.InteractionTurn|nil
local function current_runtime_turn(turns)
    return turns[#turns]
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.session.InteractionToolCallNode
local function make_tool_call_node(tool_call)
    return {
        type = "tool_call",
        tool_call_id = tool_call.tool_call_id,
        title = tool_call.argument or "",
        kind = tool_call.kind,
        status = tool_call.status,
        file_path = tool_call.file_path,
        permission_state = tool_call.permission_state,
        terminal_id = tool_call.terminal_id,
        content_nodes = build_tool_call_content_nodes(tool_call),
    }
end

--- @param opts {session_id?: string|nil, title?: string|nil, timestamp?: integer|nil, current_mode_id?: string|nil, config_options?: agentic.acp.ConfigOption[]|nil, available_commands?: agentic.acp.AvailableCommand[]|nil, turns?: agentic.session.InteractionTurn[]|nil}
--- @return agentic.session.InteractionSession
local function build_interaction_session(opts)
    local turns = {}

    for index, turn in ipairs(opts.turns or {}) do
        turns[index] = {
            index = turn.index or index,
            request = make_request(turn.request or {}),
            response = {
                provider_name = turn.response and turn.response.provider_name
                    or nil,
                nodes = vim.deepcopy(
                    turn.response and turn.response.nodes or {}
                ),
            },
            result = vim.deepcopy(turn.result),
        }
    end

    return {
        session_id = opts.session_id,
        title = opts.title or "",
        timestamp = opts.timestamp or os.time(),
        current_mode_id = opts.current_mode_id,
        config_options = vim.deepcopy(opts.config_options or {}),
        available_commands = vim.deepcopy(opts.available_commands or {}),
        turns = turns,
    }
end

--- @param opts {session_id?: string|nil, title?: string|nil, timestamp?: integer|nil, current_mode_id?: string|nil, config_options?: agentic.acp.ConfigOption[]|nil, available_commands?: agentic.acp.AvailableCommand[]|nil, turns?: agentic.session.InteractionTurn[]|nil}
--- @return agentic.session.InteractionSession
function InteractionModel.from_persisted_session(opts)
    return build_interaction_session(opts or {})
end

--- @param turns agentic.session.InteractionTurn[]
--- @param request {kind?: "user"|"review"|nil, text?: string|nil, timestamp?: integer|nil, content?: agentic.acp.Content[]|agentic.acp.Content|nil}
function InteractionModel.append_request(turns, request)
    turns[#turns + 1] = {
        index = #turns + 1,
        request = make_request(request),
        response = {
            provider_name = nil,
            nodes = {},
        },
        result = nil,
    }
end

--- @param turns agentic.session.InteractionTurn[]
--- @param kind "message"|"thought"
--- @param provider_name string|nil
--- @param content agentic.acp.Content|agentic.acp.Content[]|nil
function InteractionModel.append_response_content(
    turns,
    kind,
    provider_name,
    content
)
    local normalized = normalize_content_list(content)
    if vim.tbl_isempty(normalized) then
        return
    end

    local turn = current_runtime_turn(turns)
    if not turn then
        return
    end
    turn.response.provider_name = provider_name or turn.response.provider_name

    local last = turn.response.nodes[#turn.response.nodes]
    if last and last.type == kind and last.provider_name == provider_name then
        last.content = last.content or {}
        for _, item in ipairs(normalized) do
            last.content[#last.content + 1] = vim.deepcopy(item)
        end
        last.text = collect_text_content(last.content)
        last.content_nodes = build_content_nodes(last.content)
        return
    end

    turn.response.nodes[#turn.response.nodes + 1] = {
        type = kind,
        text = collect_text_content(normalized),
        provider_name = provider_name,
        content = normalized,
        content_nodes = build_content_nodes(normalized),
    }
end

--- @param turns agentic.session.InteractionTurn[]
--- @param provider_name string|nil
--- @param entries agentic.acp.PlanEntry[]
function InteractionModel.upsert_plan(turns, provider_name, entries)
    local turn = current_runtime_turn(turns)
    if not turn then
        return
    end
    turn.response.provider_name = provider_name or turn.response.provider_name
    local last = turn.response.nodes[#turn.response.nodes]
    if last and last.type == "plan" then
        last.entries = vim.deepcopy(entries or {})
        last.provider_name = provider_name or last.provider_name
        return
    end

    turn.response.nodes[#turn.response.nodes + 1] = {
        type = "plan",
        entries = vim.deepcopy(entries or {}),
        provider_name = provider_name,
    }
end

--- @param turns agentic.session.InteractionTurn[]
--- @param provider_name string|nil
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function InteractionModel.upsert_tool_call(turns, provider_name, tool_call)
    local node = make_tool_call_node(tool_call)

    for turn_index = #turns, 1, -1 do
        local turn = turns[turn_index]
        for node_index = #turn.response.nodes, 1, -1 do
            local existing = turn.response.nodes[node_index]
            if
                existing.type == "tool_call"
                and existing.tool_call_id == tool_call.tool_call_id
            then
                local merged_tool_call = merge_tool_call_message(
                    {
                        type = "tool_call",
                        tool_call_id = existing.tool_call_id,
                        argument = existing.title,
                        kind = existing.kind,
                        status = existing.status,
                        file_path = existing.file_path,
                        permission_state = existing.permission_state,
                        terminal_id = existing.terminal_id,
                        content_items = (function()
                            local content_items = {}
                            for _, content_node in
                                ipairs(existing.content_nodes or {})
                            do
                                if content_node.type == "content_output" then
                                    local content = content_node_to_content(
                                        content_node.content_node
                                    )
                                    if content then
                                        content_items[#content_items + 1] = {
                                            type = "content",
                                            content = content,
                                        }
                                    end
                                elseif content_node.type == "diff_output" then
                                    content_items[#content_items + 1] = {
                                        type = "diff",
                                        path = content_node.file_path,
                                        oldText = table.concat(
                                            content_node.old_lines or {},
                                            "\n"
                                        ),
                                        newText = table.concat(
                                            content_node.new_lines or {},
                                            "\n"
                                        ),
                                    }
                                elseif
                                    content_node.type == "terminal_output"
                                then
                                    content_items[#content_items + 1] = {
                                        type = "terminal",
                                        terminalId = content_node.terminal_id,
                                    }
                                end
                            end
                            return content_items
                        end)(),
                    },
                    vim.tbl_deep_extend(
                        "force",
                        { type = "tool_call" },
                        tool_call
                    )
                )
                turn.response.nodes[node_index] =
                    make_tool_call_node(merged_tool_call)
                turn.response.provider_name = provider_name
                    or turn.response.provider_name
                return
            end
        end
    end

    local turn = current_runtime_turn(turns)
    if not turn then
        return
    end
    turn.response.provider_name = provider_name or turn.response.provider_name
    turn.response.nodes[#turn.response.nodes + 1] = node
end

--- @param turns agentic.session.InteractionTurn[]
--- @param result {stop_reason?: agentic.acp.StopReason|nil, timestamp?: integer|nil, error_text?: string|nil}
--- @param provider_name string|nil
function InteractionModel.set_turn_result(turns, result, provider_name)
    local turn = current_runtime_turn(turns)
    if not turn then
        return
    end
    turn.response.provider_name = provider_name or turn.response.provider_name
    turn.result = {
        stop_reason = result.stop_reason,
        timestamp = result.timestamp,
        error_text = result.error_text,
    }
end

--- @param turns agentic.session.InteractionTurn[]
--- @param tool_call_id string
--- @param permission_state "requested"|"approved"|"rejected"|"dismissed"
function InteractionModel.set_tool_permission_state(
    turns,
    tool_call_id,
    permission_state
)
    for turn_index = #turns, 1, -1 do
        local turn = turns[turn_index]
        for node_index = #turn.response.nodes, 1, -1 do
            local node = turn.response.nodes[node_index]
            if
                node.type == "tool_call"
                and node.tool_call_id == tool_call_id
            then
                node.permission_state = permission_state
                return
            end
        end
    end
end

--- @param turns agentic.session.InteractionTurn[]
--- @return boolean
function InteractionModel.has_content(turns)
    return turns ~= nil and #turns > 0
end

--- @param turns agentic.session.InteractionTurn[]
--- @param tool_call_id string
--- @return agentic.session.InteractionToolCallNode|nil
function InteractionModel.get_tool_call(turns, tool_call_id)
    for _, turn in ipairs(turns or {}) do
        for _, node in ipairs(turn.response.nodes or {}) do
            if
                node.type == "tool_call"
                and node.tool_call_id == tool_call_id
            then
                return node
            end
        end
    end

    return nil
end

--- @param turns agentic.session.InteractionTurn[]
--- @return agentic.session.InteractionToolCallNode[]
function InteractionModel.get_tool_calls(turns)
    local tool_calls = {}
    for _, turn in ipairs(turns or {}) do
        for _, node in ipairs(turn.response.nodes or {}) do
            if node.type == "tool_call" then
                tool_calls[#tool_calls + 1] = node
            end
        end
    end
    return tool_calls
end

return InteractionModel
