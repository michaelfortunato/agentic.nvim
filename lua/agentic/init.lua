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

--- @class agentic.Agentic.InlineChatOpts
--- @field selection? agentic.Selection

--- @class agentic.Agentic.UserCommandArgs
--- @field args string
--- @field fargs string[]
--- @field line1 integer
--- @field line2 integer
--- @field range integer

--- @param session agentic.SessionManager
--- @param opts agentic.Agentic.ChatOpts|nil
local function show_session_widget(session, opts)
    opts = opts or {}

    --- @type agentic.Agentic.ChatOpts
    local show_opts = vim.tbl_extend("force", {}, opts)
    if show_opts.prompt_text ~= nil and show_opts.focus_prompt == nil then
        show_opts.focus_prompt = true
    end

    session.widget:show(show_opts)

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

    Logger.notify(
        string.format("Unknown AgenticChat subcommand: %s", subcommand),
        vim.log.levels.ERROR
    )
end

--- @param arg_lead string
--- @return string[]
local function complete_chat_subcommand(arg_lead)
    local matches = {}
    for _, candidate in ipairs({ "new", "restore" }) do
        if arg_lead == "" or candidate:find("^" .. vim.pesc(arg_lead)) then
            matches[#matches + 1] = candidate
        end
    end
    return matches
end

local function register_user_commands()
    pcall(vim.api.nvim_del_user_command, "AgenticChat")
    pcall(vim.api.nvim_del_user_command, "AgenticInline")

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
end

--- Opens the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.Agentic.ChatOpts|nil
function Agentic.open(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end

        show_session_widget(session, opts)
    end)
end

--- Closes the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.close()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session.widget:hide()
    end)
end

--- Toggles the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.Agentic.ChatOpts|nil
function Agentic.toggle(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
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
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session.widget:rotate_layout(layouts)
    end)
end

--- Add the current visual selection to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_to_session()
        session.widget:show(opts)
    end)
end

--- Add the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_file(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_file_to_session()
        session.widget:show(opts)
    end)
end

--- Add a list of file paths or buffer numbers to the Chat context
--- You can add 1 or more in a single call
--- @param opts agentic.ui.ChatWidget.AddFilesToContextOpts
function Agentic.add_files_to_context(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
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

        session.widget:show(opts)
    end)
end

--- Add either the current visual selection or the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection_or_file_to_context(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_or_file_to_session()
        session.widget:show(opts)
    end)
end

--- @class agentic.ui.NewSessionOpts : agentic.Agentic.ChatOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Add diagnostics at the current cursor line to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_current_line_diagnostics(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_current_line_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
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
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_buffer_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
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
    SessionRegistry.get_session_for_tab_page(nil, function(session)
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
    SessionRegistry.get_session_for_tab_page(nil, function(session)
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
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if session.is_generating then
            session.agent:stop_generation(session.session_id)
            session.permission_manager:clear()
        end
    end)
end

--- show a selector to restore a previous session
function Agentic.restore_session()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local current_session = SessionRegistry.sessions[tab_page_id]
    SessionRestore.show_picker(tab_page_id, current_session)
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
            if not Config.inline.enabled then
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

    -- Cleanup specific tab instance when tab is closed
    vim.api.nvim_create_autocmd("TabClosed", {
        group = cleanup_group,
        callback = function(ev)
            local tab_id = tonumber(ev.match)
            SessionRegistry.destroy_session(tab_id)
        end,
        desc = "Cleanup Agentic processes on tab close",
    })

    if Config.image_paste.enabled then
        local function get_current_session()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            return SessionRegistry.sessions[tab_page_id]
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
