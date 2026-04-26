local Theme = require("agentic.theme")

local M = {}

--- @param mode string
--- @return agentic.Theme.SpinnerState
function M.phase_to_spinner_state(mode)
    if mode == "busy" then
        return "busy"
    end

    if mode == "thinking" then
        return "thinking"
    end

    if mode == "waiting" then
        return "waiting"
    end

    if mode == "tool" then
        return "searching"
    end

    return "generating"
end

--- @param phase string|nil
--- @return boolean
function M.is_terminal_phase(phase)
    return phase == "completed" or phase == "failed"
end

--- @param text string|nil
--- @return string
function M.sanitize_text(text)
    if type(text) ~= "string" then
        return ""
    end

    return vim.trim(text:gsub("\r", ""))
end

--- @param text string|nil
--- @return string[]
function M.split_lines(text)
    text = M.sanitize_text(text)
    if text == "" then
        return {}
    end

    return vim.split(text, "\n", { plain = true, trimempty = true })
end

--- @return integer
function M.current_timestamp()
    return os.time()
end

--- @param extmark_id integer
--- @return string
function M.thread_store_key(extmark_id)
    return tostring(extmark_id)
end

--- @param bufnr integer
--- @param extmark_id integer
--- @return string
function M.thread_runtime_key(bufnr, extmark_id)
    return string.format("%d:%d", bufnr, extmark_id)
end

--- @param row integer
--- @param col integer
--- @param other_row integer
--- @param other_col integer
--- @return boolean
function M.position_lte(row, col, other_row, other_col)
    if row ~= other_row then
        return row < other_row
    end

    return col <= other_col
end

--- @param first {start_row: integer, start_col: integer, end_row: integer, end_col: integer}
--- @param second {start_row: integer, start_col: integer, end_row: integer, end_col: integer}
--- @return boolean
function M.ranges_overlap(first, second)
    if
        M.position_lte(
            first.end_row,
            first.end_col,
            second.start_row,
            second.start_col
        )
    then
        return false
    end

    if
        M.position_lte(
            second.end_row,
            second.end_col,
            first.start_row,
            first.start_col
        )
    then
        return false
    end

    return true
end

--- @param selection agentic.Selection
--- @return integer start_row
--- @return integer start_col
--- @return integer end_row
--- @return integer|nil end_col
local function raw_selection_to_extmark_range(selection)
    local start_row = math.max(0, selection.start_line - 1)
    local start_col = math.max(0, (selection.start_col or 1) - 1)
    local end_row = math.max(start_row, selection.end_line - 1)
    return start_row, start_col, end_row, selection.end_col
end

--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer start_row
--- @return integer start_col
--- @return integer end_row
--- @return integer end_col
function M.selection_to_extmark_range(bufnr, selection)
    local start_row, start_col, end_row, end_col =
        raw_selection_to_extmark_range(selection)

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return start_row, start_col, end_row, end_col or start_col
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count <= 0 then
        return start_row, start_col, end_row, end_col or start_col
    end

    start_row = math.max(0, math.min(start_row, line_count - 1))
    end_row = math.max(start_row, math.min(end_row, line_count - 1))

    if end_col == nil then
        local end_line = vim.api.nvim_buf_get_lines(
            bufnr,
            end_row,
            end_row + 1,
            false
        )[1] or ""
        end_col = #end_line
    end

    local normalized_range = M.normalize_range(bufnr, {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
    })

    if normalized_range == nil then
        return start_row, start_col, end_row, end_col
    end

    return normalized_range.start_row,
        normalized_range.start_col,
        normalized_range.end_row,
        normalized_range.end_col
end

