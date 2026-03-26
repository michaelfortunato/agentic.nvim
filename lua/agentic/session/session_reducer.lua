local SessionReducer = {}

--- @class agentic.session.State
--- @field session {id?: string|nil, title: string, timestamp: integer}
--- @field transcript {messages: agentic.ui.ChatHistory.Message[]}
--- @field permissions {queue: table[], current_request?: table|nil}
--- @field tools {by_id: table<string, table>, order: string[]}
--- @field review {active_tool_call_id?: string|nil}

--- @param opts {session_id?: string|nil, title?: string|nil, timestamp?: integer|nil, messages?: agentic.ui.ChatHistory.Message[]|nil}|nil
--- @return agentic.session.State
function SessionReducer.initial_state(opts)
    opts = opts or {}

    local messages = opts.messages or {}
    local tools = { by_id = {}, order = {} }

    for _, message in ipairs(messages) do
        if message.type == "tool_call" and message.tool_call_id then
            tools.by_id[message.tool_call_id] =
                vim.tbl_deep_extend("force", {}, message)
            tools.order[#tools.order + 1] = message.tool_call_id
        end
    end

    return {
        session = {
            id = opts.session_id,
            title = opts.title or "",
            timestamp = opts.timestamp or os.time(),
        },
        transcript = {
            messages = messages,
        },
        permissions = {
            queue = {},
            current_request = nil,
        },
        tools = tools,
        review = {
            active_tool_call_id = nil,
        },
    }
end

local function append_agent_text(messages, message)
    local last = messages[#messages]
    if last and last.type == message.type then
        last.text = last.text .. message.text
        return
    end

    table.insert(messages, message)
end

--- @param existing table|nil
--- @param update table
--- @return table
local function merge_tool_call(existing, update)
    local merged = vim.tbl_deep_extend("force", existing or {}, update)

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

--- @param state agentic.session.State
--- @param tool_call table
local function upsert_tool_state(state, tool_call)
    local tool_call_id = tool_call.tool_call_id
    if not tool_call_id then
        return
    end

    local existing = state.tools.by_id[tool_call_id]
    state.tools.by_id[tool_call_id] = merge_tool_call(existing, tool_call)

    if not existing then
        state.tools.order[#state.tools.order + 1] = tool_call_id
    end
end

--- @param messages agentic.ui.ChatHistory.Message[]
--- @param tool_call agentic.ui.ChatHistory.ToolCall
local function upsert_tool_call_message(messages, tool_call)
    for i = #messages, 1, -1 do
        local message = messages[i]
        if
            message.type == "tool_call"
            and message.tool_call_id == tool_call.tool_call_id
        then
            messages[i] = merge_tool_call(message, tool_call)
            return
        end
    end

    table.insert(messages, tool_call)
end

--- @param queue table[]
--- @param tool_call_id string
local function filter_permission_queue(queue, tool_call_id)
    return vim.tbl_filter(function(item)
        return item.toolCallId ~= tool_call_id
    end, queue)
end

--- @param state agentic.session.State|nil
--- @param event table|nil
--- @return agentic.session.State
function SessionReducer.reduce(state, event)
    state = state or SessionReducer.initial_state()

    if not event or not event.type then
        return state
    end

    if event.type == "session/set_meta" then
        if event.session_id ~= nil then
            state.session.id = event.session_id
        end
        if event.title ~= nil then
            state.session.title = event.title
        end
        if event.timestamp ~= nil then
            state.session.timestamp = event.timestamp
        end
        return state
    end

    if event.type == "session/set_title" then
        state.session.title = event.title or ""
        return state
    end

    if event.type == "session/restore_history" then
        state.transcript.messages = vim.deepcopy(event.messages or {})
        state.session.title = event.title or ""

        if not event.preserve_session_id then
            state.session.id = event.session_id
        end

        if not event.preserve_timestamp then
            state.session.timestamp = event.timestamp or state.session.timestamp
        end

        state.permissions.queue = {}
        state.permissions.current_request = nil
        return state
    end

    if event.type == "transcript/add_message" then
        table.insert(state.transcript.messages, event.message)
        return state
    end

    if event.type == "transcript/append_agent_text" then
        append_agent_text(state.transcript.messages, event.message)
        return state
    end

    if event.type == "transcript/upsert_tool_call" then
        upsert_tool_call_message(state.transcript.messages, event.tool_call)
        return state
    end

    if event.type == "tools/upsert" then
        upsert_tool_state(state, event.tool_call)
        return state
    end

    if event.type == "tools/set_permission_state" then
        local tool = state.tools.by_id[event.tool_call_id]
        if tool then
            tool.permission_state = event.permission_state
        end
        return state
    end

    if event.type == "review/set_active_tool_call" then
        state.review.active_tool_call_id = event.tool_call_id
        return state
    end

    if event.type == "review/clear_active_tool_call" then
        if
            state.review.active_tool_call_id == nil
            or state.review.active_tool_call_id == event.tool_call_id
        then
            state.review.active_tool_call_id = nil
        end
        return state
    end

    if event.type == "permissions/enqueue" then
        local tool_call_id = event.request.toolCall.toolCallId
        table.insert(state.permissions.queue, {
            toolCallId = tool_call_id,
            request = event.request,
            callback = event.callback,
        })
        return state
    end

    if event.type == "permissions/show_next" then
        if
            state.permissions.current_request == nil
            and #state.permissions.queue > 0
        then
            state.permissions.current_request =
                table.remove(state.permissions.queue, 1)
        end
        return state
    end

    if event.type == "permissions/complete_current" then
        state.permissions.current_request = nil
        return state
    end

    if event.type == "permissions/clear" then
        state.permissions.queue = {}
        state.permissions.current_request = nil
        return state
    end

    if event.type == "permissions/remove_by_tool_call_id" then
        state.permissions.queue =
            filter_permission_queue(state.permissions.queue, event.tool_call_id)

        if
            state.permissions.current_request
            and state.permissions.current_request.toolCallId
                == event.tool_call_id
        then
            state.permissions.current_request = nil
        end

        return state
    end

    return state
end

return SessionReducer
