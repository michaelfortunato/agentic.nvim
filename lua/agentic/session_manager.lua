local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SessionEvents = require("agentic.session.session_events")
local SessionRestore = require("agentic.session_restore")
local SessionSelectors = require("agentic.session.session_selectors")
local SessionState = require("agentic.session.session_state")
local SlashCommands = require("agentic.acp.slash_commands")

--- Tool call kinds that mutate files on disk.
--- When these complete, buffers must be reloaded via checktime.
local FILE_MUTATING_KINDS = {
    edit = true,
    create = true,
    write = true,
    delete = true,
    move = true,
}

local SEARCH_LIKE_TOOL_KINDS = {
    fetch = true,
    find = true,
    glob = true,
    grep = true,
    list = true,
    ls = true,
    read = true,
    search = true,
}

--- @param kind string|nil
--- @return boolean
local function is_search_like_tool_kind(kind)
    if type(kind) ~= "string" then
        return false
    end

    kind = kind:lower()
    if SEARCH_LIKE_TOOL_KINDS[kind] then
        return true
    end

    return kind:find("search", 1, true) ~= nil
        or kind:find("grep", 1, true) ~= nil
        or kind:find("glob", 1, true) ~= nil
        or kind:find("read", 1, true) ~= nil
        or kind:find("fetch", 1, true) ~= nil
end

--- @param label string
--- @param value string
--- @return string
local function build_meta_line(label, value)
    return string.format("%s · %s", label, value)
end

--- @param input_text string
--- @return string|nil
local function parse_review_prompt(input_text)
    local review_body = input_text:match("^/review%s*(.*)$")
    if review_body == nil then
        return nil
    end

    return review_body:match("^%s*(.-)%s*$")
end

