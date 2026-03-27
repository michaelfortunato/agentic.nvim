local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local BufHelpers = require("agentic.utils.buf_helpers")
local WindowDecoration = require("agentic.ui.window_decoration")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.WidgetLayout.Params
--- @field tab_page_id integer
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field focus_prompt? boolean
--- @field anchor_winid? integer|nil

--- @class agentic.ui.WidgetLayout
local WidgetLayout = {}

--- @param size number|string
--- @param max_dimension integer
--- @param default_percentage number|string
--- @return integer
local function calculate_dimension(size, max_dimension, default_percentage)
    size = size or default_percentage

    if type(size) == "string" then
        local pct = string.sub(size, -1) == "%"
            and tonumber(string.sub(size, 1, -2))
        if not pct then
            -- Invalid string without % sign, fallback to default percentage
            Logger.notify(
                "Invalid size string: "
                    .. size
                    .. ", expected format like '40%'",
                vim.log.levels.WARN
            )

            return calculate_dimension(
                default_percentage,
                max_dimension,
                default_percentage
            )
        end
        return math.max(1, math.floor(max_dimension * pct / 100))
    end

    if size > 0 and size < 1 then
        return math.max(1, math.floor(max_dimension * size))
    end

    return math.max(1, math.floor(size))
end

--- @param size number|string
--- @return integer
function WidgetLayout.calculate_width(size)
    return calculate_dimension(size, vim.o.columns, DefaultConfig.windows.width)
end

--- @param size number|string
--- @return integer
function WidgetLayout.calculate_height(size)
    return calculate_dimension(size, vim.o.lines, DefaultConfig.windows.height)
end

--- @param chat_width integer
--- @return integer
function WidgetLayout.calculate_stack_width(chat_width)
    local ratio = tonumber(Config.windows.stack_width_ratio)
        or DefaultConfig.windows.stack_width_ratio
    local min_width = tonumber(Config.windows.stack_min_width)
        or DefaultConfig.windows.stack_min_width
    local max_width = tonumber(Config.windows.stack_max_width)
        or DefaultConfig.windows.stack_max_width

    local raw_width = math.floor(chat_width * ratio)
    local clamped_width = math.max(min_width, raw_width)
    clamped_width = math.min(clamped_width, max_width)

    return math.max(1, math.min(clamped_width, math.max(1, chat_width - 1)))
end

--- @param bufnr integer
--- @param max_height integer
--- @return integer
local function calculate_dynamic_height(bufnr, max_height)
    max_height = math.max(1, max_height)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    -- Use 2 in bottom layout to prevent the file list from touching the screen edge
    local padding = Config.windows.position == "bottom" and 2 or 1
    return math.min(line_count + padding, max_height)
end

--- @param bufnr integer
--- @param enter boolean
--- @param opts vim.api.keyset.win_config
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param win_opts table<string, any>
--- @return integer
local function open_win(bufnr, enter, opts, window_name, win_opts)
    --- @type vim.api.keyset.win_config
    local default_opts = {
        split = "right",
        win = -1,
        noautocmd = true,
        style = "minimal",
    }

    local config = vim.tbl_deep_extend("force", default_opts, opts)

    local winid = vim.api.nvim_open_win(bufnr, enter, config)

    local window_config = Config.windows[window_name] or {}
    local config_win_opts = window_config.win_opts or {}

    local merged_win_opts = vim.tbl_deep_extend("force", {
        wrap = true,
        linebreak = true,
        winfixbuf = true,
        winfixheight = true,
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
    }, win_opts or {}, config_win_opts)

    for name, value in pairs(merged_win_opts) do
        vim.api.nvim_set_option_value(name, value, { win = winid })
    end

    WindowDecoration.apply_window_style(winid)

    return winid
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param panel_name string
--- @param bufnr integer
--- @param open_opts vim.api.keyset.win_config
--- @param win_opts table<string, any>
--- @return integer
local function get_or_create_window(
    win_nrs,
    panel_name,
    bufnr,
    open_opts,
    win_opts
)
    local cached_winid = win_nrs[panel_name]
    if cached_winid and vim.api.nvim_win_is_valid(cached_winid) then
        return cached_winid
    end

    local new_winid =
        open_win(bufnr, false, open_opts, panel_name, win_opts or {})
    win_nrs[panel_name] = new_winid
    WindowDecoration.render_header(bufnr, panel_name)
    return new_winid
end

--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param open_win_opts vim.api.keyset.win_config
--- @param max_height integer
local function open_or_resize_dynamic_window(
    buf_nrs,
    win_nrs,
    window_name,
    open_win_opts,
    max_height
)
    local bufnr = buf_nrs[window_name]
    local winid = win_nrs[window_name]

    if BufHelpers.is_buffer_empty(bufnr) then
        if winid and vim.api.nvim_win_is_valid(winid) then
            pcall(vim.api.nvim_win_close, winid, true)
        end
        win_nrs[window_name] = nil
        return
    end

    local height = calculate_dynamic_height(bufnr, max_height)

    if not winid or not vim.api.nvim_win_is_valid(winid) then
        open_win_opts.height = height
        win_nrs[window_name] =
            open_win(bufnr, false, open_win_opts, window_name, {})
    else
        vim.api.nvim_win_set_config(winid, { height = height })
    end

    WindowDecoration.render_header(bufnr, window_name)
end

