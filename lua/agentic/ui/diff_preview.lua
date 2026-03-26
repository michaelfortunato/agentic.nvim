local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffSplitView = require("agentic.ui.diff_split_view")
local FileSystem = require("agentic.utils.file_system")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local M = {}

local NS_DIFF = HunkNavigation.NS_DIFF
local NS_REVIEW = vim.api.nvim_create_namespace("agentic_diff_review")
M.NS_REVIEW = NS_REVIEW
local HINT_KINDS = {
    edit = true,
    create = true,
    write = true,
}

--- @class agentic.ui.DiffPreview.ReviewActions
--- @field on_accept fun()
--- @field on_reject fun()
--- @field on_accept_all? fun()
--- @field on_reject_all? fun()

--- @class agentic.ui.DiffPreview.ReviewKeymapState
--- @field saved_keymaps { accept?: table, reject?: table, accept_all?: table, reject_all?: table }
--- @field session? agentic.ui.DiffPreview.ReviewSession|nil

--- @class agentic.ui.DiffPreview.ReviewSession
--- @field file_path string
--- @field original_lines string[]
--- @field diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @field pending_block_ids integer[]
--- @field accepted_block_ids integer[]
--- @field rejected_block_ids integer[]
--- @field is_approximate boolean
--- @field review_actions agentic.ui.DiffPreview.ReviewActions

--- @type table<number, agentic.ui.DiffPreview.ReviewKeymapState>
local review_keymap_state = {}
local get_review_session
local resolve_pending_hunk

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

--- Get diff preview buffer from tabpage
--- @param tabpage number Tabpage ID
--- @return number|nil bufnr
local function get_diff_bufnr(tabpage)
    return vim.t[tabpage]._agentic_diff_preview_bufnr
end

--- Set diff preview buffer for tabpage
--- @param tabpage number Tabpage ID
--- @param bufnr number|nil Buffer number (nil to clear)
local function set_diff_bufnr(tabpage, bufnr)
    vim.t[tabpage]._agentic_diff_preview_bufnr = bufnr
end

--- Get the buffer number with active diff preview for the current or specified tabpage
--- @param tabpage number|nil Tabpage ID (defaults to current tabpage)
--- @return number|nil bufnr Buffer number with active diff, or nil if none
function M.get_active_diff_buffer(tabpage)
    local tab = tabpage or vim.api.nvim_get_current_tabpage()

    local split_state = DiffSplitView.get_split_state(tab)
    if split_state then
        return split_state.original_bufnr
    end

    return get_diff_bufnr(tab)
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
                    " %s yes-all  %s no-all ",
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
    vim.api.nvim_buf_set_extmark(bufnr, NS_REVIEW, anchor_line, 0, {
        virt_lines = build_review_banner(
            file_path,
            #diff_blocks,
            review_actions,
            is_approximate
        ),
        virt_lines_above = true,
    })
end

--- @param opts agentic.ui.DiffPreview.ShowOpts
--- @return agentic.ui.ToolCallDiff.DiffBlock[] diff_blocks
--- @return boolean is_approximate
local function resolve_diff_blocks(opts)
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
    local has_changes = table.concat(old_lines, "\n")
        ~= table.concat(new_lines, "\n")

    if not has_content or not has_changes then
        return diff_blocks, false
    end

    diff_opts.strict = false
    local fallback_blocks = ToolCallDiff.extract_diff_blocks(diff_opts)
    if #fallback_blocks == 0 then
        return diff_blocks, false
    end

    Logger.notify(
        "Diff preview: exact location changed in "
            .. opts.file_path
            .. "; showing approximate preview",
        vim.log.levels.WARN
    )
    return fallback_blocks, true
end

--- @param winid integer
--- @param line integer
--- @return boolean
local function is_line_visible_in_window(winid, line)
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

--- @param winid integer
--- @param line integer
local function focus_diff_target(winid, line)
    pcall(vim.api.nvim_set_current_win, winid)
    pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
end

--- @param bufnr integer
--- @return agentic.ui.DiffPreview.ReviewKeymapState
local function get_review_state(bufnr)
    if not review_keymap_state[bufnr] then
        review_keymap_state[bufnr] = {
            saved_keymaps = {},
            session = nil,
        }
    end

    return review_keymap_state[bufnr]
