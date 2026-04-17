local Logger = require("agentic.utils.logger")
local WidgetLayout = require("agentic.ui.widget_layout")

--- Controller for chat widget window lifecycle and tab-local window lookup.
--- @class agentic.ui.ChatWidget.WindowController
--- @field widget any
local WindowController = {}
WindowController.__index = WindowController

local EXCLUDED_FILETYPES = {
    ["neo-tree"] = true,
    ["NvimTree"] = true,
    ["oil"] = true,
    ["qf"] = true,
    ["help"] = true,
    ["man"] = true,
    ["terminal"] = true,
    ["TelescopePrompt"] = true,
    ["DiffviewFiles"] = true,
    ["DiffviewFileHistory"] = true,
    ["fugitive"] = true,
    ["gitcommit"] = true,
    ["dashboard"] = true,
    ["alpha"] = true,
    ["starter"] = true,
    ["notify"] = true,
    ["noice"] = true,
    ["aerial"] = true,
    ["Outline"] = true,
    ["trouble"] = true,
    ["spectre_panel"] = true,
    ["lazy"] = true,
    ["mason"] = true,
}

--- @param widget any
--- @return agentic.ui.ChatWidget.WindowController
function WindowController:new(widget)
    return setmetatable({ widget = widget }, self)
end

--- @return boolean
function WindowController:is_open()
    local win_id = self.widget.win_nrs.chat
    return (win_id and vim.api.nvim_win_is_valid(win_id)) or false
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
function WindowController:show(opts)
    opts = opts or {}

    WidgetLayout.open({
        tab_page_id = self.widget.tab_page_id,
        buf_nrs = self.widget.buf_nrs,
        win_nrs = self.widget.win_nrs,
        focus_prompt = opts.focus_prompt,
        anchor_winid = opts.anchor_winid,
    })

    self.widget:_restore_chat_window_view()
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
function WindowController:refresh_layout(opts)
    opts = opts or {}

    local previous_mode = vim.fn.mode()
    local previous_buf = vim.api.nvim_get_current_buf()

    self:hide()
    self:show(vim.tbl_extend("force", {
        focus_prompt = false,
    }, opts))

    vim.schedule(function()
        local winid = vim.fn.bufwinid(previous_buf)
        if winid ~= -1 then
            vim.api.nvim_set_current_win(winid)
        end

        if previous_mode == "i" then
            vim.cmd("startinsert")
        end
    end)
end

--- @return boolean
function WindowController:_should_create_fallback()
    return vim.api.nvim_get_current_tabpage() == self.widget.tab_page_id
end

function WindowController:hide()
    vim.cmd("stopinsert")

    if self:_should_create_fallback() then
        local fallback_winid = self:find_first_non_widget_window()

        if not fallback_winid then
            local created_winid = self:open_left_window()
            if not created_winid then
                Logger.notify(
                    "Failed to create fallback window; cannot hide widget safely, run `:tabclose` to close the tab instead.",
                    vim.log.levels.ERROR
                )
                return
            end
        end
    end

    self.widget:_store_chat_view()
    WidgetLayout.close(self.widget.win_nrs)
end

--- @param panel_name agentic.ui.ChatWidget.PanelNames
function WindowController:close_optional_window(panel_name)
    WidgetLayout.close_optional_window(self.widget.win_nrs, panel_name)
end

--- @param panel_name agentic.ui.ChatWidget.PanelNames
--- @param max_height integer
--- @return boolean resized
function WindowController:resize_optional_window(panel_name, max_height)
    return WidgetLayout.resize_dynamic_window(
        self.widget.buf_nrs,
        self.widget.win_nrs,
        panel_name,
        max_height
    )
end

--- @param bufnr number
--- @return boolean
function WindowController:owns_buffer(bufnr)
    for _, widget_bufnr in pairs(self.widget.buf_nrs) do
        if widget_bufnr == bufnr then
            return true
        end
    end

    return false
end

--- @return number|nil winid
function WindowController:find_first_non_widget_window()
    local all_windows = vim.api.nvim_tabpage_list_wins(self.widget.tab_page_id)

    local widget_win_ids = {}
    for _, winid in pairs(self.widget.win_nrs) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local ft = vim.bo[bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] then
                return winid
            end
        end
    end

    return nil
end

--- @return number|nil winid
function WindowController:find_first_editor_window()
    local all_windows = vim.api.nvim_tabpage_list_wins(self.widget.tab_page_id)
    local widget_win_ids = {}
    for _, winid in pairs(self.widget.win_nrs) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local ft = vim.bo[bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] and not ft:match("^Agentic") then
                return winid
            end
        end
    end

    return nil
end

--- @param bufnr integer|nil
--- @param enter boolean|nil
--- @return number|nil winid
function WindowController:open_left_window(bufnr, enter)
    if enter == nil then
        enter = true
    end

    if bufnr == nil then
        local alt_bufnr = vim.fn.bufnr("#")
        if
            alt_bufnr ~= -1
            and vim.api.nvim_buf_is_valid(alt_bufnr)
            and not self:owns_buffer(alt_bufnr)
        then
            local ft = vim.bo[alt_bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] then
                bufnr = alt_bufnr
            end
        end
    end

    if bufnr == nil then
        local oldfiles = vim.v.oldfiles
        local cwd = vim.fn.getcwd()
        if oldfiles and #oldfiles > 0 then
            for _, filepath in ipairs(oldfiles) do
                if
                    vim.startswith(filepath, cwd)
                    and vim.fn.filereadable(filepath) == 1
                then
                    local file_bufnr = vim.fn.bufnr(filepath)
                    if file_bufnr == -1 then
                        file_bufnr = vim.fn.bufadd(filepath)
                    end
                    bufnr = file_bufnr
                    break
                end
            end
        end
    end

    if bufnr == nil then
        bufnr = vim.api.nvim_create_buf(false, true)
    end

    local ok, winid = pcall(vim.api.nvim_open_win, bufnr, enter, {
        split = "left",
        win = -1,
    })

    if not ok then
        Logger.notify(
            "Failed to open window: " .. tostring(winid),
            vim.log.levels.WARN
        )
        return nil
    end

    return winid
end

return WindowController
