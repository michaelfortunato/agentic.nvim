local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.ui.Chooser
local Chooser = {}

local TAB_STATE_KEY = "_agentic_chooser_state"
local DEFAULT_MAX_HEIGHT = 10
local MIN_WIDTH = 28
local MAX_WIDTH = 86

--- @class agentic.ui.Chooser.Opts
--- @field prompt? string
--- @field format_item? fun(item: any): string
--- @field max_height? integer
--- @field escape_choice? any
--- @field filetype? string
--- @field show_title? boolean

--- @param tabpage integer
--- @return table|nil
local function get_state(tabpage)
    return vim.t[tabpage][TAB_STATE_KEY]
end

--- @param tabpage integer
--- @param state table|nil
local function set_state(tabpage, state)
    vim.t[tabpage][TAB_STATE_KEY] = state
end

--- @param width integer
--- @param height integer
--- @return vim.api.keyset.win_config
local function build_window_config(width, height)
    return {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        width = width,
        height = height,
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(1, math.floor((vim.o.columns - width) / 2)),
        zindex = 90,
    }
end

--- @param labels string[]
--- @param prompt string
--- @return integer
local function calculate_width(labels, prompt)
    local width = vim.fn.strdisplaywidth(prompt) + 4

    for _, label in ipairs(labels) do
        width = math.max(width, vim.fn.strdisplaywidth(label) + 4)
    end

    return math.max(
        MIN_WIDTH,
        math.min(width, math.min(MAX_WIDTH, vim.o.columns - 6))
    )
end

--- @param tabpage integer
function Chooser.close(tabpage)
    local state = get_state(tabpage)
    if not state then
        return
    end

    set_state(tabpage, nil)

    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        pcall(vim.api.nvim_win_close, state.winid, true)
    end

    if state.origin_winid and vim.api.nvim_win_is_valid(state.origin_winid) then
        pcall(vim.api.nvim_set_current_win, state.origin_winid)
    end
end

--- @param name string
--- @param description string|nil
--- @param is_current boolean|nil
--- @return string
function Chooser.format_named_item(name, description, is_current)
    local prefix = is_current and "● " or "  "
    if description and description ~= "" then
        return string.format("%s%s: %s", prefix, name, description)
    end

    return prefix .. name
end

--- @param items any[]
--- @param opts agentic.ui.Chooser.Opts|nil
--- @param on_choice fun(choice: any|nil)
--- @return boolean shown
function Chooser.show(items, opts, on_choice)
    opts = opts or {}

    if not items or #items == 0 then
        return false
    end

    if #vim.api.nvim_list_uis() == 0 then
        vim.ui.select(items, {
            prompt = opts.prompt,
            format_item = opts.format_item,
        }, on_choice)
        return true
    end

    local prompt = opts.prompt or "Select:"
    local show_title = opts.show_title ~= false
    local format_item = opts.format_item
        or function(item)
            return tostring(item)
        end
    local escape_choice = opts.escape_choice

    local labels = {}
    for i, item in ipairs(items) do
        labels[i] = format_item(item)
    end

    local height = math.min(#labels, opts.max_height or DEFAULT_MAX_HEIGHT)
    local width = calculate_width(labels, show_title and prompt or "")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local origin_winid = vim.api.nvim_get_current_win()

    Chooser.close(tabpage)

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = opts.filetype or "AgenticChooser"

    BufHelpers.with_modifiable(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, labels)
    end)

    local win_config = build_window_config(width, height)
    if show_title then
        win_config.title = " " .. prompt .. " "
        win_config.title_pos = "center"
    end
    local winid = vim.api.nvim_open_win(bufnr, true, win_config)

    vim.wo[winid].wrap = false
    vim.wo[winid].cursorline = true
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].winfixbuf = true
    vim.wo[winid].winhighlight =
        "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual"

    local closed = false
    local function finish(choice)
        if closed then
            return
        end

        closed = true
        set_state(tabpage, nil)

        if vim.api.nvim_win_is_valid(winid) then
            pcall(vim.api.nvim_win_close, winid, true)
        end

        if origin_winid and vim.api.nvim_win_is_valid(origin_winid) then
            pcall(vim.api.nvim_set_current_win, origin_winid)
        end

        if on_choice then
            vim.schedule(function()
                on_choice(choice)
            end)
        end
    end

    local function select_current()
        local cursor = vim.api.nvim_win_get_cursor(winid)
        finish(items[cursor[1]])
    end

    --- @param line_delta integer
    --- @return fun()
    local function move_cursor(line_delta)
        return function()
            if not vim.api.nvim_win_is_valid(winid) then
                return
            end

            local cursor = vim.api.nvim_win_get_cursor(winid)
            local target_line = math.max(
                1,
                math.min(
                    vim.api.nvim_buf_line_count(bufnr),
                    cursor[1] + (line_delta * vim.v.count1)
                )
            )
            vim.api.nvim_win_set_cursor(winid, { target_line, cursor[2] })
        end
    end

    local move_down = move_cursor(1)
    local move_up = move_cursor(-1)

    vim.cmd.stopinsert()
    BufHelpers.keymap_set(bufnr, { "n", "i" }, "j", move_down, {
        desc = "Agentic chooser: move down",
    })
    BufHelpers.keymap_set(bufnr, "n", "<Down>", move_down, {
        desc = "Agentic chooser: move down",
    })
    BufHelpers.keymap_set(bufnr, { "n", "i" }, "k", move_up, {
        desc = "Agentic chooser: move up",
    })
    BufHelpers.keymap_set(bufnr, "n", "<Up>", move_up, {
        desc = "Agentic chooser: move up",
    })
    BufHelpers.keymap_set(bufnr, { "n", "i" }, "<CR>", select_current, {
        desc = "Agentic chooser: confirm",
    })
    BufHelpers.keymap_set(bufnr, "n", "q", function()
        finish(nil)
    end, {
        desc = "Agentic chooser: cancel",
    })
    BufHelpers.keymap_set(bufnr, "n", "<Esc>", function()
        finish(escape_choice)
    end, {
        desc = "Agentic chooser: cancel",
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        once = true,
        pattern = tostring(winid),
        callback = function()
            if not closed then
                finish(nil)
            end
        end,
    })

    return true
end

return Chooser
