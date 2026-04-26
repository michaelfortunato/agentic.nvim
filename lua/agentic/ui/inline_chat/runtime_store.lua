---@diagnostic disable: invisible, missing-fields
local OverlayRenderer = require("agentic.ui.inline_chat.overlay_renderer")
local PermissionOption = require("agentic.utils.permission_option")
local Utils = require("agentic.ui.inline_chat.utils")

local M = {}

local TOOL_DETAIL_EXCERPT_CHARS = 160
local TOOL_DETAIL_EDGE_CHARS = 72
local FALLBACK_CONVERSATION_ID = "__inline_conversation"

--- @param request_or_opts table|nil
--- @return string
local function get_conversation_id(request_or_opts)
    local conversation_id = request_or_opts and request_or_opts.conversation_id
        or nil
    if type(conversation_id) == "string" and conversation_id ~= "" then
        return conversation_id
    end

    return FALLBACK_CONVERSATION_ID
end

--- @param self agentic.ui.InlineChat
--- @return table<string, agentic.ui.InlineChat.ActiveRequest>
local function ensure_active_requests(self)
    if type(self._active_requests) ~= "table" then
        self._active_requests = {}
    end

    if self._active_request and self._active_request.conversation_id then
        self._active_requests[self._active_request.conversation_id] =
            self._active_request
    end

    return self._active_requests
end

--- @param self agentic.ui.InlineChat
--- @param opts {conversation_id?: string|nil}|nil
--- @return agentic.ui.InlineChat.ActiveRequest|nil
local function get_active_request(self, opts)
    local active_requests = ensure_active_requests(self)
    if opts and opts.conversation_id then
        return active_requests[opts.conversation_id]
    end

    if
        self._active_request
        and not Utils.is_terminal_phase(self._active_request.phase)
    then
        return self._active_request
    end

    local only_request = nil
    for _, request in pairs(active_requests) do
        if not Utils.is_terminal_phase(request.phase) then
            if only_request ~= nil then
                return nil
            end
            only_request = request
        end
    end

    return only_request
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest
local function set_active_request(self, request)
    local active_requests = ensure_active_requests(self)
    active_requests[request.conversation_id] = request
    self._active_request = request
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest
local function remove_active_request(self, request)
    local active_requests = ensure_active_requests(self)
    active_requests[request.conversation_id] = nil

    if self._active_request == request then
        self._active_request = nil
        for _, active_request in pairs(active_requests) do
            self._active_request = active_request
            break
        end
    end
end

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

--- @param _self agentic.ui.InlineChat
--- @param extmark_id integer
--- @return string
local function thread_store_key(_self, extmark_id)
    return Utils.thread_store_key(extmark_id)
end

--- @param _self agentic.ui.InlineChat
--- @param bufnr integer
--- @param extmark_id integer
--- @return string
local function thread_runtime_key(_self, bufnr, extmark_id)
    return Utils.thread_runtime_key(bufnr, extmark_id)
end

--- @param _self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest
--- @param selection agentic.Selection
--- @return agentic.ui.InlineChat.ThreadTurn
local function create_thread_turn(_self, request, selection)
    local timestamp = Utils.current_timestamp()

    --- @type agentic.ui.InlineChat.ThreadTurn
    local turn = {
        conversation_id = request.conversation_id,
        selection = Utils.build_selection_snapshot(selection),
        prompt = request.prompt,
        config_context = request.config_context,
        phase = request.phase,
        status_text = request.status_text,
        thought_text = request.thought_text,
        message_text = request.message_text,
        tool_label = request.tool_label,
        tool_detail = request.tool_detail,
        tool_failed = request.tool_failed,
        overlay_hidden = request.overlay_hidden,
        created_at = timestamp,
        updated_at = timestamp,
    }

    return turn
end

