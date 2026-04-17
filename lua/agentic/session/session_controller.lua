---@diagnostic disable: invisible
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionLifecycle = require("agentic.session.session_lifecycle")
local SessionEvents = require("agentic.session.session_events")
local SessionSelectors = require("agentic.session.session_selectors")
local PermissionOption = require("agentic.utils.permission_option")

--- UI Sync Scopes
--- - Global: provider instance acquisition still uses AgentInstance
--- - Window-local: none, delegated to SessionRegistry
--- - Tab-local: none, widget ownership stays outside this module
--- - Session-local: ACP session identity, lifecycle flags, callback routing

--- Tool call kinds that mutate files on disk.
--- When these complete, buffers must be reloaded via checktime.
local FILE_MUTATING_KINDS = {
    edit = true,
    create = true,
    write = true,
    delete = true,
    move = true,
}

local SessionController = {}

--- @param value any
--- @return boolean
local function is_callable(value)
    return type(value) == "function"
        or (
            type(value) == "table"
            and getmetatable(value)
            and type(getmetatable(value).__call) == "function"
        )
end

--- @param session agentic.SessionManager
--- @param method_name string
--- @return function|nil
local function get_session_method(session, method_name)
    local method = session[method_name]
    if is_callable(method) then
        return method
    end

    local SessionManager = require("agentic.session_manager")
    local fallback = SessionManager[method_name]
    if is_callable(fallback) then
        return fallback
    end

    return nil
end

--- @param session agentic.SessionManager
--- @param method_name string
--- @param ... any
--- @return any
local function call_session_method(session, method_name, ...)
    local method = get_session_method(session, method_name)
    if method then
        return method(session, ...)
    end

    return nil
end

--- @param label string
--- @param value string
--- @return string
local function build_meta_line(label, value)
    return string.format("%s · %s", label, value)
end

--- @param hook_name "on_session_update"
--- @param data table
local function invoke_hook(hook_name, data)
    local hook = Config.hooks and Config.hooks[hook_name]

    if hook and type(hook) == "function" then
        vim.schedule(function()
            local ok, err = pcall(hook, data)
            if not ok then
                Logger.debug(
                    string.format("Hook '%s' error: %s", hook_name, err)
                )
            end
        end)
    end
end

--- @param session agentic.SessionManager
--- @param events table[]
local function dispatch_state_events(session, events)
    for _, event in ipairs(events) do
        session.session_state:dispatch(event)
    end
end

--- @param message string
--- @param is_generating boolean
--- @return string
local function with_live_config_note(message, is_generating)
    if not is_generating then
        return message
    end

    return message .. ". Applies without interrupting the current response."
end

--- @param session agentic.SessionManager
local function refresh_chat_activity(session)
    if get_session_method(session, "_refresh_chat_activity") then
        call_session_method(session, "_refresh_chat_activity")
        return
    end

    require("agentic.session.widget_binding").refresh_chat_activity(session)
end

--- @param session agentic.SessionManager
local function render_window_headers(session)
    if get_session_method(session, "_render_window_headers") then
        call_session_method(session, "_render_window_headers")
        return
    end

    require("agentic.session.widget_binding").render_window_headers(session)
end

--- @param session agentic.SessionManager
--- @param new_config_options agentic.acp.ConfigOption[]|nil
local function handle_new_config_options(session, new_config_options)
    if get_session_method(session, "_handle_new_config_options") then
        call_session_method(
            session,
            "_handle_new_config_options",
            new_config_options
        )
        return
    end

    require("agentic.session.widget_binding").handle_new_config_options(
        session,
        new_config_options
    )
end

--- @param session agentic.SessionManager
--- @return agentic.acp.ACPClient|nil
function SessionController.initialize_agent(session)
    local AgentInstance = require("agentic.acp.agent_instance")

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            if not session["_restoring"] then
                call_session_method(session, "_ensure_session_started")
            end
        end)
    end)

    if not agent then
        return nil
    end

    session.agent = agent
    return agent
end

--- @param session agentic.SessionManager
function SessionController.drain_pending_session_callbacks(session)
    if not session.session_id then
        return
    end

    local callbacks = session["_pending_session_callbacks"] or {}
    if #callbacks == 0 then
        return
    end

    session["_pending_session_callbacks"] = {}

    for _, callback in ipairs(callbacks) do
        callback()
    end
end

--- @param session agentic.SessionManager
function SessionController.ensure_session_started(session)
    if session.session_id then
        call_session_method(session, "_drain_pending_session_callbacks")
        return
    end

    if session["_session_starting"] then
        return
    end

    if not session.agent or session.agent.state ~= "ready" then
        return
    end

    session:new_session({
        restore_mode = true,
        on_created = function()
            call_session_method(session, "_drain_pending_session_callbacks")
            call_session_method(session, "_drain_queued_submissions")
        end,
    })
