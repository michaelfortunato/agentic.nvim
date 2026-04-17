---@diagnostic disable: invisible
local Config = require("agentic.config")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local ProviderUtils = require("agentic.acp.provider_utils")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SessionEvents = require("agentic.session.session_events")
local SessionSelectors = require("agentic.session.session_selectors")
local SlashCommands = require("agentic.acp.slash_commands")

--- UI Sync Scopes
--- - Tab-local: widget attachment, header rendering, queue panel layout, file/code/todo panels
--- - Window-local: chat viewport activity through ChatWidget/ChatViewport
--- - Buffer-local: message writer extmarks and side-panel buffer contents

local WidgetBinding = {}

--- @param session agentic.SessionManager
--- @return string
local function get_widget_tab_cwd(session)
    local widget_tab_page_id = session.widget and session.widget.tab_page_id
        or session.tab_page_id
    local tabnr = vim.api.nvim_tabpage_get_number(widget_tab_page_id)
    local cwd = vim.fn.getcwd(-1, tabnr)
    if cwd == nil or cwd == "" then
        cwd = vim.fn.getcwd()
    end

    return FileSystem.to_absolute_path(cwd)
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
local function clear_chat_activity(session)
    if get_session_method(session, "_clear_chat_activity") then
        call_session_method(session, "_clear_chat_activity")
        return
    end

    WidgetBinding.clear_chat_activity(session)
end

--- @param session agentic.SessionManager
--- @param state agentic.Theme.SpinnerState
--- @param opts {detail?: string|nil}|nil
local function set_chat_activity(session, state, opts)
    if get_session_method(session, "_set_chat_activity") then
        call_session_method(session, "_set_chat_activity", state, opts)
        return
    end

    WidgetBinding.set_chat_activity(session, state, opts)
end

--- @param session agentic.SessionManager
--- @return {input_text: string, file_paths: string[], code_selections: agentic.Selection[], diagnostics: agentic.ui.DiagnosticsList.Diagnostic[]}
function WidgetBinding.capture_widget_state(session)
    --- @type {input_text: string, file_paths: string[], code_selections: agentic.Selection[], diagnostics: agentic.ui.DiagnosticsList.Diagnostic[]}
    local snapshot = {
        input_text = "",
        file_paths = {},
        code_selections = {},
        diagnostics = {},
    }

    if session.widget and session.widget.get_input_text then
        snapshot.input_text = session.widget:get_input_text()
    end

    if session.file_list and session.file_list.get_files then
        snapshot.file_paths = session.file_list:get_files()
    end

    if session.code_selection and session.code_selection.get_selections then
        snapshot.code_selections = session.code_selection:get_selections()
    end

    if
        session.diagnostics_list
        and session.diagnostics_list.get_diagnostics
    then
        snapshot.diagnostics = session.diagnostics_list:get_diagnostics()
    end

    return snapshot
end

--- @param session agentic.SessionManager
function WidgetBinding.destroy_widget_bindings(session)
    if session.review_controller then
        session.review_controller:destroy()
        session.review_controller = nil
    end

    if session.status_animation and session.status_animation.stop then
        session.status_animation:stop()
    end
    session.status_animation = nil

    if session.message_writer and session.message_writer.destroy then
        session.message_writer:destroy()
    end
    session.message_writer = nil

    if session.widget then
        if session.widget.unbind_message_writer then
            session.widget:unbind_message_writer()
        end

        if session.widget.set_submit_input_handler then
            session.widget:set_submit_input_handler(function() end)
        end
    end

    session.queue_list = nil
    session.config_options = nil
    session.file_list = nil
    session.code_selection = nil
    session.diagnostics_list = nil
    session.todo_list = nil
    session.file_picker = nil
    session.skill_picker = nil
end

--- @param session agentic.SessionManager
function WidgetBinding.bind_widget_session_keymaps(session)
    if not session.widget then
        return
    end

    local BufHelpers = require("agentic.utils.buf_helpers")
    for _, bufnr in pairs(session.widget.buf_nrs) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.manage_queue,
            bufnr,
            function()
                call_session_method(session, "_focus_queue_panel")
            end,
            { desc = "Agentic: Manage queued messages" }
        )
    end
end