--- @param tool_call table
--- @return string|nil detail
local function get_tool_detail(tool_call)
    if type(tool_call.body) ~= "table" then
        return nil
    end

    local lines = {}
    for _, line in ipairs(tool_call.body) do
        local sanitized = Utils.sanitize_text(line)
        if sanitized ~= "" then
            lines[#lines + 1] = sanitized
        end
    end

    if #lines == 0 then
        return nil
    end

    local function excerpt_line(line)
        local char_count = vim.fn.strchars(line)
        if char_count <= TOOL_DETAIL_EXCERPT_CHARS then
            return line
        end

        return vim.fn.strcharpart(line, 0, TOOL_DETAIL_EDGE_CHARS)
            .. " ... "
            .. vim.fn.strcharpart(line, char_count - TOOL_DETAIL_EDGE_CHARS)
    end

    local first_line = excerpt_line(lines[1])
    local last_line = excerpt_line(lines[#lines])
    if first_line == last_line then
        return first_line
    end

    return first_line .. " ... " .. last_line
end

--- @param _self agentic.ui.InlineChat
--- @param bufnr integer
--- @param range {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid?: boolean}
--- @return {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid?: boolean}|nil
local function normalize_range(_self, bufnr, range)
    return Utils.normalize_range(bufnr, range)
end

--- @param _self agentic.ui.InlineChat
--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer start_row
--- @return integer start_col
--- @return integer end_row
--- @return integer end_col
local function selection_to_extmark_range(_self, bufnr, selection)
    return Utils.selection_to_extmark_range(bufnr, selection)
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer|nil
local function find_matching_thread_extmark(self, bufnr, selection)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local start_row, start_col, end_row, end_col =
        selection_to_extmark_range(self, bufnr, selection)

    local extmarks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        self.NS_INLINE_THREADS,
        0,
        -1,
        { details = true }
    )

    for _, extmark in ipairs(extmarks) do
        local details = extmark[4] or {}
        if
            extmark[2] == start_row
            and extmark[3] == start_col
            and (details.end_row or extmark[2]) == end_row
            and (details.end_col or extmark[3]) == end_col
        then
            return extmark[1]
        end
    end

    return nil
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer
local function ensure_thread_extmark(self, bufnr, selection)
    local existing_extmark_id =
        find_matching_thread_extmark(self, bufnr, selection)
    if existing_extmark_id ~= nil then
        return existing_extmark_id
    end

    local start_row, start_col, end_row, end_col =
        selection_to_extmark_range(self, bufnr, selection)

    return vim.api.nvim_buf_set_extmark(
        bufnr,
        self.NS_INLINE_THREADS,
        start_row,
        start_col,
        {
            end_row = end_row,
            end_col = end_col,
            right_gravity = false,
            end_right_gravity = true,
            undo_restore = true,
            invalidate = true,
        }
    )
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

    return normalize_range(self, bufnr, range)
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param extmark_id integer
--- @return string
local function get_request_runtime_key(self, bufnr, extmark_id)
    return thread_runtime_key(self, bufnr, extmark_id)
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
    local runtime_id = get_request_runtime_key(self, bufnr, range_extmark_id)
    local runtime = self._thread_runtimes[runtime_id]

    if runtime == nil then
        --- @type agentic.ui.InlineChat.ThreadRuntime
        local new_runtime = {
            source_bufnr = bufnr,
            source_winid = source_winid,
            range_extmark_id = range_extmark_id,
            overlay_extmark_id = nil,
            close_timer = nil,
            sparkle_timer = nil,
            sparkle_frame = 1,
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

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest|nil
local function dismiss_progress(self, request)
    OverlayRenderer.dismiss_progress(self, request)
end

--- @param self agentic.ui.InlineChat
--- @param runtime_id string
local function clear_thread_overlay(self, runtime_id)
    OverlayRenderer.clear_thread_overlay(self, runtime_id)
end

--- @param self agentic.ui.InlineChat
--- @param runtime_id string
local function clear_thread_runtime(self, runtime_id)
    local runtime = self._thread_runtimes[runtime_id]
    if not runtime then
        return
    end

    stop_thread_close_timer(self, runtime)
    clear_thread_overlay(self, runtime_id)

    for _, active_request in pairs(ensure_active_requests(self)) do
        if
            Utils.is_terminal_phase(active_request.phase)
            and get_request_runtime_key(
                    self,
                    active_request.source_bufnr,
                    active_request.range_extmark_id
                )
                == runtime_id
        then
            dismiss_progress(self, active_request)
            remove_active_request(self, active_request)
        end
    end

    for submission_id, queued_request in pairs(self._queued_requests) do
        if
            get_request_runtime_key(
                self,
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
--- @param request agentic.ui.InlineChat.ActiveRequest
--- @param selection agentic.Selection
--- @return agentic.ui.InlineChat.ThreadTurn
local function create_or_update_turn(self, request, selection)
    return create_thread_turn(self, request, selection)
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.RequestInput
--- @return agentic.ui.InlineChat.ActiveRequest
--- @return string
function M._build_request_state(self, request)
    local selection =
        Utils.normalize_selection(request.source_bufnr, request.selection)
    local range_extmark_id =
        ensure_thread_extmark(self, request.source_bufnr, selection)
    local runtime_id, runtime = ensure_thread_runtime(
        self,
        request.source_bufnr,
        request.source_winid,
        range_extmark_id
    )
    stop_thread_close_timer(self, runtime)

    local store = ensure_thread_store(self, request.source_bufnr)
    local thread = store[thread_store_key(self, range_extmark_id)]
    local thread_turn_index = thread and (#thread.turns + 1) or 1

    --- @type agentic.ui.InlineChat.ActiveRequest
    local request_state = {
        conversation_id = get_conversation_id(request),
        submission_id = request.submission_id,
        source_bufnr = request.source_bufnr,
        source_winid = request.source_winid,
        selection = selection,
        prompt = request.prompt,
        config_context = self._get_config_context(),
        range_extmark_id = range_extmark_id,
        thread_turn_index = thread_turn_index,
        phase = request.phase or "busy",
        status_text = request.status_text or "Starting inline request",
        thought_text = "",
        message_text = "",
        tool_label = nil,
        tool_detail = nil,
        tool_failed = false,
        overlay_hidden = false,
        progress_id = nil,
    }

    return request_state, runtime_id
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer|nil
function M._find_matching_thread_extmark(self, bufnr, selection)
    return find_matching_thread_extmark(self, bufnr, selection)
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer
function M._ensure_thread_extmark(self, bufnr, selection)
    return ensure_thread_extmark(self, bufnr, selection)
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param source_winid integer
--- @param range_extmark_id integer
--- @return string runtime_id
--- @return agentic.ui.InlineChat.ThreadRuntime runtime
function M._ensure_thread_runtime(self, bufnr, source_winid, range_extmark_id)
    return ensure_thread_runtime(self, bufnr, source_winid, range_extmark_id)
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param extmark_id integer
--- @return {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid: boolean}|nil
function M._get_thread_range(self, bufnr, extmark_id)
    return get_thread_range(self, bufnr, extmark_id)
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest
--- @return agentic.Selection
function M._get_tracked_selection(self, request)
    local range =
        get_thread_range(self, request.source_bufnr, request.range_extmark_id)
    return Utils.build_selection_snapshot(request.selection, range)
end

--- @param self agentic.ui.InlineChat
--- @return boolean
function M.has_pending_or_active_requests(self)
    return next(ensure_active_requests(self)) ~= nil
        or next(self._queued_requests) ~= nil
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param range_extmark_id integer
--- @param removed_turn_index integer
function M._shift_thread_turn_indices(
    self,
    bufnr,
    range_extmark_id,
    removed_turn_index
)
    for _, active_request in pairs(ensure_active_requests(self)) do
        if
            active_request.source_bufnr == bufnr
            and active_request.range_extmark_id == range_extmark_id
            and active_request.thread_turn_index > removed_turn_index
        then
            active_request.thread_turn_index = active_request.thread_turn_index
                - 1
        end
    end

    for _, queued_request in pairs(self._queued_requests) do
        if
            queued_request.source_bufnr == bufnr
            and queued_request.range_extmark_id == range_extmark_id
            and queued_request.thread_turn_index > removed_turn_index
        then
            queued_request.thread_turn_index = queued_request.thread_turn_index
                - 1
        end
    end
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param range_extmark_id integer
function M._drop_thread(self, bufnr, range_extmark_id)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local store = ensure_thread_store(self, bufnr)
    store[thread_store_key(self, range_extmark_id)] = nil
    vim.b[bufnr][self.THREAD_STORE_KEY] = store

    pcall(
        vim.api.nvim_buf_del_extmark,
        bufnr,
        self.NS_INLINE_THREADS,
        range_extmark_id
    )

    clear_thread_runtime(
        self,
        thread_runtime_key(self, bufnr, range_extmark_id)
    )
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param range_extmark_id integer
--- @param thread_turn_index integer
function M._remove_thread_turn(self, bufnr, range_extmark_id, thread_turn_index)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local store = ensure_thread_store(self, bufnr)
    local thread = store[thread_store_key(self, range_extmark_id)]
    if not thread then
        return
    end

    if thread_turn_index < 1 or thread_turn_index > #thread.turns then
        return
    end

    table.remove(thread.turns, thread_turn_index)
    M._shift_thread_turn_indices(
        self,
        bufnr,
        range_extmark_id,
        thread_turn_index
    )

    if #thread.turns == 0 then
        M._drop_thread(self, bufnr, range_extmark_id)
        return
    end

    thread.updated_at = Utils.current_timestamp()
    store[thread_store_key(self, range_extmark_id)] = thread
    vim.b[bufnr][self.THREAD_STORE_KEY] = store
    OverlayRenderer.render_thread(
        self,
        thread_runtime_key(self, bufnr, range_extmark_id)
    )
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
--- @param request agentic.ui.InlineChat.ActiveRequest
function M._sync_thread_history(self, bufnr, request)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local store = ensure_thread_store(self, bufnr)
    local range = get_thread_range(self, bufnr, request.range_extmark_id)
    local selection = Utils.build_selection_snapshot(request.selection, range)
    local thread_id = thread_store_key(self, request.range_extmark_id)
    local thread = store[thread_id]
    local timestamp = Utils.current_timestamp()

    if thread == nil then
        --- @type agentic.ui.InlineChat.ThreadState
        local new_thread = {
            extmark_id = request.range_extmark_id,
            source_bufnr = bufnr,
            selection = Utils.build_selection_snapshot(selection),
            turns = {},
            updated_at = timestamp,
        }
        thread = new_thread
        store[thread_id] = thread
    end

    thread.selection = Utils.build_selection_snapshot(selection)
    thread.updated_at = timestamp

    local turn = thread.turns[request.thread_turn_index]
    if turn == nil then
        turn = create_or_update_turn(self, request, selection)
        thread.turns[request.thread_turn_index] = turn
    else
        turn.conversation_id = request.conversation_id
        turn.selection = Utils.build_selection_snapshot(selection)
        turn.prompt = request.prompt
        turn.config_context = request.config_context
        turn.phase = request.phase
        turn.status_text = request.status_text
        turn.thought_text = request.thought_text
        turn.message_text = request.message_text
        turn.tool_label = request.tool_label
        turn.tool_detail = request.tool_detail
        turn.tool_failed = request.tool_failed
        turn.overlay_hidden = request.overlay_hidden
        turn.updated_at = timestamp
    end

    vim.b[bufnr][self.THREAD_STORE_KEY] = store
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.RequestInput
function M.queue_request(self, request)
    local queued_request = self._queued_requests[request.submission_id]
    local runtime_id = nil

    if queued_request == nil then
        queued_request, runtime_id = M._build_request_state(self, {
            conversation_id = request.conversation_id,
            submission_id = request.submission_id,
            prompt = request.prompt,
            selection = request.selection,
            source_bufnr = request.source_bufnr,
            source_winid = request.source_winid,
            phase = "busy",
            status_text = "Queued next",
        })
        self._queued_requests[request.submission_id] = queued_request
    else
        queued_request.source_bufnr = request.source_bufnr
        queued_request.source_winid = request.source_winid
        queued_request.conversation_id = get_conversation_id(request)
        queued_request.selection =
            Utils.normalize_selection(request.source_bufnr, request.selection)
        queued_request.prompt = request.prompt
        queued_request.config_context = self._get_config_context()
        queued_request.overlay_hidden = false
        queued_request.tool_detail = nil
        queued_request.tool_failed = false
    end

    queued_request.phase = "busy"
    queued_request.status_text = "Queued next"
    M._sync_thread_history(self, queued_request.source_bufnr, queued_request)
    OverlayRenderer.render_thread(
        self,
        runtime_id
            or get_request_runtime_key(
                self,
                queued_request.source_bufnr,
                queued_request.range_extmark_id
            )
    )
end

--- @param self agentic.ui.InlineChat
--- @param queue_items agentic.SessionManager.QueuedSubmission[]
--- @param opts {waiting_for_session?: boolean|nil, interrupt_submission?: agentic.SessionManager.QueuedSubmission|nil}|nil
function M.sync_queued_requests(self, queue_items, opts)
    opts = opts or {}

    local queue_positions = {}
    local next_position = 1
    local interrupt_submission = opts.interrupt_submission

    if
        interrupt_submission
        and interrupt_submission.id ~= nil
        and interrupt_submission.inline_request ~= nil
    then
        queue_positions[interrupt_submission.id] = next_position
        next_position = next_position + 1
    end

    for _, submission in ipairs(queue_items or {}) do
        if submission.inline_request ~= nil then
            queue_positions[submission.id] = next_position
            next_position = next_position + 1
        end
    end

    for submission_id, queued_request in pairs(self._queued_requests) do
        local position = queue_positions[submission_id]
        if position ~= nil then
            queued_request.phase = opts.waiting_for_session and "waiting"
                or "busy"
            queued_request.status_text = Utils.build_queue_status(
                position,
                opts.waiting_for_session == true
            )
            queued_request.config_context = self._get_config_context()
            queued_request.tool_detail = nil
            queued_request.tool_failed = false
            M._sync_thread_history(
                self,
                queued_request.source_bufnr,
                queued_request
            )
            OverlayRenderer.render_thread(
                self,
                get_request_runtime_key(
                    self,
                    queued_request.source_bufnr,
                    queued_request.range_extmark_id
                )
            )
        end
    end
end

--- @param self agentic.ui.InlineChat
--- @param source_bufnr integer
--- @param selection agentic.Selection
--- @return integer|nil
function M.find_overlapping_queued_submission(self, source_bufnr, selection)
    local start_row, start_col, end_row, end_col =
        selection_to_extmark_range(self, source_bufnr, selection)
    local target_range = normalize_range(self, source_bufnr, {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
    })
    if target_range == nil then
        return nil
    end

    for submission_id, queued_request in pairs(self._queued_requests) do
        if queued_request.source_bufnr == source_bufnr then
            local queued_range = get_thread_range(
                self,
                queued_request.source_bufnr,
                queued_request.range_extmark_id
            )

            if queued_range == nil then
                local queued_start_row, queued_start_col, queued_end_row, queued_end_col =
                    selection_to_extmark_range(
                        self,
                        queued_request.source_bufnr,
                        queued_request.selection
                    )
                queued_range =
                    normalize_range(self, queued_request.source_bufnr, {
                        start_row = queued_start_row,
                        start_col = queued_start_col,
                        end_row = queued_end_row,
                        end_col = queued_end_col,
                    })
            end

            if
                queued_range
                and Utils.ranges_overlap(target_range, queued_range)
            then
                return submission_id
            end
        end
    end

    return nil
end

--- @param self agentic.ui.InlineChat
--- @param submission_id integer
--- @return boolean
function M.remove_queued_submission(self, submission_id)
    local queued_request = self._queued_requests[submission_id]
    if queued_request == nil then
        return false
    end

    self._queued_requests[submission_id] = nil
    M._remove_thread_turn(
        self,
        queued_request.source_bufnr,
        queued_request.range_extmark_id,
        queued_request.thread_turn_index
    )
    return true
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.RequestInput
function M.begin_request(self, request)
    local conversation_id = get_conversation_id(request)
    local previous_request = ensure_active_requests(self)[conversation_id]
    if previous_request and Utils.is_terminal_phase(previous_request.phase) then
        OverlayRenderer.dismiss_progress(self, previous_request)
        remove_active_request(self, previous_request)
    end

    local queued_request = request.submission_id ~= nil
            and self._queued_requests[request.submission_id]
        or nil
    local runtime_id = nil

    if queued_request ~= nil then
        self._queued_requests[request.submission_id] = nil
        queued_request.conversation_id = conversation_id
        queued_request.source_bufnr = request.source_bufnr
        queued_request.source_winid = request.source_winid
        queued_request.selection =
            Utils.normalize_selection(request.source_bufnr, request.selection)
        queued_request.prompt = request.prompt
        queued_request.config_context = self._get_config_context()
        queued_request.phase = request.phase or "busy"
        queued_request.status_text = request.status_text
            or "Starting inline request"
        queued_request.tool_label = nil
        queued_request.tool_detail = nil
        queued_request.tool_failed = false
        queued_request.overlay_hidden = false
        runtime_id = get_request_runtime_key(
            self,
            queued_request.source_bufnr,
            queued_request.range_extmark_id
        )

        local _, runtime = ensure_thread_runtime(
            self,
            queued_request.source_bufnr,
            queued_request.source_winid,
            queued_request.range_extmark_id
        )
        stop_thread_close_timer(self, runtime)
        set_active_request(self, queued_request)
    else
        local request_state
        request_state, runtime_id = M._build_request_state(self, {
            conversation_id = conversation_id,
            submission_id = request.submission_id,
            prompt = request.prompt,
            selection = request.selection,
            source_bufnr = request.source_bufnr,
            source_winid = request.source_winid,
            phase = request.phase,
            status_text = request.status_text,
        })
        set_active_request(self, request_state)
    end

    local active_request = ensure_active_requests(self)[conversation_id]
    if active_request == nil then
        return
    end

    M._sync_thread_history(self, request.source_bufnr, active_request)
    OverlayRenderer.render_thread(self, runtime_id)
    OverlayRenderer.update_progress(self, active_request)
end

--- @param self agentic.ui.InlineChat
function M.refresh(self)
    for _, active_request in pairs(ensure_active_requests(self)) do
        M._sync_thread_history(
            self,
            active_request.source_bufnr,
            active_request
        )
    end

    for _, queued_request in pairs(self._queued_requests) do
        M._sync_thread_history(
            self,
            queued_request.source_bufnr,
            queued_request
        )
    end

    for runtime_id, _ in pairs(self._thread_runtimes) do
        OverlayRenderer.render_thread(self, runtime_id)
    end
end

--- @param self agentic.ui.InlineChat
--- @param update agentic.acp.SessionUpdateMessage
--- @param opts {conversation_id?: string|nil}|nil
function M.handle_session_update(self, update, opts)
    local request = get_active_request(self, opts)
    if not request or Utils.is_terminal_phase(request.phase) then
        return
    end

    if update.sessionUpdate == "agent_thought_chunk" then
        local text = update.content
                and update.content.type == "text"
                and update.content.text
            or nil
        if text and text ~= "" then
            request.thought_text = request.thought_text .. text
        end
        request.phase = "thinking"
        request.status_text = "Thinking"
        request.tool_detail = nil
        request.tool_failed = false
    elseif update.sessionUpdate == "agent_message_chunk" then
        local text = update.content
                and update.content.type == "text"
                and update.content.text
            or nil
        if text and text ~= "" then
            request.message_text = request.message_text .. text
        end
        request.phase = "generating"
        request.status_text = "Generating response"
        request.tool_detail = nil
        request.tool_failed = false
    else
        return
    end

    M._sync_thread_history(self, request.source_bufnr, request)
    OverlayRenderer.render_thread(
        self,
        get_request_runtime_key(
            self,
            request.source_bufnr,
            request.range_extmark_id
        )
    )
    OverlayRenderer.update_progress(self, request)
end

--- @param self agentic.ui.InlineChat
--- @param tool_call table
--- @param opts {conversation_id?: string|nil}|nil
function M.handle_tool_call(self, tool_call, opts)
    local request = get_active_request(self, opts)
    if not request or Utils.is_terminal_phase(request.phase) then
        return
    end

    request.phase = "tool"
    local next_tool_label = Utils.build_tool_label(tool_call)
    if
        next_tool_label == "tool"
        and request.tool_label
        and request.tool_label ~= ""
    then
        next_tool_label = request.tool_label
    end

    request.tool_label = next_tool_label
    request.tool_detail = nil
    request.tool_failed = false
    request.status_text = "Running " .. request.tool_label
    M._sync_thread_history(self, request.source_bufnr, request)
    OverlayRenderer.render_thread(
        self,
        get_request_runtime_key(
            self,
            request.source_bufnr,
            request.range_extmark_id
        )
    )
    OverlayRenderer.update_progress(self, request)
end

--- @param self agentic.ui.InlineChat
--- @param tool_call table
--- @param opts {conversation_id?: string|nil}|nil
function M.handle_tool_call_update(self, tool_call, opts)
    local request = get_active_request(self, opts)
    if not request or Utils.is_terminal_phase(request.phase) then
        return
    end

    local next_tool_label = Utils.build_tool_label(tool_call)
    if
        next_tool_label == "tool"
        and request.tool_label
        and request.tool_label ~= ""
    then
        next_tool_label = request.tool_label
    end

    request.tool_label = next_tool_label
    request.tool_detail = get_tool_detail(tool_call)

    if tool_call.status == "failed" then
        request.phase = "generating"
        request.tool_failed = true
        request.status_text = "Tool issue: " .. request.tool_label
    elseif tool_call.status == "completed" then
        request.phase = "generating"
        request.tool_detail = nil
        request.tool_failed = false
        request.status_text = "Completed " .. request.tool_label
    else
        request.phase = "tool"
        request.tool_detail = nil
        request.tool_failed = false
        request.status_text = "Running " .. request.tool_label
    end

    M._sync_thread_history(self, request.source_bufnr, request)
    OverlayRenderer.render_thread(
        self,
        get_request_runtime_key(
            self,
            request.source_bufnr,
            request.range_extmark_id
        )
    )
    OverlayRenderer.update_progress(self, request)
end

--- @param self agentic.ui.InlineChat
--- @param opts {conversation_id?: string|nil}|nil
function M.handle_permission_request(self, opts)
    local request = get_active_request(self, opts)
    if not request or Utils.is_terminal_phase(request.phase) then
        return
    end

    request.phase = "waiting"
    request.status_text = "Waiting for approval"
    request.tool_detail = nil
    request.tool_failed = false
    M._sync_thread_history(self, request.source_bufnr, request)
    OverlayRenderer.render_thread(
        self,
        get_request_runtime_key(
            self,
            request.source_bufnr,
            request.range_extmark_id
        )
    )
    OverlayRenderer.update_progress(self, request)
end

--- @param self agentic.ui.InlineChat
--- @param request agentic.ui.InlineChat.ActiveRequest|nil
local function hide_request_overlay(self, request)
    if
        not request
        or Utils.is_terminal_phase(request.phase)
        or request.overlay_hidden
    then
        return
    end

    request.overlay_hidden = true
    M._sync_thread_history(self, request.source_bufnr, request)
    clear_thread_overlay(
        self,
        get_request_runtime_key(
            self,
            request.source_bufnr,
            request.range_extmark_id
        )
    )
end

--- @param self agentic.ui.InlineChat
--- @param opts {conversation_id?: string|nil, option_id?: string|nil, options?: agentic.acp.PermissionOption[]|nil}|nil
function M.handle_permission_resolution(self, opts)
    opts = opts or {}

    local request = get_active_request(self, opts)
    if not request then
        return
    end

    hide_request_overlay(self, request)

    local permission_state =
        PermissionOption.get_state_for_option_id(opts.options, opts.option_id)
    if permission_state ~= "rejected" then
        return
    end

    local selection = M._get_tracked_selection(self, request)
    if
        request.source_bufnr == nil
        or not vim.api.nvim_buf_is_valid(request.source_bufnr)
    then
        return
    end

    vim.schedule(function()
        self:open(selection, {
            conversation_id = request.conversation_id,
            close_cancels_conversation = true,
            source_bufnr = request.source_bufnr,
            source_winid = request.source_winid,
        })
    end)
end

--- @param self agentic.ui.InlineChat
--- @param opts {conversation_id?: string|nil}|nil
function M.handle_applied_edit(self, opts)
    hide_request_overlay(self, get_active_request(self, opts))
end

--- @param self agentic.ui.InlineChat
--- @param response agentic.acp.PromptResponse|nil
--- @param err table|nil
--- @param opts {conversation_id?: string|nil}|nil
function M.complete(self, response, err, opts)
    local request = get_active_request(self, opts)
    if not request or Utils.is_terminal_phase(request.phase) then
        return
    end

    if err then
        request.phase = "failed"
        request.status_text = "Inline request failed"
        request.message_text = request.message_text == "" and vim.inspect(err)
            or request.message_text
    elseif response and response.stopReason == "cancelled" then
        request.phase = "failed"
        request.status_text = "Inline request cancelled"
    else
        request.phase = "completed"
        request.status_text = "Inline request complete"
    end

    request.tool_detail = nil
    request.tool_failed = false

    M._sync_thread_history(self, request.source_bufnr, request)
    OverlayRenderer.render_thread(
        self,
        get_request_runtime_key(
            self,
            request.source_bufnr,
            request.range_extmark_id
        )
    )
    OverlayRenderer.update_progress(self, request, true)
    OverlayRenderer.schedule_close(self, request)
end

--- @param self agentic.ui.InlineChat
--- @param bufnr integer
function M.clear_buffer(self, bufnr)
    if type(bufnr) ~= "number" then
        return
    end

    local prompt = self._prompt
    if prompt and prompt.source_bufnr == bufnr then
        self:_close_prompt(true)
    end

    for _, active_request in pairs(ensure_active_requests(self)) do
        if active_request.source_bufnr == bufnr then
            active_request.overlay_hidden = true
            remove_active_request(self, active_request)
        end
    end

    for _, queued_request in pairs(self._queued_requests) do
        if queued_request.source_bufnr == bufnr then
            queued_request.overlay_hidden = true
        end
    end

    local runtime_ids = {}
    for runtime_id, runtime in pairs(self._thread_runtimes) do
        if runtime.source_bufnr == bufnr then
            runtime_ids[#runtime_ids + 1] = runtime_id
        end
    end

    for _, runtime_id in ipairs(runtime_ids) do
        local runtime = self._thread_runtimes[runtime_id]
        if runtime then
            stop_thread_close_timer(self, runtime)
            clear_thread_overlay(self, runtime_id)
            self._thread_runtimes[runtime_id] = nil
        end
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    pcall(vim.api.nvim_buf_clear_namespace, bufnr, self.NS_INLINE, 0, -1)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        bufnr,
        self.NS_INLINE_THREADS,
        0,
        -1
    )
    vim.b[bufnr][self.THREAD_STORE_KEY] = {}
end

--- @param self agentic.ui.InlineChat
function M.clear(self)
    self:_close_prompt(true)

    for _, active_request in pairs(ensure_active_requests(self)) do
        OverlayRenderer.dismiss_progress(self, active_request)
    end

    local runtime_ids = vim.tbl_keys(self._thread_runtimes)
    for _, runtime_id in ipairs(runtime_ids) do
        clear_thread_runtime(self, runtime_id)
    end

    self._active_request = nil
    self._active_requests = {}
    self._queued_requests = {}
end

--- @param self agentic.ui.InlineChat
function M.destroy(self)
    M.clear(self)
end

return M
