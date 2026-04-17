local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local DiffSplitView = require("agentic.ui.diff_split_view")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local InlineRenderer = require("agentic.ui.diff_preview.inline_renderer")
local KeymapBridge = require("agentic.ui.diff_preview.keymap_bridge")
local Logger = require("agentic.utils.logger")
local ReviewState = require("agentic.ui.diff_preview.review_state")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local M = {}

M.NS_REVIEW = ReviewState.NS_REVIEW

--- UI Sync Scopes
--- - Tab-local: active diff preview buffer and diff split integration via vim.t[tabpage]
--- - Buffer-local: review keymap state, inline diff extmarks, restored modifiable flags
--- - Window-local: callers own review target window selection via get_winid()

--- @class agentic.ui.DiffPreview.ShowOpts
--- @field file_path string
--- @field diff agentic.ui.MessageWriter.ToolCallDiff
--- @field get_winid fun(bufnr: number): number|nil Called when buffer is not already visible, should return a winid
--- @field review_actions? agentic.ui.DiffPreview.ReviewActions|nil

local HINT_KINDS = {
    edit = true,
    create = true,
    write = true,
}

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

--- Get the buffer number with active diff preview for the current or specified tabpage
--- @param tabpage number|nil Tabpage ID (defaults to current tabpage)
--- @return number|nil bufnr Buffer number with active diff, or nil if none
function M.get_active_diff_buffer(tabpage)
    return ReviewState.get_active_diff_buffer(tabpage)
end

--- @param bufnr integer
function M.restore_review_keymaps(bufnr)
    KeymapBridge.restore_review_keymaps(bufnr)
end

--- @param decision "accept"|"reject"
--- @param fallback_key string
--- @return string
local function handle_widget_review_hunk(decision, fallback_key)
    local diff_bufnr = ReviewState.get_active_diff_buffer()
    local review_session = diff_bufnr
        and ReviewState.get_review_session(diff_bufnr)
    if not diff_bufnr or not review_session then
        return fallback_key
    end

    ReviewState.resolve_pending_hunk(diff_bufnr, decision)
    return ""
end

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_diff(opts)
    if Config.diff_preview.layout == "split" then
        local success = DiffSplitView.show_split_diff(opts)
        if success then
            return
        end
        Logger.debug("show_diff: split view failed, falling back to inline")
    end

    local diff_blocks, is_approximate = InlineRenderer.resolve_diff_blocks(opts)

    if #diff_blocks == 0 then
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
    local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, target_winid)
    if not ok then
        return
    end

    if opts.review_actions then
        ReviewState.set_review_session(
            bufnr,
            ReviewState.create_review_session(
                opts.file_path,
                diff_blocks,
                opts.review_actions,
                is_approximate
            )
        )
    end

    ReviewState.set_active_diff_buffer(tabpage, bufnr)

    InlineRenderer.render_inline_diff_blocks(
        bufnr,
        opts.file_path,
        diff_blocks,
        opts.review_actions,
        is_approximate
    )

    vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = false

    HunkNavigation.setup_keymaps(bufnr)
    KeymapBridge.setup_review_keymaps(bufnr, opts.review_actions)

    local first_diff_line = InlineRenderer.get_block_focus_line(
        diff_blocks[1],
        vim.api.nvim_buf_line_count(bufnr)
    )
    local should_focus_review = opened_review_window
        or not InlineRenderer.is_line_visible_in_window(
            target_winid,
            first_diff_line
        )

    if should_focus_review then
        InlineRenderer.focus_diff_target(
            bufnr,
            target_winid,
            first_diff_line,
            InlineRenderer.get_block_anchor_line(diff_blocks[1])
        )
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
            ReviewState.set_active_diff_buffer(tabpage, nil)
        end
    end

    HunkNavigation.restore_keymaps(bufnr)
    M.restore_review_keymaps(bufnr)

    pcall(
        vim.api.nvim_buf_clear_namespace,
        bufnr,
        HunkNavigation.NS_DIFF,
        0,
        -1
    )
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.NS_REVIEW, 0, -1)

    local prev_modifiable = vim.b[bufnr]._agentic_prev_modifiable
    if prev_modifiable ~= nil then
        vim.bo[bufnr].modifiable = prev_modifiable
        vim.b[bufnr]._agentic_prev_modifiable = nil
    end

    if is_rejection then
        local file_path = vim.api.nvim_buf_get_name(bufnr)
        local stat = file_path ~= "" and vim.uv.fs_stat(file_path)

        if not stat then
            local buf_winid = vim.fn.bufwinid(bufnr)
            if buf_winid ~= -1 then
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
        "Review in buffer: %s next, %s prev, %s accept, %s reject",
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
    local diff_keymaps = get_diff_preview_keymaps()

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

        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.accept, function()
            return handle_widget_review_hunk("accept", diff_keymaps.accept)
        end, {
            desc = "Accept next review hunk - Agentic DiffPreview",
            expr = true,
            nowait = true,
        })

        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.reject, function()
            return handle_widget_review_hunk("reject", diff_keymaps.reject)
        end, {
            desc = "Reject next review hunk - Agentic DiffPreview",
            expr = true,
            nowait = true,
        })
    end
end

return M
