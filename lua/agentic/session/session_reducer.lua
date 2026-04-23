local InteractionModel = require("agentic.session.interaction_model")

local SessionReducer = {}

--- @class agentic.session.State
--- @field session {id?: string|nil, title: string, timestamp: integer, current_mode_id?: string|nil, config_options: agentic.acp.ConfigOption[], available_commands: agentic.acp.AvailableCommand[]}
--- @field interaction {turns: agentic.session.InteractionTurn[]}
--- @field permissions {queue: table[], current_request?: table|nil}
--- @field review {active_tool_call_id?: string|nil}

--- @param opts {session_id?: string|nil, title?: string|nil, timestamp?: integer|nil, current_mode_id?: string|nil, config_options?: agentic.acp.ConfigOption[]|nil, available_commands?: agentic.acp.AvailableCommand[]|nil, turns?: agentic.session.InteractionTurn[]|nil}|nil
--- @return agentic.session.State
function SessionReducer.initial_state(opts)
    opts = opts or {}

    local interaction = InteractionModel.from_persisted_session({
        session_id = opts.session_id,
        title = opts.title,
        timestamp = opts.timestamp,
        current_mode_id = opts.current_mode_id,
        config_options = opts.config_options or {},
        available_commands = opts.available_commands or {},
        turns = opts.turns or {},
    })

    return {
        session = {
            id = opts.session_id,
            title = opts.title or "",
            timestamp = opts.timestamp or os.time(),
            current_mode_id = opts.current_mode_id,
            config_options = vim.deepcopy(interaction.config_options or {}),
            available_commands = vim.deepcopy(
                interaction.available_commands or {}
            ),
        },
        interaction = {
            turns = interaction.turns,
        },
        permissions = {
            queue = {},
            current_request = nil,
        },
        review = {
            active_tool_call_id = nil,
        },
    }
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

    if event.type == "session/set_current_mode" then
        state.session.current_mode_id = event.current_mode_id
        return state
    end

    if event.type == "session/set_config_options" then
        state.session.config_options = vim.deepcopy(event.config_options or {})
        return state
    end

    if event.type == "session/set_available_commands" then
        state.session.available_commands =
            vim.deepcopy(event.available_commands or {})
        return state
    end

    if event.type == "session/load_persisted_session" then
        local interaction = InteractionModel.from_persisted_session({
            session_id = event.session_id,
            title = event.title,
            timestamp = event.timestamp,
            current_mode_id = event.current_mode_id,
            config_options = event.config_options or {},
            available_commands = event.available_commands or {},
            turns = event.turns or {},
        })
        state.interaction.turns = interaction.turns
        state.session.title = event.title or ""
        state.session.config_options =
            vim.deepcopy(interaction.config_options or {})
        state.session.available_commands =
            vim.deepcopy(interaction.available_commands or {})
        if not event.preserve_current_mode_id then
            state.session.current_mode_id = event.current_mode_id
        end

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

    if event.type == "interaction/append_request" then
        InteractionModel.append_request(state.interaction.turns, event.request)
        return state
    end

    if event.type == "interaction/append_response" then
        InteractionModel.append_response_content(
            state.interaction.turns,
            event.kind,
            event.provider_name,
            event.content,
            event.turn_id
        )
        return state
    end

    if event.type == "interaction/upsert_tool_call" then
        InteractionModel.upsert_tool_call(
            state.interaction.turns,
            event.provider_name,
            event.tool_call,
            event.turn_id
        )
        return state
    end

    if event.type == "interaction/set_tool_permission_state" then
        InteractionModel.set_tool_permission_state(
            state.interaction.turns,
            event.tool_call_id,
            event.permission_state
        )
        return state
    end

    if event.type == "interaction/upsert_plan" then
        InteractionModel.upsert_plan(
            state.interaction.turns,
            event.provider_name,
            event.entries,
            event.turn_id
        )
        return state
    end

    if event.type == "interaction/set_turn_result" then
        InteractionModel.set_turn_result(
            state.interaction.turns,
            event.result,
            event.provider_name,
            event.turn_id
        )
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
            sessionId = event.request.sessionId,
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
