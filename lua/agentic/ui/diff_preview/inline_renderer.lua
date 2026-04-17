local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Renders inline diff preview content and line decorations.
--- @class agentic.ui.DiffPreview.InlineRenderer
local M = {}

local NS_DIFF = HunkNavigation.NS_DIFF
M.NS_REVIEW = vim.api.nvim_create_namespace("agentic_diff_review")

--- @return agentic.UserConfig.DiffPreviewKeymaps
local function get_diff_preview_keymaps()
    local configured = Config.keymaps and Config.keymaps.diff_preview or {}
    local defaults = DefaultConfig.keymaps.diff_preview

    return {
        next_hunk = configured.next_hunk or defaults.next_hunk,
        prev_hunk = configured.prev_hunk or defaults.prev_hunk,
        accept = configured.accept or defaults.accept,
        reject = configured.reject or defaults.reject,
        accept_all = configured.accept_all or defaults.accept_all,
        reject_all = configured.reject_all or defaults.reject_all,
    }
end

--- @param file_path string
--- @param hunk_count integer
--- @param review_actions agentic.ui.DiffPreview.ReviewActions|nil
--- @param is_approximate boolean|nil
--- @return table
local function build_review_banner(
    file_path,
    hunk_count,
    review_actions,
    is_approximate
)
    local basename = vim.fs.basename(file_path)
    local hunk_label =
        string.format("%d hunk%s", hunk_count, hunk_count == 1 and "" or "s")
    local diff_keymaps = get_diff_preview_keymaps()

    --- @type table
    local banner = {
        {
            { " Agentic Review ", Theme.HL_GROUPS.REVIEW_BANNER_ACCENT },
            { " " .. basename .. " ", Theme.HL_GROUPS.REVIEW_BANNER_ACCENT },
            { " " .. hunk_label .. " ", Theme.HL_GROUPS.REVIEW_BANNER },
            {
                string.format(
                    " %s prev  %s next ",
                    diff_keymaps.prev_hunk,
                    diff_keymaps.next_hunk
                ),
                Theme.HL_GROUPS.REVIEW_BANNER,
            },
        },
    }

    if is_approximate then
        banner[#banner + 1] = {
            { " Context drift ", Theme.HL_GROUPS.REVIEW_BANNER_ACCENT },
            {
                " showing approximate diff preview ",
                Theme.HL_GROUPS.REVIEW_BANNER,
            },
        }
    end

    if review_actions then
        banner[#banner + 1] = {
            { " ACP whole diff ", Theme.HL_GROUPS.REVIEW_BANNER_ACCENT },
            {
                string.format(
                    " %s accept-all  %s reject-all ",
                    diff_keymaps.accept_all,
                    diff_keymaps.reject_all
                ),
                Theme.HL_GROUPS.REVIEW_BANNER,
            },
        }
    end

    return banner
end

--- @param bufnr integer
--- @param file_path string
--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @param review_actions agentic.ui.DiffPreview.ReviewActions|nil
--- @param is_approximate boolean|nil
local function render_review_banner(
    bufnr,
    file_path,
    diff_blocks,
    review_actions,
    is_approximate
)
    local first_block = diff_blocks[1]
    if not first_block then
        return
    end

    local anchor_line = math.max(0, first_block.start_line - 1)
    vim.api.nvim_buf_set_extmark(bufnr, M.NS_REVIEW, anchor_line, 0, {
        virt_lines = build_review_banner(
            file_path,
            #diff_blocks,
            review_actions,
            is_approximate
        ),
        virt_lines_above = true,
    })
end

--- @param old_lines string[]
--- @param new_lines string[]
--- @return boolean
local function has_preview_changes(old_lines, new_lines)
    return table.concat(old_lines, "\n") ~= table.concat(new_lines, "\n")
end

--- @param file_path string
local function notify_approximate_preview(file_path)
    Logger.notify(
        "Diff preview: could not re-anchor diff exactly in "
            .. file_path
            .. "; showing approximate preview",
        vim.log.levels.WARN
    )
