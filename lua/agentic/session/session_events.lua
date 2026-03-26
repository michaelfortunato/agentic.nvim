local SessionEvents = {}

--- @param opts {session_id?: string|nil, title?: string|nil, timestamp?: integer|nil}
--- @return table
function SessionEvents.set_session_meta(opts)
    opts = opts or {}
    return {
        type = "session/set_meta",
        session_id = opts.session_id,
        title = opts.title,
        timestamp = opts.timestamp,
    }
end

--- @param title string
--- @return table
function SessionEvents.set_session_title(title)
    return {
        type = "session/set_title",
        title = title,
    }
end

--- @param history agentic.ui.ChatHistory
--- @param opts {preserve_session_id?: boolean|nil, preserve_timestamp?: boolean|nil}|nil
--- @return table
function SessionEvents.restore_history(history, opts)
    opts = opts or {}
    return {
        type = "session/restore_history",
        session_id = history.session_id,
        title = history.title,
        timestamp = history.timestamp,
        messages = history.messages,
        preserve_session_id = opts.preserve_session_id == true,
        preserve_timestamp = opts.preserve_timestamp == true,
    }
end

--- @param message agentic.ui.ChatHistory.Message
--- @return table
function SessionEvents.add_transcript_message(message)
    return {
        type = "transcript/add_message",
        message = message,
    }
end

--- @param message {type: "agent"|"thought", text: string, provider_name: string}
--- @return table
function SessionEvents.append_agent_text(message)
    return {
        type = "transcript/append_agent_text",
        message = message,
    }
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @return table
function SessionEvents.upsert_transcript_tool_call(tool_call)
    return {
        type = "transcript/upsert_tool_call",
        tool_call = tool_call,
    }
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @return table
function SessionEvents.upsert_tool_call(tool_call)
    return {
        type = "tools/upsert",
        tool_call = tool_call,
    }
end

--- @param tool_call_id string
--- @param permission_state "requested"|"approved"|"rejected"|"dismissed"
--- @return table
function SessionEvents.set_tool_permission_state(tool_call_id, permission_state)
    return {
        type = "tools/set_permission_state",
        tool_call_id = tool_call_id,
        permission_state = permission_state,
    }
end

--- @param tool_call_id string
--- @return table
function SessionEvents.set_review_target(tool_call_id)
    return {
        type = "review/set_active_tool_call",
        tool_call_id = tool_call_id,
    }
end

--- @param tool_call_id string
--- @param is_rejection boolean|nil
--- @return table
function SessionEvents.clear_review_target(tool_call_id, is_rejection)
    return {
        type = "review/clear_active_tool_call",
        tool_call_id = tool_call_id,
        is_rejection = is_rejection == true,
    }
end

--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @return table
function SessionEvents.enqueue_permission(request, callback)
    return {
        type = "permissions/enqueue",
        request = request,
        callback = callback,
    }
end

--- @return table
function SessionEvents.show_next_permission()
    return {
        type = "permissions/show_next",
    }
end

--- @return table
function SessionEvents.complete_current_permission()
    return {
        type = "permissions/complete_current",
    }
end

--- @return table
function SessionEvents.clear_permissions()
    return {
        type = "permissions/clear",
    }
end

--- @param tool_call_id string
--- @return table
function SessionEvents.remove_permission_by_tool_call_id(tool_call_id)
    return {
        type = "permissions/remove_by_tool_call_id",
        tool_call_id = tool_call_id,
    }
end

return SessionEvents
