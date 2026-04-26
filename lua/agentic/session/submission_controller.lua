---@diagnostic disable: invisible
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local PromptBuilder = require("agentic.session.prompt_builder")
local SessionEvents = require("agentic.session.session_events")
local SlashCommands = require("agentic.acp.slash_commands")

--- UI Sync Scopes
--- - Session-local: submission preparation, queue ordering, request dispatch
--- - Tab-local UI updates are delegated back through SessionManager widget methods

--- @param response agentic.acp.PromptResponse|nil
--- @param err table|nil
--- @return {stop_reason?: agentic.acp.StopReason|nil, timestamp: integer, error_text?: string|nil}
local function build_turn_result_message(response, err)
    local turn_result = {
        stop_reason = response and response.stopReason or nil,
        timestamp = os.time(),
        error_text = nil,
    }

    if err then
        turn_result.error_text = vim.inspect(err)
    end

    return turn_result
end

--- @param hook_name "on_prompt_submit"|"on_response_complete"
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

local get_session_method
local call_session_method

--- @param session agentic.SessionManager
local function render_window_headers(session)
    if get_session_method(session, "_render_window_headers") then
        call_session_method(session, "_render_window_headers")
        return
    end

    require("agentic.session.widget_binding").render_window_headers(session)
end

--- @param session agentic.SessionManager
local function refresh_chat_activity(session)
    if get_session_method(session, "_refresh_chat_activity") then
        call_session_method(session, "_refresh_chat_activity")
        return
    end

    require("agentic.session.widget_binding").refresh_chat_activity(session)
end

local SubmissionController = {}

--- @param session agentic.SessionManager
--- @return string|nil
local function get_active_generation_session_id(session)
    if session.is_generating and session.session_id then
        return session.session_id
    end

    for _, inline_session in pairs(session["_inline_sessions"] or {}) do
        if inline_session.is_generating and inline_session.session_id then
            return inline_session.session_id
        end
    end

    return session.session_id
end

--- @param session agentic.SessionManager
--- @param surface "chat"|"inline"
--- @return string
local function next_turn_id(session, surface)
    session["_next_interaction_turn_id"] = (
        session["_next_interaction_turn_id"] or 0
    ) + 1
    return string.format("%s-%d", surface, session["_next_interaction_turn_id"])
end

--- @param session agentic.SessionManager
--- @return string
local function next_inline_conversation_id(session)
    session["_next_inline_conversation_id"] = (
        session["_next_inline_conversation_id"] or 0
    ) + 1
    return string.format(
        "inline-conversation-%d",
        session["_next_inline_conversation_id"]
    )
end

--- @param session agentic.SessionManager
--- @param conversation_id string
--- @return agentic.SessionManager.InlineSession|nil
local function get_inline_session(session, conversation_id)
    return session["_inline_sessions"]
            and session["_inline_sessions"][conversation_id]
        or nil
end

--- @param session agentic.SessionManager
--- @param conversation_id string
--- @return boolean
local function inline_conversation_is_generating(session, conversation_id)
    local inline_session = get_inline_session(session, conversation_id)
    return inline_session ~= nil and inline_session.is_generating == true
end

