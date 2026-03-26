local SessionSelectors = {}

--- @param state agentic.session.State
--- @return table
function SessionSelectors.get_session_meta(state)
    return state.session
end

--- @param state agentic.session.State
--- @return agentic.ui.ChatHistory.Message[]
function SessionSelectors.get_transcript_messages(state)
    return state.transcript.messages
end

--- @param state agentic.session.State
--- @return table[]
function SessionSelectors.get_permission_queue(state)
    return state.permissions.queue
end

--- @param state agentic.session.State
--- @return table|nil
function SessionSelectors.get_current_permission(state)
    return state.permissions.current_request
end

--- @param state agentic.session.State
--- @param tool_call_id string
--- @return table|nil
function SessionSelectors.get_tool_call(state, tool_call_id)
    return state.tools.by_id[tool_call_id]
end

--- @param state agentic.session.State
--- @return table[]
function SessionSelectors.get_tool_calls(state)
    local tools = {}

    for _, tool_call_id in ipairs(state.tools.order) do
        local tool = state.tools.by_id[tool_call_id]
        if tool then
            tools[#tools + 1] = tool
        end
    end

    return tools
end

--- @param state agentic.session.State
--- @return string|nil
function SessionSelectors.get_active_review_tool_call_id(state)
    return state.review.active_tool_call_id
end

--- @param state agentic.session.State
--- @return table|nil
function SessionSelectors.get_active_review_tool_call(state)
    local active_tool_call_id =
        SessionSelectors.get_active_review_tool_call_id(state)
    if not active_tool_call_id then
        return nil
    end

    return SessionSelectors.get_tool_call(state, active_tool_call_id)
end

--- @param state agentic.session.State
--- @return boolean
function SessionSelectors.has_pending_permissions(state)
    return state.permissions.current_request ~= nil
        or #state.permissions.queue > 0
end

--- @param state agentic.session.State
--- @return agentic.ui.ChatHistory.StorageData
function SessionSelectors.get_chat_history_data(state)
    return {
        session_id = state.session.id,
        title = state.session.title,
        timestamp = state.session.timestamp,
        messages = state.transcript.messages,
    }
end

return SessionSelectors
