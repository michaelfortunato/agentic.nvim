local BufHelpers = require("agentic.utils.buf_helpers")
local FileSystem = require("agentic.utils.file_system")
local DiffSplitView = require("agentic.ui.diff_split_view")
local InlineRenderer = require("agentic.ui.diff_preview.inline_renderer")
local Logger = require("agentic.utils.logger")

--- Owns diff-review runtime state and tab-local active diff bookkeeping.
--- @class agentic.ui.DiffPreview.ReviewState
local M = {}

M.NS_REVIEW = InlineRenderer.NS_REVIEW

local BUFFER_REVIEW_KEY = "_agentic_pending_reviews"
local TAB_REVIEW_SESSIONS_KEY = "_agentic_review_sessions"
local TAB_ACTIVE_REVIEW_KEY = "_agentic_active_review_key"

local TERMINAL_CLEAR_REASONS = {
    approved = true,
    rejected = true,
    dismissed = true,
    tool_completed = true,
    tool_failed = true,
}

local DETACH_CALLBACK_REASONS = {
    manual_clear = true,
    window_closed = true,
    buffer_detached = true,
    show_failed = true,
}

--- @type table<number, agentic.ui.DiffPreview.ReviewKeymapState>
local review_keymap_state = {}

--- @type table<string, { review_actions?: agentic.ui.DiffPreview.ReviewActions|nil, on_detach?: fun(payload: agentic.ui.DiffPreview.DetachPayload)|nil }>
local review_callbacks = {}

--- @type agentic.ui.DiffPreview.ReviewActions
local NOOP_REVIEW_ACTIONS = {
    on_accept = function() end,
    on_reject = function() end,
}

--- @alias agentic.ui.DiffPreview.ClearReason
--- | "approved"
--- | "rejected"
--- | "dismissed"
--- | "tool_completed"
--- | "tool_failed"
--- | "manual_clear"
--- | "window_closed"
--- | "buffer_detached"
--- | "render_refresh"
--- | "show_failed"

--- @class agentic.ui.DiffPreview.DetachPayload
--- @field bufnr integer|nil
--- @field review_key string
--- @field tabpage integer|nil
--- @field tool_call_id string
--- @field reason agentic.ui.DiffPreview.ClearReason

--- @class agentic.ui.DiffPreview.ReviewActions
--- @field on_accept fun()
--- @field on_reject fun()
--- @field on_accept_all? fun()
--- @field on_reject_all? fun()

--- @class agentic.ui.DiffPreview.ReviewKeymapState
--- @field review_key? string
--- @field saved_keymaps { accept?: table, reject?: table, accept_all?: table, reject_all?: table }

--- @class agentic.ui.DiffPreview.BufferReviewAttachment
--- @field tabpage integer

--- @class agentic.ui.DiffPreview.ReviewSession
--- @field review_key string
--- @field tool_call_id string
--- @field file_path string
--- @field original_lines string[]
--- @field diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @field pending_block_ids integer[]
--- @field accepted_block_ids integer[]
--- @field rejected_block_ids integer[]
--- @field is_approximate boolean
--- @field review_actions agentic.ui.DiffPreview.ReviewActions
--- @field needs_review boolean
--- @field on_detach? fun(payload: agentic.ui.DiffPreview.DetachPayload)|nil

--- @class agentic.ui.DiffPreview.StoredReviewSession
--- @field review_key string
--- @field tool_call_id string
--- @field file_path string
--- @field original_lines string[]
--- @field diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @field pending_block_ids integer[]
--- @field accepted_block_ids integer[]
--- @field rejected_block_ids integer[]
--- @field is_approximate boolean
--- @field needs_review boolean

--- @param bufnr integer|nil
--- @return boolean
local function is_valid_bufnr(bufnr)
    return type(bufnr) == "number"
        and bufnr > 0
        and vim.api.nvim_buf_is_valid(bufnr)
end

--- @param tabpage integer|nil
--- @return boolean
local function is_valid_tabpage(tabpage)
    return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

