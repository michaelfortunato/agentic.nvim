---@diagnostic disable: invisible
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionEvents = require("agentic.session.session_events")
local SessionSelectors = require("agentic.session.session_selectors")
local SessionLifecycle = {}

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

--- @param session agentic.SessionManager
--- @param opts {route?: "chat"|"inline"|nil, inline_conversation_id?: string|nil}|nil
--- @return agentic.acp.ClientHandlers
local function build_handlers(session, opts)
    local handler_opts = opts or {}

    return {
        on_error = function(err)
            Logger.debug("Agent error: ", err)
            if
                SessionSelectors.has_interaction_content(
                    session.session_state:get_state()
                )
            then
                session.session_state:dispatch(
                    SessionEvents.set_interaction_turn_result({
                        stop_reason = nil,
                        timestamp = os.time(),
                        error_text = vim.inspect(err),
                    }, session.agent.provider_config.name)
                )
            end
        end,

        on_session_update = function(update)
            if get_session_method(session, "_on_session_update") then
                call_session_method(
                    session,
                    "_on_session_update",
                    update,
                    handler_opts
                )
            end
        end,

        on_tool_call = function(tool_call)
            if get_session_method(session, "_on_tool_call") then
                call_session_method(
                    session,
                    "_on_tool_call",
                    tool_call,
                    handler_opts
                )
            end
        end,

        on_tool_call_update = function(tool_call_update)
            if get_session_method(session, "_on_tool_call_update") then
                call_session_method(
                    session,
                    "_on_tool_call_update",
                    tool_call_update,
                    handler_opts
                )
            end
        end,

        on_request_permission = function(request, callback)
            if get_session_method(session, "_handle_permission_request") then
                call_session_method(
                    session,
                    "_handle_permission_request",
                    request,
                    callback,
                    handler_opts
                )
            end
        end,
    }
end

--- @param option agentic.acp.ConfigOption|nil
--- @param value string|nil
--- @return boolean supported
local function config_option_supports_value(option, value)
    if not option or type(value) ~= "string" or value == "" then
        return false
    end

    local options = option.options or {}
    for _, candidate in ipairs(options) do
        if candidate.value == value then
            return true
        end

        if
            type(candidate) == "table"
            and type(candidate.options) == "table"
        then
            for _, grouped_candidate in ipairs(candidate.options) do
                if grouped_candidate.value == value then
                    return true
                end
            end
        end
    end

    return false
end

--- @param desired_options agentic.acp.ConfigOption[]|nil
--- @param announced_options agentic.acp.ConfigOption[]|nil
--- @return {id: string, value: string}[] changes
--- @return boolean restores_mode
--- @return boolean restores_model
--- @return table<string, boolean> restored_config_ids
local function get_config_changes(desired_options, announced_options)
    if
        type(desired_options) ~= "table"
        or type(announced_options) ~= "table"
    then
        return {}, false, false, {}
    end

    local announced_by_id = {}
    for _, option in ipairs(announced_options) do
        announced_by_id[option.id] = option
    end

    local restores_mode = false
    local restores_model = false
    local restored_config_ids = {}
    local changes = {}

    for _, desired_option in ipairs(desired_options) do
        local announced_option = announced_by_id[desired_option.id]
        local desired_value = desired_option.currentValue

        if
            announced_option
            and desired_value ~= nil
            and config_option_supports_value(announced_option, desired_value)
        then
            restored_config_ids[announced_option.id] = true

            if announced_option.category == "mode" then
                restores_mode = true
            elseif announced_option.category == "model" then
                restores_model = true
            end

            if desired_value ~= announced_option.currentValue then
                changes[#changes + 1] = {
                    id = announced_option.id,
                    value = desired_value,
                }
            end
        end
    end

    return changes, restores_mode, restores_model, restored_config_ids
end

--- @param session agentic.SessionManager
--- @param announced_options agentic.acp.ConfigOption[]|nil
--- @return {id: string, value: string}[] changes
--- @return boolean restores_mode
--- @return boolean restores_model
--- @return table<string, boolean> restored_config_ids
local function get_restorable_config_changes(session, announced_options)
    local persisted_session = session.session_state
            and session.session_state.get_persisted_session_data
            and session.session_state:get_persisted_session_data()
        or nil
    local persisted_options = persisted_session
            and persisted_session.config_options
        or {}

    return get_config_changes(persisted_options, announced_options)