end

--- @param session agentic.SessionManager
--- @param callback fun()
function SessionController.with_active_session(session, callback)
    if session.session_id then
        callback()
        return
    end

    local pending_session_callbacks = session["_pending_session_callbacks"]
        or {}
    pending_session_callbacks[#pending_session_callbacks + 1] = callback
    session["_pending_session_callbacks"] = pending_session_callbacks
    call_session_method(session, "_ensure_session_started")
end

--- @param session agentic.SessionManager
--- @param state agentic.session.State|nil
--- @return string[]
function SessionController.build_chat_welcome_lines(session, state)
    state = state or session.session_state:get_state()
    local session_meta = SessionSelectors.get_session_meta(state)
    if not session_meta or not session_meta.id then
        return {}
    end

    local agent_info = session.agent and session.agent.agent_info or nil
    local provider_name = session.agent and session.agent.provider_config.name
        or "Unknown provider"
    local name = provider_name
    if agent_info and agent_info.version then
        name = name .. " v" .. agent_info.version
    end

    local started_at =
        os.date("%Y-%m-%d %H:%M:%S", session_meta.timestamp or os.time())
    --- @cast started_at string

    return {
        build_meta_line("Agentic", name),
        build_meta_line("Session", session_meta.id),
        build_meta_line("Started", started_at),
    }
end

--- @param session agentic.SessionManager
--- @return {state: agentic.Theme.SpinnerState, detail?: string|nil}|nil
function SessionController.get_active_tool_activity(session)
    if not session.session_state then
        return nil
    end

    local activity = SessionSelectors.get_chat_activity_info(
        session.session_state:get_state(),
        {
            session_starting = false,
            is_generating = true,
            agent_phase = session["_agent_phase"],
        }
    )

    if activity == nil or activity.detail == nil then
        return nil
    end

    return activity
end

--- @param session agentic.SessionManager
--- @param update agentic.acp.SessionUpdateMessage
function SessionController.on_session_update(session, update)
    local SlashCommands = require("agentic.acp.slash_commands")

    if session.inline_chat and session.inline_chat:is_active() then
        session.inline_chat:handle_session_update(update)
    end

    if update.sessionUpdate == "agent_message_chunk" then
        session["_agent_phase"] = "generating"
        refresh_chat_activity(session)

        if update.content then
            session.session_state:dispatch(
                SessionEvents.append_interaction_response(
                    "message",
                    session.agent.provider_config.name,
                    vim.deepcopy(update.content)
                )
            )
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        session["_agent_phase"] = "thinking"
        refresh_chat_activity(session)

        if update.content then
            session.session_state:dispatch(
                SessionEvents.append_interaction_response(
                    "thought",
                    session.agent.provider_config.name,
                    vim.deepcopy(update.content)
                )
            )
        end
    elseif update.sessionUpdate == "session_info_update" then
        if update.title ~= nil then
            session.session_state:dispatch(
                SessionEvents.set_session_title(update.title or "")
            )
            render_window_headers(session)
        end
    elseif update.sessionUpdate == "plan" then
        session.session_state:dispatch(
            SessionEvents.upsert_interaction_plan(
                session.agent.provider_config.name,
                vim.deepcopy(update.entries or {})
            )
        )
        if Config.windows.todos.display then
            session.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "available_commands_update" then
        session.session_state:dispatch(
            SessionEvents.set_available_commands(update.availableCommands or {})
        )
        SlashCommands.setCommands(
            session.widget.buf_nrs.input,
            update.availableCommands
        )
    elseif update.sessionUpdate == "current_mode_update" then
        session.session_state:dispatch(
            SessionEvents.set_current_mode(update.currentModeId)
        )
        if
            session.config_options and session.config_options.set_current_mode
        then
            session.config_options:set_current_mode(update.currentModeId)
        end
        render_window_headers(session)
    elseif update.sessionUpdate == "usage_update" then
        -- Usage updates are informational for now. Keep them recognized so
        -- providers can emit ACP usage telemetry without triggering warnings.
    elseif update.sessionUpdate == "config_option_update" then
        handle_new_config_options(session, update.configOptions)
    else
        Logger.debug(
            "Unknown session update type: ",
            tostring(
                --- @diagnostic disable-next-line: undefined-field
                update.sessionUpdate
            )
        )
    end

    invoke_hook("on_session_update", {
        session_id = session.session_id,
        tab_page_id = session.tab_page_id,
        update = update,
    })
end

--- @param session agentic.SessionManager
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function SessionController.on_tool_call(session, tool_call)
    if session.inline_chat and session.inline_chat:is_active() then
        session.inline_chat:handle_tool_call(tool_call)
    end

    session.session_state:dispatch(
        SessionEvents.upsert_interaction_tool_call(
            session.agent.provider_config.name,
            tool_call
        )
    )
    refresh_chat_activity(session)
end

--- @param session agentic.SessionManager
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBlock
function SessionController.on_tool_call_update(session, tool_call_update)
    if session.inline_chat and session.inline_chat:is_active() then
        session.inline_chat:handle_tool_call_update(tool_call_update)
    end

    local events = {
        SessionEvents.upsert_interaction_tool_call(
            session.agent.provider_config.name,
            tool_call_update
        ),
    }

    if
        tool_call_update.status == "completed"
        or tool_call_update.status == "failed"
    then
        events[#events + 1] = SessionEvents.clear_review_target(
            tool_call_update.tool_call_id,
            tool_call_update.status == "failed"
        )
    end

    dispatch_state_events(session, events)

    if tool_call_update.status == "failed" then
        session.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    refresh_chat_activity(session)

    if tool_call_update.status == "completed" then
        local tracker = nil
        if session.session_state then
            tracker = SessionSelectors.get_tool_call(
                session.session_state:get_state(),
                tool_call_update.tool_call_id
            )
        end

        local tool_kind = tracker and tracker.kind or tool_call_update.kind
        if tool_kind and FILE_MUTATING_KINDS[tool_kind] then
            if
                session.inline_chat
                and session.inline_chat.is_active
                and session.inline_chat:is_active()
                and session.inline_chat.handle_applied_edit
            then
                session.inline_chat:handle_applied_edit()
            end
            vim.cmd.checktime()
        end
    end
end

--- @param session agentic.SessionManager
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function SessionController.handle_permission_request(session, request, callback)
    if session.inline_chat and session.inline_chat:is_active() then
        session.inline_chat:handle_permission_request()
    end

    local tool_call_id = request.toolCall.toolCallId

    local wrapped_callback = function(option_id)
        local permission_state =
            PermissionOption.get_state_for_option_id(request.options, option_id)

        dispatch_state_events(session, {
            SessionEvents.set_interaction_tool_permission_state(
                tool_call_id,
                permission_state
            ),
            SessionEvents.clear_review_target(
                tool_call_id,
                permission_state == "rejected"
                    or permission_state == "dismissed"
            ),
        })
        if
            session.inline_chat
            and session.inline_chat.handle_permission_resolution
        then
            session.inline_chat:handle_permission_resolution({
                option_id = option_id,
                options = request.options,
            })
        end
        callback(option_id)
        vim.schedule(function()
            refresh_chat_activity(session)
        end)
    end

    dispatch_state_events(session, {
        SessionEvents.set_interaction_tool_permission_state(
            tool_call_id,
            "requested"
        ),
        SessionEvents.set_review_target(tool_call_id),
    })
    session.permission_manager:add_request(request, wrapped_callback)
    refresh_chat_activity(session)
end

--- @param session agentic.SessionManager
--- @param config_id string
--- @param value string
function SessionController.handle_config_option_change(
    session,
    config_id,
    value
)
    if not session.session_id then
        return
    end

    session.agent:set_config_option(
        session.session_id,
        config_id,
        value,
        function(result, err)
            if err then
                Logger.notify(
                    string.format(
                        "Failed to change config option '%s': %s",
                        config_id,
                        err.message
                    ),
                    vim.log.levels.ERROR
                )
                return
            end

            if result and result.configOptions then
                Logger.debug("received result after setting config option")
                handle_new_config_options(session, result.configOptions)
            else
                local option =
                    session.config_options:get_config_option(config_id)
                if option then
                    option.currentValue = value
                end
                render_window_headers(session)
                if session.inline_chat then
                    session.inline_chat:refresh()
                end
            end

            local option_name = session.config_options:get_config_option_name(
                config_id
            ) or config_id
            local value_name = session.config_options:get_config_value_name(
                config_id,
                value
            ) or value

            Logger.notify(
                with_live_config_note(
                    string.format("%s changed to: %s", option_name, value_name),
                    session.is_generating
                ),
                vim.log.levels.INFO,
                { title = "Agentic Config changed" }
            )
        end
    )
end

--- @param session agentic.SessionManager
--- @param opts {restore_mode: boolean|nil, on_created: fun()|nil}|nil
function SessionController.new_session(session, opts)
    return SessionLifecycle.start(session, opts)
end

--- @param session agentic.SessionManager
function SessionController.cancel_session(session)
    return SessionLifecycle.cancel(session)
end

--- @param session agentic.SessionManager
function SessionController.switch_provider(session)
    return SessionLifecycle.switch_provider(session)
end

--- @param session agentic.SessionManager
--- @param persisted_session agentic.session.PersistedSession|agentic.session.PersistedSession.StorageData
--- @param opts {reuse_session?: boolean}|nil
function SessionController.restore_session_data(
    session,
    persisted_session,
    opts
)
    return SessionLifecycle.restore_session_data(
        session,
        persisted_session,
        opts
    )
end

return SessionController