--- @param bufnr integer
--- @return table<string, agentic.ui.DiffPreview.BufferReviewAttachment>|nil
local function get_buffer_review_store(bufnr)
    if not is_valid_bufnr(bufnr) then
        return nil
    end

    local store = vim.b[bufnr][BUFFER_REVIEW_KEY]
    if type(store) ~= "table" then
        store = {}
        vim.b[bufnr][BUFFER_REVIEW_KEY] = store
    end

    return store
end

--- @param tabpage integer
--- @return table<string, agentic.ui.DiffPreview.StoredReviewSession>
local function get_tab_review_sessions(tabpage)
    local sessions = vim.t[tabpage][TAB_REVIEW_SESSIONS_KEY]
    if type(sessions) ~= "table" then
        sessions = {}
        vim.t[tabpage][TAB_REVIEW_SESSIONS_KEY] = sessions
    end

    return sessions
end

--- @param review_key string
--- @param review_actions agentic.ui.DiffPreview.ReviewActions|nil
--- @param on_detach fun(payload: agentic.ui.DiffPreview.DetachPayload)|nil
local function set_review_callbacks(review_key, review_actions, on_detach)
    review_callbacks[review_key] = {
        review_actions = review_actions,
        on_detach = on_detach,
    }
end

--- @param review_key string
--- @param stored_session agentic.ui.DiffPreview.StoredReviewSession
--- @return agentic.ui.DiffPreview.ReviewSession
local function hydrate_review_session(review_key, stored_session)
    local callbacks = review_callbacks[review_key] or {}

    --- @type agentic.ui.DiffPreview.ReviewSession
    local session = {
        review_key = stored_session.review_key,
        tool_call_id = stored_session.tool_call_id,
        file_path = stored_session.file_path,
        original_lines = vim.deepcopy(stored_session.original_lines or {}),
        diff_blocks = vim.deepcopy(stored_session.diff_blocks or {}),
        pending_block_ids = vim.deepcopy(
            stored_session.pending_block_ids or {}
        ),
        accepted_block_ids = vim.deepcopy(
            stored_session.accepted_block_ids or {}
        ),
        rejected_block_ids = vim.deepcopy(
            stored_session.rejected_block_ids or {}
        ),
        is_approximate = stored_session.is_approximate == true,
        review_actions = callbacks.review_actions or NOOP_REVIEW_ACTIONS,
        needs_review = stored_session.needs_review == true,
        on_detach = callbacks.on_detach,
    }

    return session
end

--- @param session agentic.ui.DiffPreview.ReviewSession
--- @return agentic.ui.DiffPreview.StoredReviewSession
local function serialize_review_session(session)
    --- @type agentic.ui.DiffPreview.StoredReviewSession
    local stored_session = {
        review_key = session.review_key,
        tool_call_id = session.tool_call_id,
        file_path = session.file_path,
        original_lines = vim.deepcopy(session.original_lines or {}),
        diff_blocks = vim.deepcopy(session.diff_blocks or {}),
        pending_block_ids = vim.deepcopy(session.pending_block_ids or {}),
        accepted_block_ids = vim.deepcopy(session.accepted_block_ids or {}),
        rejected_block_ids = vim.deepcopy(session.rejected_block_ids or {}),
        is_approximate = session.is_approximate == true,
        needs_review = session.needs_review == true,
    }

    return stored_session
end

--- @param review_key string
--- @return integer|nil
function M.find_review_tabpage(review_key)
    if not review_key or review_key == "" then
        return nil
    end

    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        if is_valid_tabpage(tabpage) then
            local session = get_tab_review_sessions(tabpage)[review_key]
            if session ~= nil then
                return tabpage
            end
        end
    end

    return nil
end

--- @param tool_call_id string|nil
--- @return string|nil
function M.find_review_key_by_tool_call_id(tool_call_id)
    if not tool_call_id or tool_call_id == "" then
        return nil
    end

    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        if is_valid_tabpage(tabpage) then
            for review_key, review_session in
                pairs(get_tab_review_sessions(tabpage))
            do
                if review_session.tool_call_id == tool_call_id then
                    return review_key
                end
            end
        end
    end

    return nil