end

--- @param session agentic.SessionManager
--- @param announced_options agentic.acp.ConfigOption[]|nil
--- @return {id: string, value: string}[] changes
local function get_inline_config_changes(session, announced_options)
    local config_options = session.config_options
    local desired_options = config_options and config_options._options or {}
    local changes = get_config_changes(desired_options, announced_options)

    return changes
end

--- @param session agentic.SessionManager
--- @param config_id string
--- @param value string
local function update_local_config_option_value(session, config_id, value)
    if session.config_options and session.config_options.get_config_option then
        local option = session.config_options:get_config_option(config_id)
        if option then
            option.currentValue = value
        end
    end

    local render_window_headers = rawget(session, "_render_window_headers")
    if type(render_window_headers) == "function" then
        render_window_headers(session)
    end

    if session.inline_chat and session.inline_chat.refresh then
        session.inline_chat:refresh()
    end
end

--- @param session agentic.SessionManager
--- @param target_session_id string|nil
--- @param changes {id: string, value: string}[]
--- @param callback fun()
local function restore_config_changes(
    session,
    target_session_id,
    changes,
    callback
)
    if target_session_id == nil then
        callback()
        return
    end

    local change = table.remove(changes, 1)
    if not change then
        callback()
        return
    end

    session.agent:set_config_option(
        target_session_id,
        change.id,
        change.value,
        function(result, err)
            if err then
                Logger.debug(
                    "Failed to restore config option ",
                    change.id,
                    ": ",
                    err.message or vim.inspect(err)
                )
            elseif result and result.configOptions then
                local handle_new_config_options =
                    rawget(session, "_handle_new_config_options")
                if type(handle_new_config_options) == "function" then
                    handle_new_config_options(session, result.configOptions)
                end
            else
                update_local_config_option_value(
                    session,
                    change.id,
                    change.value
                )
            end

            restore_config_changes(
                session,
                target_session_id,
                changes,
                callback
            )
        end
    )
end

--- @param session agentic.SessionManager
--- @param conversation_id string|nil
function SessionLifecycle.cancel_inline(session, conversation_id)
    local inline_sessions = session._inline_sessions or {}

    local function cancel_entry(target_conversation_id, inline_session)
        if
            inline_session
            and inline_session.session_id
            and session.agent
            and session.agent.cancel_session
        then
            session.agent:cancel_session(inline_session.session_id)
        end

        inline_sessions[target_conversation_id] = nil
        if
            session._inline_submission_queues
            and target_conversation_id ~= nil
        then
            session._inline_submission_queues[target_conversation_id] = nil
        end
    end

    if conversation_id ~= nil then
        cancel_entry(conversation_id, inline_sessions[conversation_id])
    else
        for target_conversation_id, inline_session in pairs(inline_sessions) do
            cancel_entry(target_conversation_id, inline_session)
        end
    end

    session._inline_sessions = inline_sessions
    session._inline_session_id = nil
    session._inline_session_starting = false
    session._pending_inline_session_callbacks = {}
end

--- @param session agentic.SessionManager
function SessionLifecycle.cancel(session)
    if get_session_method(session, "_cancel_inline_session") then
        call_session_method(session, "_cancel_inline_session")
    end

    if session.session_id then
        session.agent:cancel_session(session.session_id)
        session.widget:clear()
        session.message_writer:reset()
        session.todo_list:clear()
        session.file_list:clear()
        session.code_selection:clear()
        session.diagnostics_list:clear()
        session.config_options:clear()
    end

    session.session_id = nil
    session._agent_phase = nil
    session._session_starting = false
    if get_session_method(session, "_clear_inline_chat") then
        call_session_method(session, "_clear_inline_chat")
    end
    if get_session_method(session, "_clear_chat_activity") then
        call_session_method(session, "_clear_chat_activity")
    elseif session.status_animation and session.status_animation.stop then
        session.status_animation:stop()
    end
    session.permission_manager:clear()
    if get_session_method(session, "_sync_prompt_commands") then
        call_session_method(session, "_sync_prompt_commands", {})
    else
        require("agentic.session.widget_binding").sync_prompt_commands(
            session,
            {}
        )
    end

    session.session_state:replace_persisted_session_data()
    session._restored_turns_to_send = nil
    local was_visible = session.submission_queue:clear()
    if get_session_method(session, "_sync_queue_panel") then
        call_session_method(session, "_sync_queue_panel", was_visible)
    end
