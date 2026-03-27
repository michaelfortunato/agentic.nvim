local Config = require("agentic.config")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SessionLifecycle = require("agentic.session.session_lifecycle")
local PromptBuilder = require("agentic.session.prompt_builder")
local SessionEvents = require("agentic.session.session_events")
local SessionSelectors = require("agentic.session.session_selectors")
local SessionState = require("agentic.session.session_state")
local SubmissionQueue = require("agentic.session.submission_queue")
local SlashCommands = require("agentic.acp.slash_commands")
local PermissionOption = require("agentic.utils.permission_option")

--- Tool call kinds that mutate files on disk.
--- When these complete, buffers must be reloaded via checktime.
local FILE_MUTATING_KINDS = {
    edit = true,
    create = true,
    write = true,
    delete = true,
    move = true,
}

--- @param label string
--- @param value string
--- @return string
local function build_meta_line(label, value)
    return string.format("%s · %s", label, value)
end

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
--- @field request {kind: "user"|"review", text: string, timestamp: integer, content: agentic.acp.Content[]}
--- @field inline_request? {prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}|nil

--- @class agentic.SessionManager
--- @field instance_id? integer
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
--- @field inline_chat agentic.ui.InlineChat
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field diagnostics_list agentic.ui.DiagnosticsList
--- @field config_options agentic.acp.AgentConfigOptions
--- @field todo_list agentic.ui.TodoList
--- @field file_picker? agentic.ui.FilePicker
--- @field session_state agentic.session.SessionState
--- @field submission_queue agentic.session.SubmissionQueue
--- @field _restored_turns_to_send? agentic.session.InteractionTurn[] Restored turns to prepend on the next prompt submit
--- @field _restoring boolean Flag to prevent auto-new_session during restore
--- @field _agent_phase? agentic.Theme.SpinnerState
--- @field _session_starting boolean
--- @field _session_state_subscription? integer
--- @field _pending_session_callbacks fun()[]
--- @field _restoring_widget_state? boolean
local SessionManager = {}
SessionManager.__index = SessionManager

--- @param tab_page_id integer
--- @param opts {instance_id?: integer|nil}|nil
function SessionManager:new(tab_page_id, opts)
    opts = opts or {}
    local AgentInstance = require("agentic.acp.agent_instance")
    local ChatWidget = require("agentic.ui.chat_widget")
    local InlineChat = require("agentic.ui.inline_chat")
    local PermissionManager = require("agentic.ui.permission_manager")

    self = setmetatable({
        instance_id = opts.instance_id,
        session_id = nil,
        tab_page_id = tab_page_id,
        _is_first_message = true,
        is_generating = false,
        _restoring = false,
        submission_queue = SubmissionQueue:new(),
        _agent_phase = nil,
        _session_starting = false,
        _pending_session_callbacks = {},
    }, self)

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            -- Skip auto-new_session while a persisted session restore is in flight
            if not self._restoring then
                self:_ensure_session_started()
            end
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.session_state = SessionState:new()
    self.permission_manager = PermissionManager:new(self.session_state)

    self.widget = ChatWidget:new(tab_page_id, function() end, {
        instance_id = self.instance_id,
    })
    self._session_state_subscription = self.session_state:subscribe(
        function(state)
            self:_render_interaction_session(state)
        end
    )
    self:_attach_widget(self.widget)

    self.inline_chat = InlineChat:new({
        tab_page_id = tab_page_id,
        on_submit = function(request)
            return self:_submit_inline_request(request)
        end,
        on_change_mode = function()
            self.config_options:show_mode_selector()
        end,
        on_change_model = function()
            self.config_options:show_model_selector()
        end,
        on_change_thought_level = function()
            self.config_options:show_thought_level_selector()
        end,
        on_change_approval_preset = function()
            self.config_options:show_approval_preset_selector()
        end,
        get_config_context = function()
            return self.config_options and self.config_options:get_header_context()
                or nil
        end,
    })

    return self
end

