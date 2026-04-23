local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local Theme = require("agentic.theme")
local SessionRegistry = require("agentic.session_registry")
local SessionRestore = require("agentic.session_restore")
local CodeSelection = require("agentic.ui.code_selection")
local Object = require("agentic.utils.object")
local Logger = require("agentic.utils.logger")

--- @class agentic.Agentic
local Agentic = {}

--- @class agentic.Agentic.ChatOpts : agentic.ui.ChatWidget.ShowOpts
--- @field prompt_text? string Pre-fill the chat input buffer after opening

--- @alias agentic.Agentic.ShowSessionOpts
--- | agentic.Agentic.ChatOpts
--- | agentic.ui.ChatWidget.AddToContextOpts
--- | agentic.ui.ChatWidget.AddFilesToContextOpts

--- @class agentic.Agentic.InlineChatOpts
--- @field selection? agentic.Selection

--- @class agentic.Agentic.UserCommandArgs
--- @field args string
--- @field fargs string[]
--- @field line1 integer
--- @field line2 integer
--- @field range integer

--- @param tab_page_id integer|nil
--- @return agentic.SessionManager[] sessions
local function get_open_widget_sessions(tab_page_id)
    local resolved_tab_page_id = tab_page_id
        or vim.api.nvim_get_current_tabpage()
    --- @type agentic.SessionManager[]
    local sessions = {}

    for _, session in
        ipairs(SessionRegistry.get_widget_sessions(resolved_tab_page_id))
    do
        local widget = session and session.widget or nil
        if widget and widget.is_open and widget:is_open() then
            sessions[#sessions + 1] = session
        end
    end

    return sessions
end

--- @param tab_page_id integer|nil
--- @return agentic.SessionManager|nil session
local function get_open_widget_session(tab_page_id)
    return get_open_widget_sessions(tab_page_id)[1]
end

--- @param tab_page_id integer|nil
--- @param except_session agentic.SessionManager|nil
--- @return integer hidden_count
local function hide_open_widget_sessions(tab_page_id, except_session)
    local hidden_count = 0

    for _, session in ipairs(get_open_widget_sessions(tab_page_id)) do
        if
            session ~= except_session
            and session.widget
            and session.widget.hide
        then
            session.widget:hide()
            hidden_count = hidden_count + 1
        end
    end

    return hidden_count
end

--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil session
local function get_or_create_widget_session(callback)
    local session = get_open_widget_session(nil)
    if session then
        if callback then
            callback(session)
        end
        return session
    end

    return SessionRegistry.get_or_create_session(callback)
end

--- @param session agentic.SessionManager
--- @param opts agentic.Agentic.ShowSessionOpts|nil
local function show_session_widget(session, opts)
    opts = opts or {}

    --- @type agentic.Agentic.ChatOpts
    local show_opts = vim.tbl_extend("force", {}, opts)
    if show_opts.prompt_text ~= nil and show_opts.focus_prompt == nil then
        show_opts.focus_prompt = true
    end

    local invoking_winid = vim.api.nvim_get_current_win()
    if show_opts.anchor_winid == nil then
        local current_session =
            SessionRegistry.find_session_by_buf(vim.api.nvim_get_current_buf())
        if
            current_session
            and current_session.widget
            and current_session.widget.find_first_editor_window
        then
            show_opts.anchor_winid =
                current_session.widget:find_first_editor_window()
        else
            show_opts.anchor_winid = invoking_winid
        end
    end

    local widget_tab_page_id = session.widget and session.widget.tab_page_id
        or vim.api.nvim_get_current_tabpage()
    hide_open_widget_sessions(widget_tab_page_id, session)
    if
        show_opts.anchor_winid ~= nil
        and not vim.api.nvim_win_is_valid(show_opts.anchor_winid)
    then
        show_opts.anchor_winid = vim.api.nvim_get_current_win()
    end

    session.widget:show(show_opts)
    SessionRegistry.set_active_session(session, show_opts.anchor_winid)

    if show_opts.prompt_text ~= nil then
        session.widget:set_input_text(show_opts.prompt_text)
        session.widget:focus_input()
    end
end

--- @param command_opts agentic.Agentic.UserCommandArgs
--- @return string|nil
local function get_command_prompt_text(command_opts)
    if command_opts.range == 0 then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(
        0,
        command_opts.line1 - 1,
        command_opts.line2,
        false
    )
    if #lines == 0 then
        return nil
    end

    return table.concat(lines, "\n")
end

--- @param command_opts agentic.Agentic.UserCommandArgs
--- @return agentic.Selection|nil
local function get_command_selection(command_opts)
    if command_opts.range == 0 then
        return nil
    end

    return CodeSelection.get_buffer_selection(
        0,
        command_opts.line1,
        command_opts.line2
    )
end

--- @param command_opts agentic.Agentic.UserCommandArgs
--- @return agentic.Agentic.ChatOpts|nil
local function get_chat_command_opts(command_opts)
    local prompt_text = get_command_prompt_text(command_opts)
    if prompt_text == nil then
        return nil
    end

    return {
        auto_add_to_context = false,
        focus_prompt = true,
        prompt_text = prompt_text,
    }
end

--- @param command_opts agentic.Agentic.UserCommandArgs
local function handle_chat_command(command_opts)
    local subcommand = vim.trim(command_opts.args or "")

    if subcommand == "" then
        Agentic.toggle(get_chat_command_opts(command_opts))
        return
    end

    if subcommand == "new" then
        Agentic.new_session(
            get_chat_command_opts(command_opts) --[[@as agentic.ui.NewSessionOpts|nil]]
        )
        return
    end

    if subcommand == "restore" then
        Agentic.restore_session()
        return
    end

    if subcommand == "load" then
        Agentic.load_session()
        return
    end

    Logger.notify(
        string.format("Unknown AgenticChat subcommand: %s", subcommand),
        vim.log.levels.ERROR
    )
end

--- @param arg_lead string
--- @return string[]
local function complete_chat_subcommand(arg_lead)
    local matches = {}
    for _, candidate in ipairs({ "new", "restore", "load" }) do
        if arg_lead == "" or candidate:find("^" .. vim.pesc(arg_lead)) then
            matches[#matches + 1] = candidate
        end
    end
    return matches
end

local function register_user_commands()
    pcall(vim.api.nvim_del_user_command, "AgenticChat")
    pcall(vim.api.nvim_del_user_command, "AgenticInline")
    pcall(vim.api.nvim_del_user_command, "AgenticInlineClear")

    vim.api.nvim_create_user_command("AgenticChat", function(command_opts)
        handle_chat_command(
            command_opts --[[@as agentic.Agentic.UserCommandArgs]]
        )
    end, {
        nargs = "?",
        range = true,
        complete = function(arg_lead)
            return complete_chat_subcommand(arg_lead)
        end,
        desc = "Toggle Agentic chat, start a new chat, or restore a session",
    })

    vim.api.nvim_create_user_command("AgenticInline", function(command_opts)
        local selection = get_command_selection(
            command_opts --[[@as agentic.Agentic.UserCommandArgs]]
        )
        Agentic.inline_chat({ selection = selection })
    end, {
        nargs = 0,
        range = true,
        desc = "Open Agentic inline chat for the current or provided selection",
    })

    vim.api.nvim_create_user_command("AgenticInlineClear", function()
        Agentic.inline_clear_current_buffer()
    end, {
        nargs = 0,
        desc = "Clear Agentic inline artifacts for the current buffer",
    })
end

--- Opens the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.Agentic.ChatOpts|nil
function Agentic.open(opts)
    get_or_create_widget_session(function(session)
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end

        show_session_widget(session, opts)
    end)
end

--- Closes the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.close()
    if hide_open_widget_sessions(nil, nil) > 0 then
        return
    end

    SessionRegistry.get_current_session(function(session)
        session.widget:hide()
    end)
end

--- Toggles the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.Agentic.ChatOpts|nil
function Agentic.toggle(opts)
    if
        (not opts or opts.prompt_text == nil)
        and hide_open_widget_sessions(nil, nil) > 0
    then
        return
    end

    get_or_create_widget_session(function(session)
        if
            session.widget:is_open() and (not opts or opts.prompt_text == nil)
        then
            session.widget:hide()
        else
            if not opts or opts.auto_add_to_context ~= false then
                session:add_selection_or_file_to_session()
            end

            show_session_widget(session, opts)
        end
    end)
end

--- Rotates through predefined window layouts for the chat widget
--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function Agentic.rotate_layout(layouts)
    local open_widget_session = get_open_widget_session(nil)
    if open_widget_session then
        hide_open_widget_sessions(nil, open_widget_session)
        open_widget_session.widget:rotate_layout(layouts)
        return
    end

    SessionRegistry.get_current_session(function(session)
        session.widget:rotate_layout(layouts)
    end)
end

--- Add the current visual selection to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection(opts)
    get_or_create_widget_session(function(session)
        session:add_selection_to_session()
        show_session_widget(session, opts)
    end)
end

--- Add the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_file(opts)
    get_or_create_widget_session(function(session)
        session:add_file_to_session()
        show_session_widget(session, opts)
    end)
end

--- Add a list of file paths or buffer numbers to the Chat context
--- You can add 1 or more in a single call
--- @param opts agentic.ui.ChatWidget.AddFilesToContextOpts
function Agentic.add_files_to_context(opts)
    get_or_create_widget_session(function(session)
        local files = opts.files

        if files and type(files) == "table" then
            for _, path in ipairs(files) do
                session:add_file_to_session(path)
            end
        else
            Logger.notify(
                "Wrong parameters passed to `add_files_to_context()`: "
                    .. vim.inspect(opts)
            )
        end

        show_session_widget(session, opts)
    end)
end

--- Add either the current visual selection or the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection_or_file_to_context(opts)
    get_or_create_widget_session(function(session)
        session:add_selection_or_file_to_session()
        show_session_widget(session, opts)
    end)
end

--- @class agentic.ui.NewSessionOpts : agentic.Agentic.ChatOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Add diagnostics at the current cursor line to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_current_line_diagnostics(opts)
    get_or_create_widget_session(function(session)
        local count = session:add_current_line_diagnostics_to_context()
        if count > 0 then
            show_session_widget(session, opts)
        else
            Logger.notify(
                "No diagnostics found on the current line",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Add all diagnostics from the current buffer to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_buffer_diagnostics(opts)
    get_or_create_widget_session(function(session)
        local count = session:add_buffer_diagnostics_to_context()
        if count > 0 then
            show_session_widget(session, opts)
        else
            Logger.notify(
                "No diagnostics found in the current buffer",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Open inline chat for the current visual selection.
--- @param opts agentic.Agentic.InlineChatOpts|nil
function Agentic.inline_chat(opts)
    SessionRegistry.get_or_create_session(function(session)
        session:open_inline_chat(opts and opts.selection or nil)
    end)
end

--- Destroys the current Chat session and starts a new one
--- @param opts agentic.ui.NewSessionOpts|nil
function Agentic.new_session(opts)
    if opts and opts.provider then
        Config.provider = opts.provider
    end

    local session = SessionRegistry.new_session()
    if session then
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        show_session_widget(session, opts)
    end
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.new_session_with_provider(opts)
    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            local merged_opts = vim.tbl_deep_extend("force", opts or {}, {
                provider = provider_name,
            }) --[[@as agentic.ui.NewSessionOpts]]

            Agentic.new_session(merged_opts)
        end
    end)
end

--- @class agentic.ui.SwitchProviderOpts
--- @field provider? agentic.UserConfig.ProviderName

--- @param provider_name agentic.UserConfig.ProviderName
local function apply_provider_switch(provider_name)
    Config.provider = provider_name
    SessionRegistry.get_current_session(function(session)
        session:switch_provider()
    end)
end

--- Switch to a different provider while preserving chat UI and history.
--- If opts.provider is set, switches directly. Otherwise shows a picker.
--- @param opts agentic.ui.SwitchProviderOpts|nil
function Agentic.switch_provider(opts)
    if opts and opts.provider then
        apply_provider_switch(opts.provider)
        return
    end

    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            apply_provider_switch(provider_name)
        end
    end)
end

--- Stops the agent's current generation or tool execution
--- The session remains active and ready for the next prompt
--- Safe to call multiple times or when no generation is active
function Agentic.stop_generation()
    SessionRegistry.get_current_session(function(session)
        local target_session_ids = {}
        if session.is_generating and session.session_id then
            target_session_ids[#target_session_ids + 1] = session.session_id
        end

        for _, inline_session in
            pairs(rawget(session, "_inline_sessions") or {})
        do
            if inline_session.is_generating and inline_session.session_id then
                target_session_ids[#target_session_ids + 1] =
                    inline_session.session_id
            end
        end

        if
            #target_session_ids == 0
            and session.get_active_generation_session_id
        then
            local target_session_id = session:get_active_generation_session_id()
            if target_session_id then
                target_session_ids[#target_session_ids + 1] = target_session_id
            end
        end

        if #target_session_ids > 0 then
            for _, target_session_id in ipairs(target_session_ids) do
                session.agent:stop_generation(target_session_id)
            end
            session.permission_manager:clear()
        end
    end)
end

--- show a selector to restore a previous session
function Agentic.restore_session()
    local current_session = get_open_widget_session(nil)
        or SessionRegistry.get_current_session()
    SessionRestore.show_picker(current_session)
end

function Agentic.load_session()
    local current_session = get_open_widget_session(nil)
        or SessionRegistry.get_current_session()
    if not current_session then
        Logger.notify(
            "Open or focus a chat widget before loading another live session.",
            vim.log.levels.INFO
        )
        return
    end

    local shown = SessionRegistry.select_live_session(
        current_session,
        function(target_session)
            if target_session then
                SessionRegistry.load_session_into_current_widget(target_session)
            end
        end
    )

    if not shown then
        Logger.notify(
            "No other live sessions are available in this tab.",
            vim.log.levels.INFO
        )
    end
end

function Agentic.inline_clear_current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    SessionRegistry.clear_inline_buffer(bufnr)
    Logger.notify(
        "Cleared Agentic inline artifacts for the current buffer.",
        vim.log.levels.INFO
    )
end

--- Used to make sure we don't set multiple signal handlers or autocmds, if the user calls setup multiple times
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
--- @param opts agentic.PartialUserConfig
function Agentic.setup(opts)
    -- make sure invalid user config doesn't crash setup and leave things half-initialized
    local ok, err = pcall(function()
        Object.merge_config(Config, opts or {})
    end)

    if not ok then
        Logger.notify(
            "[Agentic] Error in user configuration: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic: user config merge error" }
        )
    end

    if traps_set then
        return
    end

    traps_set = true

    vim.treesitter.language.register("markdown", "AgenticChat")

    Theme.setup()
    register_user_commands()

    local BufHelpers = require("agentic.utils.buf_helpers")

    vim.api.nvim_create_autocmd("BufEnter", {
        group = cleanup_group,
        callback = function(ev)
            if not Config.inline or not Config.inline.enabled then
                return
            end

            if not Config.keymaps.inline or not Config.keymaps.inline.open then
                return
            end

            if vim.b[ev.buf]._agentic_inline_keymaps_bound then
                return
            end

            if vim.bo[ev.buf].buftype ~= "" then
                return
            end

            if vim.bo[ev.buf].filetype:match("^Agentic") then
                return
            end

            BufHelpers.multi_keymap_set(
                Config.keymaps.inline.open,
                ev.buf,
                function()
                    Agentic.inline_chat()
                end,
                { desc = "Agentic: Inline chat" }
            )
            vim.b[ev.buf]._agentic_inline_keymaps_bound = true
        end,
        desc = "Bind Agentic inline chat keymaps to editable buffers",
    })

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = cleanup_group,
        callback = function()
            Theme.setup()
        end,
        desc = "Reapply Agentic highlights after colorscheme changes",
    })

    -- Force-reload buffers when files change on disk (e.g., agent edits files directly).
    -- Suppresses the "file changed" prompt so modified buffers reload silently,
    -- matching Cursor/Zed behavior where agent changes always win.
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = cleanup_group,
        pattern = "*",
        callback = function()
            vim.v.fcs_choice = "reload"
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = cleanup_group,
        callback = function()
            AgentInstance:cleanup_all()
        end,
        desc = "Cleanup Agentic processes on exit",
    })

    -- Cleanup widget-bound sessions when a tab is closed.
    vim.api.nvim_create_autocmd("TabClosed", {
        group = cleanup_group,
        callback = function(ev)
            local tab_id = tonumber(ev.match)
            if tab_id ~= nil then
                SessionRegistry.destroy_widget_sessions_for_tab(tab_id)
            end
        end,
        desc = "Cleanup Agentic processes on tab close",
    })

    if Config.image_paste.enabled then
        local function get_current_session()
            return SessionRegistry.get_current_session()
        end

        local Clipboard = require("agentic.ui.clipboard")

        Clipboard.setup({
            is_cursor_in_widget = function()
                local session = get_current_session()
                return session and session.widget:is_cursor_in_widget() or false
            end,
            on_paste = function(file_path)
                local session = get_current_session()

                if not session then
                    return false
                end

                local ret = session.file_list:add(file_path) or false

                if ret then
                    session.widget:show({
                        focus_prompt = false,
                    })
                end

                return ret
            end,
        })
    end

    -- Setup signal handlers for graceful shutdown
    local sigterm_handler = vim.uv.new_signal()
    if sigterm_handler then
        vim.uv.signal_start(sigterm_handler, "sigterm", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end

    -- SIGINT handler (Ctrl-C) - note: may not trigger in raw terminal mode
    local sigint_handler = vim.uv.new_signal()
    if sigint_handler then
        vim.uv.signal_start(sigint_handler, "sigint", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end
end

return Agentic