end

--- @param review_key string|nil
--- @param tabpage integer|nil
--- @return agentic.ui.DiffPreview.ReviewSession|nil
function M.get_review_session_by_key(review_key, tabpage)
    if not review_key or review_key == "" then
        return nil
    end

    local target_tabpage = tabpage or M.find_review_tabpage(review_key)
    if not target_tabpage or not is_valid_tabpage(target_tabpage) then
        return nil
    end

    local stored_session = get_tab_review_sessions(target_tabpage)[review_key]
    if stored_session == nil then
        return nil
    end

    return hydrate_review_session(review_key, stored_session)
end

--- @param tabpage integer|nil
--- @return string|nil
function M.get_active_review_key(tabpage)
    local target_tabpage = tabpage or vim.api.nvim_get_current_tabpage()
    if not is_valid_tabpage(target_tabpage) then
        return nil
    end

    local review_key = vim.t[target_tabpage][TAB_ACTIVE_REVIEW_KEY]
    if type(review_key) ~= "string" or review_key == "" then
        return nil
    end

    return review_key
end

--- @param tabpage integer|nil
--- @param review_key string|nil
function M.set_active_review_key(tabpage, review_key)
    local target_tabpage = tabpage or vim.api.nvim_get_current_tabpage()
    if not is_valid_tabpage(target_tabpage) then
        return
    end

    vim.t[target_tabpage][TAB_ACTIVE_REVIEW_KEY] = review_key
end

--- @param bufnr integer
--- @param tabpage integer|nil
--- @return string|nil review_key
--- @return integer|nil attachment_tabpage
function M.get_attached_review_key(bufnr, tabpage)
    local store = get_buffer_review_store(bufnr)
    if not store then
        return nil, nil
    end

    local target_tabpage = tabpage
    if not target_tabpage then
        local current_tabpage = vim.api.nvim_get_current_tabpage()
        local active_review_key = M.get_active_review_key(current_tabpage)
        local attachment = active_review_key and store[active_review_key] or nil
        if attachment and attachment.tabpage == current_tabpage then
            return active_review_key, current_tabpage
        end
        target_tabpage = current_tabpage
    end

    local active_review_key = M.get_active_review_key(target_tabpage)
    local attachment = active_review_key and store[active_review_key] or nil
    if attachment and attachment.tabpage == target_tabpage then
        return active_review_key, target_tabpage
    end

    local first_review_key = nil
    local first_tabpage = nil
    for review_key, pending_attachment in pairs(store) do
        if pending_attachment.tabpage == target_tabpage then
            return review_key, target_tabpage
        end
        if first_review_key == nil then
            first_review_key = review_key
            first_tabpage = pending_attachment.tabpage
        end
    end

    return first_review_key, first_tabpage
end

--- @param bufnr integer
--- @param review_key string|nil
--- @return agentic.ui.DiffPreview.BufferReviewAttachment|nil
function M.get_buffer_review_attachment(bufnr, review_key)
    local store = get_buffer_review_store(bufnr)
    if not store then
        return nil
    end

    if review_key ~= nil then
        return store[review_key]
    end

    local attached_review_key = M.get_active_review_key()
    if attached_review_key and store[attached_review_key] then
        return store[attached_review_key]
    end

    local first_attachment = next(store)
    if not first_attachment then
        return nil
    end

    return store[first_attachment]
end

--- @param bufnr integer
--- @return agentic.ui.DiffPreview.ReviewKeymapState|nil
function M.get_review_state(bufnr)
    if not is_valid_bufnr(bufnr) then
        return nil
    end

    if not review_keymap_state[bufnr] then
        review_keymap_state[bufnr] = {
            review_key = nil,
            saved_keymaps = {},
        }
    end

    return review_keymap_state[bufnr]
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