--- @param session agentic.SessionManager
--- @param widget agentic.ui.ChatWidget
--- @param snapshot {input_text?: string|nil, file_paths?: string[]|nil, code_selections?: agentic.Selection[]|nil, diagnostics?: agentic.ui.DiagnosticsList.Diagnostic[]|nil}|nil
function WidgetBinding.attach_widget(session, widget, snapshot)
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
    WidgetBinding.destroy_widget_bindings(session)
    session.widget = widget
    session.tab_page_id = widget.tab_page_id
    session.widget:set_submit_input_handler(function(input_text)
        call_session_method(session, "_handle_input_submit", input_text)
    end)

    session.message_writer = MessageWriter:new(session.widget.buf_nrs.chat, {
        should_auto_scroll = function()
            return session.widget:should_follow_chat_output()
        end,
        scroll_to_bottom = function()
            session.widget:scroll_chat_to_bottom()
        end,
        provider_name = session.agent.provider_config.name,
    })
    session.widget:bind_message_writer(session.message_writer)

    session.status_animation = StatusAnimation:new(session.widget.buf_nrs.chat)
    session.review_controller = ReviewController:new(
        session.session_state,
        session.widget,
        session.permission_manager
    )
    session.permission_manager:set_diff_review_handler(function(current_request)
        return session.review_controller:activate_diff_review(current_request)
    end)

    session.queue_list = QueueList:new(session.widget.buf_nrs.queue, {
        on_steer = function(submission_id)
            call_session_method(
                session,
                "_steer_queued_submission",
                submission_id
            )
        end,
        on_send_now = function(submission_id)
            call_session_method(
                session,
                "_send_queued_submission_now",
                submission_id
            )
        end,
        on_remove = function(submission_id)
            call_session_method(
                session,
                "_remove_queued_submission",
                submission_id
            )
        end,
        on_cancel = function()
            session.widget:focus_input()
        end,
    })

    call_session_method(session, "_setup_prompt_completion", FilePicker)

    session.config_options = AgentConfigOptions:new(
        session.widget.buf_nrs,
        function(config_id, value)
            call_session_method(
                session,
                "_handle_config_option_change",
                config_id,
                value
            )
        end
    )

    session.file_list = FileList:new(
        session.widget.buf_nrs.files,
        function(file_list)
            if file_list:is_empty() then
                session.widget:close_optional_window("files")
                session.widget:move_cursor_to(session.widget.win_nrs.input)
            else
                session.widget:render_header(
                    "files",
                    tostring(#file_list:get_files())
                )
                if not session["_restoring_widget_state"] then
                    session.widget:show({ focus_prompt = false })
                end
            end
        end
    )

    session.code_selection = CodeSelection:new(
        session.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                session.widget:close_optional_window("code")
                session.widget:move_cursor_to(session.widget.win_nrs.input)
            else
                session.widget:render_header(
                    "code",
                    tostring(#code_selection:get_selections())
                )
                if not session["_restoring_widget_state"] then
                    session.widget:show({ focus_prompt = false })
                end
            end
        end
    )

    session.diagnostics_list = DiagnosticsList:new(
        session.widget.buf_nrs.diagnostics,
        function(diagnostics_list)
            if diagnostics_list:is_empty() then
                session.widget:close_optional_window("diagnostics")
                session.widget:move_cursor_to(session.widget.win_nrs.input)
            else
                session.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                if not session["_restoring_widget_state"] then
                    session.widget:show({ focus_prompt = false })
                end
            end
        end
    )

    session.todo_list = TodoList:new(
        session.widget.buf_nrs.todos,
        function(todo_list)
            if
                not todo_list:is_empty()
                and not session["_restoring_widget_state"]
            then
                session.widget:show({ focus_prompt = false })
            end
        end,
        function()
            session.widget:close_optional_window("todos")
        end
    )

    WidgetBinding.bind_widget_session_keymaps(session)

    session["_restoring_widget_state"] = true
    session.widget:set_input_text(snapshot.input_text or "")
    for _, file_path in ipairs(snapshot.file_paths or {}) do
        session.file_list:add(file_path)
    end
    for _, selection in ipairs(snapshot.code_selections or {}) do
        session.code_selection:add(selection)
    end
    session.diagnostics_list:add_many(snapshot.diagnostics or {})

    local state = session.session_state:get_state()
    session.config_options:set_options(
        state.session.config_options or {},
        session.agent and session.agent.provider_config or nil
    )
    if
        state.session.current_mode_id
        and session.config_options.set_current_mode
    then
        session.config_options:set_current_mode(state.session.current_mode_id)
    end
    call_session_method(
        session,
        "_sync_prompt_commands",
        state.session.available_commands or {}
    )

    if Config.windows.todos.display then
        local entries = SessionSelectors.get_latest_plan_entries(state)
        if #entries > 0 then
            session.todo_list:render(entries)
        else
            session.todo_list:clear()
        end
    end

    session.queue_list:set_items(session.submission_queue:list())
    call_session_method(session, "_render_interaction_session", state)
    call_session_method(session, "_render_window_headers")
    session["_restoring_widget_state"] = false
    call_session_method(
        session,
        "_sync_queue_panel",
        session.submission_queue:count() > 0
    )
    call_session_method(session, "_sync_inline_queue_states")
    call_session_method(session, "_refresh_chat_activity")

    if session.widget:is_open() then
        session.widget:show({ focus_prompt = false })
    end
end

--- @param session agentic.SessionManager
--- @param other_session agentic.SessionManager|nil
function WidgetBinding.swap_widget(session, other_session)
    if
        other_session == nil
        or other_session == session
        or session.widget == nil
        or other_session.widget == nil
    then
        return
    end

    local own_snapshot = call_session_method(session, "_capture_widget_state")
    local other_snapshot =
        call_session_method(other_session, "_capture_widget_state")
    local own_widget = session.widget
    local other_widget = other_session.widget

    call_session_method(session, "_attach_widget", other_widget, own_snapshot)
    call_session_method(
        other_session,
        "_attach_widget",
        own_widget,
        other_snapshot
    )
end

--- @param session agentic.SessionManager
--- @param file_picker_module agentic.ui.FilePicker|nil
function WidgetBinding.setup_prompt_completion(session, file_picker_module)
    local FilePicker = file_picker_module or require("agentic.ui.file_picker")
    local SkillPicker = require("agentic.ui.skill_picker")

    session.file_picker = FilePicker:new(session.widget.buf_nrs.input, {
        resolve_root = function()
            return call_session_method(session, "_get_workspace_root")
        end,
        resolve_cwd = function()
            return call_session_method(session, "_get_current_cwd")
        end,
        on_file_selected = function(file_path)
            if session.file_list then
                session.file_list:add(file_path)
            end
        end,
    })

    if ProviderUtils.is_codex_provider(session.agent.provider_config) then
        session.skill_picker = SkillPicker:new(session.widget.buf_nrs.input, {
            resolve_workspace_root = function()
                return call_session_method(session, "_get_workspace_root")
            end,
        })
    else
        session.skill_picker = nil
    end

    SlashCommands.setup_completion(session.widget.buf_nrs.input)
end

--- @param session agentic.SessionManager
--- @param available_commands agentic.acp.AvailableCommand[]|nil
function WidgetBinding.sync_prompt_commands(session, available_commands)
    if
        not session.widget
        or not session.widget.buf_nrs
        or not session.widget.buf_nrs.input
    then
        return
    end

    local CodexLocalCommands = require("agentic.acp.codex_local_commands")

    -- Keep Codex-only shortcuts out of ACP session state and merge them only
    -- into the local completion list for this input buffer.
    SlashCommands.setCommands(
        session.widget.buf_nrs.input,
        available_commands or {},
        {
            local_commands = CodexLocalCommands.get_available_commands(session),
        }
    )
end

--- @param session agentic.SessionManager
--- @param state agentic.session.State|nil
function WidgetBinding.render_interaction_session(session, state)
    if not session.message_writer then
        return
    end

    state = state or session.session_state:get_state()
    session.message_writer:render_interaction_session(
        SessionSelectors.get_interaction_session(state),
        {
            welcome_lines = call_session_method(
                session,
                "_build_chat_welcome_lines",
                state
            ),
        }
    )
end

--- @param session agentic.SessionManager
--- @param state agentic.Theme.SpinnerState
--- @param opts {detail?: string|nil}|nil
function WidgetBinding.set_chat_activity(session, state, opts)
    if not session.status_animation or not session.status_animation.start then
        return
    end

    session.status_animation:start(state, opts)
end

--- @param session agentic.SessionManager
function WidgetBinding.clear_chat_activity(session)
    if session.status_animation and session.status_animation.stop then
        session.status_animation:stop()
    end
end

--- @param session agentic.SessionManager
function WidgetBinding.refresh_chat_activity(session)
    if not session.session_state then
        clear_chat_activity(session)
        return
    end

    local activity = SessionSelectors.get_chat_activity_info(
        session.session_state:get_state(),
        {
            session_starting = session["_session_starting"],
            is_generating = session.is_generating,
            agent_phase = session["_agent_phase"],
        }
    )

    if not activity then
        clear_chat_activity(session)
        return
    end

    set_chat_activity(session, activity.state, {
        detail = activity.detail,
    })
end

--- @param session agentic.SessionManager
function WidgetBinding.render_window_headers(session)
    local parts = {}
    local config_context = session.config_options:get_header_context()
    local queue_count = session.submission_queue
            and session.submission_queue:count()
        or 0
    if config_context and config_context ~= "" then
        parts[#parts + 1] = config_context
    end

    if queue_count > 0 then
        parts[#parts + 1] = string.format("Queue: %d", queue_count)
    end

    session.widget:render_header("chat", table.concat(parts, " | "))
    session.widget:render_header("input", "")
end

--- @param session agentic.SessionManager
function WidgetBinding.clear_inline_chat(session)
    if session.inline_chat then
        session.inline_chat:clear()
    end
end

--- @param session agentic.SessionManager
function WidgetBinding.focus_queue_panel(session)
    if session.submission_queue:is_empty() then
        Logger.notify("Queue is empty", vim.log.levels.INFO, {
            title = "Agentic Queue",
        })
        return
    end

    call_session_method(
        session,
        "_sync_queue_panel",
        session.submission_queue:count() > 0
    )
    session.widget:show({ focus_prompt = false })
    session.widget:move_cursor_to(session.widget.win_nrs.queue)
end

--- @param session agentic.SessionManager
--- @param was_visible boolean|nil
function WidgetBinding.sync_queue_panel(session, was_visible)
    local queue_count = session.submission_queue:count()
    local is_visible = queue_count > 0
    local queue_winid = session.widget
        and session.widget.win_nrs
        and session.widget.win_nrs.queue
    local queue_had_focus = queue_winid
        and vim.api.nvim_win_is_valid(queue_winid)
        and vim.api.nvim_get_current_win() == queue_winid

    if session.queue_list then
        session.queue_list:set_items(session.submission_queue:list())
    end

    if is_visible then
        session.widget:render_header("queue", tostring(queue_count))
    end

    call_session_method(session, "_render_window_headers")

    if
        not session.widget
        or type(session.widget.is_open) ~= "function"
        or not session.widget:is_open()
    then
        return
    end

    if was_visible ~= nil and was_visible ~= is_visible then
        session.widget:refresh_layout({ focus_prompt = false })
        if not is_visible and queue_had_focus then
            session.widget:focus_input()
        end
        return
    end

    if is_visible then
        local resized = session.widget:resize_optional_window(
            "queue",
            Config.windows.queue.max_height
        )
        if not resized then
            session.widget:refresh_layout({ focus_prompt = false })
        end
        return
    end

    session.widget:close_optional_window("queue")
    if queue_had_focus then
        session.widget:focus_input()
    end
end

--- @param session agentic.SessionManager
--- @return string
function WidgetBinding.get_workspace_root(session)
    local file_path
    local target_winid = session.widget:find_first_editor_window()

    if target_winid and vim.api.nvim_win_is_valid(target_winid) then
        local target_bufnr = vim.api.nvim_win_get_buf(target_winid)
        local target_path = vim.api.nvim_buf_get_name(target_bufnr)
        if target_path ~= "" then
            file_path = target_path
        end
    end

    local start_dir = file_path
            and vim.fs.dirname(FileSystem.to_absolute_path(file_path))
        or get_widget_tab_cwd(session)
    local git_marker = vim.fs.find({ ".git" }, {
        upward = true,
        path = start_dir,
    })[1]

    if git_marker then
        return FileSystem.to_absolute_path(vim.fs.dirname(git_marker))
    end

    return get_widget_tab_cwd(session)
end

--- @param session agentic.SessionManager
--- @return string
function WidgetBinding.get_current_cwd(session)
    return get_widget_tab_cwd(session)
end

--- @param session agentic.SessionManager
--- @param new_config_options agentic.acp.ConfigOption[]|nil
function WidgetBinding.handle_new_config_options(session, new_config_options)
    session.session_state:dispatch(
        SessionEvents.set_config_options(new_config_options or {})
    )
    session.config_options:set_options(
        new_config_options,
        session.agent and session.agent.provider_config or nil
    )
    call_session_method(
        session,
        "_sync_prompt_commands",
        session.session_state:get_state().session.available_commands or {}
    )
    call_session_method(session, "_render_window_headers")

    if session.inline_chat then
        session.inline_chat:refresh()
    end
end

return WidgetBinding
