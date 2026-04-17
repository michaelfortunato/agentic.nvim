local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local ChatViewport = require("agentic.ui.chat_viewport")
local DiffPreview = require("agentic.ui.diff_preview")
local HeaderController = require("agentic.ui.chat_widget.header_controller")
local InputController = require("agentic.ui.chat_widget.input_controller")
local Logger = require("agentic.utils.logger")
local WindowController = require("agentic.ui.chat_widget.window_controller")
local WindowDecoration = require("agentic.ui.window_decoration")

--- UI Sync Scopes
--- - Tab-local: widget buffers, widget windows, header contexts, header overlays
--- - Window-local: chat follow/unread state via ChatViewport
--- - Buffer-local: per-buffer keymaps and rendered header/application state

--- @alias agentic.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"queue"|"input"|"diagnostics"

--- Runtime header parts with dynamic context
--- @class agentic.ui.ChatWidget.HeaderParts
--- @field title string Main header text
--- @field context? string Dynamic info (managed internally)
--- @field suffix? string Context help text

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts>

--- Options for controlling widget display behavior
--- @class agentic.ui.ChatWidget.AddToContextOpts
--- @field focus_prompt? boolean

--- Options for adding file paths or buffers to the current Chat context
--- @class agentic.ui.ChatWidget.AddFilesToContextOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field files (string|integer)[]

--- Options for showing the widget
--- @class agentic.ui.ChatWidget.ShowOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field auto_add_to_context? boolean Automatically add current selection or file to context when opening
--- @field anchor_winid? integer Open the widget relative to this window when creating it

--- A sidebar-style chat widget with multiple windows stacked vertically
--- The main chat window is the first, and contains the width, the below ones adapt to its size
--- @class agentic.ui.ChatWidget
--- @field instance_id? integer
--- @field tab_page_id integer
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field on_submit_input fun(prompt: string) external callback to be called when user submits the input
--- @field _chat_viewport agentic.ui.ChatViewport
--- @field _message_writer? agentic.ui.MessageWriter
--- @field headers agentic.ui.ChatWidget.Headers
--- @field _header_contexts table<agentic.ui.ChatWidget.PanelNames, string|nil>
--- @field _header_overlays table<agentic.ui.ChatWidget.PanelNames, string|nil>
--- @field _window_controller agentic.ui.ChatWidget.WindowController
--- @field _input_controller agentic.ui.ChatWidget.InputController
--- @field _header_controller agentic.ui.ChatWidget.HeaderController
local ChatWidget = {}
ChatWidget.__index = ChatWidget

--- @param tab_page_id integer
--- @param on_submit_input fun(prompt: string)
--- @param opts {instance_id?: integer|nil}|nil
function ChatWidget:new(tab_page_id, on_submit_input, opts)
    opts = opts or {}
    self = setmetatable({}, self)

    self.win_nrs = {}
    self._header_contexts = {}
    self._header_overlays = {}
    self.on_submit_input = on_submit_input
    self.tab_page_id = tab_page_id
    self.instance_id = opts.instance_id
    self.headers = WindowDecoration.get_default_headers()
    self._headers = self.headers

    self._window_controller = WindowController:new(self)
    self._input_controller = InputController:new(self)
    self._header_controller = HeaderController:new(self)

    self._chat_viewport = ChatViewport:new({
        tab_page_id = tab_page_id,
        get_chat_winid = function()
            return self.win_nrs.chat
        end,
        set_unread_context = function(context)
            self:_set_header_overlay("chat", context)
        end,
    })

    self:_initialize()

    return self
end

--- @return boolean
function ChatWidget:is_open()
    return self._window_controller:is_open()
end

--- Check if the cursor is currently in one of the widget's buffers
--- @return boolean
function ChatWidget:is_cursor_in_widget()
    if not self:is_open() then
        return false
    end

    return self:_is_widget_buffer(vim.api.nvim_get_current_buf())
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
function ChatWidget:show(opts)
    self._window_controller:show(opts)