end

--- @param opts agentic.ui.DiffPreview.ShowOpts
--- @return agentic.ui.ToolCallDiff.DiffBlock[] diff_blocks
--- @return boolean is_approximate
function M.resolve_diff_blocks(opts)
    local diff_opts = {
        path = opts.file_path,
        old_text = opts.diff.old,
        new_text = opts.diff.new,
        replace_all = opts.diff.all,
        strict = true,
    }
    local diff_blocks = ToolCallDiff.extract_diff_blocks(diff_opts)
    if #diff_blocks > 0 then
        return diff_blocks, false
    end

    local new_lines = ToolCallDiff.normalize_to_lines(opts.diff.new or {})
    local old_lines = ToolCallDiff.normalize_to_lines(opts.diff.old or {})
    local has_content = not ToolCallDiff.is_empty_lines(new_lines)
        or not ToolCallDiff.is_empty_lines(old_lines)
    local has_changes = has_preview_changes(old_lines, new_lines)

    if not has_content or not has_changes then
        return diff_blocks, false
    end

    diff_opts.strict = false
    local fallback_blocks = ToolCallDiff.extract_diff_blocks(diff_opts)
    if #fallback_blocks == 0 then
        return diff_blocks, false
    end

    if not opts.suppress_approximate_notify then
        notify_approximate_preview(opts.file_path)
    end
    return fallback_blocks, true
end

--- @param winid integer
--- @param line integer
--- @return boolean
function M.is_line_visible_in_window(winid, line)
    if not vim.api.nvim_win_is_valid(winid) then
        return false
    end

    local visible_range = vim.api.nvim_win_call(winid, function()
        return { vim.fn.line("w0"), vim.fn.line("w$") }
    end)
    local topline = visible_range and visible_range[1] or nil
    local botline = visible_range and visible_range[2] or nil
    if not topline or not botline then
        return false
    end

    return line >= topline and line <= botline
end

--- @param bufnr integer
--- @param winid integer
--- @param line integer
--- @param anchor_line integer|nil
function M.focus_diff_target(bufnr, winid, line, anchor_line)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    pcall(vim.api.nvim_set_current_win, winid)
    pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })

    if anchor_line == nil then
        return
    end

    local scroll_cmd = HunkNavigation.get_scroll_cmd(bufnr, winid, anchor_line)
    if scroll_cmd == "" then
        return
    end

    pcall(vim.api.nvim_win_call, winid, function()
        vim.cmd("normal! " .. scroll_cmd)
    end)
end

--- @param block agentic.ui.ToolCallDiff.DiffBlock
--- @return integer
function M.get_block_anchor_line(block)
    if #block.old_lines == 0 then
        return math.max(0, block.start_line - 2)
    end

    return math.max(0, block.end_line - 1)
end

--- @param block agentic.ui.ToolCallDiff.DiffBlock
--- @param line_count integer
--- @return integer
function M.get_block_focus_line(block, line_count)
    local above_line = block.start_line > 1 and block.start_line - 1 or nil
    local below_line = nil

    if #block.old_lines == 0 then
        if block.start_line <= line_count then
            below_line = block.start_line
        end
    elseif block.end_line < line_count then
        below_line = block.end_line + 1
    end

    return below_line
        or above_line
        or math.max(1, math.min(line_count, block.start_line))
end

--- @param bufnr integer
local function clear_rendered_diff(bufnr)
    HunkNavigation.invalidate_cache(bufnr)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_DIFF, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.NS_REVIEW, 0, -1)
end