--- @param session_id string|nil
--- @param tool_call_id string|nil
--- @return string|nil
function M.create_review_key(session_id, tool_call_id)
    if
        type(session_id) ~= "string"
        or session_id == ""
        or type(tool_call_id) ~= "string"
        or tool_call_id == ""
    then
        return nil
    end

    return session_id .. ":" .. tool_call_id
end

--- @param bufnr integer
--- @return agentic.ui.DiffPreview.ReviewSession|nil
function M.get_review_session(bufnr)
    local review_key, tabpage = M.get_attached_review_key(bufnr)
    if not review_key or not tabpage then
        return nil
    end

    return M.get_review_session_by_key(review_key, tabpage)
end

--- @param tabpage number|nil
--- @return number|nil bufnr
function M.get_active_diff_buffer(tabpage)
    local target_tabpage = tabpage or vim.api.nvim_get_current_tabpage()
    local split_state = DiffSplitView.get_split_state(target_tabpage)
    if split_state then
        return split_state.original_bufnr
    end

    return vim.t[target_tabpage]._agentic_diff_preview_bufnr
end

--- @param tabpage number|nil
--- @param bufnr number|nil
function M.set_active_diff_buffer(tabpage, bufnr)
    local target_tabpage = tabpage or vim.api.nvim_get_current_tabpage()
    if not is_valid_tabpage(target_tabpage) then
        return
    end

    vim.t[target_tabpage]._agentic_diff_preview_bufnr = bufnr
end

--- @param review_key string
--- @param session agentic.ui.DiffPreview.ReviewSession|nil
--- @param tabpage integer|nil
function M.set_review_session(review_key, session, tabpage)
    local target_tabpage = tabpage or M.find_review_tabpage(review_key)
    if
        not review_key
        or review_key == ""
        or not target_tabpage
        or not is_valid_tabpage(target_tabpage)
    then
        return
    end

    if session ~= nil then
        set_review_callbacks(
            review_key,
            session.review_actions,
            session.on_detach
        )
    end

    local sessions = get_tab_review_sessions(target_tabpage)
    if session == nil then
        sessions[review_key] = nil
    else
        sessions[review_key] = serialize_review_session(session)
    end
    vim.t[target_tabpage][TAB_REVIEW_SESSIONS_KEY] = sessions
end

--- @param review_key string|nil
--- @param tabpage integer|nil
function M.remove_review_session(review_key, tabpage)
    if not review_key or review_key == "" then
        return
    end

    local target_tabpage = tabpage or M.find_review_tabpage(review_key)
    if not target_tabpage or not is_valid_tabpage(target_tabpage) then
        return
    end

    local sessions = get_tab_review_sessions(target_tabpage)
    sessions[review_key] = nil
    vim.t[target_tabpage][TAB_REVIEW_SESSIONS_KEY] = sessions
    review_callbacks[review_key] = nil
end

--- @param bufnr integer
--- @param tabpage integer
--- @param review_key string
function M.attach_review_to_buffer(bufnr, tabpage, review_key)
    local store = get_buffer_review_store(bufnr)
    if not store then
        return
    end

    store[review_key] = { tabpage = tabpage }
    vim.b[bufnr][BUFFER_REVIEW_KEY] = store
    M.set_active_diff_buffer(tabpage, bufnr)
    M.set_active_review_key(tabpage, review_key)

    local review_session = M.get_review_session_by_key(review_key, tabpage)
    if review_session then
        review_session.needs_review = false
        M.set_review_session(review_key, review_session, tabpage)
    end
end

--- @param bufnr integer
--- @param review_key string|nil
--- @param tabpage integer|nil
function M.detach_review_from_buffer(bufnr, review_key, tabpage)
    local store = get_buffer_review_store(bufnr)
    if not store then
        return
    end

    local attached_review_key, attached_tabpage =
        M.get_attached_review_key(bufnr, tabpage)
    local target_review_key = review_key or attached_review_key
    local target_tabpage = tabpage or attached_tabpage
    if not target_review_key then
        return
    end

    store[target_review_key] = nil
    if next(store) == nil then
        vim.b[bufnr][BUFFER_REVIEW_KEY] = nil
    else
        vim.b[bufnr][BUFFER_REVIEW_KEY] = store
    end

    if target_tabpage then
        if M.get_active_diff_buffer(target_tabpage) == bufnr then
            M.set_active_diff_buffer(target_tabpage, nil)
        end
        if M.get_active_review_key(target_tabpage) == target_review_key then
            M.set_active_review_key(target_tabpage, nil)
        end
    end