--- @param session agentic.SessionManager
--- @param submission agentic.SessionManager.QueuedSubmission
local function enqueue_inline_submission(session, submission)
    local inline_request = submission.inline_request
    if not inline_request then
        return
    end

    local conversation_id = inline_request.conversation_id
    if conversation_id == nil or conversation_id == "" then
        return
    end

    session["_next_inline_submission_id"] = (
        session["_next_inline_submission_id"] or 0
    ) + 1
    submission.id = session["_next_inline_submission_id"]

    local queues = session["_inline_submission_queues"] or {}
    local queue = queues[conversation_id] or {}
    queue[#queue + 1] = submission
    queues[conversation_id] = queue
    session["_inline_submission_queues"] = queues

    if session.inline_chat and session.inline_chat.queue_request then
        session.inline_chat:queue_request({
            conversation_id = conversation_id,
            submission_id = submission.id,
            prompt = inline_request.prompt,
            selection = inline_request.selection,
            source_bufnr = inline_request.source_bufnr,
            source_winid = inline_request.source_winid,
        })
    end
end

--- @param session agentic.SessionManager
--- @param conversation_id string
local function drain_inline_submission_queue(session, conversation_id)
    if inline_conversation_is_generating(session, conversation_id) then
        return
    end

    local queues = session["_inline_submission_queues"] or {}
    local queue = queues[conversation_id]
    if queue == nil or #queue == 0 then
        queues[conversation_id] = nil
        session["_inline_submission_queues"] = queues
        return
    end

    local next_submission = table.remove(queue, 1)
    if #queue == 0 then
        queues[conversation_id] = nil
    end
    session["_inline_submission_queues"] = queues

    call_session_method(session, "_dispatch_submission", next_submission)
end

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
get_session_method = function(session, method_name)
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
call_session_method = function(session, method_name, ...)
    local method = get_session_method(session, method_name)
    if method then
        return method(session, ...)
    end

    return nil
end

--- @param session agentic.SessionManager
--- @param input_text string
function SubmissionController.attach_mentioned_files(session, input_text)
    if not session.file_picker or not session.file_list then
        return
    end

    for _, file_path in
        ipairs(session.file_picker:resolve_mentioned_file_paths(input_text))
    do
        session.file_list:add(file_path)
    end
end

--- @param session agentic.SessionManager
--- @param input_text string
--- @param opts {code_selection?: agentic.ui.CodeSelection|nil, file_list?: agentic.ui.FileList|nil, diagnostics_list?: agentic.ui.DiagnosticsList|nil, chat_winid?: integer|nil, selections?: agentic.Selection[]|nil, inline_instructions?: string|nil, surface?: "chat"|"inline"|nil, include_system_info?: boolean|nil, use_session_context?: boolean|nil}
--- @return agentic.SessionManager.QueuedSubmission
function SubmissionController.prepare_submission(session, input_text, opts)
    opts = opts or {}

    local use_session_context = opts.use_session_context ~= false
    local restored_turns_to_send = use_session_context
            and session["_restored_turns_to_send"]
        or nil
    local include_system_info = opts.include_system_info
    if include_system_info == nil then
        if use_session_context then
            include_system_info = session["_is_first_message"]
        else
            include_system_info = true
        end
    end

    local should_set_title = restored_turns_to_send
        or session.session_state:get_state().session.title == ""
    if should_set_title then
        session.session_state:dispatch(
            SessionEvents.set_session_title(input_text)
        )
        call_session_method(session, "_render_window_headers")
    end

    local built_submission = PromptBuilder.build_submission({
        input_text = input_text,
        provider_name = session.agent.provider_config.name,
        restored_turns_to_send = restored_turns_to_send,
        include_system_info = include_system_info,
        code_selection = opts.code_selection,
        file_list = opts.file_list,
        diagnostics_list = opts.diagnostics_list,
        chat_winid = opts.chat_winid,
        selections = opts.selections,
        inline_instructions = opts.inline_instructions,
        surface = opts.surface,
    })

    if use_session_context and built_submission.consumed_restored_turns then
        session["_restored_turns_to_send"] = nil
    end

    if use_session_context and built_submission.consumed_first_message then
        session["_is_first_message"] = false
    end

    --- @type agentic.SessionManager.QueuedSubmission
    local submission = {
        id = 0,
        turn_id = next_turn_id(session, opts.surface or "chat"),
        input_text = input_text,
        prompt = built_submission.prompt,
        request = built_submission.request,
    }
    submission.request.turn_id = submission.turn_id

    return submission
end

--- @param session agentic.SessionManager
--- @param submission agentic.SessionManager.QueuedSubmission
function SubmissionController.enqueue_submission(session, submission)
    local was_visible = session.submission_queue:count() > 0
    local submission_id = session.submission_queue:enqueue(submission)

    if submission.inline_request and session.inline_chat then
        session.inline_chat:queue_request({
            submission_id = submission_id,
            prompt = submission.inline_request.prompt,
            selection = submission.inline_request.selection,
            source_bufnr = submission.inline_request.source_bufnr,
            source_winid = submission.inline_request.source_winid,
        })
    end

    call_session_method(session, "_sync_queue_panel", was_visible)
    call_session_method(session, "_sync_inline_queue_states")

    Logger.notify(
        "Queued follow-up. It will be sent when the agent is ready.",
        vim.log.levels.INFO,
        { title = "Agentic Queue" }
    )
end

--- @param session agentic.SessionManager
function SubmissionController.drain_queued_submissions(session)
    if session.is_generating or not session.session_id then
        return
    end

    local was_visible = session.submission_queue:count() > 0
    local next_submission = session.submission_queue:pop_next()
    call_session_method(session, "_sync_queue_panel", was_visible)
    call_session_method(session, "_sync_inline_queue_states")

    if next_submission then
        call_session_method(session, "_dispatch_submission", next_submission)
    end
end

--- @param session agentic.SessionManager
--- @param submission_id integer
function SubmissionController.remove_queued_submission(session, submission_id)
    local was_visible = session.submission_queue:count() > 0
    local removed_submission = session.submission_queue:remove(submission_id)
    if not removed_submission then
        return
    end

    if removed_submission.inline_request and session.inline_chat then
        session.inline_chat:remove_queued_submission(removed_submission.id)
    end

    call_session_method(session, "_sync_queue_panel", was_visible)
    call_session_method(session, "_sync_inline_queue_states")
end

--- @param session agentic.SessionManager
--- @param submission_id integer
function SubmissionController.steer_queued_submission(session, submission_id)
    local submission = session.submission_queue:prioritize(submission_id)
    if not submission then
        return
    end

    call_session_method(session, "_sync_queue_panel", true)
    call_session_method(session, "_sync_inline_queue_states")

    if not session.is_generating then
        call_session_method(session, "_drain_queued_submissions")
    end
end

--- @param session agentic.SessionManager
--- @param submission_id integer
function SubmissionController.send_queued_submission_now(session, submission_id)
    if session.is_generating then
        local was_visible = session.submission_queue:count() > 0
        local submission =
            session.submission_queue:interrupt_with(submission_id)
        call_session_method(session, "_sync_queue_panel", was_visible)
        if not submission then
            return
        end

        call_session_method(session, "_sync_inline_queue_states")
        local target_session_id = get_active_generation_session_id(session)
        if target_session_id then
            session.agent:stop_generation(target_session_id)
        end
        return
    end

    local was_visible = session.submission_queue:count() > 0
    local submission = session.submission_queue:remove(submission_id)
    call_session_method(session, "_sync_queue_panel", was_visible)
    if not submission then
        return
    end

    call_session_method(session, "_sync_inline_queue_states")
    call_session_method(session, "_dispatch_submission", submission)
end

--- @param session agentic.SessionManager
function SubmissionController.sync_inline_queue_states(session)
    if not session.inline_chat or not session.submission_queue then
        return
    end

    session.inline_chat:sync_queued_requests(session.submission_queue:list(), {
        waiting_for_session = session.session_id == nil,
        interrupt_submission = session.submission_queue:get_interrupt_submission(),
    })
end

--- @param session agentic.SessionManager
--- @param input_text string
function SubmissionController.handle_input_submit(session, input_text)
    session.todo_list:close_if_all_completed()

    local prompt_bufnr = session.widget
            and session.widget.buf_nrs
            and session.widget.buf_nrs.input
        or nil
    local command_name = SlashCommands.get_input_command_name(input_text)

    if command_name == "new" then
        session:new_session()
        return
    end

    if get_session_method(session, "_handle_local_slash_command") then
        local handled = call_session_method(
            session,
            "_handle_local_slash_command",
            input_text
        )
        if handled then
            return
        end
    end

    if prompt_bufnr then
        input_text = SlashCommands.normalize_input(prompt_bufnr, input_text)
    end

    if not session.session_id then
        call_session_method(session, "_with_active_session", function()
            call_session_method(session, "_handle_input_submit", input_text)
        end)
        return
    end

    if get_session_method(session, "_attach_mentioned_files") then
        call_session_method(session, "_attach_mentioned_files", input_text)
    end

    local submission =
        call_session_method(session, "_prepare_submission", input_text, {
            code_selection = session.code_selection,
            file_list = session.file_list,
            diagnostics_list = session.diagnostics_list,
            chat_winid = session.widget.win_nrs.chat,
        })

    if session.is_generating then
        call_session_method(session, "_enqueue_submission", submission)
        return
    end

    call_session_method(session, "_dispatch_submission", submission)
end

--- @param session agentic.SessionManager
--- @param submission agentic.SessionManager.QueuedSubmission
function SubmissionController.dispatch_submission(session, submission)
    local inline_request = submission.inline_request
    if inline_request ~= nil then
        local conversation_id = inline_request.conversation_id
        if conversation_id == nil or conversation_id == "" then
            conversation_id = next_inline_conversation_id(session)
            inline_request.conversation_id = conversation_id
        end
        local inline_prompt = inline_request.prompt
        local inline_selection = inline_request.selection
        local inline_source_bufnr = inline_request.source_bufnr
        local inline_source_winid = inline_request.source_winid

        if inline_conversation_is_generating(session, conversation_id) then
            enqueue_inline_submission(session, submission)
            return
        end

        call_session_method(
            session,
            "_with_active_inline_session",
            conversation_id,
            function(target_session_id)
                local inline_session =
                    get_inline_session(session, conversation_id)
                if inline_session == nil then
                    return
                end

                if
                    session.inline_chat and session.inline_chat.begin_request
                then
                    session.inline_chat:begin_request({
                        conversation_id = conversation_id,
                        submission_id = submission.id,
                        prompt = inline_prompt,
                        selection = inline_selection,
                        source_bufnr = inline_source_bufnr,
                        source_winid = inline_source_winid,
                        phase = "thinking",
                        status_text = "Preparing inline request",
                    })
                end

                session.session_state:dispatch(
                    SessionEvents.append_interaction_request(submission.request)
                )

                invoke_hook("on_prompt_submit", {
                    prompt = submission.input_text,
                    session_id = target_session_id,
                    tab_page_id = session.tab_page_id,
                })

                local session_id = target_session_id
                local tab_page_id = session.tab_page_id
                local turn_id = submission.turn_id
                inline_session.is_generating = true
                inline_session.active_turn_id = turn_id
                inline_session.awaiting_rejected_followup = false
                inline_session.close_on_complete = false

                session.agent:send_prompt(
                    target_session_id,
                    submission.prompt,
                    function(response, err)
                        local prompt_response = response
                        --- @cast prompt_response agentic.acp.PromptResponse|nil
                        vim.schedule(function()
                            local current_inline_session =
                                get_inline_session(session, conversation_id)

                            if current_inline_session then
                                current_inline_session.is_generating = false
                            end

                            session.session_state:dispatch(
                                SessionEvents.set_interaction_turn_result(
                                    build_turn_result_message(
                                        prompt_response,
                                        err
                                    ),
                                    session.agent.provider_config.name,
                                    { turn_id = turn_id }
                                )
                            )

                            invoke_hook("on_response_complete", {
                                session_id = session_id,
                                tab_page_id = tab_page_id,
                                success = err == nil,
                                error = err,
                            })

                            if session.inline_chat then
                                session.inline_chat:complete(
                                    prompt_response,
                                    err,
                                    { conversation_id = conversation_id }
                                )
                            end

                            local should_close = true
                            if current_inline_session then
                                should_close = current_inline_session.close_on_complete
                                    or not current_inline_session.awaiting_rejected_followup
                            end

                            if should_close then
                                call_session_method(
                                    session,
                                    "_cancel_inline_session",
                                    conversation_id
                                )
                            else
                                drain_inline_submission_queue(
                                    session,
                                    conversation_id
                                )
                            end

                            if not err then
                                session.session_state:save_persisted_session_data(
                                    function(save_err)
                                        if save_err then
                                            Logger.debug(
                                                "Chat history save error:",
                                                save_err
                                            )
                                        end
                                    end
                                )
                            end
                        end)
                    end
                )
            end
        )
        return
    end

    local target_session_id = session.session_id

    if not target_session_id then
        call_session_method(session, "_with_active_session", function()
            call_session_method(session, "_dispatch_submission", submission)
        end)
        return
    end

    session.session_state:dispatch(
        SessionEvents.append_interaction_request(submission.request)
    )

    invoke_hook("on_prompt_submit", {
        prompt = submission.input_text,
        session_id = target_session_id,
        tab_page_id = session.tab_page_id,
    })

    local session_id = target_session_id
    local tab_page_id = session.tab_page_id
    local turn_id = submission.turn_id
    session.is_generating = true
    session["_active_chat_turn_id"] = turn_id
    session["_agent_phase"] = "thinking"
    render_window_headers(session)
    refresh_chat_activity(session)

    session.agent:send_prompt(
        target_session_id,
        submission.prompt,
        function(response, err)
            local prompt_response = response
            --- @cast prompt_response agentic.acp.PromptResponse|nil
            vim.schedule(function()
                session.is_generating = false
                session["_active_chat_turn_id"] = nil
                session["_agent_phase"] = nil

                session.session_state:dispatch(
                    SessionEvents.set_interaction_turn_result(
                        build_turn_result_message(prompt_response, err),
                        session.agent.provider_config.name,
                        { turn_id = turn_id }
                    )
                )
                refresh_chat_activity(session)

                invoke_hook("on_response_complete", {
                    session_id = session_id,
                    tab_page_id = tab_page_id,
                    success = err == nil,
                    error = err,
                })

                if not err then
                    session.session_state:save_persisted_session_data(
                        function(save_err)
                            if save_err then
                                Logger.debug(
                                    "Chat history save error:",
                                    save_err
                                )
                            end
                        end
                    )
                end

                call_session_method(session, "_drain_queued_submissions")
            end)
        end
    )
end

--- @param session agentic.SessionManager
--- @param request {conversation_id?: string|nil, prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}
--- @return boolean accepted
function SubmissionController.submit_inline_request(session, request)
    local conversation_id = request.conversation_id
    if conversation_id == nil or conversation_id == "" then
        conversation_id = next_inline_conversation_id(session)
    end

    local submission =
        call_session_method(session, "_prepare_submission", request.prompt, {
            selections = { request.selection },
            inline_instructions = PromptBuilder.build_inline_instructions(),
            surface = "inline",
            include_system_info = true,
            use_session_context = false,
        })
    submission.inline_request = {
        conversation_id = conversation_id,
        prompt = request.prompt,
        selection = request.selection,
        source_bufnr = request.source_bufnr,
        source_winid = request.source_winid,
    }

    if inline_conversation_is_generating(session, conversation_id) then
        enqueue_inline_submission(session, submission)
        return true
    end

    call_session_method(session, "_dispatch_submission", submission)
    return true
end

return SubmissionController