--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return integer
function M.clamp_col(bufnr, row, col)
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    return math.max(0, math.min(col, #line))
end

--- @param bufnr integer
--- @param range {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid?: boolean}
--- @return {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid?: boolean}|nil
function M.normalize_range(bufnr, range)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count <= 0 then
        return nil
    end

    local start_row = math.max(0, math.min(range.start_row, line_count - 1))
    local end_row = math.max(start_row, math.min(range.end_row, line_count - 1))
    local start_col = M.clamp_col(bufnr, start_row, range.start_col)
    local end_col = M.clamp_col(bufnr, end_row, range.end_col)

    if start_row == end_row and end_col < start_col then
        end_col = start_col
    end

    return {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
        invalid = range.invalid == true,
    }
end

--- @param selection agentic.Selection
--- @param range {start_row: integer, start_col: integer, end_row: integer, end_col: integer}|nil
--- @return agentic.Selection
function M.build_selection_snapshot(selection, range)
    --- @type agentic.Selection
    local snapshot = vim.deepcopy(selection)

    if range then
        snapshot.start_line = range.start_row + 1
        snapshot.end_line = range.end_row + 1
        if selection.start_col ~= nil or selection.end_col ~= nil then
            snapshot.start_col = math.max(1, range.start_col + 1)
            if range.end_col >= 0 then
                snapshot.end_col = math.max(1, range.end_col)
            end
            if
                snapshot.start_col ~= nil
                and snapshot.end_col ~= nil
                and snapshot.start_col > snapshot.end_col
            then
                snapshot.start_col = snapshot.end_col
            end
        end
    end

    return snapshot
end

--- @param bufnr integer
--- @param selection agentic.Selection
--- @return agentic.Selection
function M.normalize_selection(bufnr, selection)
    local start_row, start_col, end_row, end_col =
        M.selection_to_extmark_range(bufnr, selection)

    return M.build_selection_snapshot(selection, {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
    })
end

--- @param text string|nil
--- @return string|nil
function M.latest_line(text)
    local lines = M.split_lines(text)
    return lines[#lines]
end

--- @param text string
--- @param max_width integer
--- @return string prefix
--- @return string rest
local function split_display_prefix(text, max_width)
    local char_count = vim.fn.strchars(text)
    local width = 0
    local prefix_chars = 0

    for index = 0, char_count - 1 do
        local char = vim.fn.strcharpart(text, index, 1)
        local char_width = vim.fn.strdisplaywidth(char)
        if prefix_chars > 0 and width + char_width > max_width then
            break
        end

        width = width + char_width
        prefix_chars = prefix_chars + 1
        if width >= max_width then
            break
        end
    end

    if prefix_chars == 0 then
        prefix_chars = 1
    end

    return vim.fn.strcharpart(text, 0, prefix_chars),
        vim.fn.strcharpart(text, prefix_chars)
end

--- @param text string|nil
--- @param max_width integer
--- @return string[] lines
function M.wrap_text(text, max_width)
    text = M.sanitize_text(text):gsub("%s+", " ")
    max_width = math.max(1, max_width)

    if text == "" then
        return {}
    end

    local wrapped = {}
    local current = ""

    for _, word in
        ipairs(vim.split(text, " ", { plain = true, trimempty = true }))
    do
        while vim.fn.strdisplaywidth(word) > max_width do
            if current ~= "" then
                wrapped[#wrapped + 1] = current
                current = ""
            end

            local chunk, rest = split_display_prefix(word, max_width)
            wrapped[#wrapped + 1] = chunk
            word = rest
        end

        if word ~= "" then
            local candidate = current == "" and word or (current .. " " .. word)
            if vim.fn.strdisplaywidth(candidate) <= max_width then
                current = candidate
            else
                wrapped[#wrapped + 1] = current
                current = word
            end
        end
    end

    if current ~= "" then
        wrapped[#wrapped + 1] = current
    end

    return wrapped
end

--- @param selection agentic.Selection
--- @return string
function M.format_range(selection)
    local file_name = vim.fs.basename(selection.file_path or "")
    if file_name == "" then
        file_name = "[No Name]"
    end

    if selection.start_col ~= nil and selection.end_col ~= nil then
        return string.format(
            "%s:%d:%d-%d:%d",
            file_name,
            selection.start_line,
            selection.start_col,
            selection.end_line,
            selection.end_col
        )
    end

    return string.format(
        "%s:%d-%d",
        file_name,
        selection.start_line,
        selection.end_line
    )
end

--- @param position integer
--- @param waiting_for_session boolean
--- @return string
function M.build_queue_status(position, waiting_for_session)
    if waiting_for_session then
        return "Waiting for session"
    end

    if position <= 1 then
        return "Queued next"
    end

    return string.format("Queued #%d", position)
end

--- @param tool_call table
--- @return string
function M.build_tool_label(tool_call)
    local kind = M.sanitize_text(tool_call.kind)
    local argument = M.sanitize_text(tool_call.argument)
    local file_name = vim.fs.basename(M.sanitize_text(tool_call.file_path))

    if argument ~= "" then
        return string.format("%s %s", kind, argument)
    end

    if file_name ~= "" then
        return string.format("%s %s", kind, file_name)
    end

    return kind ~= "" and kind or "tool"
end

--- @param hl string|string[]|nil
--- @return string|string[]|nil
function M.fade_inline_hl(hl)
    if type(hl) == "table" then
        local groups = vim.deepcopy(hl)
        groups[#groups + 1] = Theme.HL_GROUPS.INLINE_FADE
        return groups
    end

    if type(hl) == "string" and hl ~= "" then
        return { hl, Theme.HL_GROUPS.INLINE_FADE }
    end

    return Theme.HL_GROUPS.INLINE_FADE
end

--- @param text string
--- @param hl string|string[]|nil
--- @return [string, string|string[]|nil]
function M.faded_segment(text, hl)
    local segment = { text, M.fade_inline_hl(hl) }
    return segment
end

return M
