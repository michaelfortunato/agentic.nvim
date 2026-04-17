local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local Chooser = require("agentic.ui.chooser")
local WidgetLayout = require("agentic.ui.widget_layout")

--- @class agentic.ui.QueueList.Item
--- @field id integer
--- @field input_text string

--- @class agentic.ui.QueueList.Actions
--- @field on_steer? fun(submission_id: integer)
--- @field on_send_now? fun(submission_id: integer)
--- @field on_remove? fun(submission_id: integer)
--- @field on_cancel? fun()

--- @class agentic.ui.QueueList
--- @field _items agentic.ui.QueueList.Item[]
--- @field _line_to_submission_id table<integer, integer>
--- @field _header_line_count integer
--- @field _bufnr integer
--- @field _actions agentic.ui.QueueList.Actions
local QueueList = {}
QueueList.__index = QueueList

local NS_QUEUE_LIST = vim.api.nvim_create_namespace("agentic_queue_list")
local ACTION_ITEMS = {
    {
        id = "steer",
        name = "Steer",
        description = "Send next when the agent is ready",
    },
    {
        id = "send_now",
        name = "Send Now",
        description = "Interrupt the current response",
    },
    {
        id = "remove",
        name = "Remove",
        description = "Drop this message from the queue",
    },
}

--- @param count integer
--- @return string[]
local function build_header_lines(count)
    return {
        string.format("Queue · %d pending", count),
        "<CR> choose · ! now · d remove",
    }
end

--- @param bufnr integer
--- @return integer
local function get_preview_width(bufnr)
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
        return math.max(8, vim.api.nvim_win_get_width(winid) - 2)
    end

    if Config.windows.position == "bottom" then
        local chat_width = WidgetLayout.calculate_width(Config.windows.width)
        return math.max(8, WidgetLayout.calculate_stack_width(chat_width) - 2)
    end

    return math.max(8, WidgetLayout.calculate_width(Config.windows.width) - 2)
end

--- @param text string
--- @param max_width integer
--- @return string
local function compact_preview(text, max_width)
    local single_line = (text or ""):gsub("%s+", " "):gsub("^%s+", "")
    if vim.fn.strdisplaywidth(single_line) <= max_width then
        return single_line
    end

    local ellipsis = "..."
    local limit = math.max(1, max_width - vim.fn.strdisplaywidth(ellipsis))
    local truncated = single_line

    while truncated ~= "" and vim.fn.strdisplaywidth(truncated) > limit do
        truncated =
            vim.fn.strcharpart(truncated, 0, vim.fn.strchars(truncated) - 1)
    end

    if truncated == "" then
        return ellipsis
    end

    return truncated .. ellipsis
end

--- @param bufnr integer
--- @param actions agentic.ui.QueueList.Actions|nil
--- @return agentic.ui.QueueList
function QueueList:new(bufnr, actions)
    local instance = setmetatable({
        _items = {},
        _line_to_submission_id = {},
        _header_line_count = 0,
        _bufnr = bufnr,
        _actions = actions or {},
    }, self)

    instance:_setup_keybindings()

    return instance
end

--- @param items agentic.ui.QueueList.Item[]
function QueueList:set_items(items)
    self._items = vim.deepcopy(items or {})
    self:_render()
end

--- @return boolean
function QueueList:is_empty()
    return #self._items == 0
end

--- @return integer
function QueueList:count()
    return #self._items
end

--- @return integer|nil
function QueueList:_get_submission_id_at_cursor()
    if #self._items == 0 then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local submission_id = self._line_to_submission_id[cursor[1]]
    if submission_id then
        return submission_id
    end

    if cursor[1] <= self._header_line_count then
        return self._items[1] and self._items[1].id or nil
    end

    return nil
end

--- @param callback fun(submission_id: integer)|nil
function QueueList:_run_action(callback)
    if not callback then
        return
    end

    local submission_id = self:_get_submission_id_at_cursor()
    if not submission_id then
        return
    end

    callback(submission_id)