end

--- @param block agentic.ui.ToolCallDiff.DiffBlock
--- @return integer
local function get_block_anchor_line(block)
    if #block.old_lines == 0 then
        return math.max(0, block.start_line - 2)
    end

    return math.max(0, block.end_line - 1)
end

--- @param block agentic.ui.ToolCallDiff.DiffBlock
--- @param line_count integer
--- @return integer|nil above_line
--- @return integer|nil below_line
local function get_block_review_lines(block, line_count)
    local above_line = block.start_line > 1 and block.start_line - 1 or nil
    local below_line = nil

    if #block.old_lines == 0 then
        if block.start_line <= line_count then
            below_line = block.start_line
        end
    elseif block.end_line < line_count then
        below_line = block.end_line + 1
    end

    return above_line, below_line
end

--- @param block agentic.ui.ToolCallDiff.DiffBlock
--- @param line_count integer
--- @return integer
local function get_block_focus_line(block, line_count)
    local above_line, below_line = get_block_review_lines(block, line_count)
    return below_line
        or above_line
        or math.max(1, math.min(line_count, block.start_line))
end

--- @param session agentic.ui.DiffPreview.ReviewSession
--- @return agentic.ui.ToolCallDiff.DiffBlock[]
local function get_pending_diff_blocks(session)
    --- @type agentic.ui.ToolCallDiff.DiffBlock[]
    local pending_blocks = {}

    for _, block_id in ipairs(session.pending_block_ids) do
        pending_blocks[#pending_blocks + 1] = session.diff_blocks[block_id]
    end

    return pending_blocks
end

--- @param file_path string
--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @param review_actions agentic.ui.DiffPreview.ReviewActions
--- @param is_approximate boolean
--- @return agentic.ui.DiffPreview.ReviewSession
local function create_review_session(
    file_path,
    diff_blocks,
    review_actions,
    is_approximate
)
    local original_lines = FileSystem.read_from_buffer_or_disk(
        FileSystem.to_absolute_path(file_path)
    ) or {}
    --- @type integer[]
    local pending_block_ids = {}
    for block_id = 1, #diff_blocks do
        pending_block_ids[#pending_block_ids + 1] = block_id
    end

    local session = {
        file_path = file_path,
        original_lines = vim.deepcopy(original_lines or {}),
        diff_blocks = vim.deepcopy(diff_blocks),
        pending_block_ids = pending_block_ids,
        accepted_block_ids = {},
        rejected_block_ids = {},
        is_approximate = is_approximate == true,
        review_actions = review_actions,
    }

    return session
end

--- @param lines string[]
--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @return string[]
local function apply_diff_blocks_to_lines(lines, diff_blocks)
    local result = vim.deepcopy(lines or {})
    local offset = 0

    for _, block in ipairs(diff_blocks) do
        local current_start = block.start_line + offset
        local before = vim.list_slice(result, 1, current_start - 1)
        local after =
            vim.list_slice(result, current_start + #block.old_lines, #result)

        result = before
        vim.list_extend(result, vim.deepcopy(block.new_lines))
        vim.list_extend(result, after)
        offset = offset + #block.new_lines - #block.old_lines
    end

    return result
end

--- @param file_path string
--- @param lines string[]
--- @return boolean success
--- @return string|nil error
local function write_reviewed_lines(file_path, lines)
    local abs_path = FileSystem.to_absolute_path(file_path)
    local bufnr = vim.fn.bufnr(abs_path)

    if
        bufnr ~= -1
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_is_loaded(bufnr)
    then
        local write_result = BufHelpers.with_modifiable(bufnr, function(buf)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

            local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
                vim.cmd("silent write!")
            end)
            if not ok then
                return "Failed to write reviewed hunks: " .. tostring(err)
            end

            return true
        end)

        if write_result == true then
            return true, nil
        end

        if type(write_result) == "string" then
            return false, write_result
        end

        return false, "Failed to update reviewed buffer"
    end

    return FileSystem.save_to_disk(abs_path, table.concat(lines, "\n"))
end

--- @param bufnr integer
local function clear_rendered_diff(bufnr)
    HunkNavigation.invalidate_cache(bufnr)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_DIFF, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_REVIEW, 0, -1)
end

--- @param bufnr integer
--- @param key string
--- @return table|nil
local function save_buffer_keymap(bufnr, key)
    local ok, keymaps = pcall(vim.api.nvim_buf_get_keymap, bufnr, "n")
    if not ok then
        return nil
    end

    for _, map_info in ipairs(keymaps) do
        if map_info and map_info.lhs == key then
            return map_info
        end
    end

    return nil
end

--- @param bufnr integer
function M.restore_review_keymaps(bufnr)
    local state = review_keymap_state[bufnr]
    if not state then
        return
    end

    local review_keymaps = get_diff_preview_keymaps()
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.accept)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.reject)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.accept_all)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.reject_all)

    if state.saved_keymaps then
        for _, saved_map in pairs(state.saved_keymaps) do
            if saved_map and saved_map.lhs then
                local opts = {}
                if saved_map.noremap == 1 then
                    opts.noremap = true
                end
                if saved_map.silent == 1 then
                    opts.silent = true
                end
                if saved_map.expr == 1 then
                    opts.expr = true
                end
                if saved_map.nowait == 1 then
                    opts.nowait = true
                end

                if saved_map.callback then
                    opts.buffer = bufnr
                    pcall(
                        BufHelpers.keymap_set,
                        bufnr,
                        "n",
                        saved_map.lhs,
                        saved_map.callback,
                        opts
                    )
                elseif saved_map.rhs and saved_map.rhs ~= "" then
                    pcall(
                        vim.api.nvim_buf_set_keymap,
                        bufnr,
                        "n",
                        saved_map.lhs,
                        saved_map.rhs,
                        opts
                    )
                end
            end
        end
    end

    review_keymap_state[bufnr] = nil
