local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local KeymapHelp = require("agentic.ui.keymap_help")

--- Controller for chat widget input flow and prompt-related keymaps.
--- @class agentic.ui.ChatWidget.InputController
--- @field widget any
local InputController = {}
InputController.__index = InputController

local KEYMAP_HELP_KEY = "?"

--- @param widget any
--- @return agentic.ui.ChatWidget.InputController
function InputController:new(widget)
    return setmetatable({ widget = widget }, self)
end

--- @param on_submit_input fun(prompt: string)|nil
function InputController:set_submit_input_handler(on_submit_input)
    self.widget.on_submit_input = on_submit_input or function() end
end

function InputController:submit_input()
    local lines =
        vim.api.nvim_buf_get_lines(self.widget.buf_nrs.input, 0, -1, false)

    local prompt = table.concat(lines, "\n"):match("^%s*(.-)%s*$")
    local mode = vim.fn.mode()
    local should_restore_insert = mode:sub(1, 1) == "i"
        and not Config.settings.move_cursor_to_chat_on_submit

    if not prompt or prompt == "" or not prompt:match("%S") then
        return
    end

    if Config.settings.move_cursor_to_chat_on_submit then
        vim.cmd("stopinsert")
    end

    vim.api.nvim_buf_set_lines(self.widget.buf_nrs.input, 0, -1, false, {})

    for _, panel_name in ipairs({ "code", "files", "diagnostics" }) do
        BufHelpers.with_modifiable(
            self.widget.buf_nrs[panel_name],
            function(bufnr)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
            end
        )
    end

    self.widget.on_submit_input(prompt)

    for _, panel_name in ipairs({ "code", "files", "diagnostics" }) do
        self.widget:close_optional_window(panel_name)
    end

    if Config.settings.move_cursor_to_chat_on_submit then
        self.widget:move_cursor_to(self.widget.win_nrs.chat)
    elseif should_restore_insert then
        vim.schedule(function()
            local winid = self.widget.win_nrs.input
            if not winid or not vim.api.nvim_win_is_valid(winid) then
                return
            end

            if vim.api.nvim_get_current_win() ~= winid then
                return
            end

            BufHelpers.start_insert_on_last_char()
        end)
    end
end

--- @param winid integer|nil
local function scroll_window_to_bottom(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    local last_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_win_set_cursor(winid, { last_line, 0 })
end

--- @param winid integer|nil
--- @param callback fun()|nil
function InputController:move_cursor_to(winid, callback)
    vim.schedule(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_set_current_win(winid)

            if winid == self.widget.win_nrs.chat then
                self.widget:scroll_chat_to_bottom()
            else
                scroll_window_to_bottom(winid)
            end

            if callback then
                callback()
            end
        end
    end)
end

function InputController:focus_input()
    vim.schedule(function()
        self.widget:scroll_chat_to_bottom()

        local winid = self.widget.win_nrs.input
        if not winid or not vim.api.nvim_win_is_valid(winid) then
            return
        end

        vim.api.nvim_set_current_win(winid)
        BufHelpers.start_insert_on_last_char()
    end)
end

--- @param text string
function InputController:set_input_text(text)
    local normalized = (text or ""):gsub("\r", "")
    local lines = vim.split(normalized, "\n", { plain = true })

    if #lines == 0 then
        lines = { "" }
    end

    BufHelpers.with_modifiable(self.widget.buf_nrs.input, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)
end

--- @return string
function InputController:get_input_text()
    local lines =
        vim.api.nvim_buf_get_lines(self.widget.buf_nrs.input, 0, -1, false)
    return table.concat(lines, "\n")
end

function InputController:bind_keymaps()
    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.submit,
        self.widget.buf_nrs.input,
        function()
            self:submit_input()
        end,
        { desc = "Agentic: Submit prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.paste_image,
        self.widget.buf_nrs.input,
        function()
            vim.schedule(function()
                local Clipboard = require("agentic.ui.clipboard")
                local res = Clipboard.paste_image()

                if res ~= nil then
                    vim.paste({ res }, -1)
                end
            end)
        end,
        { desc = "Agentic: Paste image from clipboard" }
    )

    for _, bufnr in pairs(self.widget.buf_nrs) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.close,
            bufnr,
            function()
                self.widget:hide()
            end,
            { desc = "Agentic: Close Chat widget" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_provider,
            bufnr,
            function()
                require("agentic").switch_provider()
            end,
            { desc = "Agentic: Switch provider" }
        )

        BufHelpers.multi_keymap_set(KEYMAP_HELP_KEY, bufnr, function()
            KeymapHelp.show_for_buffer(bufnr)
        end, { desc = "Agentic: Show available keymaps" })
    end

    BufHelpers.keymap_set(self.widget.buf_nrs.chat, "n", "<CR>", function()
        local winid = self.widget.win_nrs.chat
        if not winid or not vim.api.nvim_win_is_valid(winid) then
            return
        end

        if not self.widget._message_writer then
            return
        end

        local cursor = vim.api.nvim_win_get_cursor(winid)
        local toggled =
            self.widget._message_writer:toggle_tool_block_at_line(cursor[1] - 1)

        if not toggled then
            vim.cmd("normal! \\<CR>")
        end
    end, {
        desc = "Agentic: Toggle chat card details",
    })

    for panel_name, bufnr in pairs(self.widget.buf_nrs) do
        if panel_name ~= "input" then
            for _, key in ipairs({
                "a",
                "A",
                "o",
                "O",
                "i",
                "I",
                "c",
                "C",
                "x",
                "X",
            }) do
                BufHelpers.keymap_set(bufnr, "n", key, function()
                    self:focus_input()
                end)
            end
        end
    end
end

function InputController:destroy() end

return InputController
