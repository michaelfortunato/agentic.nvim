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

--- @param current_mode_id string
--- @return table
function SessionEvents.set_current_mode(current_mode_id)
    return {
        type = "session/set_current_mode",
        current_mode_id = current_mode_id,
    }
end

--- @param config_options agentic.acp.ConfigOption[]
--- @return table
function SessionEvents.set_config_options(config_options)
    return {
        type = "session/set_config_options",
        config_options = config_options,
    }
end

--- @param available_commands agentic.acp.AvailableCommand[]
--- @return table
function SessionEvents.set_available_commands(available_commands)
    return {
        type = "session/set_available_commands",
        available_commands = available_commands,
    }
end

--- @param persisted_session agentic.session.PersistedSession|agentic.session.PersistedSession.StorageData
--- @param opts {preserve_session_id?: boolean|nil, preserve_timestamp?: boolean|nil, preserve_current_mode_id?: boolean|nil}|nil
--- @return table
function SessionEvents.load_persisted_session(persisted_session, opts)
    opts = opts or {}
    return {
        type = "session/load_persisted_session",
        session_id = persisted_session.session_id,
        title = persisted_session.title,
        timestamp = persisted_session.timestamp,
        current_mode_id = persisted_session.current_mode_id,
        config_options = persisted_session.config_options,
        available_commands = persisted_session.available_commands,
        turns = persisted_session.turns,
        preserve_session_id = opts.preserve_session_id == true,
        preserve_timestamp = opts.preserve_timestamp == true,
        preserve_current_mode_id = opts.preserve_current_mode_id == true,
    }
end

--- @param request {kind?: "user"|"review"|nil, surface?: "chat"|"inline"|nil, text?: string|nil, timestamp?: integer|nil, content?: agentic.acp.Content[]|agentic.acp.Content|nil}
--- @return table
function SessionEvents.append_interaction_request(request)
    return {
        type = "interaction/append_request",
        request = request,
    }
end

--- @param provider_name string|nil
--- @param entries agentic.acp.PlanEntry[]
--- @return table
function SessionEvents.upsert_interaction_plan(provider_name, entries)
    return {
        type = "interaction/upsert_plan",
        provider_name = provider_name,
        entries = entries,
    }
end

--- @param kind "message"|"thought"
--- @param provider_name string|nil
--- @param content agentic.acp.Content|agentic.acp.Content[]
--- @return table
function SessionEvents.append_interaction_response(kind, provider_name, content)
    return {
        type = "interaction/append_response",
        kind = kind,
        provider_name = provider_name,
        content = content,
    }
end

--- @param provider_name string|nil
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @return table
function SessionEvents.upsert_interaction_tool_call(provider_name, tool_call)
    return {
        type = "interaction/upsert_tool_call",
        provider_name = provider_name,
        tool_call = tool_call,
    }
end

--- @param result {stop_reason?: agentic.acp.StopReason|nil, timestamp?: integer|nil, error_text?: string|nil}
--- @param provider_name string|nil
--- @return table
function SessionEvents.set_interaction_turn_result(result, provider_name)
    return {
        type = "interaction/set_turn_result",
        result = result,
        provider_name = provider_name,
    }
end

--- @param tool_call_id string
--- @param permission_state "requested"|"approved"|"rejected"|"dismissed"
--- @return table
function SessionEvents.set_interaction_tool_permission_state(
    tool_call_id,
    permission_state
)
    return {
        type = "interaction/set_tool_permission_state",
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
--- @param clear_reason agentic.ui.DiffPreview.ClearReason|nil
--- @return table
function SessionEvents.clear_review_target(tool_call_id, clear_reason)
    return {
        type = "review/clear_active_tool_call",
        tool_call_id = tool_call_id,
        clear_reason = clear_reason,
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