end

--- @param bufnr integer
--- @param review_actions agentic.ui.DiffPreview.ReviewActions|nil
local function setup_review_keymaps(bufnr, review_actions)
    if not review_actions then
        return
    end

    local review_keymaps = get_diff_preview_keymaps()
    local state = get_review_state(bufnr)
    state.saved_keymaps.accept =
        save_buffer_keymap(bufnr, review_keymaps.accept)
    state.saved_keymaps.reject =
        save_buffer_keymap(bufnr, review_keymaps.reject)
    state.saved_keymaps.accept_all =
        save_buffer_keymap(bufnr, review_keymaps.accept_all)
    state.saved_keymaps.reject_all =
        save_buffer_keymap(bufnr, review_keymaps.reject_all)

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.accept, function()
        if get_review_session(bufnr) then
            if resolve_pending_hunk(bufnr, "accept") then
                return ""
            end
            return review_keymaps.accept
        end
        review_actions.on_accept()
        return ""
    end, {
        desc = "Agentic Review: Accept diff",
        nowait = true,
        expr = true,
    })

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.reject, function()
        if get_review_session(bufnr) then
            if resolve_pending_hunk(bufnr, "reject") then
                return ""
            end
            return review_keymaps.reject
        end
        review_actions.on_reject()
        return ""
    end, {
        desc = "Agentic Review: Reject diff",
        nowait = true,
        expr = true,
    })

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.accept_all, function()
        (review_actions.on_accept_all or review_actions.on_accept)()
    end, { desc = "Agentic Review: Accept diff", nowait = true })

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.reject_all, function()
        (review_actions.on_reject_all or review_actions.on_reject)()
    end, { desc = "Agentic Review: Reject diff", nowait = true })
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

--- Get the diff highlight for a column position based on word-level change
--- Always returns DIFF_ADD for line background, DIFF_ADD_WORD for changed portions
--- @param col integer 0-indexed column
--- @param change table|nil Change info from find_inline_change
--- @return string hl_group
local function get_diff_hl_for_col(col, change)
    if change and col >= change.new_start and col < change.new_end then
        return Theme.HL_GROUPS.DIFF_ADD_WORD
    end
    return Theme.HL_GROUPS.DIFF_ADD
end

