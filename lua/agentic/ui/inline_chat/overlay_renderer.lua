---@diagnostic disable: invisible
local Config = require("agentic.config")
local Theme = require("agentic.theme")

local Utils = require("agentic.ui.inline_chat.utils")

local M = {}

local PROGRESS_PERCENT = {
    busy = 5,
    thinking = 20,
    generating = 55,
    tool = 72,
    waiting = 85,
    completed = 100,
    failed = 100,
}

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @return agentic.ui.InlineChat.ThreadStore
local function ensure_thread_store(self, bufnr)
    local store = vim.b[bufnr][self.THREAD_STORE_KEY]
    if type(store) ~= "table" then
        store = {}
        vim.b[bufnr][self.THREAD_STORE_KEY] = store
    end

    --- @cast store agentic.ui.InlineChat.ThreadStore
    return store
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param extmark_id integer
--- @return {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid: boolean}|nil
local function get_thread_range(self, bufnr, extmark_id)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        self.NS_INLINE_THREADS,
        extmark_id,
        { details = true }
    )

    if not mark or #mark == 0 then
        return nil
    end

    local details = mark[3] or {}

    --- @type {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid: boolean}
    local range = {
        start_row = mark[1],
        start_col = mark[2],
        end_row = details.end_row or mark[1],
        end_col = details.end_col or mark[2],
        invalid = details.invalid == true,
    }

    return Utils.normalize_range(bufnr, range)
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param source_winid integer
--- @param range_extmark_id integer
--- @return string runtime_id
--- @return agentic.ui.InlineChat.ThreadRuntime runtime
local function ensure_thread_runtime(
    self,
    bufnr,
    source_winid,
    range_extmark_id
)
    local runtime_id = Utils.thread_runtime_key(bufnr, range_extmark_id)
    local runtime = self._thread_runtimes[runtime_id]

    if runtime == nil then
        --- @type agentic.ui.InlineChat.ThreadRuntime
        local new_runtime = {
            source_bufnr = bufnr,
            source_winid = source_winid,
            range_extmark_id = range_extmark_id,
            overlay_extmark_id = nil,
            close_timer = nil,
        }
        runtime = new_runtime
        self._thread_runtimes[runtime_id] = runtime
    else
        runtime.source_bufnr = bufnr
        runtime.source_winid = source_winid
        runtime.range_extmark_id = range_extmark_id
    end

    return runtime_id, runtime
end

--- @param _self agentic.ui.InlineChat
--- @param runtime agentic.ui.InlineChat.ThreadRuntime
local function stop_thread_close_timer(_self, runtime)
    if not runtime.close_timer then
        return
    end

    pcall(function()
        runtime.close_timer:stop()
    end)
    pcall(function()
        runtime.close_timer:close()
    end)
    runtime.close_timer = nil
end

--- @param _self agentic.ui.InlineChat
--- @param runtime agentic.ui.InlineChat.ThreadRuntime
--- @return integer
function M.get_max_width(_self, runtime)
    if
        runtime.source_winid and vim.api.nvim_win_is_valid(runtime.source_winid)
    then
        return math.max(
            24,
            vim.api.nvim_win_get_width(runtime.source_winid) - 4
        )
    end

    local fallback_winid = vim.fn.bufwinid(runtime.source_bufnr)
    if fallback_winid ~= -1 and vim.api.nvim_win_is_valid(fallback_winid) then
        runtime.source_winid = fallback_winid
        return math.max(24, vim.api.nvim_win_get_width(fallback_winid) - 4)
    end

    return 72
end

--- @param hl string|string[]|nil
--- @return string|string[]|nil
local function fade_inline_hl(hl)
    return Utils.fade_inline_hl(hl)
end

--- @param text string
--- @param hl string|string[]|nil
--- @return [string, string|string[]|nil]
local function faded_segment(text, hl)
    return { text, fade_inline_hl(hl) }
end

--- @param _self agentic.ui.InlineChat
--- @param label string
--- @param text string
--- @param label_hl string|string[]|nil
--- @param text_hl string|string[]|nil
--- @param max_width integer
--- @return table
function M.build_compact_line(_self, label, text, label_hl, text_hl, max_width)
    local label_text = label .. ": "
    local available_width =
        math.max(12, max_width - vim.fn.strdisplaywidth(label_text) - 4)

    return {
        faded_segment("  ", Theme.HL_GROUPS.REVIEW_BANNER),
        faded_segment(label_text, label_hl),
        faded_segment(Utils.truncate_text(text, available_width), text_hl),
    }
