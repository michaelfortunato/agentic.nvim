local BufHelpers = require("agentic.utils.buf_helpers")
local FileSystem = require("agentic.utils.file_system")
local DiffSplitView = require("agentic.ui.diff_split_view")
local InlineRenderer = require("agentic.ui.diff_preview.inline_renderer")
local Logger = require("agentic.utils.logger")

--- Owns diff-review runtime state and tab-local active diff bookkeeping.
--- @class agentic.ui.DiffPreview.ReviewState
local M = {}

M.NS_REVIEW = InlineRenderer.NS_REVIEW

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

local function get_review_state(bufnr)
    if not review_keymap_state[bufnr] then
        review_keymap_state[bufnr] = {
            saved_keymaps = {},
            session = nil,
        }
    end

    return review_keymap_state[bufnr]
end

--- @param bufnr integer
--- @return agentic.ui.DiffPreview.ReviewKeymapState
function M.get_review_state(bufnr)
    return get_review_state(bufnr)
end

--- @param bufnr integer
--- @return agentic.ui.DiffPreview.ReviewKeymapState|nil
function M.peek_review_state(bufnr)
    return review_keymap_state[bufnr]
end

--- @param bufnr integer
function M.clear_review_state(bufnr)
    review_keymap_state[bufnr] = nil
end

--- @param bufnr integer
--- @return agentic.ui.DiffPreview.ReviewSession|nil
function M.get_review_session(bufnr)
    local state = review_keymap_state[bufnr]
    return state and state.session or nil
end

--- @param bufnr integer
--- @param session agentic.ui.DiffPreview.ReviewSession|nil
function M.set_review_session(bufnr, session)
    local state = get_review_state(bufnr)
    state.session = session
end

--- @param tabpage number|nil
--- @return number|nil bufnr
function M.get_active_diff_buffer(tabpage)
    local tab = tabpage or vim.api.nvim_get_current_tabpage()
    local split_state = DiffSplitView.get_split_state(tab)
    if split_state then
        return split_state.original_bufnr
    end

    return vim.t[tab]._agentic_diff_preview_bufnr
end

--- @param tabpage number|nil
--- @param bufnr number|nil
function M.set_active_diff_buffer(tabpage, bufnr)
    local tab = tabpage or vim.api.nvim_get_current_tabpage()
    vim.t[tab]._agentic_diff_preview_bufnr = bufnr
end

--- @param file_path string
--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @param review_actions agentic.ui.DiffPreview.ReviewActions
--- @param is_approximate boolean
--- @return agentic.ui.DiffPreview.ReviewSession
function M.create_review_session(
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

    --- @type agentic.ui.DiffPreview.ReviewSession
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

--- @param session agentic.ui.DiffPreview.ReviewSession
local function finalize_review_session(session)
    if #session.rejected_block_ids == 0 then
        Logger.notify("All hunks reviewed", vim.log.levels.INFO)
        vim.schedule(session.review_actions.on_accept)
        return
    end

    if #session.accepted_block_ids == 0 then
        vim.schedule(session.review_actions.on_reject)
        return
    end

    if session.is_approximate then
        Logger.notify(
            "Partial hunk review is unavailable for approximate diff previews",
            vim.log.levels.WARN
        )
        vim.schedule(session.review_actions.on_reject)
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

    vim.schedule(session.review_actions.on_reject)
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

local function focus_next_pending_block(bufnr, session, winid, cursor_line)
    for _, pending_block_id in ipairs(session.pending_block_ids) do
        local pending_block = session.diff_blocks[pending_block_id]
        if pending_block.start_line > cursor_line then
            InlineRenderer.focus_diff_target(
                bufnr,
                winid,
                pending_block.start_line,
                InlineRenderer.get_block_anchor_line(pending_block)
            )
            return true
        end
    end

    return false
end

--- @param bufnr integer
--- @param decision "accept"|"reject"
--- @return boolean resolved
function M.resolve_pending_hunk(bufnr, decision)
    local state = review_keymap_state[bufnr]
    local session = state and state.session
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
        return focus_next_pending_block(bufnr, session, winid, cursor_line)
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
        return true
    end

    InlineRenderer.render_inline_diff_blocks(
        bufnr,
        session.file_path,
        get_pending_diff_blocks(session),
        session.review_actions,
        session.is_approximate
    )

    local next_position = math.min(position, #session.pending_block_ids)
    local next_block_id = session.pending_block_ids[next_position]
    if next_block_id then
        local next_block = session.diff_blocks[next_block_id]
        InlineRenderer.focus_diff_target(
            bufnr,
            winid,
            InlineRenderer.get_block_focus_line(
                next_block,
                vim.api.nvim_buf_line_count(bufnr)
            ),
            InlineRenderer.get_block_anchor_line(next_block)
        )
    end

    return true
end

return M