--- Builds segments for a line without syntax highlighting
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

    -- Line-level highlight for unchanged portions, word-level for changed
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
            string.format("%s yes", review_keymaps.accept),
            Theme.HL_GROUPS.DIFF_ADD,
        },
        { "  ", Theme.HL_GROUPS.REVIEW_BANNER },
        {
            string.format("%s no", review_keymaps.reject),
            Theme.HL_GROUPS.DIFF_DELETE,
        },
    }
end

--- Builds segments for a line with syntax highlighting
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
            -- Build highlight spec: syntax highlight + diff background
            local hl_spec = current_hl and { current_hl, current_diff_hl }
                or current_diff_hl
            table.insert(segments, { text, hl_spec })
            seg_start = col
            current_hl = hl
            current_diff_hl = diff_hl
        end
    end

    -- Final segment
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
            -- For each new_line in pairs (which matches filtered.new_lines order),
            -- store the corresponding old_line (nil for pure insertions)
            table.insert(aligned, pair.old_line)
            if pair.old_line then
                has_modifications = true
            end
        end
    end

    return has_modifications and aligned or nil
end

--- Builds virt_lines with syntax highlighting and diff background
--- @param new_lines string[]
--- @param old_lines (string|nil)[]|nil Sequential old lines aligned with new_lines
--- @param lang string
--- @return table virt_lines
local function get_highlighted_virt_lines(new_lines, old_lines, lang)
    local row_col_hl = build_highlight_map(new_lines, lang)

    local virt_lines = {}
    for row, line in ipairs(new_lines) do
        local col_hl = row_col_hl and row_col_hl[row - 1]

        -- Find word-level change if we have corresponding old line
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
local function render_inline_diff_blocks(
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
                get_block_anchor_line(block),
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
                get_block_anchor_line(block),
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

--- @param bufnr integer
--- @return agentic.ui.DiffPreview.ReviewSession|nil
get_review_session = function(bufnr)
    local state = review_keymap_state[bufnr]
    return state and state.session or nil
end

--- @param session agentic.ui.DiffPreview.ReviewSession
--- @param cursor_line integer
--- @param line_count integer
--- @return integer|nil block_id
--- @return integer|nil position
local function find_pending_block_for_cursor(session, cursor_line, line_count)
    local below_block_id = nil
    local below_position = nil
    local above_block_id = nil
    local above_position = nil

    for position, block_id in ipairs(session.pending_block_ids) do
        local block = session.diff_blocks[block_id]
        local above_line, below_line = get_block_review_lines(block, line_count)
        if below_line == cursor_line then
            below_block_id = block_id
            below_position = position
        elseif above_line == cursor_line and not above_block_id then
            above_block_id = block_id
            above_position = position
        end
    end

    return below_block_id or above_block_id, below_position or above_position
end

--- @param session agentic.ui.DiffPreview.ReviewSession
local function finalize_review_session(session)
    if #session.rejected_block_ids == 0 then
        session.review_actions.on_accept()
        return
    end

    if #session.accepted_block_ids == 0 then
        session.review_actions.on_reject()
        return
    end

    if session.is_approximate then
        Logger.notify(
            "Partial hunk review is unavailable for approximate diff previews",
            vim.log.levels.WARN
        )
        session.review_actions.on_reject()
        return
    end

    --- @type agentic.ui.ToolCallDiff.DiffBlock[]
    local accepted_blocks = {}
    for _, block_id in ipairs(session.accepted_block_ids) do
        accepted_blocks[#accepted_blocks + 1] = session.diff_blocks[block_id]
    end

    local reviewed_lines =
        apply_diff_blocks_to_lines(session.original_lines, accepted_blocks)
    local wrote, err = write_reviewed_lines(session.file_path, reviewed_lines)
    if not wrote then
        Logger.notify(
            "Failed to apply accepted hunks: " .. tostring(err),
            vim.log.levels.ERROR
        )
    end

    session.review_actions.on_reject()
end

--- @param bufnr integer
--- @param decision "accept"|"reject"
--- @return boolean resolved
resolve_pending_hunk = function(bufnr, decision)
    local state = get_review_state(bufnr)
    local session = state.session
    if not session then
        return false
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        return false
    end

    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local block_id, position =
        find_pending_block_for_cursor(session, cursor_line, line_count)
    if not block_id or not position then
        return false
    end

    if decision == "accept" then
        session.accepted_block_ids[#session.accepted_block_ids + 1] = block_id
    else
        session.rejected_block_ids[#session.rejected_block_ids + 1] = block_id
    end
    table.remove(session.pending_block_ids, position)

    if #session.pending_block_ids == 0 then
        state.session = nil
        finalize_review_session(session)
        return
    end

    render_inline_diff_blocks(
        bufnr,
        session.file_path,
        get_pending_diff_blocks(session),
        session.review_actions,
        session.is_approximate
    )

    local next_position = math.min(position, #session.pending_block_ids)
    local next_block_id = session.pending_block_ids[next_position]
    if next_block_id then
        focus_diff_target(
            winid,
            get_block_focus_line(session.diff_blocks[next_block_id], line_count)
        )
    end

    return true
end

--- @class agentic.ui.DiffPreview.ShowOpts
--- @field file_path string
--- @field diff agentic.ui.MessageWriter.ToolCallDiff
--- @field get_winid fun(bufnr: number): number|nil Called when buffer is not already visible, should return a winid
--- @field review_actions? agentic.ui.DiffPreview.ReviewActions|nil

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_diff(opts)
    if Config.diff_preview.layout == "split" then
        local success = DiffSplitView.show_split_diff(opts)
        if success then
            return
        end
        Logger.debug("show_diff: split view failed, falling back to inline")
    end

    local diff_blocks, is_approximate = resolve_diff_blocks(opts)

    if #diff_blocks == 0 then
        -- Empty diff is valid (e.g. new file Write tool where content arrives in updates)
        local new_lines = ToolCallDiff.normalize_to_lines(opts.diff.new or {})
        local old_lines = ToolCallDiff.normalize_to_lines(opts.diff.old or {})
        local has_content = not ToolCallDiff.is_empty_lines(new_lines)
            or not ToolCallDiff.is_empty_lines(old_lines)
        if has_content then
            Logger.notify(
                "Diff preview: could not match diff in " .. opts.file_path,
                vim.log.levels.WARN
            )
        end
        return
    end

    local bufnr = vim.fn.bufnr(opts.file_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufadd(opts.file_path)
    end

    local winid = vim.fn.bufwinid(bufnr)
    local target_winid = winid ~= -1 and winid or nil
    local opened_review_window = target_winid == nil

    if not target_winid then
        target_winid = opts.get_winid(bufnr)
    end

    if not target_winid then
        return
    end

    M.clear_diff(bufnr)
    local state = get_review_state(bufnr)
    if opts.review_actions then
        state.session = create_review_session(
            opts.file_path,
            diff_blocks,
            opts.review_actions,
            is_approximate
        )
    else
        state.session = nil
    end

    render_inline_diff_blocks(
        bufnr,
        opts.file_path,
        opts.review_actions and get_pending_diff_blocks(state.session)
            or diff_blocks,
        opts.review_actions,
        is_approximate
    )

    if #diff_blocks > 0 then
        local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, target_winid)
        if not ok then
            return
        end
        set_diff_bufnr(tabpage, bufnr)

        -- Make buffer read-only to prevent edits while diff is visible
        vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable
        vim.bo[bufnr].modifiable = false

        HunkNavigation.setup_keymaps(bufnr)
        setup_review_keymaps(bufnr, opts.review_actions)

        local first_diff_line = get_block_focus_line(
            diff_blocks[1],
            vim.api.nvim_buf_line_count(bufnr)
        )
        local should_focus_review = opened_review_window
            or not is_line_visible_in_window(target_winid, first_diff_line)

        if should_focus_review then
            focus_diff_target(target_winid, first_diff_line)
        end
    end
end

--- Clears the diff highlights from the given buffer
--- @param buf number|string Buffer number or file path
--- @param is_rejection boolean|nil If true and file doesn't exist, cleanup buffer
function M.clear_diff(buf, is_rejection)
    local bufnr = type(buf) == "string" and vim.fn.bufnr(buf) or buf --[[@as integer]]

    if bufnr == -1 then
        return
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
        local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, winid)
        if ok then
            if DiffSplitView.get_split_state(tabpage) then
                DiffSplitView.clear_split_diff(tabpage)
                return
            end
            set_diff_bufnr(tabpage, nil)
        end
    end

    HunkNavigation.restore_keymaps(bufnr)
    M.restore_review_keymaps(bufnr)

    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_DIFF, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_REVIEW, 0, -1)

    -- Restore modifiable state if it was saved
    local prev_modifiable = vim.b[bufnr]._agentic_prev_modifiable
    if prev_modifiable ~= nil then
        vim.bo[bufnr].modifiable = prev_modifiable
        vim.b[bufnr]._agentic_prev_modifiable = nil
    end

    -- On rejection for new files, switch window to alternate buffer
    if is_rejection then
        local file_path = vim.api.nvim_buf_get_name(bufnr)
        local stat = file_path ~= "" and vim.uv.fs_stat(file_path)

        if not stat then
            local buf_winid = vim.fn.bufwinid(bufnr)
            if buf_winid ~= -1 then
                -- Get alternate buffer for the target window, not current window
                local alt = vim.api.nvim_win_call(buf_winid, function()
                    return vim.fn.bufnr("#")
                end)

                local target_buf
                if alt ~= -1 and alt ~= bufnr then
                    target_buf = alt
                else
                    target_buf = vim.api.nvim_create_buf(true, true)
                end
                pcall(vim.api.nvim_win_set_buf, buf_winid, target_buf)
            end
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
end

--- Add hint line for navigation keybindings to permission request
--- @param tracker table|nil Tool call tracker with kind field
--- @param lines_to_append string[] Array of lines to append hint to
--- @return number|nil hint_line_index Index of hint line in array, or nil if not added
function M.add_navigation_hint(tracker, lines_to_append)
    -- Only add hint for edit tools with diff preview enabled
    if
        not tracker
        or not HINT_KINDS[tracker.kind]
        or not Config.diff_preview
        or not Config.diff_preview.enabled
    then
        return nil
    end

    local diff_keymaps = get_diff_preview_keymaps()
    local hint_text = string.format(
        "Review in buffer: %s next, %s prev, %s yes, %s no",
        diff_keymaps.next_hunk,
        diff_keymaps.prev_hunk,
        diff_keymaps.accept,
        diff_keymaps.reject
    )

    local hint_line_index = #lines_to_append
    table.insert(lines_to_append, hint_text)

    return hint_line_index
end

--- Apply low-contrast Comment styling to hint line
--- Wrapped in pcall to prevent blocking user if styling fails
--- @param bufnr number Buffer number
--- @param ns_id number Namespace ID for extmark
--- @param button_start_row number Start row of button block
--- @param hint_line_index number Index of hint line in appended lines
function M.apply_hint_styling(bufnr, ns_id, button_start_row, hint_line_index)
    pcall(function()
        local hint_line_row = button_start_row + hint_line_index
        -- Get the actual line content to determine end column
        local hint_line_content = vim.api.nvim_buf_get_lines(
            bufnr,
            hint_line_row,
            hint_line_row + 1,
            false
        )[1] or ""

        vim.api.nvim_buf_set_extmark(bufnr, ns_id, hint_line_row, 0, {
            end_row = hint_line_row,
            end_col = #hint_line_content,
            hl_group = "Comment",
            hl_eol = false,
        })
    end)
end

--- Setup hunk navigation keymaps for widget buffers
--- Allows navigating hunks in the active diff buffer from widget buffers
--- @param buf_nrs table<string, number>
function M.setup_diff_navigation_keymaps(buf_nrs)
    local diff_keymaps = Config.keymaps.diff_preview

    for _, bufnr in pairs(buf_nrs) do
        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.next_hunk, function()
            local diff_bufnr = M.get_active_diff_buffer()
            if not diff_bufnr then
                Logger.notify("No active diff preview", vim.log.levels.INFO)
                return
            end
            HunkNavigation.navigate_next(diff_bufnr)
        end, {
            desc = "Go to next hunk - Agentic DiffPreview",
        })

        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.prev_hunk, function()
            local diff_bufnr = M.get_active_diff_buffer()
            if not diff_bufnr then
                Logger.notify("No active diff preview", vim.log.levels.INFO)
                return
            end
            HunkNavigation.navigate_prev(diff_bufnr)
        end, {
            desc = "Go to previous hunk - Agentic DiffPreview",
        })
    end
end

return M
