local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionEvents = require("agentic.session.session_events")
local SessionSelectors = require("agentic.session.session_selectors")
local SlashCommands = require("agentic.acp.slash_commands")

local SessionLifecycle = {}

--- @param session agentic.SessionManager
--- @param method_name string
--- @param ... any
local function call_session_method(session, method_name, ...)
    local method = session[method_name]
    if type(method) == "function" then
        return method(session, ...)
    end
end

--- @param session agentic.SessionManager
--- @param field_name string
--- @param value any
local function set_session_field(session, field_name, value)
    rawset(session, field_name, value)
end

--- @param session agentic.SessionManager
local function clear_chat_activity(session)
    if rawget(session, "_clear_chat_activity") ~= nil then
        call_session_method(session, "_clear_chat_activity")
        return
    end

    if session.status_animation and session.status_animation.stop then
        session.status_animation:stop()
    end
end

--- @param session agentic.SessionManager
--- @return agentic.acp.ClientHandlers
local function build_handlers(session)
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
            call_session_method(session, "_on_session_update", update)
        end,

        on_tool_call = function(tool_call)
            call_session_method(session, "_on_tool_call", tool_call)
        end,

        on_tool_call_update = function(tool_call_update)
            call_session_method(
                session,
                "_on_tool_call_update",
                tool_call_update
            )
        end,

        on_request_permission = function(request, callback)
            call_session_method(
                session,
                "_handle_permission_request",
                request,
                callback
            )
        end,
    }
end

--- @param session agentic.SessionManager
function SessionLifecycle.cancel(session)
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
    set_session_field(session, "_agent_phase", nil)
    set_session_field(session, "_session_starting", false)
    call_session_method(session, "_clear_inline_chat")
    clear_chat_activity(session)
    session.permission_manager:clear()
    SlashCommands.setCommands(session.widget.buf_nrs.input, {})

    session.session_state:replace_persisted_session_data()
    set_session_field(session, "_restored_turns_to_send", nil)
    local was_visible = session.submission_queue:clear()
    call_session_method(session, "_sync_queue_panel", was_visible)
end

--- @param session agentic.SessionManager
--- @param opts {restore_mode?: boolean, on_created?: fun()}|nil
function SessionLifecycle.start(session, opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode or false
    local on_created = opts.on_created
    if not restore_mode then
        SessionLifecycle.cancel(session)
    end

    set_session_field(session, "_session_starting", true)
    call_session_method(session, "_refresh_chat_activity")

    session.agent:create_session(
        build_handlers(session),
        function(response, err)
            set_session_field(session, "_session_starting", false)
            call_session_method(session, "_refresh_chat_activity")

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
                call_session_method(
                    session,
                    "_handle_new_config_options",
                    response.configOptions
                )
            else
                call_session_method(session, "_render_window_headers")
            end

            session.config_options:set_initial_mode(
                session.agent.provider_config.default_mode,
                function(mode)
                    call_session_method(session, "_handle_mode_change", mode)
                end
            )

            if not restore_mode then
                set_session_field(session, "_is_first_message", true)
            end

            vim.schedule(function()
                if on_created then
                    on_created()
                end
            end)
        end
    )
end

--- @param session agentic.SessionManager
function SessionLifecycle.switch_provider(session)
    if session.is_generating then
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
                        call_session_method(session, "_render_window_headers")
                        set_session_field(
                            session,
                            "_restored_turns_to_send",
                            vim.deepcopy(persisted_session.turns or {})
                        )
                        set_session_field(session, "_is_first_message", true)
                    end,
                })
            end)
        end
    )

    if not new_agent then
        return
    end

    if old_session_id then
        old_agent:cancel_session(old_session_id)
    end
    session.session_id = nil
    set_session_field(session, "_agent_phase", nil)
    set_session_field(session, "_session_starting", false)
    call_session_method(session, "_clear_inline_chat")
    clear_chat_activity(session)
    session.permission_manager:clear()
    session.todo_list:clear()
    session.agent = new_agent
end

--- @param session agentic.SessionManager
--- @param persisted_session agentic.session.PersistedSession|agentic.session.PersistedSession.StorageData
--- @param opts {reuse_session?: boolean}|nil
function SessionLifecycle.restore_session_data(session, persisted_session, opts)
    opts = opts or {}

    set_session_field(session, "_restoring", true)
    set_session_field(
        session,
        "_restored_turns_to_send",
        vim.deepcopy(persisted_session.turns or {})
    )
    set_session_field(session, "_is_first_message", false)

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
        set_session_field(session, "_restoring", false)
        set_session_field(session, "_restored_turns_to_send", nil)
        return
    end

    session:new_session({
        restore_mode = true,
        on_created = function()
            set_session_field(session, "_restoring", false)
        end,
    })
end

return SessionLifecycle