end

--- @param session agentic.SessionManager
--- @param opts {restore_mode: boolean|nil, on_created: fun()|nil}|nil
function SessionLifecycle.start(session, opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode or false
    local on_created = opts.on_created
    if not restore_mode then
        SessionLifecycle.cancel(session)
    end

    session._session_starting = true
    if get_session_method(session, "_refresh_chat_activity") then
        call_session_method(session, "_refresh_chat_activity")
    end

    session.agent:create_session(
        build_handlers(session),
        function(response, err)
            session._session_starting = false
            if get_session_method(session, "_refresh_chat_activity") then
                call_session_method(session, "_refresh_chat_activity")
            end

            if err or not response then
                session.session_id = nil
                return
            end

            session.session_id = response.sessionId
            session.session_state:dispatch(SessionEvents.set_session_meta({
                session_id = response.sessionId,
                timestamp = os.time(),
            }))
            if response.modes and response.modes.currentModeId then
                session.session_state:dispatch(
                    SessionEvents.set_current_mode(response.modes.currentModeId)
                )
                if
                    session.config_options
                    and session.config_options.set_current_mode
                then
                    session.config_options:set_current_mode(
                        response.modes.currentModeId
                    )
                end
            end

            if response.configOptions then
                Logger.debug("Provider announce configOptions")
                if
                    get_session_method(session, "_handle_new_config_options")
                then
                    call_session_method(
                        session,
                        "_handle_new_config_options",
                        response.configOptions
                    )
                end
            else
                if get_session_method(session, "_render_window_headers") then
                    call_session_method(session, "_render_window_headers")
                end
            end

            local function finish_session_setup()
                if session.config_options then
                    local changes, restores_mode, restores_model, restored_ids =
                        get_restorable_config_changes(
                            session,
                            response.configOptions
                        )
                    local provider_config = session.agent.provider_config

                    local apply_initial_config = function()
                        if
                            not restores_mode
                            and session.config_options.set_initial_mode
                        then
                            session.config_options:set_initial_mode(
                                provider_config.default_mode
                            )
                        end

                        if
                            not restores_model
                            and session.config_options.set_initial_model
                        then
                            session.config_options:set_initial_model(
                                provider_config.default_model
                            )
                        end

                        if
                            session.config_options.set_initial_config_options
                        then
                            session.config_options:set_initial_config_options(
                                provider_config.default_config_options,
                                restored_ids
                            )
                        end
                    end

                    if #changes > 0 then
                        restore_config_changes(
                            session,
                            session.session_id,
                            changes,
                            function()
                                apply_initial_config()

                                if not restore_mode then
                                    session._is_first_message = true
                                end

                                vim.schedule(function()
                                    if on_created then
                                        on_created()
                                    end
                                end)
                            end
                        )
                        return
                    end

                    apply_initial_config()
                end

                if not restore_mode then
                    session._is_first_message = true
                end

                vim.schedule(function()
                    if on_created then
                        on_created()
                    end
                end)
            end

            finish_session_setup()
        end
    )
end

--- @param session agentic.SessionManager
--- @param opts {conversation_id?: string|nil, on_created: fun(session_id: string)|nil}|nil
function SessionLifecycle.start_inline(session, opts)
    opts = opts or {}
    local conversation_id = opts.conversation_id
    if conversation_id == nil or conversation_id == "" then
        return
    end

    local on_created = opts.on_created
    local inline_sessions = session._inline_sessions or {}
    local inline_session = inline_sessions[conversation_id]

    if inline_session == nil then
        --- @type agentic.SessionManager.InlineSession
        inline_session = {
            session_id = nil,
            starting = false,
            is_generating = false,
            active_turn_id = nil,
            pending_callbacks = {},
            awaiting_rejected_followup = false,
            close_on_complete = false,
        }
        inline_sessions[conversation_id] = inline_session
        session._inline_sessions = inline_sessions
    end

    if inline_session.session_id then
        if on_created then
            vim.schedule(function()
                on_created(inline_session.session_id)
            end)
        end
        return
    end

    if on_created then
        inline_session.pending_callbacks[#inline_session.pending_callbacks + 1] =
            on_created
    end

    if inline_session.starting then
        return
    end

    inline_session.starting = true
    session._inline_session_starting = true

    session.agent:create_session(
        build_handlers(session, {
            route = "inline",
            inline_conversation_id = conversation_id,
        }),
        function(response, err)
            inline_session.starting = false

            if err or not response then
                inline_sessions[conversation_id] = nil
                session._inline_sessions = inline_sessions
                session._inline_session_starting = false
                return
            end

            inline_session.session_id = response.sessionId
            session._inline_session_id = response.sessionId
            session._inline_session_starting = false

            local function finish_inline_setup()
                local callbacks = inline_session.pending_callbacks or {}
                inline_session.pending_callbacks = {}

                vim.schedule(function()
                    for _, callback in ipairs(callbacks) do
                        callback(response.sessionId)
                    end
                end)
            end

            local changes =
                get_inline_config_changes(session, response.configOptions)

            if #changes > 0 then
                restore_config_changes(
                    session,
                    inline_session.session_id,
                    changes,
                    finish_inline_setup
                )
                return
            end

            finish_inline_setup()
        end
    )
end

--- @param session agentic.SessionManager
function SessionLifecycle.switch_provider(session)
    local inline_generating = false
    for _, inline_session in pairs(session._inline_sessions or {}) do
        if inline_session.is_generating then
            inline_generating = true
            break
        end
    end

    if session.is_generating or inline_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    local AgentInstance = require("agentic.acp.agent_instance")

    local persisted_session = session.session_state:get_persisted_session_data()
    local old_agent = session.agent
    local old_session_id = session.session_id

    local new_agent = AgentInstance.get_instance(
        Config.provider,
        function(client)
            vim.schedule(function()
                session.agent = client

                session:new_session({
                    restore_mode = true,
                    on_created = function()
                        session.session_state:dispatch(
                            SessionEvents.load_persisted_session(
                                persisted_session,
                                {
                                    preserve_session_id = true,
                                    preserve_timestamp = true,
                                }
                            )
                        )
                        if
                            get_session_method(
                                session,
                                "_render_window_headers"
                            )
                        then
                            call_session_method(
                                session,
                                "_render_window_headers"
                            )
                        end
                        session._restored_turns_to_send =
                            vim.deepcopy(persisted_session.turns or {})
                        session._is_first_message = true
                    end,
                })
            end)
        end
    )

    if not new_agent then
        return
    end

    SessionLifecycle.cancel_inline(session)

    if old_session_id then
        old_agent:cancel_session(old_session_id)
    end
    session.session_id = nil
    session._agent_phase = nil
    session._session_starting = false
    if get_session_method(session, "_clear_inline_chat") then
        call_session_method(session, "_clear_inline_chat")
    end
    if get_session_method(session, "_clear_chat_activity") then
        call_session_method(session, "_clear_chat_activity")
    elseif session.status_animation and session.status_animation.stop then
        session.status_animation:stop()
    end
    session.permission_manager:clear()
    session.todo_list:clear()
    session.agent = new_agent
end

--- @param session agentic.SessionManager
--- @param persisted_session agentic.session.PersistedSession|agentic.session.PersistedSession.StorageData
--- @param opts {reuse_session?: boolean}|nil
function SessionLifecycle.restore_session_data(session, persisted_session, opts)
    opts = opts or {}

    session._restoring = true
    session._restored_turns_to_send =
        vim.deepcopy(persisted_session.turns or {})
    session._is_first_message = false

    if opts.reuse_session then
        session.session_state:dispatch(
            SessionEvents.load_persisted_session(persisted_session, {
                preserve_session_id = true,
                preserve_timestamp = true,
                preserve_current_mode_id = true,
            })
        )
    else
        session.session_state:replace_persisted_session_data(persisted_session)
    end

    if opts.reuse_session and session.session_id then
        session._restoring = false
        session._restored_turns_to_send = nil
        return
    end

    session:new_session({
        restore_mode = true,
        on_created = function()
            session._restoring = false
        end,
    })
end

return SessionLifecycle