end

--- @param review_key string
--- @return boolean
function M.should_resolve_from_chooser(review_key)
    local review_session = M.get_review_session_by_key(review_key)
    return review_session ~= nil
        and review_session.needs_review == true
        and #review_session.pending_block_ids > 0
end

--- @param session agentic.ui.DiffPreview.ReviewSession
--- @return agentic.ui.ToolCallDiff.DiffBlock[]
function M.get_pending_diff_blocks(session)
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
--- @param opts {review_key?: string|nil, tool_call_id?: string|nil, on_detach?: fun(payload: agentic.ui.DiffPreview.DetachPayload)|nil}|nil
--- @return agentic.ui.DiffPreview.ReviewSession
function M.create_review_session(
    file_path,
    diff_blocks,
    review_actions,
    is_approximate,
    opts
)
    opts = opts or {}

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
        review_key = opts.review_key or "",
        tool_call_id = opts.tool_call_id or "",
        file_path = file_path,
        original_lines = vim.deepcopy(original_lines or {}),
        diff_blocks = vim.deepcopy(diff_blocks),
        pending_block_ids = pending_block_ids,
        accepted_block_ids = {},
        rejected_block_ids = {},
        is_approximate = is_approximate == true,
        review_actions = review_actions,
        needs_review = false,
        on_detach = opts.on_detach,
    }

    return session
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
--- @return "accept"|"reject"|nil
local function apply_review_result(session)
    if #session.rejected_block_ids == 0 then
        Logger.notify("All hunks reviewed", vim.log.levels.INFO)
        return "accept"
    end

    if #session.accepted_block_ids == 0 then
        return "reject"
    end

    if session.is_approximate then
        Logger.notify(
            "Partial hunk review is unavailable for approximate diff previews",
            vim.log.levels.WARN
        )
        return "reject"
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

    return "reject"
end

--- @param session agentic.ui.DiffPreview.ReviewSession
--- @param opts {skip_permission_callback?: boolean|nil}|nil
--- @return "accept"|"reject"|nil
local function finalize_review_session(session, opts)
    opts = opts or {}
    local outcome = apply_review_result(session)
    if opts.skip_permission_callback or outcome == nil then
        return outcome
    end

    if outcome == "accept" then
        vim.schedule(session.review_actions.on_accept)
    else
        vim.schedule(session.review_actions.on_reject)
    end

    return outcome
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