end

--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function ChatWidget:rotate_layout(layouts)
    if not layouts or #layouts == 0 then
        layouts = { "right", "bottom", "left" }
    end

    if #layouts == 1 then
        Logger.notify(
            "Only one layout defined for rotation, it'll always show the same: "
                .. layouts[1],
            vim.log.levels.WARN,
            { title = "Agentic: rotate layout" }
        )
    end

    local current = Config.windows.position
    local next_layout = layouts[1]

    for i, layout in ipairs(layouts) do
        if layout == current then
            local next_index = i % #layouts + 1
            if layouts[next_index] then
                next_layout = layouts[next_index]
            end
            break
        end
    end

    Config.windows.position = next_layout

    local previous_mode = vim.fn.mode()
    local previous_buf = vim.api.nvim_get_current_buf()

    self:hide()
    self:show({
        focus_prompt = false,
    })

    vim.schedule(function()
        local win = vim.fn.bufwinid(previous_buf)
        if win ~= -1 then
            vim.api.nvim_set_current_win(win)
        end
        if previous_mode == "i" then
            vim.cmd("startinsert")
        end
    end)
end

--- Rebuild the widget windows while preserving the current widget focus when possible.
--- Useful when a dynamic panel needs to appear in the middle of the layout stack.
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function ChatWidget:refresh_layout(opts)
    self._window_controller:refresh_layout(opts)
end

--- Closes all windows but keeps buffers in memory
function ChatWidget:hide()
    self._window_controller:hide()
end

--- Cleans up all buffers content without destroying them
function ChatWidget:clear()
    for name, bufnr in pairs(self.buf_nrs) do
        BufHelpers.with_modifiable(bufnr, function()
            local ok =
                pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, { "" })
            if not ok then
                Logger.debug(
                    string.format(
                        "Failed to clear buffer '%s' with id: %d",
                        name,
                        bufnr
                    )
                )
            end
        end)
    end
end

--- Deletes all buffers and removes them from memory
--- This instance is no longer usable after calling this method
function ChatWidget:destroy()
    self:hide()
    self._header_controller:destroy()
    self._input_controller:destroy()
    self._chat_viewport:destroy()
    self._header_contexts = {}
    self._header_overlays = {}
    self._message_writer = nil

    for name, bufnr in pairs(self.buf_nrs) do
        self.buf_nrs[name] = nil
        local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to delete buffer '%s' with id: %d",
                    name,
                    bufnr
                )
            )
        end
    end
end

--- @param message_writer agentic.ui.MessageWriter
function ChatWidget:bind_message_writer(message_writer)
    self._message_writer = message_writer
    self._chat_viewport:bind_message_writer(message_writer)
end

function ChatWidget:unbind_message_writer()
    self._message_writer = nil
    self._chat_viewport:unbind_message_writer()
end

--- @param on_submit_input fun(prompt: string)|nil
function ChatWidget:set_submit_input_handler(on_submit_input)
    self._input_controller:set_submit_input_handler(on_submit_input)
end

function ChatWidget:_submit_input()
    self._input_controller:submit_input()
end

--- @param winid integer|nil
--- @param callback fun()|nil
function ChatWidget:move_cursor_to(winid, callback)
    self._input_controller:move_cursor_to(winid, callback)
end

function ChatWidget:focus_input()
    self._input_controller:focus_input()
end

--- @param text string
function ChatWidget:set_input_text(text)
    self._input_controller:set_input_text(text)
end

--- @return string
function ChatWidget:get_input_text()
    return self._input_controller:get_input_text()
end

function ChatWidget:_initialize()
    self.buf_nrs = self:_create_buf_nrs()
    self:_bind_keymaps()
    self:_bind_events_to_change_headers()

    for _, bufnr in ipairs({
        self.buf_nrs.chat,
        self.buf_nrs.input,
    }) do
        vim.api.nvim_create_autocmd("BufWinLeave", {
            buffer = bufnr,
            callback = function()
                self:hide()
            end,
        })
    end