--- @return {input_text: string, file_paths: string[], code_selections: agentic.Selection[], diagnostics: agentic.ui.DiagnosticsList.Diagnostic[]}
function SessionManager:_capture_widget_state()
    --- @type {input_text: string, file_paths: string[], code_selections: agentic.Selection[], diagnostics: agentic.ui.DiagnosticsList.Diagnostic[]}
    local snapshot = {
        input_text = "",
        file_paths = {},
        code_selections = {},
        diagnostics = {},
    }

    if self.widget and self.widget.get_input_text then
        snapshot.input_text = self.widget:get_input_text()
    end

    if self.file_list and self.file_list.get_files then
        snapshot.file_paths = self.file_list:get_files()
    end

    if self.code_selection and self.code_selection.get_selections then
        snapshot.code_selections = self.code_selection:get_selections()
    end

    if self.diagnostics_list and self.diagnostics_list.get_diagnostics then
        snapshot.diagnostics = self.diagnostics_list:get_diagnostics()
    end

    return snapshot
end

function SessionManager:_destroy_widget_bindings()
    if self.review_controller then
        self.review_controller:destroy()
        self.review_controller = nil
    end

    if self.status_animation and self.status_animation.stop then
        self.status_animation:stop()
    end
    self.status_animation = nil

    if self.message_writer and self.message_writer.destroy then
        self.message_writer:destroy()
    end
    self.message_writer = nil

    if self.widget then
        if self.widget.unbind_message_writer then
            self.widget:unbind_message_writer()
        end

        if self.widget.set_submit_input_handler then
            self.widget:set_submit_input_handler(function() end)
        end
    end

    self.queue_list = nil
    self.config_options = nil
    self.file_list = nil
    self.code_selection = nil
    self.diagnostics_list = nil
    self.todo_list = nil
    self.file_picker = nil
end

function SessionManager:_bind_widget_session_keymaps()
    if not self.widget then
        return
    end

    local BufHelpers = require("agentic.utils.buf_helpers")
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
end