--- @param review_key string
--- @param decision "accept"|"reject"
--- @param opts {tabpage?: integer|nil, skip_permission_callback?: boolean|nil}|nil
--- @return boolean resolved
function M.resolve_all_pending(review_key, decision, opts)
    opts = opts or {}

    local tabpage = opts.tabpage or M.find_review_tabpage(review_key)
    local review_session = M.get_review_session_by_key(review_key, tabpage)
    if not review_session or #review_session.pending_block_ids == 0 then
        return false
    end

    while #review_session.pending_block_ids > 0 do
        local block_id = table.remove(review_session.pending_block_ids, 1)
        if decision == "accept" then
            review_session.accepted_block_ids[#review_session.accepted_block_ids + 1] =
                block_id
        else
            review_session.rejected_block_ids[#review_session.rejected_block_ids + 1] =
                block_id
        end
    end

    review_session.needs_review = false
    M.set_review_session(review_key, review_session, tabpage)
    finalize_review_session(review_session, opts)
    return true
end

--- @param bufnr integer
--- @param decision "accept"|"reject"
--- @return boolean resolved
function M.resolve_pending_hunk(bufnr, decision)
    local review_key, tabpage = M.get_attached_review_key(bufnr)
    if not review_key or not tabpage then
        return false
    end

    local review_session = M.get_review_session_by_key(review_key, tabpage)
    if not review_session then
        return false
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        return false
    end

    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local block_id, position =
        find_pending_block_for_cursor(review_session, cursor_line, line_count)
    if not block_id or not position then
        return focus_next_pending_block(
            bufnr,
            review_session,
            winid,
            cursor_line
        )
    end

    if decision == "accept" then
        review_session.accepted_block_ids[#review_session.accepted_block_ids + 1] =
            block_id
    else
        review_session.rejected_block_ids[#review_session.rejected_block_ids + 1] =
            block_id
    end
    table.remove(review_session.pending_block_ids, position)

    if #review_session.pending_block_ids == 0 then
        review_session.needs_review = false
        M.set_review_session(review_key, review_session, tabpage)
        finalize_review_session(review_session)
        return true
    end

    M.set_review_session(review_key, review_session, tabpage)

    InlineRenderer.render_inline_diff_blocks(
        bufnr,
        review_session.file_path,
        M.get_pending_diff_blocks(review_session),
        review_session.review_actions,
        review_session.is_approximate
    )

    local next_position = math.min(position, #review_session.pending_block_ids)
    local next_block_id = review_session.pending_block_ids[next_position]
    if next_block_id then
        local next_block = review_session.diff_blocks[next_block_id]
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

--- @param reason agentic.ui.DiffPreview.ClearReason|nil
--- @return boolean
function M.is_terminal_clear_reason(reason)
    return reason ~= nil and TERMINAL_CLEAR_REASONS[reason] == true
end

--- @param reason agentic.ui.DiffPreview.ClearReason|nil
--- @return boolean
function M.should_cleanup_new_file(reason)
    return reason == "rejected"
        or reason == "dismissed"
        or reason == "tool_failed"
end

--- @param reason agentic.ui.DiffPreview.ClearReason|nil
--- @return boolean
function M.should_notify_detach(reason)
    return reason ~= nil and DETACH_CALLBACK_REASONS[reason] == true
end

--- @param review_key string|nil
--- @param reason agentic.ui.DiffPreview.ClearReason|nil
--- @param bufnr integer|nil
--- @param tabpage integer|nil
function M.mark_review_detached(review_key, reason, bufnr, tabpage)
    if not review_key or review_key == "" then
        return
    end

    local target_tabpage = tabpage or M.find_review_tabpage(review_key)
    local review_session =
        M.get_review_session_by_key(review_key, target_tabpage)
    if not review_session then
        return
    end

    if bufnr then
        M.detach_review_from_buffer(bufnr, review_key, target_tabpage)
    elseif
        target_tabpage
        and M.get_active_review_key(target_tabpage) == review_key
    then
        M.set_active_review_key(target_tabpage, nil)
        M.set_active_diff_buffer(target_tabpage, nil)
    end

    if M.is_terminal_clear_reason(reason) then
        M.remove_review_session(review_key, target_tabpage)
        return
    end

    if #review_session.pending_block_ids > 0 then
        review_session.needs_review = true
    end
    M.set_review_session(review_key, review_session, target_tabpage)
end

--- @param review_key string|nil
--- @param reason agentic.ui.DiffPreview.ClearReason|nil
--- @param bufnr integer|nil
--- @param tabpage integer|nil
function M.notify_review_detach(review_key, reason, bufnr, tabpage)
    if
        reason == nil
        or not M.should_notify_detach(reason)
        or not review_key
    then
        return
    end

    local target_tabpage = tabpage or M.find_review_tabpage(review_key)
    local review_session =
        M.get_review_session_by_key(review_key, target_tabpage)
    if not review_session then
        return
    end

    local on_detach = review_session.on_detach
    if not on_detach then
        return
    end

    vim.schedule(function()
        on_detach({
            bufnr = bufnr,
            review_key = review_key,
            tabpage = target_tabpage,
            tool_call_id = review_session.tool_call_id,
            reason = reason,
        })
    end)
end

return M