--- Builds a highlight map for all lines parsed as a block
--- @param lines string[]
--- @param lang string
--- @return table<number, table<number, string>>|nil row_col_hl Map of row -> col -> hl_group
local function build_highlight_map(lines, lang)
    if not lang or lang == "" or #lines == 0 then
        return nil
    end

    local content = table.concat(lines, "\n")

    local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
    if not ok or not parser then
        return nil
    end

    local trees = parser:parse()
    if not trees or #trees == 0 then
        return nil
    end

    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return nil
    end

    local row_col_hl = {}
    for i = 0, #lines - 1 do
        row_col_hl[i] = {}
    end

    for id, node in query:iter_captures(trees[1]:root(), content) do
        local name = query.captures[id]
        local start_row, start_col, end_row, end_col = node:range()
        local hl_group = "@" .. name .. "." .. lang

        for row = start_row, end_row do
            if row_col_hl[row] then
                local col_start = (row == start_row) and start_col or 0
                local col_end = (row == end_row) and end_col or #lines[row + 1]
                for col = col_start, col_end - 1 do
                    row_col_hl[row][col] = hl_group
                end
            end
        end
    end

    return row_col_hl
end

--- @param col integer 0-indexed column
--- @param change table|nil Change info from find_inline_change
--- @return string hl_group
local function get_diff_hl_for_col(col, change)
    if change and col >= change.new_start and col < change.new_end then
        return Theme.HL_GROUPS.DIFF_ADD_WORD
    end
    return Theme.HL_GROUPS.DIFF_ADD
end

--- @param line string
--- @param change table|nil Change info from find_inline_change
--- @return table[] segments
local function build_plain_segments(line, change)
    if not change then
        return { { line, Theme.HL_GROUPS.DIFF_ADD } }
    end

    local segments = {}
    local before = line:sub(1, change.new_start)
    local changed = line:sub(change.new_start + 1, change.new_end)
    local after = line:sub(change.new_end + 1)

    if #before > 0 then
        table.insert(segments, { before, Theme.HL_GROUPS.DIFF_ADD })
    end
    if #changed > 0 then
        table.insert(segments, { changed, Theme.HL_GROUPS.DIFF_ADD_WORD })
    end
    if #after > 0 then
        table.insert(segments, { after, Theme.HL_GROUPS.DIFF_ADD })
    end

    return #segments > 0 and segments or { { line, Theme.HL_GROUPS.DIFF_ADD } }
end

--- @return table
local function build_hunk_review_footer()
    local review_keymaps = get_diff_preview_keymaps()

    return {
        { "  ", Theme.HL_GROUPS.REVIEW_BANNER },
        {
            string.format("%s accept", review_keymaps.accept),
            Theme.HL_GROUPS.DIFF_ADD,
        },
        { "  ", Theme.HL_GROUPS.REVIEW_BANNER },
        {
            string.format("%s reject", review_keymaps.reject),
            Theme.HL_GROUPS.DIFF_DELETE,
        },
    }
end

--- @param line string
--- @param col_hl table<number, string>
--- @param change table|nil Change info from find_inline_change
--- @return table[] segments
local function build_highlighted_segments(line, col_hl, change)
    local segments = {}
    local current_hl = col_hl[0]
    local current_diff_hl = get_diff_hl_for_col(0, change)
    local seg_start = 0

    for col = 1, #line do
        local hl = col_hl[col]
        local diff_hl = get_diff_hl_for_col(col, change)
        if hl ~= current_hl or diff_hl ~= current_diff_hl then
            local text = line:sub(seg_start + 1, col)
            local hl_spec = current_hl and { current_hl, current_diff_hl }
                or current_diff_hl
            table.insert(segments, { text, hl_spec })
            seg_start = col
            current_hl = hl
            current_diff_hl = diff_hl
        end
    end

    local text = line:sub(seg_start + 1)
    if #text > 0 then
        local hl_spec = current_hl and { current_hl, current_diff_hl }
            or current_diff_hl
        table.insert(segments, { text, hl_spec })
    end

    return #segments > 0 and segments or { { line, Theme.HL_GROUPS.DIFF_ADD } }
end