end

--- @param callback fun()|nil
function QueueList:_run_cancel(callback)
    if not callback then
        return
    end

    callback()
end

function QueueList:_render()
    local lines = {}
    local line_to_submission_id = {}
    local line_width = get_preview_width(self._bufnr)

    if #self._items > 0 then
        vim.list_extend(lines, build_header_lines(#self._items))
    end
    self._header_line_count = #lines

    for index, item in ipairs(self._items) do
        local prefix = string.format("%d. ", index)
        local preview = compact_preview(
            item.input_text,
            math.max(4, line_width - vim.fn.strdisplaywidth(prefix))
        )

        lines[#lines + 1] = prefix .. preview
        line_to_submission_id[#lines] = item.id
    end

    self._line_to_submission_id = line_to_submission_id

    BufHelpers.with_modifiable(self._bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)

    local function set_highlight(line_idx, start_col, end_col, hl_group)
        local line = lines[line_idx + 1] or ""
        local target_end_col = end_col
        if target_end_col == -1 then
            target_end_col = #line
        end

        if target_end_col <= start_col then
            return
        end

        vim.api.nvim_buf_set_extmark(
            self._bufnr,
            NS_QUEUE_LIST,
            line_idx,
            start_col,
            {
                end_row = line_idx,
                end_col = target_end_col,
                hl_group = hl_group,
            }
        )
    end

    vim.api.nvim_buf_clear_namespace(self._bufnr, NS_QUEUE_LIST, 0, -1)
    if #self._items > 0 then
        set_highlight(0, 0, -1, "Title")
        set_highlight(1, 0, -1, "Comment")

        for line_idx = self._header_line_count, #lines - 1 do
            local line = lines[line_idx + 1]
            local prefix_end = line and line:find("%. ", 1, true)
            if prefix_end then
                set_highlight(line_idx, 0, prefix_end, "Comment")
            end
        end
    end
end

function QueueList:_open_action_menu()
    local submission_id = self:_get_submission_id_at_cursor()
    if not submission_id then
        return
    end

    Chooser.show(ACTION_ITEMS, {
        prompt = "Queue action",
        filetype = "AgenticQueueAction",
        format_item = function(item)
            return Chooser.format_named_item(item.name, item.description)
        end,
        max_height = #ACTION_ITEMS,
    }, function(choice)
        if not choice then
            return
        end

        if choice.id == "steer" then
            if self._actions.on_steer then
                self._actions.on_steer(submission_id)
            end
        elseif choice.id == "send_now" then
            if self._actions.on_send_now then
                self._actions.on_send_now(submission_id)
            end
        elseif choice.id == "remove" then
            if self._actions.on_remove then
                self._actions.on_remove(submission_id)
            end
        end
    end)
end

function QueueList:_setup_keybindings()
    BufHelpers.keymap_set(self._bufnr, "n", "<CR>", function()
        self:_open_action_menu()
    end, {
        desc = "Agentic queue: actions",
    })

    BufHelpers.keymap_set(self._bufnr, "n", "!", function()
        self:_run_action(self._actions.on_send_now)
    end, {
        desc = "Agentic queue: send now",
    })

    BufHelpers.keymap_set(self._bufnr, "n", "d", function()
        self:_run_action(self._actions.on_remove)
    end, {
        desc = "Agentic queue: remove",
        nowait = true,
    })

    BufHelpers.keymap_set(self._bufnr, "n", "q", function()
        self:_run_cancel(self._actions.on_cancel)
    end, {
        desc = "Agentic queue: focus prompt",
    })

    BufHelpers.keymap_set(self._bufnr, "n", "<Esc>", function()
        self:_run_cancel(self._actions.on_cancel)
    end, {
        desc = "Agentic queue: focus prompt",
    })
end

return QueueList
