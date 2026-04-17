local Config = require("agentic.config")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local Logger = require("agentic.utils.logger")
local SessionState = require("agentic.session.session_state")
local SubmissionQueue = require("agentic.session.submission_queue")
local SessionController = require("agentic.session.session_controller")
local SubmissionController = require("agentic.session.submission_controller")
local WidgetBinding = require("agentic.session.widget_binding")

--- @class agentic.SessionManager.QueuedSubmission
--- @field id integer
--- @field input_text string
--- @field prompt agentic.acp.Content[]
--- @field request {kind: "user"|"review", surface: "chat"|"inline", text: string, timestamp: integer, content: agentic.acp.Content[]}
--- @field inline_request? {prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}|nil

--- @class agentic.SessionManager
--- @field instance_id? integer
--- @field session_id? string
--- @field tab_page_id integer Current widget tab page
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
--- @field queue_list? agentic.ui.QueueList
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
--- @field _editor_winid? integer
local SessionManager = {}
SessionManager.__index = SessionManager

--- @param opts {instance_id?: integer|nil, tab_page_id?: integer|nil}|nil
function SessionManager:new(opts)
    opts = opts or {}
    local ChatWidget = require("agentic.ui.chat_widget")
    local InlineChat = require("agentic.ui.inline_chat")
    local PermissionManager = require("agentic.ui.permission_manager")
    local widget_tab_page_id = opts.tab_page_id
        or vim.api.nvim_get_current_tabpage()

    self = setmetatable({
        instance_id = opts.instance_id,
        session_id = nil,
        tab_page_id = widget_tab_page_id,
        _is_first_message = true,
        is_generating = false,
        _restoring = false,
        submission_queue = SubmissionQueue:new(),
        _agent_phase = nil,
        _session_starting = false,
        _pending_session_callbacks = {},
    }, self)

    if not SessionController.initialize_agent(self) then
        return
    end

    self.session_state = SessionState:new()
    self.permission_manager = PermissionManager:new(self.session_state)

    self.widget = ChatWidget:new(widget_tab_page_id, function() end, {
        instance_id = self.instance_id,
    })
    self._session_state_subscription = self.session_state:subscribe(
        function(state)
            self:_render_interaction_session(state)
        end
    )
    self:_attach_widget(self.widget)

    self.inline_chat = InlineChat:new({
        tab_page_id = widget_tab_page_id,
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
            return self.config_options
                    and self.config_options:get_header_context()
                or nil
        end,
    })

    return self
end

--- @return {input_text: string, file_paths: string[], code_selections: agentic.Selection[], diagnostics: agentic.ui.DiagnosticsList.Diagnostic[]}
function SessionManager:_capture_widget_state()
    return WidgetBinding.capture_widget_state(self)
end

function SessionManager:_destroy_widget_bindings()
    WidgetBinding.destroy_widget_bindings(self)
end

function SessionManager:_bind_widget_session_keymaps()
    WidgetBinding.bind_widget_session_keymaps(self)
end

--- @param widget agentic.ui.ChatWidget
--- @param snapshot {input_text?: string|nil, file_paths?: string[]|nil, code_selections?: agentic.Selection[]|nil, diagnostics?: agentic.ui.DiagnosticsList.Diagnostic[]|nil}|nil
function SessionManager:_attach_widget(widget, snapshot)
    WidgetBinding.attach_widget(self, widget, snapshot)
end

--- @param other_session agentic.SessionManager|nil
function SessionManager:swap_widget(other_session)
    WidgetBinding.swap_widget(self, other_session)
end

--- @param file_picker_module agentic.ui.FilePicker|nil
function SessionManager:_setup_prompt_completion(file_picker_module)
    WidgetBinding.setup_prompt_completion(self, file_picker_module)
end

function SessionManager:_drain_pending_session_callbacks()
    SessionController.drain_pending_session_callbacks(self)
end

function SessionManager:_ensure_session_started()
    SessionController.ensure_session_started(self)
end

--- @param callback fun()
function SessionManager:_with_active_session(callback)
    SessionController.with_active_session(self, callback)
end

--- @param input_text string
function SessionManager:_attach_mentioned_files(input_text)
    SubmissionController.attach_mentioned_files(self, input_text)
end

--- @param state agentic.session.State|nil
--- @return string[]
function SessionManager:_build_chat_welcome_lines(state)
    return SessionController.build_chat_welcome_lines(self, state)
end