--- Build old_lines array aligned with filtered new_lines for word-level diff
--- Iterates pairs in order to match the sequential order of filtered.new_lines
--- @param pairs agentic.ui.ToolCallDiff.ChangedPair[]
--- @return (string|nil)[]|nil aligned Array matching filtered.new_lines order, nil if no modifications
local function build_aligned_old_lines(pairs)
    --- @type (string|nil)[]
    local aligned = {}
    local has_modifications = false

    for _, pair in ipairs(pairs) do
        if pair.new_line then
            table.insert(aligned, pair.old_line)
            if pair.old_line then
                has_modifications = true
            end
        end
    end

    return has_modifications and aligned or nil
end

--- @param new_lines string[]
--- @param old_lines (string|nil)[]|nil Sequential old lines aligned with new_lines
--- @param lang string
--- @return table virt_lines
local function get_highlighted_virt_lines(new_lines, old_lines, lang)
    local row_col_hl = build_highlight_map(new_lines, lang)

    local virt_lines = {}
    for row, line in ipairs(new_lines) do
        local col_hl = row_col_hl and row_col_hl[row - 1]

        local old_line = old_lines and old_lines[row]
        local change = old_line
            and DiffHighlighter.find_inline_change(old_line, line)

        local segments = (col_hl and #line > 0)
                and build_highlighted_segments(line, col_hl, change)
            or build_plain_segments(line, change)

        table.insert(virt_lines, segments)
    end

    return virt_lines
end

--- @param bufnr integer
--- @param file_path string
--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @param review_actions agentic.ui.DiffPreview.ReviewActions|nil
--- @param is_approximate boolean|nil
function M.render_inline_diff_blocks(
    bufnr,
    file_path,
    diff_blocks,
    review_actions,
    is_approximate
)
    clear_rendered_diff(bufnr)

    for _, block in ipairs(diff_blocks) do
        local old_count = #block.old_lines
        local new_count = #block.new_lines

        local filtered = ToolCallDiff.filter_unchanged_lines(
            block.old_lines,
            block.new_lines
        )

        if old_count > 0 then
            for _, pair in ipairs(filtered.pairs) do
                if pair.old_line and pair.old_idx then
                    local line = block.start_line + pair.old_idx - 2

                    DiffHighlighter.apply_diff_highlights(
                        bufnr,
                        NS_DIFF,
                        line,
                        pair.old_line,
                        pair.new_line
                    )
                end
            end
        end

        if new_count > 0 and #filtered.new_lines > 0 then
            local ft = vim.bo[bufnr].filetype
            local lang = vim.treesitter.language.get_lang(ft) or ft
            local aligned_old_lines = build_aligned_old_lines(filtered.pairs)

            local virt_lines = get_highlighted_virt_lines(
                filtered.new_lines,
                aligned_old_lines,
                lang
            )
            if review_actions then
                virt_lines[#virt_lines + 1] = build_hunk_review_footer()
            end

            local ok, err = pcall(
                vim.api.nvim_buf_set_extmark,
                bufnr,
                NS_DIFF,
                M.get_block_anchor_line(block),
                0,
                { virt_lines = virt_lines }
            )
            if not ok then
                Logger.notify("Failed to set virtual lines: " .. tostring(err))
            end
        elseif review_actions then
            local ok, err = pcall(
                vim.api.nvim_buf_set_extmark,
                bufnr,
                NS_DIFF,
                M.get_block_anchor_line(block),
                0,
                { virt_lines = { build_hunk_review_footer() } }
            )
            if not ok then
                Logger.notify("Failed to set review footer: " .. tostring(err))
            end
        end
    end

    if #diff_blocks > 0 then
        render_review_banner(
            bufnr,
            file_path,
            diff_blocks,
            review_actions,
            is_approximate
        )
    end
end

--- @param decision "accept"|"reject"
--- @param fallback_key string
--- @return string
function M.handle_widget_review_hunk(
    diff_bufnr,
    review_session,
    decision,
    fallback_key
)
    if not diff_bufnr or not review_session then
        return fallback_key
    end

    local review_state = require("agentic.ui.diff_preview.review_state")
    review_state.resolve_pending_hunk(diff_bufnr, decision)
    return ""
end

return M