end

--- @param self agentic.ui.InlineChat
--- @param entry agentic.ui.InlineChat.ActiveRequest|agentic.ui.InlineChat.ThreadTurn
--- @param selection agentic.Selection
--- @param max_width integer
--- @return table[]
function M.build_virtual_lines(self, entry, selection, max_width)
    local config_context = entry.config_context
    local status_hl =
        Theme.get_spinner_hl_group(Utils.phase_to_spinner_state(entry.phase))
    local latest_thought = Config.inline.show_thoughts
            and Utils.latest_line(entry.thought_text)
        or nil
    local latest_response = Utils.latest_line(entry.message_text)

    --- @type table[]
    local lines = {
        {
            faded_segment("  ", Theme.HL_GROUPS.REVIEW_BANNER),
            faded_segment(
                "[Agentic Inline] ",
                Theme.HL_GROUPS.REVIEW_BANNER_ACCENT
            ),
            faded_segment(
                Utils.format_range(selection) .. " ",
                Theme.HL_GROUPS.REVIEW_BANNER
            ),
            faded_segment(entry.status_text, status_hl),
        },
    }

    local detail_line = nil

    if entry.phase == "thinking" and latest_thought then
        detail_line = M.build_compact_line(
            self,
            "Thinking",
            latest_thought,
            Theme.HL_GROUPS.THOUGHT_TEXT,
            Theme.HL_GROUPS.THOUGHT_TEXT,
            max_width
        )
    elseif
        (entry.phase == "tool" or entry.phase == "waiting")
        and entry.tool_label
        and entry.tool_label ~= ""
    then
        detail_line = M.build_compact_line(
            self,
            "Tool",
            entry.tool_label,
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.ACTIVITY_TEXT,
            max_width
        )
    elseif latest_response then
        local result_hl = entry.phase == "failed"
                and Theme.HL_GROUPS.STATUS_FAILED
            or Theme.HL_GROUPS.REVIEW_BANNER
        detail_line = M.build_compact_line(
            self,
            Utils.is_terminal_phase(entry.phase) and "Result" or "Response",
            latest_response,
            entry.phase == "failed" and Theme.HL_GROUPS.STATUS_FAILED
                or Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            result_hl,
            max_width
        )
    elseif entry.tool_label and entry.tool_label ~= "" then
        local tool_line = M.build_compact_line(
            self,
            "Tool",
            entry.tool_label,
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.ACTIVITY_TEXT,
            max_width
        )
        detail_line = tool_line
    elseif entry.prompt ~= "" then
        detail_line = M.build_compact_line(
            self,
            "Prompt",
            entry.prompt,
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.REVIEW_BANNER,
            max_width
        )
    elseif config_context and config_context ~= "" then
        detail_line = M.build_compact_line(
            self,
            "Config",
            config_context,
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.REVIEW_BANNER,
            max_width
        )
    end

    if detail_line then
        lines[#lines + 1] = detail_line
    end

    return lines
end

--- @param _self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest|nil
function M.dismiss_progress(_self, request)
    if
        not request
        or not request.progress_id
        or not Config.inline.progress
        or not Utils.supports_progress_messages()
    then
        return
    end

    pcall(
        vim.api.nvim_echo,
        { { "dismissed", Theme.HL_GROUPS.ACTIVITY_TEXT } },
        true,
        {
            id = request.progress_id,
            kind = "progress",
            status = "success",
            percent = 100,
            title = "Agentic Inline",
        }
    )
    request.progress_id = nil
end

--- @param _self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest|nil
--- @param is_terminal boolean|nil
function M.update_progress(_self, request, is_terminal)
    if
        not request
        or not Config.inline.progress
        or not Utils.supports_progress_messages()
    then
        return
    end

    local message = request.status_text
    if request.tool_label and request.phase == "tool" then
        message = request.tool_label
    end

    local ok, progress_id = pcall(
        vim.api.nvim_echo,
        {
            { message, Theme.HL_GROUPS.ACTIVITY_TEXT },
        },
        true,
        {
            id = request.progress_id,
            kind = "progress",
            status = is_terminal and "success" or "running",
            percent = PROGRESS_PERCENT[request.phase]
                or PROGRESS_PERCENT.generating,
            title = "Agentic Inline",
        }
    )

    if ok and request.progress_id == nil then
        local numeric_progress_id = tonumber(progress_id)
        if numeric_progress_id ~= nil then
            request.progress_id = numeric_progress_id
        end
    end
end

--- @param self agentic.ui.InlineChat
--- @param runtime_id string
function M.clear_thread_overlay(self, runtime_id)
    local runtime = self._thread_runtimes[runtime_id]
    if not runtime or not runtime.overlay_extmark_id then
        return
    end

    if vim.api.nvim_buf_is_valid(runtime.source_bufnr) then
        pcall(
            vim.api.nvim_buf_del_extmark,
            runtime.source_bufnr,
            self.NS_INLINE,
            runtime.overlay_extmark_id
        )
    end

    runtime.overlay_extmark_id = nil
end

--- @param self agentic.ui.InlineChat
--- @param runtime_id string
function M.clear_thread_runtime(self, runtime_id)
    local runtime = self._thread_runtimes[runtime_id]
    if not runtime then
        return
    end

    stop_thread_close_timer(self, runtime)
    M.clear_thread_overlay(self, runtime_id)

    local active_request = self._active_request
    if
        active_request
        and Utils.is_terminal_phase(active_request.phase)
        and Utils.thread_runtime_key(
                active_request.source_bufnr,
                active_request.range_extmark_id
            )
            == runtime_id
    then
        M.dismiss_progress(self, active_request)
        self._active_request = nil
    end

    for submission_id, queued_request in pairs(self._queued_requests) do
        if
            Utils.thread_runtime_key(
                queued_request.source_bufnr,
                queued_request.range_extmark_id
            ) == runtime_id
        then
            self._queued_requests[submission_id] = nil
        end
    end

    self._thread_runtimes[runtime_id] = nil
end

--- @param self agentic.ui.InlineChat
--- @param runtime_id string
function M.render_thread(self, runtime_id)
    local runtime = self._thread_runtimes[runtime_id]
    if not runtime or not vim.api.nvim_buf_is_valid(runtime.source_bufnr) then
        return
    end

    local store = ensure_thread_store(self, runtime.source_bufnr)
    local thread = store[Utils.thread_store_key(runtime.range_extmark_id)]
    local turn = thread and thread.turns[#thread.turns] or nil

    if not turn then
        M.clear_thread_overlay(self, runtime_id)
        return
    end

    if turn.overlay_hidden then
        M.clear_thread_overlay(self, runtime_id)
        return
    end

    local range =
        get_thread_range(self, runtime.source_bufnr, runtime.range_extmark_id)
    if not range or range.invalid then
        M.clear_thread_overlay(self, runtime_id)
        return
    end

    local selection = Utils.build_selection_snapshot(turn.selection, range)
    local line_count =
        math.max(1, vim.api.nvim_buf_line_count(runtime.source_bufnr))
    local anchor_line = math.max(
        0,
        math.min(
            line_count - 1,
            range and range.end_row or (selection.end_line - 1)
        )
    )
    local max_width = M.get_max_width(self, runtime)

    local lines = M.build_virtual_lines(self, turn, selection, max_width)

    runtime.overlay_extmark_id = vim.api.nvim_buf_set_extmark(
        runtime.source_bufnr,
        self.NS_INLINE,
        anchor_line,
        0,
        {
            id = runtime.overlay_extmark_id,
            virt_lines = lines,
            virt_lines_above = false,
        }
    )
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest
function M.schedule_close(self, request)
    local delay = Config.inline.result_ttl_ms
    if
        delay == nil
        or delay <= 0
        or request.source_bufnr == nil
        or request.source_winid == nil
        or request.range_extmark_id == nil
    then
        return
    end

    local runtime_id, runtime = ensure_thread_runtime(
        self,
        request.source_bufnr,
        request.source_winid,
        request.range_extmark_id
    )

    if runtime.close_timer then
        pcall(function()
            runtime.close_timer:stop()
        end)
        pcall(function()
            runtime.close_timer:close()
        end)
    end

    runtime.close_timer = vim.defer_fn(function()
        M.clear_thread_runtime(self, runtime_id)
    end, delay)
end

return M