--- @param widget agentic.ui.ChatWidget
--- @param snapshot {input_text?: string|nil, file_paths?: string[]|nil, code_selections?: agentic.Selection[]|nil, diagnostics?: agentic.ui.DiagnosticsList.Diagnostic[]|nil}|nil
function SessionManager:_attach_widget(widget, snapshot)
    local AgentConfigOptions = require("agentic.acp.agent_config_options")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local FilePicker = require("agentic.ui.file_picker")
    local MessageWriter = require("agentic.ui.message_writer")
    local QueueList = require("agentic.ui.queue_list")
    local ReviewController = require("agentic.ui.review_controller")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")

    snapshot = snapshot or {}
    self:_destroy_widget_bindings()
    self.widget = widget
    self.widget:set_submit_input_handler(function(input_text)
        self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat, {
        should_auto_scroll = function()
            return self.widget:should_follow_chat_output()
        end,
        scroll_to_bottom = function()
            self.widget:scroll_chat_to_bottom()
        end,
        provider_name = self.agent.provider_config.name,
    })
    self.widget:bind_message_writer(self.message_writer)

    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.review_controller = ReviewController:new(
        self.session_state,
        self.widget,
        self.permission_manager
    )
    self.permission_manager:set_diff_review_handler(function(current_request)
        return self.review_controller:activate_diff_review(current_request)
    end)

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

    self:_setup_prompt_completion(FilePicker)

    self.config_options = AgentConfigOptions:new(
        self.widget.buf_nrs,
        function(config_id, value)
            SessionManager._handle_config_option_change(self, config_id, value)
        end
    )

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_optional_window("files")
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget:render_header("files", tostring(#file_list:get_files()))
            if not self._restoring_widget_state then
                self.widget:show({ focus_prompt = false })
            end
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
                if not self._restoring_widget_state then
                    self.widget:show({ focus_prompt = false })
                end
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
                self.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                if not self._restoring_widget_state then
                    self.widget:show({ focus_prompt = false })
                end
            end
        end
    )

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() and not self._restoring_widget_state then
            self.widget:show({ focus_prompt = false })
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    self:_bind_widget_session_keymaps()

    self._restoring_widget_state = true
    self.widget:set_input_text(snapshot.input_text or "")
    for _, file_path in ipairs(snapshot.file_paths or {}) do
        self.file_list:add(file_path)
    end
    for _, selection in ipairs(snapshot.code_selections or {}) do
        self.code_selection:add(selection)
    end
    self.diagnostics_list:add_many(snapshot.diagnostics or {})

    local state = self.session_state:get_state()
    self.config_options:set_options(
        state.session.config_options or {},
        self.agent and self.agent.provider_config or nil
    )
    if state.session.current_mode_id and self.config_options.set_current_mode then
        self.config_options:set_current_mode(state.session.current_mode_id)
    end
    SlashCommands.setCommands(
        self.widget.buf_nrs.input,
        state.session.available_commands or {}
    )

    if Config.windows.todos.display then
        local entries = SessionSelectors.get_latest_plan_entries(state)
        if #entries > 0 then
            self.todo_list:render(entries)
        else
            self.todo_list:clear()
        end
    end

    self.queue_list:set_items(self.submission_queue:list())
    self:_render_interaction_session(state)
    self:_render_window_headers()
    self._restoring_widget_state = false
    self:_sync_queue_panel(self.submission_queue:count() > 0)
    self:_sync_inline_queue_states()
    SessionManager._refresh_chat_activity(self)

    if self.widget:is_open() then
        self.widget:show({ focus_prompt = false })
    end
end

--- @param other_session agentic.SessionManager|nil
function SessionManager:swap_widget(other_session)
    if
        other_session == nil
        or other_session == self
        or self.widget == nil
        or other_session.widget == nil
    then
        return
    end

    local own_snapshot = self:_capture_widget_state()
    local other_snapshot = other_session:_capture_widget_state()
    local own_widget = self.widget
    local other_widget = other_session.widget

    self:_attach_widget(other_widget, own_snapshot)
    other_session:_attach_widget(own_widget, other_snapshot)
end

--- @param file_picker_module agentic.ui.FilePicker|nil
function SessionManager:_setup_prompt_completion(file_picker_module)
    local FilePicker = file_picker_module or require("agentic.ui.file_picker")

    self.file_picker = FilePicker:new(self.widget.buf_nrs.input, {
        resolve_root = function()
            return self:_get_workspace_root()
        end,
        on_file_selected = function(file_path)
            if self.file_list then
                self.file_list:add(file_path)
            end
        end,
    })
    SlashCommands.setup_completion(self.widget.buf_nrs.input)
end

function SessionManager:_drain_pending_session_callbacks()
    if not self.session_id then
        return
    end

    local callbacks = self._pending_session_callbacks or {}
    if #callbacks == 0 then
        return
    end

    self._pending_session_callbacks = {}

    for _, callback in ipairs(callbacks) do
        callback()
    end
end

function SessionManager:_ensure_session_started()
    if self.session_id then
        self:_drain_pending_session_callbacks()
        return
    end

    if self._session_starting then
        return
    end

    if not self.agent or self.agent.state ~= "ready" then
        return
    end

    self:new_session({
        restore_mode = true,
        on_created = function()
            self:_drain_pending_session_callbacks()
            self:_drain_queued_submissions()
        end,
    })
end

--- @param callback fun()
function SessionManager:_with_active_session(callback)
    if self.session_id then
        callback()
        return
    end

    self._pending_session_callbacks = self._pending_session_callbacks or {}
    self._pending_session_callbacks[#self._pending_session_callbacks + 1] =
        callback
    self:_ensure_session_started()
end

--- @param input_text string
function SessionManager:_attach_mentioned_files(input_text)
    if not self.file_picker or not self.file_list then
        return
    end

    for _, file_path in
        ipairs(self.file_picker:resolve_mentioned_file_paths(input_text))
    do
        self.file_list:add(file_path)
    end
end

--- @param state agentic.session.State|nil
--- @return string[]
function SessionManager:_build_chat_welcome_lines(state)
    state = state or self.session_state:get_state()
    local session_meta = SessionSelectors.get_session_meta(state)
    if not session_meta or not session_meta.id then
        return {}
    end

    local agent_info = self.agent and self.agent.agent_info or nil
    local provider_name = self.agent and self.agent.provider_config.name
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

--- @param state agentic.session.State|nil
function SessionManager:_render_interaction_session(state)
    if not self.message_writer then
        return
    end

    state = state or self.session_state:get_state()
    self.message_writer:render_interaction_session(
        SessionSelectors.get_interaction_session(state),
        {
            welcome_lines = self:_build_chat_welcome_lines(state),
        }
    )
end

--- @param state agentic.Theme.SpinnerState
--- @param opts {detail?: string|nil}|nil
function SessionManager:_set_chat_activity(state, opts)
    if not self.status_animation or not self.status_animation.start then
        return
    end

    self.status_animation:start(state, opts)
end

function SessionManager:_clear_chat_activity()
    if self.status_animation and self.status_animation.stop then
        self.status_animation:stop()
    end
end

function SessionManager:_refresh_chat_activity()
    if not self.session_state then
        SessionManager._clear_chat_activity(self)
        return
    end

    local activity = SessionSelectors.get_chat_activity_info(
        self.session_state:get_state(),
        {
            session_starting = self._session_starting,
            is_generating = self.is_generating,
            agent_phase = self._agent_phase,
        }
    )

    if not activity then
        SessionManager._clear_chat_activity(self)
        return
    end

    SessionManager._set_chat_activity(self, activity.state, {
        detail = activity.detail,
    })
end

--- @return {state: agentic.Theme.SpinnerState, detail?: string|nil}|nil
function SessionManager:_get_active_tool_activity()
    if not self.session_state then
        return nil
    end

    local activity = SessionSelectors.get_chat_activity_info(
        self.session_state:get_state(),
        {
            session_starting = false,
            is_generating = true,
            agent_phase = self._agent_phase,
        }
    )

    if activity == nil or activity.detail == nil then
        return nil
    end

    return activity
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    if self.inline_chat and self.inline_chat:is_active() then
        self.inline_chat:handle_session_update(update)
    end

    if update.sessionUpdate == "agent_message_chunk" then
        self._agent_phase = "generating"
        SessionManager._refresh_chat_activity(self)

        if update.content then
            self.session_state:dispatch(
                SessionEvents.append_interaction_response(
                    "message",
                    self.agent.provider_config.name,
                    vim.deepcopy(update.content)
                )
            )
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self._agent_phase = "thinking"
        SessionManager._refresh_chat_activity(self)

        if update.content then
            self.session_state:dispatch(
                SessionEvents.append_interaction_response(
                    "thought",
                    self.agent.provider_config.name,
                    vim.deepcopy(update.content)
                )
            )
        end
    elseif update.sessionUpdate == "session_info_update" then
        if update.title ~= nil then
            self.session_state:dispatch(
                SessionEvents.set_session_title(update.title or "")
            )
            self:_render_window_headers()
        end
    elseif update.sessionUpdate == "plan" then
        self.session_state:dispatch(
            SessionEvents.upsert_interaction_plan(
                self.agent.provider_config.name,
                vim.deepcopy(update.entries or {})
            )
        )
        if Config.windows.todos.display then
            self.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "available_commands_update" then
        self.session_state:dispatch(
            SessionEvents.set_available_commands(update.availableCommands or {})
        )
        SlashCommands.setCommands(
            self.widget.buf_nrs.input,
            update.availableCommands
        )
    elseif update.sessionUpdate == "current_mode_update" then
        self.session_state:dispatch(
            SessionEvents.set_current_mode(update.currentModeId)
        )
        if self.config_options and self.config_options.set_current_mode then
            self.config_options:set_current_mode(update.currentModeId)
        end
        self:_render_window_headers()
    elseif update.sessionUpdate == "usage_update" then
        -- Usage updates are informational for now. Keep them recognized so
        -- providers can emit ACP usage telemetry without triggering warnings.
    elseif update.sessionUpdate == "config_option_update" then
        self:_handle_new_config_options(update.configOptions)
    else
        Logger.debug(
            "Unknown session update type: ",
            tostring(
                --- @diagnostic disable-next-line: undefined-field -- expected it to be unknown
                update.sessionUpdate
            )
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
    if self.inline_chat and self.inline_chat:is_active() then
        self.inline_chat:handle_tool_call(tool_call)
    end

    self.session_state:dispatch(
        SessionEvents.upsert_interaction_tool_call(
            self.agent.provider_config.name,
            tool_call
        )
    )
    SessionManager._refresh_chat_activity(self)
end

--- Handle tool call update: update UI, history, diff preview, permissions, and reload buffers
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call_update(tool_call_update)
    if self.inline_chat and self.inline_chat:is_active() then
        self.inline_chat:handle_tool_call_update(tool_call_update)
    end

    local events = {
        SessionEvents.upsert_interaction_tool_call(
            self.agent.provider_config.name,
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

    dispatch_state_events(self, events)

    if tool_call_update.status == "failed" then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    SessionManager._refresh_chat_activity(self)

    -- Reload buffers when file-mutating tool calls complete.
    -- This is derived from interaction state, not renderer-local tool trackers.
    if tool_call_update.status == "completed" then
        local tracker = nil
        if self.session_state then
            tracker = SessionSelectors.get_tool_call(
                self.session_state:get_state(),
                tool_call_update.tool_call_id
            )
        end

        local tool_kind = tracker and tracker.kind or tool_call_update.kind
        if tool_kind and FILE_MUTATING_KINDS[tool_kind] then
            if
                self.inline_chat
                and self.inline_chat.is_active
                and self.inline_chat:is_active()
                and self.inline_chat.handle_applied_edit
            then
                self.inline_chat:handle_applied_edit()
            end
            vim.cmd.checktime()
        end
    end
end

--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function SessionManager:_handle_permission_request(request, callback)
    if self.inline_chat and self.inline_chat:is_active() then
        self.inline_chat:handle_permission_request()
    end

    local tool_call_id = request.toolCall.toolCallId

    local wrapped_callback = function(option_id)
        local permission_state =
            PermissionOption.get_state_for_option_id(request.options, option_id)

        dispatch_state_events(self, {
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
        callback(option_id)
        vim.schedule(function()
            SessionManager._refresh_chat_activity(self)
        end)
    end

    dispatch_state_events(self, {
        SessionEvents.set_interaction_tool_permission_state(
            tool_call_id,
            "requested"
        ),
        SessionEvents.set_review_target(tool_call_id),
    })
    self.permission_manager:add_request(request, wrapped_callback)
    SessionManager._refresh_chat_activity(self)
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
                if self.inline_chat then
                    self.inline_chat:refresh()
                end
            end

            local option_name = self.config_options:get_config_option_name(
                config_id
            ) or config_id
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
    local queue_count = self.submission_queue and self.submission_queue:count()
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

--- @param input_text string
--- @param opts {code_selection?: agentic.ui.CodeSelection|nil, file_list?: agentic.ui.FileList|nil, diagnostics_list?: agentic.ui.DiagnosticsList|nil, chat_winid?: integer|nil, selections?: agentic.Selection[]|nil, inline_instructions?: string|nil}
--- @return agentic.SessionManager.QueuedSubmission
function SessionManager:_prepare_submission(input_text, opts)
    opts = opts or {}

    if self._restored_turns_to_send then
        self.session_state:dispatch(SessionEvents.set_session_title(input_text))
        self:_render_window_headers()
    elseif self.session_state:get_state().session.title == "" then
        self.session_state:dispatch(SessionEvents.set_session_title(input_text))
        self:_render_window_headers()
    end

    local built_submission = PromptBuilder.build_submission({
        input_text = input_text,
        provider_name = self.agent.provider_config.name,
        restored_turns_to_send = self._restored_turns_to_send,
        include_system_info = self._is_first_message,
        code_selection = opts.code_selection,
        file_list = opts.file_list,
        diagnostics_list = opts.diagnostics_list,
        chat_winid = opts.chat_winid,
        selections = opts.selections,
        inline_instructions = opts.inline_instructions,
    })

    if built_submission.consumed_restored_turns then
        self._restored_turns_to_send = nil
    end

    if built_submission.consumed_first_message then
        self._is_first_message = false
    end

    --- @type agentic.SessionManager.QueuedSubmission
    local submission = {
        id = 0,
        input_text = input_text,
        prompt = built_submission.prompt,
        request = built_submission.request,
    }

    return submission
end

--- @param submission agentic.SessionManager.QueuedSubmission
function SessionManager:_enqueue_submission(submission)
    local was_visible = self.submission_queue:count() > 0
    local submission_id = self.submission_queue:enqueue(submission)

    if submission.inline_request and self.inline_chat then
        self.inline_chat:queue_request({
            submission_id = submission_id,
            prompt = submission.inline_request.prompt,
            selection = submission.inline_request.selection,
            source_bufnr = submission.inline_request.source_bufnr,
            source_winid = submission.inline_request.source_winid,
        })
    end

    self:_sync_queue_panel(was_visible)
    self:_sync_inline_queue_states()

    Logger.notify(
        "Queued follow-up. It will be sent when the agent is ready.",
        vim.log.levels.INFO,
        { title = "Agentic Queue" }
    )
end

function SessionManager:_drain_queued_submissions()
    if self.is_generating or not self.session_id then
        return
    end

    local was_visible = self.submission_queue:count() > 0
    local next_submission = self.submission_queue:pop_next()
    self:_sync_queue_panel(was_visible)
    self:_sync_inline_queue_states()

    if next_submission then
        self:_dispatch_submission(next_submission)
    end
end

function SessionManager:_focus_queue_panel()
    if self.submission_queue:is_empty() then
        Logger.notify("Queue is empty", vim.log.levels.INFO, {
            title = "Agentic Queue",
        })
        return
    end

    self:_sync_queue_panel(self.submission_queue:count() > 0)
    self.widget:show({ focus_prompt = false })
    self.widget:move_cursor_to(self.widget.win_nrs.queue)
end

--- @param submission_id integer
function SessionManager:_remove_queued_submission(submission_id)
    local was_visible = self.submission_queue:count() > 0
    local removed_submission = self.submission_queue:remove(submission_id)
    if not removed_submission then
        return
    end

    if removed_submission.inline_request and self.inline_chat then
        self.inline_chat:remove_queued_submission(removed_submission.id)
    end

    self:_sync_queue_panel(was_visible)
    self:_sync_inline_queue_states()
end

--- @param submission_id integer
function SessionManager:_steer_queued_submission(submission_id)
    local submission = self.submission_queue:prioritize(submission_id)
    if not submission then
        return
    end

    self:_sync_queue_panel(true)
    self:_sync_inline_queue_states()

    if not self.is_generating then
        self:_drain_queued_submissions()
    end
end

--- @param submission_id integer
function SessionManager:_send_queued_submission_now(submission_id)
    if self.is_generating then
        local was_visible = self.submission_queue:count() > 0
        local submission = self.submission_queue:interrupt_with(submission_id)
        self:_sync_queue_panel(was_visible)
        if not submission then
            return
        end

        self:_sync_inline_queue_states()
        self.agent:stop_generation(self.session_id)
        return
    end

    local was_visible = self.submission_queue:count() > 0
    local submission = self.submission_queue:remove(submission_id)
    self:_sync_queue_panel(was_visible)
    if not submission then
        return
    end

    self:_sync_inline_queue_states()
    self:_dispatch_submission(submission)
end

function SessionManager:_sync_inline_queue_states()
    if not self.inline_chat or not self.submission_queue then
        return
    end

    self.inline_chat:sync_queued_requests(self.submission_queue:list(), {
        waiting_for_session = self.session_id == nil,
        interrupt_submission = self.submission_queue:get_interrupt_submission(),
    })
end

--- @param was_visible boolean|nil
function SessionManager:_sync_queue_panel(was_visible)
    local queue_count = self.submission_queue:count()
    local is_visible = queue_count > 0
    local queue_winid = self.widget
        and self.widget.win_nrs
        and self.widget.win_nrs.queue
    local queue_had_focus = queue_winid
        and vim.api.nvim_win_is_valid(queue_winid)
        and vim.api.nvim_get_current_win() == queue_winid

    if self.queue_list then
        self.queue_list:set_items(self.submission_queue:list())
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

    if not self.session_id then
        self:_with_active_session(function()
            self:_handle_input_submit(input_text)
        end)
        return
    end

    if self._attach_mentioned_files then
        self:_attach_mentioned_files(input_text)
    end

    local submission = self:_prepare_submission(input_text, {
        code_selection = self.code_selection,
        file_list = self.file_list,
        diagnostics_list = self.diagnostics_list,
        chat_winid = self.widget.win_nrs.chat,
    })

    if self.is_generating then
        self:_enqueue_submission(submission)
        return
    end

    self:_dispatch_submission(submission)
end

--- @param submission agentic.SessionManager.QueuedSubmission
function SessionManager:_dispatch_submission(submission)
    if not self.session_id then
        self:_with_active_session(function()
            self:_dispatch_submission(submission)
        end)
        return
    end

    if submission.inline_request and self.inline_chat then
        self.inline_chat:begin_request({
            submission_id = submission.id,
            prompt = submission.inline_request.prompt,
            selection = submission.inline_request.selection,
            source_bufnr = submission.inline_request.source_bufnr,
            source_winid = submission.inline_request.source_winid,
            phase = "thinking",
            status_text = "Preparing inline request",
        })
    end

    self.session_state:dispatch(
        SessionEvents.append_interaction_request(submission.request)
    )

    invoke_hook("on_prompt_submit", {
        prompt = submission.input_text,
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
    })

    local session_id = self.session_id
    local tab_page_id = self.tab_page_id
    self.is_generating = true
    self._agent_phase = "thinking"
    self:_render_window_headers()
    SessionManager._refresh_chat_activity(self)

    self.agent:send_prompt(
        self.session_id,
        submission.prompt,
        function(response, err)
            local prompt_response = response
            --- @cast prompt_response agentic.acp.PromptResponse|nil
            vim.schedule(function()
                self.is_generating = false
                self._agent_phase = nil

                self.session_state:dispatch(
                    SessionEvents.set_interaction_turn_result(
                        build_turn_result_message(prompt_response, err),
                        self.agent.provider_config.name
                    )
                )
                SessionManager._refresh_chat_activity(self)

                invoke_hook("on_response_complete", {
                    session_id = session_id,
                    tab_page_id = tab_page_id,
                    success = err == nil,
                    error = err,
                })

                if submission.inline_request and self.inline_chat then
                    self.inline_chat:complete(prompt_response, err)
                end

                if not err then
                    self.session_state:save_persisted_session_data(
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

                self:_drain_queued_submissions()
            end)
        end
    )
end

--- Create a new session, optionally cancelling any existing one
--- @param opts {restore_mode?: boolean, on_created?: fun()}|nil
function SessionManager:new_session(opts)
    return SessionLifecycle.start(self, opts)
end

function SessionManager:_cancel_session()
    return SessionLifecycle.cancel(self)
end

--- Switch to a different ACP provider while preserving chat UI and history.
--- Reads Config.provider (already set by caller) for the target provider.
function SessionManager:switch_provider()
    return SessionLifecycle.switch_provider(self)
end

function SessionManager:_clear_inline_chat()
    if self.inline_chat then
        self.inline_chat:clear()
    end
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

--- @param selection agentic.Selection|nil
function SessionManager:open_inline_chat(selection)
    if not Config.inline.enabled then
        Logger.notify("Inline chat is disabled.", vim.log.levels.INFO)
        return
    end

    local inline_selection = selection
        or self.code_selection.get_selected_text()
    if not inline_selection then
        Logger.notify(
            "Select a range in visual mode before starting inline chat.",
            vim.log.levels.INFO
        )
        return
    end

    if
        inline_selection.file_path == nil
        or inline_selection.file_path == ""
    then
        Logger.notify(
            "Inline chat requires a named file buffer.",
            vim.log.levels.WARN
        )
        return
    end

    local source_bufnr = vim.api.nvim_get_current_buf()
    local overlapping_submission_id = self.inline_chat
            and self.inline_chat:find_overlapping_queued_submission(
                source_bufnr,
                inline_selection
            )
        or nil
    if overlapping_submission_id ~= nil then
        self:_remove_queued_submission(overlapping_submission_id)
        Logger.notify(
            "Removed queued inline request for this range.",
            vim.log.levels.INFO
        )
        return
    end

    self.inline_chat:open(inline_selection)
end

--- @param request {prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}
--- @return boolean accepted
function SessionManager:_submit_inline_request(request)
    local submission = self:_prepare_submission(request.prompt, {
        selections = { request.selection },
        inline_instructions = PromptBuilder.build_inline_instructions(),
    })
    submission.inline_request = request

    if not self.session_id then
        self:_enqueue_submission(submission)
        self:_ensure_session_started()
        return true
    end

    if self.is_generating then
        self:_enqueue_submission(submission)
        return true
    end

    self:_dispatch_submission(submission)
    return true
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
    local target_winid = self.widget:find_first_editor_window()

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
    self.session_state:dispatch(
        SessionEvents.set_config_options(new_config_options or {})
    )
    self.config_options:set_options(
        new_config_options,
        self.agent and self.agent.provider_config or nil
    )
    self:_render_window_headers()

    if self.inline_chat then
        self.inline_chat:refresh()
    end
end

function SessionManager:destroy()
    self.session_state:unsubscribe(self._session_state_subscription)
    self:_cancel_session()
    self.inline_chat:destroy()
    self.review_controller:destroy()
    self.permission_manager:destroy()
    SessionManager._clear_chat_activity(self)
    self.message_writer:destroy()
    self.widget:destroy()
end

--- Restore session from loaded persisted session data
--- Creates a new ACP session (agent doesn't know old session_id)
--- and renders the restored interaction tree from session state.
--- @param persisted_session agentic.session.PersistedSession|agentic.session.PersistedSession.StorageData
--- @param opts {reuse_session?: boolean}|nil If reuse_session=true, restore into the current ACP session instead of creating a new one
function SessionManager:restore_session_data(persisted_session, opts)
    return SessionLifecycle.restore_session_data(self, persisted_session, opts)
end

return SessionManager