--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param max_height integer
--- @return boolean resized
function WidgetLayout.resize_dynamic_window(
    buf_nrs,
    win_nrs,
    window_name,
    max_height
)
    local bufnr = buf_nrs[window_name]
    local winid = win_nrs[window_name]

    if
        not bufnr
        or not vim.api.nvim_buf_is_valid(bufnr)
        or not winid
        or not vim.api.nvim_win_is_valid(winid)
        or BufHelpers.is_buffer_empty(bufnr)
    then
        return false
    end

    local height = calculate_dynamic_height(bufnr, max_height)

    vim.api.nvim_win_set_config(winid, {
        height = height,
    })
    WindowDecoration.render_header(bufnr, window_name)
    return vim.api.nvim_win_get_height(winid) == height
end

--- @param params agentic.ui.WidgetLayout.Params
--- @param position agentic.UserConfig.Windows.Position
local function show_layout(params, position)
    local is_bottom = position == "bottom"
    local win_nrs = params.win_nrs
    local buf_nrs = params.buf_nrs
    local should_focus = (
        params.focus_prompt == nil and true or params.focus_prompt
    ) == true

    local split_direction = is_bottom and "below"
        or (position == "left" and "left" or "right")

    --- @type vim.api.keyset.win_config
    local chat_opts = {
        win = params.anchor_winid and vim.api.nvim_win_is_valid(
            params.anchor_winid
        ) and params.anchor_winid or -1,
        split = split_direction,
    }

    if is_bottom then
        chat_opts.height = WidgetLayout.calculate_height(Config.windows.height)
    else
        chat_opts.width = WidgetLayout.calculate_width(Config.windows.width)
    end

    get_or_create_window(win_nrs, "chat", buf_nrs.chat, chat_opts, {
        scrolloff = 4,
        winfixheight = is_bottom,
        winfixwidth = not is_bottom,
    })

    local chat_width = vim.api.nvim_win_get_width(win_nrs.chat)
    local stack_width = WidgetLayout.calculate_stack_width(chat_width)

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "queue", {
        win = win_nrs.chat,
        split = is_bottom and "right" or "below",
        width = is_bottom and stack_width or nil,
    }, Config.windows.queue.max_height)

    -- Input window: right/left layouts keep it below chat or queue.
    -- Bottom layout keeps it in the right stack, below queue when present.
    --- @type vim.api.keyset.win_config
    local input_opts = { fixed = true }
    if is_bottom then
        if win_nrs.queue and vim.api.nvim_win_is_valid(win_nrs.queue) then
            input_opts.win = win_nrs.queue
            input_opts.split = "below"
            input_opts.height = Config.windows.input.height
        else
            input_opts.win = win_nrs.chat
            input_opts.split = "right"
            input_opts.width = stack_width
        end
    else
        input_opts.win = win_nrs.queue or win_nrs.chat
        input_opts.split = "below"
        input_opts.height = Config.windows.input.height
    end

    get_or_create_window(win_nrs, "input", buf_nrs.input, input_opts, {
        winfixheight = not is_bottom,
        winfixwidth = is_bottom,
    })

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "code", {
        win = is_bottom and win_nrs.input or win_nrs.chat,
        split = "below",
    }, Config.windows.code.max_height)

    local ref_win = is_bottom and (win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "files", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.files.max_height)

    ref_win = is_bottom and (win_nrs.files or win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "diagnostics", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.diagnostics.max_height)

    if Config.windows.todos.display then
        ref_win = is_bottom
                and (win_nrs.diagnostics or win_nrs.files or win_nrs.code or win_nrs.input)
            or win_nrs.chat

        open_or_resize_dynamic_window(buf_nrs, win_nrs, "todos", {
            win = ref_win,
            split = "below",
        }, Config.windows.todos.max_height)
    end

    if should_focus then
        vim.schedule(function()
            local winid = win_nrs.input
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_set_current_win(winid)
                BufHelpers.start_insert_on_last_char()
            end
        end)
    end
end

--- @param params agentic.ui.WidgetLayout.Params
function WidgetLayout.open(params)
    if
        not params.tab_page_id
        or not vim.api.nvim_tabpage_is_valid(params.tab_page_id)
    then
        Logger.notify(
            "Invalid tab_page_id in WidgetLayout.open: "
                .. tostring(params.tab_page_id),
            vim.log.levels.ERROR
        )
        return
    end

    local position = Config.windows.position

    if position ~= "right" and position ~= "left" and position ~= "bottom" then
        Logger.notify(
            "Invalid windows.position config: "
                .. tostring(position)
                .. ', falling back to "right"',
            vim.log.levels.ERROR
        )

        position = "right"
    end

    local ok, err = pcall(show_layout, params, position)
    if not ok then
        Logger.notify(
            string.format(
                "Failed to show %s layout (tab: %d): %s",
                position,
                params.tab_page_id,
                tostring(err)
            ),
            vim.log.levels.ERROR
        )
    end
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
function WidgetLayout.close(win_nrs)
    for name, winid in pairs(win_nrs) do
        win_nrs[name] = nil
        local ok = pcall(vim.api.nvim_win_close, winid, true)
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to close window '%s' with id: %d",
                    name,
                    winid
                )
            )
        end
    end
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
function WidgetLayout.close_optional_window(win_nrs, window_name)
    local winid = win_nrs[window_name]

    -- Capture chat height before closing so we can restore it.
    -- In bottom layout, Neovim redistributes freed height to siblings.
    local chat_winid = win_nrs.chat
    local chat_height = nil
    if
        Config.windows.position == "bottom"
        and chat_winid
        and vim.api.nvim_win_is_valid(chat_winid)
    then
        chat_height = vim.api.nvim_win_get_height(chat_winid)
    end

    if winid and vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
    end
    win_nrs[window_name] = nil

    -- Restore chat height when in bottom layout, since closing a sibling window redistributes height.
    if chat_height then
        ---@cast chat_winid integer if we have height, then chat_winid must be valid integer
        vim.api.nvim_win_set_config(chat_winid, { height = chat_height })
    end
end

return WidgetLayout