--- @param state agentic.session.State|nil
function SessionManager:_render_interaction_session(state)
    WidgetBinding.render_interaction_session(self, state)
end

--- @param state agentic.Theme.SpinnerState
--- @param opts {detail?: string|nil}|nil
function SessionManager:_set_chat_activity(state, opts)
    WidgetBinding.set_chat_activity(self, state, opts)
end

function SessionManager:_clear_chat_activity()
    WidgetBinding.clear_chat_activity(self)
end

function SessionManager:_refresh_chat_activity()
    WidgetBinding.refresh_chat_activity(self)
end

--- @return {state: agentic.Theme.SpinnerState, detail?: string|nil}|nil
function SessionManager:_get_active_tool_activity()
    return SessionController.get_active_tool_activity(self)
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    SessionController.on_session_update(self, update)
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call(tool_call)
    SessionController.on_tool_call(self, tool_call)
end

--- Handle tool call update: update UI, history, diff preview, permissions, and reload buffers
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call_update(tool_call_update)
    SessionController.on_tool_call_update(self, tool_call_update)
end

--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function SessionManager:_handle_permission_request(request, callback)
    SessionController.handle_permission_request(self, request, callback)
end

--- Send a generic config option update to the agent
--- @param config_id string
--- @param value string
function SessionManager:_handle_config_option_change(config_id, value)
    SessionController.handle_config_option_change(self, config_id, value)
end

function SessionManager:_render_window_headers()
    WidgetBinding.render_window_headers(self)
end

--- @param input_text string
--- @param opts {code_selection?: agentic.ui.CodeSelection|nil, file_list?: agentic.ui.FileList|nil, diagnostics_list?: agentic.ui.DiagnosticsList|nil, chat_winid?: integer|nil, selections?: agentic.Selection[]|nil, inline_instructions?: string|nil, surface?: "chat"|"inline"|nil}
--- @return agentic.SessionManager.QueuedSubmission
function SessionManager:_prepare_submission(input_text, opts)
    return SubmissionController.prepare_submission(self, input_text, opts)
end

--- @param submission agentic.SessionManager.QueuedSubmission
function SessionManager:_enqueue_submission(submission)
    SubmissionController.enqueue_submission(self, submission)
end

function SessionManager:_drain_queued_submissions()
    SubmissionController.drain_queued_submissions(self)
end

function SessionManager:_focus_queue_panel()
    WidgetBinding.focus_queue_panel(self)
end

--- @param submission_id integer
function SessionManager:_remove_queued_submission(submission_id)
    SubmissionController.remove_queued_submission(self, submission_id)
end

--- @param submission_id integer
function SessionManager:_steer_queued_submission(submission_id)
    SubmissionController.steer_queued_submission(self, submission_id)
end

--- @param submission_id integer
function SessionManager:_send_queued_submission_now(submission_id)
    SubmissionController.send_queued_submission_now(self, submission_id)
end

function SessionManager:_sync_inline_queue_states()
    SubmissionController.sync_inline_queue_states(self)
end

--- @param was_visible boolean|nil
function SessionManager:_sync_queue_panel(was_visible)
    WidgetBinding.sync_queue_panel(self, was_visible)
end

--- @param input_text string
function SessionManager:_handle_input_submit(input_text)
    SubmissionController.handle_input_submit(self, input_text)
end

--- @param submission agentic.SessionManager.QueuedSubmission
function SessionManager:_dispatch_submission(submission)
    SubmissionController.dispatch_submission(self, submission)
end

--- Create a new session, optionally cancelling any existing one
--- @param opts {restore_mode: boolean|nil, on_created: fun()|nil}|nil
function SessionManager:new_session(opts)
    return SessionController.new_session(self, opts)
end

function SessionManager:_cancel_session()
    return SessionController.cancel_session(self)
end

--- Switch to a different ACP provider while preserving chat UI and history.
--- Reads Config.provider (already set by caller) for the target provider.
function SessionManager:switch_provider()
    return SessionController.switch_provider(self)
end

function SessionManager:_clear_inline_chat()
    WidgetBinding.clear_inline_chat(self)
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
    return SubmissionController.submit_inline_request(self, request)
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
    return WidgetBinding.get_workspace_root(self)
end

--- @param new_config_options agentic.acp.ConfigOption[]|nil
function SessionManager:_handle_new_config_options(new_config_options)
    WidgetBinding.handle_new_config_options(self, new_config_options)
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
    return SessionController.restore_session_data(self, persisted_session, opts)
end

return SessionManager