--- @param input_text string
--- @param timestamp string
--- @return string[]
local function build_user_message_lines(input_text, timestamp)
    local review_body = parse_review_prompt(input_text)
    if review_body ~= nil then
        local lines = {
            build_meta_line("Review", timestamp),
        }

        if review_body ~= "" then
            lines[#lines + 1] = review_body
        end

        return lines
    end

    return {
        build_meta_line("User", timestamp),
        input_text,
    }
end

--- @param hook_name "on_prompt_submit" | "on_response_complete" | "on_session_update"
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

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.ui.ChatHistory.ToolCall
local function as_transcript_tool_call(tool_call)
    return vim.tbl_deep_extend("force", {
        type = "tool_call",
    }, tool_call)
end

--- @param session agentic.SessionManager
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
local function upsert_tool_call_block(session, tool_call)
    if session.message_writer.tool_call_blocks[tool_call.tool_call_id] then
        session.message_writer:update_tool_call_block(tool_call)
        return
    end

    session.message_writer:write_tool_call_block(tool_call)
end

--- @param session agentic.SessionManager
--- @param response agentic.acp.PromptResponse|nil
--- @param err table|nil
local function write_turn_complete(session, response, err)
    local finish_message =
        build_meta_line("Turn complete", os.date("%Y-%m-%d %H:%M:%S"))

    if err then
        finish_message = string.format(
            "%s\n%s\n%s",
            build_meta_line("Agent error", "details below"),
            vim.inspect(err),
            finish_message
        )
    elseif response and response.stopReason == "cancelled" then
        finish_message = string.format(
            "\n%s\n%s",
            build_meta_line("Stopped", "user request"),
            finish_message
        )
    end

    session.message_writer:write_message(
        ACPPayloads.generate_agent_message(finish_message)
    )
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

--- @class agentic.SessionManager.QueuedSubmission
--- @field id integer
--- @field input_text string
--- @field prompt agentic.acp.Content[]
--- @field message_lines string[]
--- @field user_msg agentic.ui.ChatHistory.UserMessage

--- @class agentic.SessionManager
--- @field session_id? string
--- @field tab_page_id integer
--- @field _is_first_message boolean Whether this is the first message in the session, used to add system info only once
--- @field is_generating boolean
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field review_controller agentic.ui.ReviewController
--- @field status_animation agentic.ui.StatusAnimation
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field diagnostics_list agentic.ui.DiagnosticsList
--- @field config_options agentic.acp.AgentConfigOptions
--- @field todo_list agentic.ui.TodoList
--- @field chat_history agentic.ui.ChatHistory
--- @field session_state agentic.session.SessionState
--- @field _queued_submissions agentic.SessionManager.QueuedSubmission[]
--- @field _next_queue_id integer
--- @field _interrupt_submission? agentic.SessionManager.QueuedSubmission
--- @field _history_to_send? agentic.ui.ChatHistory.Message[] Messages to prepend on next prompt submit
--- @field _restoring boolean Flag to prevent auto-new_session during restore
--- @field _agent_phase? agentic.Theme.SpinnerState
--- @field _session_starting boolean
local SessionManager = {}
SessionManager.__index = SessionManager

--- @param provider_name string
--- @param session_id string|nil
--- @param version string|nil
--- @return string header
function SessionManager._generate_welcome_header(
    provider_name,
    session_id,
    version
)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local name = provider_name
    if version then
        name = name .. " v" .. version
    end
    return string.format(
        "Agentic · %s\nSession · %s\nStarted · %s",
        name,
        session_id or "unknown",
        timestamp
    )
end

--- @param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local BufHelpers = require("agentic.utils.buf_helpers")
    local ChatWidget = require("agentic.ui.chat_widget")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local FilePicker = require("agentic.ui.file_picker")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local ReviewController = require("agentic.ui.review_controller")
    local QueueList = require("agentic.ui.queue_list")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")
    local AgentConfigOptions = require("agentic.acp.agent_config_options")

    self = setmetatable({
        session_id = nil,
        tab_page_id = tab_page_id,
        _is_first_message = true,
        is_generating = false,
        _restoring = false,
        _queued_submissions = {},
        _next_queue_id = 0,
        _interrupt_submission = nil,
        _agent_phase = nil,
        _session_starting = false,
    }, self)

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            -- Skip auto-new_session if restore_from_history was called
            if not self._restoring then
                self:new_session()
            end
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.session_state = SessionState:new()
    self.chat_history = self.session_state:get_history()

    self.widget = ChatWidget:new(tab_page_id, function(input_text)
        self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat, {
        should_auto_scroll = function()
            return self.widget:should_follow_chat_output()
        end,
        scroll_to_bottom = function()
            self.widget:scroll_chat_to_bottom()
        end,
    })
    self.widget:bind_message_writer(self.message_writer)
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.permission_manager = PermissionManager:new(self.session_state)
    self.review_controller =
        ReviewController:new(self.session_state, self.widget)
    self.queue_list = QueueList:new(self.widget.buf_nrs.queue, {
        on_steer = function(submission_id)
            self:_steer_queued_submission(submission_id)
        end,
        on_send_now = function(submission_id)
            self:_send_queued_submission_now(submission_id)
        end,
        on_remove = function(submission_id)
            self:_remove_queued_submission(submission_id)
        end,
        on_cancel = function()
            self.widget:focus_input()
        end,
    })

    FilePicker:new(self.widget.buf_nrs.input, {
        resolve_root = function()
            return self:_get_workspace_root()
        end,
    })
    SlashCommands.setup_completion(self.widget.buf_nrs.input)

    self.config_options = AgentConfigOptions:new(
        self.widget.buf_nrs,
        function(mode_id, is_legacy)
            self:_handle_mode_change(mode_id, is_legacy)
        end,
        function(model_id, is_legacy)
            self:_handle_model_change(model_id, is_legacy)
        end,
        function(config_id, value)
            self:_handle_config_option_change(config_id, value)
        end
    )

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_optional_window("files")
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget:render_header("files", tostring(#file_list:get_files()))
            self.widget:show({ focus_prompt = false })
        end
    end)

    self.code_selection = CodeSelection:new(
        self.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                self.widget:close_optional_window("code")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget:render_header(
                    "code",
                    tostring(#code_selection:get_selections())
                )
                self.widget:show({ focus_prompt = false })
            end
        end
    )

    self.diagnostics_list = DiagnosticsList:new(
        self.widget.buf_nrs.diagnostics,
        function(diagnostics_list)
            if diagnostics_list:is_empty() then
                self.widget:close_optional_window("diagnostics")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                -- show() opens layouts but does not update the diagnostics header count
                self.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                self.widget:show({ focus_prompt = false })
            end
        end
    )

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() then
            self.widget:show({ focus_prompt = false })
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    for _, bufnr in pairs(self.widget.buf_nrs) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.manage_queue,
            bufnr,
            function()
                self:_focus_queue_panel()
            end,
            { desc = "Agentic: Manage queued messages" }
        )
    end

    return self
end

--- @param state agentic.Theme.SpinnerState
function SessionManager:_set_chat_activity(state)
    if not self.status_animation or not self.status_animation.start then
        return
    end

    self.status_animation:start(state)
end

function SessionManager:_clear_chat_activity()
    if self.status_animation and self.status_animation.stop then
        self.status_animation:stop()
    end
end

--- @return agentic.Theme.SpinnerState|nil
function SessionManager:_get_active_tool_activity()
    if not self.session_state then
        return nil
    end

    local state = self.session_state:get_state()
    local tool_calls = SessionSelectors.get_tool_calls(state)

    for i = #tool_calls, 1, -1 do
        local tool_call = tool_calls[i]
        if
            tool_call
            and (tool_call.status == "pending"
                or tool_call.status == "in_progress")
        then
            if is_search_like_tool_kind(tool_call.kind) then
                return "searching"
            end

            return "generating"
        end
    end

    return nil
end

function SessionManager:_refresh_chat_activity()
    if self._session_starting then
        SessionManager._set_chat_activity(self, "busy")
        return
    end

    if self.session_state then
        local state = self.session_state:get_state()
        if SessionSelectors.has_pending_permissions(state) then
            SessionManager._set_chat_activity(self, "waiting")
            return
        end
    end

    if not self.is_generating then
        SessionManager._clear_chat_activity(self)
        return
    end

    local tool_activity = SessionManager._get_active_tool_activity(self)
    if tool_activity then
        SessionManager._set_chat_activity(self, tool_activity)
        return
    end

    SessionManager._set_chat_activity(self, self._agent_phase or "thinking")
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    if update.sessionUpdate == "agent_message_chunk" then
        self.message_writer:write_message_chunk(vim.tbl_extend("force", {}, update, {
            is_agent_reply = true,
            provider_name = self.agent.provider_config.name,
        }))
        self._agent_phase = "generating"
        SessionManager._refresh_chat_activity(self)

        if update.content and update.content.text then
            self.session_state:dispatch(SessionEvents.append_agent_text({
                type = "agent",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            }))
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self.message_writer:write_message_chunk(update)
        self._agent_phase = "thinking"
        SessionManager._refresh_chat_activity(self)

        if update.content and update.content.text then
            self.session_state:dispatch(SessionEvents.append_agent_text({
                type = "thought",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            }))
        end
    elseif update.sessionUpdate == "session_info_update" then
        if update.title ~= nil then
            self.session_state:dispatch(
                SessionEvents.set_session_title(update.title or "")
            )
            self:_render_window_headers()
        end
    elseif update.sessionUpdate == "plan" then
        if Config.windows.todos.display then
            self.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "available_commands_update" then
        SlashCommands.setCommands(
            self.widget.buf_nrs.input,
            update.availableCommands
        )
    elseif update.sessionUpdate == "current_mode_update" then
        -- only for legacy modes, not for config_options
        if
            self.config_options.legacy_agent_modes:handle_agent_update_mode(
                update.currentModeId
            )
        then
            self:_render_window_headers()
        end
    elseif update.sessionUpdate == "config_option_update" then
        self:_handle_new_config_options(update.configOptions)
    elseif update.sessionUpdate == "usage_update" then
        -- Usage updates contain token/cost information - currently informational only
        -- Fields: used (tokens), size (context window), cost (optional: amount, currency)
        -- Keeping silent for now to avoid "press any key" prompts on large JSON output
    else
        -- TODO: Move this to Logger from notify to debug when confidence is high
        Logger.notify(
            "Unknown session update type: "
                .. tostring(
                    --- @diagnostic disable-next-line: undefined-field -- expected it to be unknown
                    update.sessionUpdate
                ),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end

    invoke_hook("on_session_update", {
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
        update = update,
    })
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call(tool_call)
    dispatch_state_events(self, {
        SessionEvents.upsert_tool_call(tool_call),
        SessionEvents.upsert_transcript_tool_call(
            as_transcript_tool_call(tool_call)
        ),
    })
    upsert_tool_call_block(self, tool_call)
    SessionManager._refresh_chat_activity(self)
end

--- Handle tool call update: update UI, history, diff preview, permissions, and reload buffers
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call_update(tool_call_update)
    dispatch_state_events(self, {
        SessionEvents.upsert_tool_call(tool_call_update),
        SessionEvents.upsert_transcript_tool_call(
            as_transcript_tool_call(tool_call_update)
        ),
        SessionEvents.clear_review_target(
            tool_call_update.tool_call_id,
            tool_call_update.status == "failed"
        ),
    })
    upsert_tool_call_block(self, tool_call_update)

    if tool_call_update.status == "failed" then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    SessionManager._refresh_chat_activity(self)

    -- Reload buffers when file-mutating tool calls complete
    if tool_call_update.status == "completed" then
        local tracker =
            self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]

        if tracker and tracker.kind and FILE_MUTATING_KINDS[tracker.kind] then
            vim.cmd.checktime()
        end
    end
end

--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function SessionManager:_handle_permission_request(request, callback)
    local tool_call_id = request.toolCall.toolCallId

    local wrapped_callback = function(option_id)
        local permission_state = "dismissed"

        if option_id == "allow_once" or option_id == "allow_always" then
            permission_state = "approved"
        elseif option_id == "reject_once" or option_id == "reject_always" then
            permission_state = "rejected"
        end

        dispatch_state_events(self, {
            SessionEvents.set_tool_permission_state(
                tool_call_id,
                permission_state
            ),
            SessionEvents.clear_review_target(
                tool_call_id,
                permission_state == "rejected"
                    or permission_state == "dismissed"
            ),
        })
        callback(option_id)
        vim.schedule(function()
            SessionManager._refresh_chat_activity(self)
        end)
    end

    dispatch_state_events(self, {
        SessionEvents.set_tool_permission_state(tool_call_id, "requested"),
        SessionEvents.set_review_target(tool_call_id),
    })
    self.permission_manager:add_request(request, wrapped_callback)
    SessionManager._refresh_chat_activity(self)
end

--- Send the newly selected mode to the agent and handle the response
--- @param mode_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_mode_change(mode_id, is_legacy)
    if not self.session_id then
        return
    end

    local function callback(result, err)
        if err then
            Logger.notify(
                string.format(
                    "Failed to change mode to '%s': %s",
                    mode_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            -- needed for backward compatibility
            self.config_options.legacy_agent_modes.current_mode_id = mode_id

            if result and result.configOptions then
                Logger.debug("received result after setting mode")
                self:_handle_new_config_options(result.configOptions)
            else
                self:_render_window_headers()
            end

            local mode_name = self.config_options:get_mode_name(mode_id)
            Logger.notify(
                with_live_config_note(
                    "Mode changed to: " .. mode_name,
                    self.is_generating
                ),
                vim.log.levels.INFO,
                {
                    title = "Agentic Mode changed",
                }
            )
        end
    end

    if is_legacy then
        self.agent:set_mode(self.session_id, mode_id, callback)
    else
        local config_id = self.config_options.mode
                and self.config_options.mode.id
            or "mode"
        self.agent:set_config_option(
            self.session_id,
            config_id,
            mode_id,
            callback
        )
    end
end

--- Send the newly selected model to the agent
--- @param model_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_model_change(model_id, is_legacy)
    if not self.session_id then
        return
    end

    local callback = function(result, err)
        if err then
            Logger.notify(
                string.format(
                    "Failed to change model to '%s': %s",
                    model_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            -- Always update legacy state on success (mirrors _handle_mode_change pattern)
            self.config_options.legacy_agent_models.current_model_id = model_id

            if result and result.configOptions then
                Logger.debug("received result after setting model")
                self:_handle_new_config_options(result.configOptions)
            else
                self:_render_window_headers()
            end

            Logger.notify(
                with_live_config_note(
                    "Model changed to: " .. model_id,
                    self.is_generating
                ),
                vim.log.levels.INFO,
                { title = "Agentic Model changed" }
            )
        end
    end

    if is_legacy then
        self.agent:set_model(self.session_id, model_id, callback)
    else
        local config_id = self.config_options.model
                and self.config_options.model.id
            or "model"
        self.agent:set_config_option(
            self.session_id,
            config_id,
            model_id,
            callback
        )
    end
end

--- Send a generic config option update to the agent
--- @param config_id string
--- @param value string
function SessionManager:_handle_config_option_change(config_id, value)
    if not self.session_id then
        return
    end

    self.agent:set_config_option(
        self.session_id,
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
                self:_handle_new_config_options(result.configOptions)
            else
                local option = self.config_options:get_config_option(config_id)
                if option then
                    option.currentValue = value
                end
                self:_render_window_headers()
            end

            local option_name =
                self.config_options:get_config_option_name(config_id)
                or config_id
            local value_name = self.config_options:get_config_value_name(
                config_id,
                value
            ) or value

            Logger.notify(
                with_live_config_note(
                    string.format("%s changed to: %s", option_name, value_name),
                    self.is_generating
                ),
                vim.log.levels.INFO,
                { title = "Agentic Config changed" }
            )
        end
    )
end

function SessionManager:_render_window_headers()
    local parts = {}
    local config_context = self.config_options:get_header_context()
    local queue_count = self._queued_submissions and #self._queued_submissions
        or 0
    if config_context and config_context ~= "" then
        parts[#parts + 1] = config_context
    end

    if queue_count > 0 then
        parts[#parts + 1] = string.format("Queue: %d", queue_count)
    end

    self.widget:render_header("chat", table.concat(parts, " | "))
    self.widget:render_header("input", "")
end

--- @param submission agentic.SessionManager.QueuedSubmission
function SessionManager:_enqueue_submission(submission)
    local was_visible = #self._queued_submissions > 0
    self._next_queue_id = self._next_queue_id + 1
    submission.id = self._next_queue_id
    self._queued_submissions[#self._queued_submissions + 1] = submission
    self:_sync_queue_panel(was_visible)

    Logger.notify(
        "Queued follow-up. It will be sent when the agent is ready.",
        vim.log.levels.INFO,
        { title = "Agentic Queue" }
    )
end

--- @return agentic.SessionManager.QueuedSubmission|nil
function SessionManager:_pop_next_queued_submission()
    if #self._queued_submissions == 0 then
        return nil
    end

    return table.remove(self._queued_submissions, 1)
end

--- @param submission_id integer
--- @return integer|nil
function SessionManager:_find_queued_submission_index(submission_id)
    for index, submission in ipairs(self._queued_submissions) do
        if submission.id == submission_id then
            return index
        end
    end

    return nil
end

function SessionManager:_drain_queued_submissions()
    if self.is_generating then
        return
    end

    local was_visible = #self._queued_submissions > 0
    local next_submission = self._interrupt_submission
    self._interrupt_submission = nil

    if not next_submission then
        next_submission = self:_pop_next_queued_submission()
    end

    self:_sync_queue_panel(was_visible)

    if next_submission then
        self:_dispatch_submission(next_submission)
    end
end

function SessionManager:_focus_queue_panel()
    if #self._queued_submissions == 0 then
        Logger.notify("Queue is empty", vim.log.levels.INFO, {
            title = "Agentic Queue",
        })
        return
    end

    self:_sync_queue_panel(#self._queued_submissions > 0)
    self.widget:show({ focus_prompt = false })
    self.widget:move_cursor_to(self.widget.win_nrs.queue)
end

--- @param submission_id integer
function SessionManager:_remove_queued_submission(submission_id)
    local submission_index = self:_find_queued_submission_index(submission_id)
    if not submission_index then
        return
    end

    local was_visible = #self._queued_submissions > 0
    table.remove(self._queued_submissions, submission_index)
    self:_sync_queue_panel(was_visible)
end

--- @param submission_id integer
function SessionManager:_steer_queued_submission(submission_id)
    local submission_index = self:_find_queued_submission_index(submission_id)
    if not submission_index then
        return
    end

    local submission = table.remove(self._queued_submissions, submission_index)
    if not submission then
        return
    end

    table.insert(self._queued_submissions, 1, submission)
    self:_sync_queue_panel(true)

    if not self.is_generating then
        self:_drain_queued_submissions()
    end
end

--- @param submission_id integer
function SessionManager:_send_queued_submission_now(submission_id)
    local submission_index = self:_find_queued_submission_index(submission_id)
    if not submission_index then
        return
    end

    local was_visible = #self._queued_submissions > 0
    local submission = table.remove(self._queued_submissions, submission_index)
    self:_sync_queue_panel(was_visible)
    if not submission then
        return
    end

    if self.is_generating then
        self._interrupt_submission = submission
        self.agent:stop_generation(self.session_id)
        return
    end

    self:_dispatch_submission(submission)
end

--- @param was_visible boolean|nil
function SessionManager:_sync_queue_panel(was_visible)
    local queue_count = #self._queued_submissions
    local is_visible = queue_count > 0
    local queue_winid = self.widget and self.widget.win_nrs
        and self.widget.win_nrs.queue
    local queue_had_focus = queue_winid
        and vim.api.nvim_win_is_valid(queue_winid)
        and vim.api.nvim_get_current_win() == queue_winid

    if self.queue_list then
        self.queue_list:set_items(self._queued_submissions)
    end

    if is_visible then
        self.widget:render_header("queue", tostring(queue_count))
    end

    self:_render_window_headers()

    if
        not self.widget
        or type(self.widget.is_open) ~= "function"
        or not self.widget:is_open()
    then
        return
    end

    if was_visible ~= nil and was_visible ~= is_visible then
        self.widget:refresh_layout({ focus_prompt = false })
        if not is_visible and queue_had_focus then
            self.widget:focus_input()
        end
        return
    end

    if is_visible then
        local resized = self.widget:resize_optional_window(
            "queue",
            Config.windows.queue.max_height
        )
        if not resized then
            self.widget:refresh_layout({ focus_prompt = false })
        end
        return
    end

    if not is_visible then
        self.widget:close_optional_window("queue")
        if queue_had_focus then
            self.widget:focus_input()
        end
    end
end

--- @param input_text string
function SessionManager:_handle_input_submit(input_text)
    self.todo_list:close_if_all_completed()

    -- Intercept /new command to start new session locally, cancelling existing one
    -- Its necessary to avoid race conditions and make sure everything is cleaned properly,
    -- the Agent might not send an identifiable response that could be acted upon
    if input_text:match("^/new%s*") then
        self:new_session()
        return
    end

    --- @type agentic.acp.Content[]
    local prompt = {}

    -- If restored/switched session, prepend history on first submit
    if self._history_to_send then
        self.session_state:dispatch(SessionEvents.set_session_title(input_text))
        self:_render_window_headers()
        ChatHistory.prepend_restored_messages(self._history_to_send, prompt)
        self._history_to_send = nil
    elseif self.chat_history.title == "" then
        self.session_state:dispatch(SessionEvents.set_session_title(input_text))
        self:_render_window_headers()
    end

    table.insert(prompt, {
        type = "text",
        text = input_text,
    })

    -- Add system info on first message only (after user text so resume picker shows the prompt)
    if self._is_first_message then
        self._is_first_message = false

        table.insert(prompt, {
            type = "text",
            text = self:_get_system_info(),
        })
    end

    --- The message to be written to the chat widget
    local message_lines =
        build_user_message_lines(input_text, os.date("%Y-%m-%d %H:%M:%S"))

    if not self.code_selection:is_empty() then
        table.insert(message_lines, "")
        table.insert(message_lines, "Code")
        table.insert(message_lines, "")

        table.insert(prompt, {
            type = "text",
            text = table.concat({
                "IMPORTANT: Focus and respect the line numbers provided in the <line_start> and <line_end> tags for each <selected_code> tag.",
                "The selection shows ONLY the specified line range, not the entire file!",
                "The file may contain duplicated content of the selected snippet.",
                "When using edit tools, on the referenced files, MAKE SURE your changes target the correct lines by including sufficient surrounding context to make the match unique.",
                "After you make edits to the referenced files, go back and read the file to verify your changes were applied correctly.",
            }, "\n"),
        })

        local selections = self.code_selection:get_selections()
        self.code_selection:clear()

        for _, selection in ipairs(selections) do
            if selection and #selection.lines > 0 then
                -- Add line numbers to each line in the snippet
                local numbered_lines = {}
                for i, line in ipairs(selection.lines) do
                    local line_num = selection.start_line + i - 1
                    table.insert(
                        numbered_lines,
                        string.format("Line %d: %s", line_num, line)
                    )
                end
                local numbered_snippet = table.concat(numbered_lines, "\n")

                table.insert(prompt, {
                    type = "text",
                    text = string.format(
                        table.concat({
                            "<selected_code>",
                            "<path>%s</path>",
                            "<line_start>%s</line_start>",
                            "<line_end>%s</line_end>",
                            "<snippet>",
                            "%s",
                            "</snippet>",
                            "</selected_code>",
                        }, "\n"),
                        FileSystem.to_absolute_path(selection.file_path),
                        selection.start_line,
                        selection.end_line,
                        numbered_snippet
                    ),
                })

                table.insert(
                    message_lines,
                    string.format(
                        "```%s %s#L%d-L%d\n%s\n```",
                        selection.file_type,
                        selection.file_path,
                        selection.start_line,
                        selection.end_line,
                        table.concat(selection.lines, "\n")
                    )
                )
            end
        end
    end

    if not self.file_list:is_empty() then
        table.insert(message_lines, "")
        table.insert(message_lines, "Files")

        local files = self.file_list:get_files()
        self.file_list:clear()

        for _, file_path in ipairs(files) do
            table.insert(prompt, ACPPayloads.create_file_content(file_path))

            table.insert(
                message_lines,
                string.format("  - @%s", FileSystem.to_smart_path(file_path))
            )
        end
    end

    if not self.diagnostics_list:is_empty() then
        table.insert(message_lines, "")
        table.insert(message_lines, "Diagnostics")

        local diagnostics = self.diagnostics_list:get_diagnostics()
        self.diagnostics_list:clear()

        local WidgetLayout = require("agentic.ui.widget_layout")

        local chat_width = WidgetLayout.calculate_width(Config.windows.width)
        local chat_winid = self.widget.win_nrs.chat
        if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
            chat_width = vim.api.nvim_win_get_width(chat_winid)
        end

        local DiagnosticsContext = require("agentic.ui.diagnostics_context")

        local formatted_diagnostics =
            DiagnosticsContext.format_diagnostics(diagnostics, chat_width)

        for _, prompt_entry in ipairs(formatted_diagnostics.prompt_entries) do
            table.insert(prompt, prompt_entry)
        end

        for _, summary_line in ipairs(formatted_diagnostics.summary_lines) do
            table.insert(message_lines, summary_line)
        end
    end

    --- @type agentic.ui.ChatHistory.UserMessage
    local user_msg = {
        type = "user",
        text = input_text,
        timestamp = os.time(),
        provider_name = self.agent.provider_config.name,
    }
    local submission = {
        id = 0,
        input_text = input_text,
        prompt = prompt,
        message_lines = message_lines,
        user_msg = user_msg,
    }

    if self.is_generating then
        self:_enqueue_submission(submission)
        return
    end

    self:_dispatch_submission(submission)
end

--- @param submission agentic.SessionManager.QueuedSubmission
function SessionManager:_dispatch_submission(submission)
    self.message_writer:begin_turn()
    self.message_writer:write_message(
        ACPPayloads.generate_user_message(submission.message_lines)
    )
    self.session_state:dispatch(
        SessionEvents.add_transcript_message(submission.user_msg)
    )

    invoke_hook("on_prompt_submit", {
        prompt = submission.input_text,
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
    })

    local session_id = self.session_id
    local tab_page_id = self.tab_page_id
    local chat_history = self.chat_history

    self.is_generating = true
    self._agent_phase = "thinking"
    self:_render_window_headers()
    SessionManager._refresh_chat_activity(self)

    self.agent:send_prompt(
        self.session_id,
        submission.prompt,
        function(response, err)
            vim.schedule(function()
                self.is_generating = false
                self._agent_phase = nil

                write_turn_complete(self, response, err)
                SessionManager._refresh_chat_activity(self)

                invoke_hook("on_response_complete", {
                    session_id = session_id,
                    tab_page_id = tab_page_id,
                    success = err == nil,
                    error = err,
                })

                if not err then
                    chat_history:save(function(save_err)
                        if save_err then
                            Logger.debug("Chat history save error:", save_err)
                        end
                    end)
                end

                self:_drain_queued_submissions()
            end)
        end
    )
end

--- Create a new session, optionally cancelling any existing one
--- @param opts {restore_mode?: boolean, on_created?: fun()}|nil
function SessionManager:new_session(opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode or false
    local on_created = opts.on_created
    if not restore_mode then
        self:_cancel_session()
    end

    self._session_starting = true
    SessionManager._refresh_chat_activity(self)

    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
            Logger.debug("Agent error: ", err)

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message({
                    "🐞 Agent Error:",
                    "",
                    vim.inspect(err),
                })
            )
        end,

        on_session_update = function(update)
            self:_on_session_update(update)
        end,

        on_tool_call = function(tool_call)
            self:_on_tool_call(tool_call)
        end,

        on_tool_call_update = function(tool_call_update)
            self:_on_tool_call_update(tool_call_update)
        end,

        on_request_permission = function(request, callback)
            self:_handle_permission_request(request, callback)
        end,
    }

    self.agent:create_session(handlers, function(response, err)
        self._session_starting = false
        SessionManager._refresh_chat_activity(self)

        if err or not response then
            -- no log here, already logged in create_session
            self.session_id = nil
            return
        end

        self.session_id = response.sessionId
        self.session_state:dispatch(SessionEvents.set_session_meta({
            session_id = response.sessionId,
            timestamp = os.time(),
        }))

        if response.configOptions then
            Logger.debug("Provider announce configOptions")
            self:_handle_new_config_options(response.configOptions)
        else
            if response.modes then
                Logger.debug("Provider announce legacy mode")
                self.config_options:set_legacy_modes(response.modes)
            end

            if response.models then
                Logger.debug("Provider announce legacy models")
                self.config_options:set_legacy_models(response.models)
            end

            self:_render_window_headers()
        end

        self.config_options:set_initial_mode(
            self.agent.provider_config.default_mode,
            function(mode, is_legacy)
                self:_handle_mode_change(mode, is_legacy)
            end
        )

        -- Reset first message flag for new session (skip when restoring)
        if not restore_mode then
            self._is_first_message = true
        end

        -- Add initial welcome message after session is created
        -- Defer to avoid fast event context issues
        -- For restore: write welcome first, then replay via on_created
        vim.schedule(function()
            local agent_info = self.agent.agent_info
            local welcome_message = SessionManager._generate_welcome_header(
                self.agent.provider_config.name,
                self.session_id,
                agent_info and agent_info.version
            )

            self.message_writer:write_message(
                ACPPayloads.generate_user_message(welcome_message)
            )

            -- Invoke on_created callback after welcome message is written
            if on_created then
                on_created()
            end
        end)
    end)
end

function SessionManager:_cancel_session()
    if self.session_id then
        -- only cancel and clear content if there was an session
        -- Otherwise, it clears selections and files when opening for the first time
        self.agent:cancel_session(self.session_id)
        self.widget:clear()
        self.message_writer:reset()
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
        self.diagnostics_list:clear()
        self.config_options:clear()
    end

    self.session_id = nil
    self._agent_phase = nil
    self._session_starting = false
    SessionManager._clear_chat_activity(self)
    self.permission_manager:clear()
    SlashCommands.setCommands(self.widget.buf_nrs.input, {})

    self.session_state:replace_history(ChatHistory:new())
    self.chat_history = self.session_state:get_history()
    self._history_to_send = nil
    local was_visible = #self._queued_submissions > 0
    self._queued_submissions = {}
    self._interrupt_submission = nil
    self:_sync_queue_panel(was_visible)
end

--- Switch to a different ACP provider while preserving chat UI and history.
--- Reads Config.provider (already set by caller) for the target provider.
function SessionManager:switch_provider()
    if self.is_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    local AgentInstance = require("agentic.acp.agent_instance")

    -- Save references before get_instance (on_ready may fire synchronously)
    local saved_history = self.chat_history
    local old_agent = self.agent
    local old_session_id = self.session_id

    -- Get new agent instance BEFORE tearing down the current session
    local new_agent = AgentInstance.get_instance(
        Config.provider,
        function(client)
            vim.schedule(function()
                self.agent = client

                self:new_session({
                    restore_mode = true,
                    on_created = function()
                        -- Capture new session metadata before overwriting
                        local new_session_id = self.chat_history.session_id
                        local new_timestamp = self.chat_history.timestamp

                        -- Restore saved messages (new_session created a fresh one)
                        self.session_state:replace_history(saved_history)
                        self.chat_history = self.session_state:get_history()
                        self.chat_history.session_id = new_session_id
                        self.chat_history.timestamp = new_timestamp
                        self._history_to_send = saved_history.messages
                        self._is_first_message = true
                    end,
                })
            end)
        end
    )

    if not new_agent then
        return
    end

    -- Soft cancel: tear down old ACP session now that we have a new agent
    if old_session_id then
        old_agent:cancel_session(old_session_id)
    end
    self.session_id = nil
    self._agent_phase = nil
    self._session_starting = false
    SessionManager._clear_chat_activity(self)
    self.permission_manager:clear()
    self.todo_list:clear()

    -- If agent was already cached, on_ready fired synchronously above.
    -- If not, it will fire when the process is ready.
    self.agent = new_agent
end

function SessionManager:add_selection_or_file_to_session()
    local added_selection = self:add_selection_to_session()

    if not added_selection then
        self:add_file_to_session()
    end
end

function SessionManager:add_selection_to_session()
    local selection = self.code_selection.get_selected_text()

    if selection then
        self.code_selection:add(selection)
        return true
    end

    return false
end

--- @param buf integer|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
end

--- Add diagnostics at the current cursor line to context
--- @param bufnr integer|nil Buffer number to get diagnostics from, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_current_line_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_diagnostics_at_cursor(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- Add all diagnostics from the current buffer to context
--- @param bufnr integer|nil Buffer number, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_buffer_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_buffer_diagnostics(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- @return string
function SessionManager:_get_workspace_root()
    local file_path
    local target_winid = self.widget:find_first_non_widget_window()

    if target_winid and vim.api.nvim_win_is_valid(target_winid) then
        local target_bufnr = vim.api.nvim_win_get_buf(target_winid)
        local target_path = vim.api.nvim_buf_get_name(target_bufnr)
        if target_path ~= "" then
            file_path = target_path
        end
    end

    local tabnr = vim.api.nvim_tabpage_get_number(self.tab_page_id)
    local cwd = vim.fn.getcwd(-1, tabnr)
    if cwd == nil or cwd == "" then
        cwd = vim.fn.getcwd()
    end

    local start_dir = file_path
            and vim.fs.dirname(FileSystem.to_absolute_path(file_path))
        or FileSystem.to_absolute_path(cwd)
    local git_marker = vim.fs.find({ ".git" }, {
        upward = true,
        path = start_dir,
    })[1]

    if git_marker then
        return FileSystem.to_absolute_path(vim.fs.dirname(git_marker))
    end

    return FileSystem.to_absolute_path(cwd)
end

--- @param new_config_options agentic.acp.ConfigOption[]
function SessionManager:_handle_new_config_options(new_config_options)
    self.config_options:set_options(new_config_options)
    self:_render_window_headers()
end

function SessionManager:_get_system_info()
    local os_name = vim.uv.os_uname().sysname
    local os_version = vim.uv.os_uname().release
    local os_machine = vim.uv.os_uname().machine
    local shell = os.getenv("SHELL")
    local neovim_version = tostring(vim.version())
    local today = os.date("%Y-%m-%d")

    local res = string.format(
        [[
- Platform: %s-%s-%s
- Shell: %s
- Editor: Neovim %s
- Current date: %s]],
        os_name,
        os_version,
        os_machine,
        shell,
        neovim_version,
        today
    )

    local project_root = vim.uv.cwd()

    local git_root = vim.fs.root(project_root or 0, ".git")
    if git_root then
        project_root = git_root
        res = res .. "\n- This is a Git repository."

        local branch =
            vim.fn.system("git rev-parse --abbrev-ref HEAD"):gsub("\n", "")
        if vim.v.shell_error == 0 and branch ~= "" then
            res = res .. string.format("\n- Current branch: %s", branch)
        end

        local changed = vim.fn.system("git status --porcelain"):gsub("\n$", "")
        if vim.v.shell_error == 0 and changed ~= "" then
            local files = vim.split(changed, "\n")
            res = res .. "\n- Changed files:"
            for _, file in ipairs(files) do
                res = res .. "\n  - " .. file
            end
        end

        local commits = vim.fn
            .system("git log -3 --oneline --format='%h (%ar) %an: %s'")
            :gsub("\n$", "")
        if vim.v.shell_error == 0 and commits ~= "" then
            local commit_lines = vim.split(commits, "\n")
            res = res .. "\n- Recent commits:"
            for _, commit in ipairs(commit_lines) do
                res = res .. "\n  - " .. commit
            end
        end
    end

    if project_root then
        res = res .. string.format("\n- Project root: %s", project_root)
    end

    res = "<environment_info>\n" .. res .. "\n</environment_info>"
    return res
end

function SessionManager:destroy()
    self:_cancel_session()
    self.review_controller:destroy()
    self.permission_manager:destroy()
    SessionManager._clear_chat_activity(self)
    self.message_writer:destroy()
    self.widget:destroy()
end

--- Restore session from loaded chat history
--- Creates a new ACP session (agent doesn't know old session_id)
--- and replays messages to UI. History is sent on first prompt submit.
--- @param history agentic.ui.ChatHistory
--- @param opts {reuse_session?: boolean}|nil If reuse_session=true, replay into current session without creating new one
function SessionManager:restore_from_history(history, opts)
    opts = opts or {}

    -- Prevent constructor's auto-new_session from running
    self._restoring = true
    self._history_to_send = history.messages
    self._is_first_message = false

    -- Update existing chat_history with loaded data, keeping current session_id
    if opts.reuse_session then
        self.session_state:dispatch(SessionEvents.restore_history(history, {
            preserve_session_id = true,
            preserve_timestamp = true,
        }))
    else
        self.session_state:replace_history(history)
        self.chat_history = self.session_state:get_history()
    end

    if opts.reuse_session and self.session_id then
        -- Reuse existing ACP session, just replay messages
        self._restoring = false
        self.message_writer:reset()
        SessionRestore.replay_messages(
            self.message_writer,
            self._history_to_send
        )
        -- ACP session already knows these messages; clear to prevent duplicate prepend
        self._history_to_send = nil
    else
        -- Create fresh ACP session, then replay messages after session is ready
        self:new_session({
            restore_mode = true,
            on_created = function()
                self._restoring = false
                self.message_writer:reset()
                SessionRestore.replay_messages(
                    self.message_writer,
                    self._history_to_send
                )
            end,
        })
    end
end

return SessionManager