end

--- @return boolean
function ChatWidget:_update_chat_follow_output()
    return self._chat_viewport:update_follow_output()
end

function ChatWidget:_store_chat_view()
    self._chat_viewport:store_view()
end

function ChatWidget:_restore_chat_window_view()
    self._chat_viewport:restore_view()
end

--- @return boolean
function ChatWidget:should_follow_chat_output()
    return self._chat_viewport:should_follow_output()
end

function ChatWidget:scroll_chat_to_bottom()
    self._chat_viewport:scroll_to_bottom()
end

function ChatWidget:_bind_keymaps()
    self._input_controller:bind_keymaps()
    DiffPreview.setup_diff_navigation_keymaps(self.buf_nrs)
end

--- @return agentic.ui.ChatWidget.BufNrs
function ChatWidget:_create_buf_nrs()
    local chat = self:_create_new_buf({
        filetype = "AgenticChat",
    })

    local todos = self:_create_new_buf({
        filetype = "AgenticTodos",
    })

    local code = self:_create_new_buf({
        filetype = "AgenticCode",
    })

    local files = self:_create_new_buf({
        filetype = "AgenticFiles",
    })

    local queue = self:_create_new_buf({
        filetype = "AgenticQueue",
    })

    local diagnostics = self:_create_new_buf({
        filetype = "AgenticDiagnostics",
    })

    local input = self:_create_new_buf({
        filetype = "AgenticInput",
        modifiable = true,
    })

    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        queue = queue,
        diagnostics = diagnostics,
        input = input,
    }

    return buf_nrs
end

--- @param opts table<string, any>
--- @return integer bufnr
function ChatWidget:_create_new_buf(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)

    local config = vim.tbl_deep_extend("force", {
        swapfile = false,
        buftype = "nofile",
        bufhidden = "hide",
        buflisted = false,
        modifiable = false,
    }, opts)

    for key, value in pairs(config) do
        vim.api.nvim_set_option_value(key, value, { buf = bufnr })
    end

    return bufnr
end

function ChatWidget:_refresh_header_keymap_hints()
    self._header_controller:refresh_header_keymap_hints()
end

function ChatWidget:_bind_events_to_change_headers()
    self._header_controller:bind_events_to_change_headers()
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @return string|nil
function ChatWidget:_get_effective_header_context(window_name)
    return self._header_controller:get_effective_header_context(window_name)
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil
function ChatWidget:_set_header_overlay(window_name, context)
    self._header_controller:set_header_overlay(window_name, context)
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil
function ChatWidget:render_header(window_name, context)
    self._header_controller:render_header(window_name, context)
end

--- @param panel_name agentic.ui.ChatWidget.PanelNames
function ChatWidget:close_optional_window(panel_name)
    self._window_controller:close_optional_window(panel_name)
end

--- @param panel_name agentic.ui.ChatWidget.PanelNames
--- @param max_height integer
--- @return boolean resized
function ChatWidget:resize_optional_window(panel_name, max_height)
    return self._window_controller:resize_optional_window(
        panel_name,
        max_height
    )
end

--- @return number|nil winid
function ChatWidget:find_first_non_widget_window()
    return self._window_controller:find_first_non_widget_window()
end

--- @return number|nil winid
function ChatWidget:find_first_editor_window()
    return self._window_controller:find_first_editor_window()
end

--- @param bufnr number
--- @return boolean
function ChatWidget:_is_widget_buffer(bufnr)
    return self:owns_buffer(bufnr)
end

--- @param bufnr integer
--- @return boolean
function ChatWidget:owns_buffer(bufnr)
    return self._window_controller:owns_buffer(bufnr)
end

--- @param bufnr number|nil
--- @param enter boolean|nil
--- @return number|nil winid
function ChatWidget:open_left_window(bufnr, enter)
    return self._window_controller:open_left_window(bufnr, enter)
end

package.loaded["agentic.ui.ChatWidget"] = ChatWidget

return ChatWidget
