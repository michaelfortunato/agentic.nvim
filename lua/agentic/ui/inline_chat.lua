local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local KeymapHelp = require("agentic.ui.keymap_help")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local NS_INLINE = vim.api.nvim_create_namespace("agentic_inline_chat")
local NS_INLINE_THREADS =
    vim.api.nvim_create_namespace("agentic_inline_chat_threads")
local KEYMAP_HELP_KEY = "?"
local THREAD_STORE_KEY = "_agentic_inline_threads"

local PROGRESS_PERCENT = {
    busy = 5,
    thinking = 20,
    generating = 55,
    tool = 72,
    waiting = 85,
    completed = 100,
    failed = 100,
}

--- @class agentic.ui.InlineChat.OpenSelection
--- @field file_path string
--- @field start_line integer
--- @field end_line integer

--- @class agentic.ui.InlineChat.PromptState
--- @field prompt_bufnr integer
--- @field prompt_winid integer
--- @field selection agentic.Selection
--- @field source_bufnr integer
--- @field source_winid integer

--- @class agentic.ui.InlineChat.ActiveRequest
--- @field source_bufnr integer
--- @field source_winid integer
--- @field selection agentic.Selection
--- @field prompt string
--- @field range_extmark_id integer
--- @field overlay_extmark_id? integer
--- @field thread_turn_index integer
--- @field phase "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed"
--- @field status_text string
--- @field thought_text string
--- @field message_text string
--- @field tool_label? string
--- @field progress_id? integer
--- @field close_timer? uv.uv_timer_t

--- @class agentic.ui.InlineChat.ThreadTurn
--- @field selection agentic.Selection
--- @field prompt string
--- @field phase "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed"
--- @field status_text string
--- @field thought_text string
--- @field message_text string
--- @field tool_label? string
--- @field created_at integer
--- @field updated_at integer

--- @class agentic.ui.InlineChat.ThreadState
--- @field extmark_id integer
--- @field source_bufnr integer
--- @field selection agentic.Selection
--- @field turns agentic.ui.InlineChat.ThreadTurn[]
--- @field updated_at integer

--- @alias agentic.ui.InlineChat.ThreadStore table<string, agentic.ui.InlineChat.ThreadState>

--- @class agentic.ui.InlineChat.NewOpts
--- @field tab_page_id integer
--- @field on_submit fun(request: {prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}): boolean
--- @field on_change_mode? fun(): nil
--- @field on_change_model? fun(): nil
--- @field on_change_thought_level? fun(): nil
--- @field on_change_approval_preset? fun(): nil
--- @field get_config_context? fun(): string|nil

--- @class agentic.ui.InlineChat
--- @field tab_page_id integer
--- @field _on_submit fun(request: {prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}): boolean
--- @field _on_change_mode fun(): nil
--- @field _on_change_model fun(): nil
--- @field _on_change_thought_level fun(): nil
--- @field _on_change_approval_preset fun(): nil
--- @field _get_config_context fun(): string|nil
--- @field _prompt? agentic.ui.InlineChat.PromptState
--- @field _active_request? agentic.ui.InlineChat.ActiveRequest
local InlineChat = {}
InlineChat.__index = InlineChat
InlineChat.NS_INLINE = NS_INLINE
InlineChat.NS_INLINE_THREADS = NS_INLINE_THREADS
InlineChat.THREAD_STORE_KEY = THREAD_STORE_KEY

--- @param mode string
--- @return agentic.Theme.SpinnerState
local function phase_to_spinner_state(mode)
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

--- @return boolean
local function supports_progress_messages()
    return vim.fn.has("nvim-0.12") == 1
end

--- @param keymaps agentic.UserConfig.KeymapValue
--- @param mode string
--- @return string|nil
local function find_keymap(keymaps, mode)
    if type(keymaps) == "string" then
        return mode == "n" and keymaps or nil
    end

    if type(keymaps) ~= "table" then
        return nil
    end

    for _, keymap in ipairs(keymaps) do
        if type(keymap) == "string" and mode == "n" then
            return keymap
        end

        if type(keymap) == "table" then
            if keymap.mode == mode then
                return keymap[1]
            end

            if type(keymap.mode) == "table" then
                local modes = keymap.mode
                --- @cast modes string[]
                for _, candidate_mode in ipairs(modes) do
                    if candidate_mode == mode then
                        return keymap[1]
                    end
                end
            end
        end
    end

    return nil
end

--- @param text string|nil
--- @return string
local function sanitize_text(text)
    if type(text) ~= "string" then
        return ""
    end

    return vim.trim(text:gsub("\r", ""))
end

--- @param text string|nil
--- @return string[]
local function split_lines(text)
    text = sanitize_text(text)
    if text == "" then
        return {}
    end

    return vim.split(text, "\n", { plain = true, trimempty = true })
end

--- @return integer
local function current_timestamp()
    return os.time()
end

--- @param extmark_id integer
--- @return string
local function thread_store_key(extmark_id)
    return tostring(extmark_id)
end

--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer start_row
--- @return integer start_col
--- @return integer end_row
--- @return integer end_col
local function selection_to_extmark_range(bufnr, selection)
    local start_row = math.max(0, selection.start_line - 1)
    local start_col = math.max(0, (selection.start_col or 1) - 1)
    local end_row = math.max(start_row, selection.end_line - 1)
    local end_col = selection.end_col

    if end_col == nil then
        local end_line = vim.api.nvim_buf_get_lines(
            bufnr,
            end_row,
            end_row + 1,
            false
        )[1] or ""
        end_col = #end_line
    end

    return start_row, start_col, end_row, end_col
end

--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return integer
local function clamp_col(bufnr, row, col)
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    return math.max(0, math.min(col, #line))
end

--- @param bufnr integer
--- @param range {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid?: boolean}
--- @return {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid?: boolean}|nil
local function normalize_range(bufnr, range)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count <= 0 then
        return nil
    end

    local start_row = math.max(0, math.min(range.start_row, line_count - 1))
    local end_row = math.max(start_row, math.min(range.end_row, line_count - 1))
    local start_col = clamp_col(bufnr, start_row, range.start_col)
    local end_col = clamp_col(bufnr, end_row, range.end_col)

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

--- @param bufnr integer
--- @return agentic.ui.InlineChat.ThreadStore
local function ensure_thread_store(bufnr)
    local store = vim.b[bufnr][THREAD_STORE_KEY]
    if type(store) ~= "table" then
        store = {}
        vim.b[bufnr][THREAD_STORE_KEY] = store
    end

    --- @cast store agentic.ui.InlineChat.ThreadStore
    return store
end

--- @param selection agentic.Selection
--- @param range {start_row: integer, start_col: integer, end_row: integer, end_col: integer}|nil
--- @return agentic.Selection
local function build_selection_snapshot(selection, range)
    --- @type agentic.Selection
    local snapshot = vim.deepcopy(selection)

    if range then
        snapshot.start_line = range.start_row + 1
        snapshot.end_line = range.end_row + 1
        snapshot.start_col = range.start_col + 1
        if range.end_col >= 0 then
            snapshot.end_col = range.end_col
        end
    end

    return snapshot
end

--- @param request agentic.ui.InlineChat.ActiveRequest
--- @param selection agentic.Selection
--- @return agentic.ui.InlineChat.ThreadTurn
local function create_thread_turn(request, selection)
    local timestamp = current_timestamp()

    --- @type agentic.ui.InlineChat.ThreadTurn
    local turn = {
        selection = build_selection_snapshot(selection),
        prompt = request.prompt,
        phase = request.phase,
        status_text = request.status_text,
        thought_text = request.thought_text,
        message_text = request.message_text,
        tool_label = request.tool_label,
        created_at = timestamp,
        updated_at = timestamp,
    }

    return turn
end

--- @param lines string[]
--- @param limit integer
--- @return string[]
local function tail_lines(lines, limit)
    if #lines <= limit then
        return lines
    end

    return vim.list_slice(lines, #lines - limit + 1, #lines)
end

--- @param text string
--- @param max_width integer
--- @return string
local function truncate_text(text, max_width)
    text = sanitize_text(text):gsub("%s+", " ")
    if text == "" or max_width <= 0 then
        return text
    end

    if vim.fn.strdisplaywidth(text) <= max_width then
        return text
    end

    if max_width <= 3 then
        return vim.fn.strcharpart(text, 0, max_width)
    end

    return vim.fn.strcharpart(text, 0, max_width - 3) .. "..."
end

--- @param selection agentic.Selection
--- @return string
local function format_range(selection)
    local file_name = vim.fs.basename(selection.file_path or "")
    if file_name == "" then
        file_name = "[No Name]"
    end

    return string.format(
        "%s:%d-%d",
        file_name,
        selection.start_line,
        selection.end_line
    )
end

--- @param tool_call table
--- @return string
local function build_tool_label(tool_call)
    local kind = sanitize_text(tool_call.kind)
    local argument = sanitize_text(tool_call.argument)
    local file_name = vim.fs.basename(sanitize_text(tool_call.file_path))

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
local function fade_inline_hl(hl)
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
local function faded_segment(text, hl)
    local segment = { text, fade_inline_hl(hl) }
    return segment
end

--- @param opts agentic.ui.InlineChat.NewOpts
--- @return agentic.ui.InlineChat
function InlineChat:new(opts)
    local instance = setmetatable({
        tab_page_id = opts.tab_page_id,
        _on_submit = opts.on_submit,
        _on_change_mode = opts.on_change_mode or function() end,
        _on_change_model = opts.on_change_model or function() end,
        _on_change_thought_level = opts.on_change_thought_level
            or function() end,
        _on_change_approval_preset = opts.on_change_approval_preset
            or function() end,
        _get_config_context = opts.get_config_context or function()
            return nil
        end,
        _prompt = nil,
        _active_request = nil,
    }, self)

    return instance
end

--- @return boolean
function InlineChat:is_active()
    return self._active_request ~= nil
end

--- @return boolean
function InlineChat:is_prompt_open()
    return self._prompt ~= nil
        and vim.api.nvim_win_is_valid(self._prompt.prompt_winid)
end

--- @param selection agentic.Selection
--- @return boolean opened
function InlineChat:open(selection)
    if
        self._active_request ~= nil
        and self._active_request.phase ~= "completed"
        and self._active_request.phase ~= "failed"
    then
        Logger.notify(
            "An inline request is already running in this tab.",
            vim.log.levels.WARN
        )
        return false
    end

    self:clear()

    local source_winid = vim.api.nvim_get_current_win()
    local source_bufnr = vim.api.nvim_get_current_buf()
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local prompt_width = math.max(24, Config.inline.prompt_width)
    local win_width = vim.api.nvim_win_get_width(source_winid)
    local width = math.min(prompt_width, math.max(24, win_width - 6))
    local height = math.max(1, Config.inline.prompt_height)
    local footer = self:_build_prompt_footer()

    vim.bo[prompt_bufnr].buftype = "nofile"
    vim.bo[prompt_bufnr].bufhidden = "wipe"
    vim.bo[prompt_bufnr].buflisted = false
    vim.bo[prompt_bufnr].swapfile = false
    vim.bo[prompt_bufnr].modifiable = true
    vim.bo[prompt_bufnr].filetype = "AgenticInput"

    vim.api.nvim_buf_set_lines(prompt_bufnr, 0, -1, false, { "" })

    local ok, prompt_winid = pcall(vim.api.nvim_open_win, prompt_bufnr, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " Inline " .. format_range(selection) .. " ",
        title_pos = "left",
        footer = footer ~= "" and footer or nil,
        footer_pos = "right",
        zindex = 250,
    })

    if not ok then
        Logger.notify(
            "Failed to open inline prompt window.",
            vim.log.levels.ERROR
        )
        pcall(vim.api.nvim_buf_delete, prompt_bufnr, { force = true })
        return false
    end

    vim.wo[prompt_winid].wrap = true
    vim.wo[prompt_winid].linebreak = true
    vim.wo[prompt_winid].winhighlight = "FloatBorder:"
        .. Theme.HL_GROUPS.REVIEW_BANNER_ACCENT

    self._prompt = {
        prompt_bufnr = prompt_bufnr,
        prompt_winid = prompt_winid,
        selection = vim.deepcopy(selection),
        source_bufnr = source_bufnr,
        source_winid = source_winid,
    }

    self:_bind_prompt_keymaps()
    vim.cmd("startinsert")
    return true
end

function InlineChat:_bind_prompt_keymaps()
    local prompt = self._prompt
    if not prompt then
        return
    end

    local submit = function()
        self:_submit_prompt()
    end

    BufHelpers.keymap_set(prompt.prompt_bufnr, { "i", "n" }, "<CR>", submit, {
        desc = "Agentic: Submit inline prompt",
    })

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.submit,
        prompt.prompt_bufnr,
        submit,
        { desc = "Agentic: Submit inline prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.close,
        prompt.prompt_bufnr,
        function()
            self:_close_prompt(true)
        end,
        { desc = "Agentic: Close inline prompt" }
    )

    BufHelpers.keymap_set(prompt.prompt_bufnr, "n", "<Esc>", function()
        self:_close_prompt(true)
    end, { desc = "Agentic: Close inline prompt" })

    BufHelpers.multi_keymap_set(KEYMAP_HELP_KEY, prompt.prompt_bufnr, function()
        KeymapHelp.show_for_buffer(prompt.prompt_bufnr)
    end, { desc = "Agentic: Show available keymaps" })

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.change_mode,
        prompt.prompt_bufnr,
        function()
            self._on_change_mode()
        end,
        { desc = "Agentic: Inline mode selector" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.switch_model,
        prompt.prompt_bufnr,
        function()
            self._on_change_model()
        end,
        { desc = "Agentic: Inline model selector" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.switch_thought_level,
        prompt.prompt_bufnr,
        function()
            self._on_change_thought_level()
        end,
        { desc = "Agentic: Inline reasoning selector" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.switch_approval_preset,
        prompt.prompt_bufnr,
        function()
            self._on_change_approval_preset()
        end,
        { desc = "Agentic: Inline approval selector" }
    )
end

function InlineChat:_submit_prompt()
    local prompt = self._prompt
    if not prompt or not vim.api.nvim_buf_is_valid(prompt.prompt_bufnr) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(prompt.prompt_bufnr, 0, -1, false)
    local text = sanitize_text(table.concat(lines, "\n"))
    if text == "" then
        Logger.notify("Inline prompt is empty.", vim.log.levels.INFO)
        return
    end

    local accepted = self._on_submit({
        prompt = text,
        selection = vim.deepcopy(prompt.selection),
        source_bufnr = prompt.source_bufnr,
        source_winid = prompt.source_winid,
    })

    if accepted then
        self:_close_prompt(false)
    end
end

--- @param restore_focus boolean
function InlineChat:_close_prompt(restore_focus)
    local prompt = self._prompt
    if not prompt then
        return
    end

    self._prompt = nil

    if
        prompt.prompt_winid and vim.api.nvim_win_is_valid(prompt.prompt_winid)
    then
        pcall(vim.api.nvim_win_close, prompt.prompt_winid, true)
    elseif vim.api.nvim_buf_is_valid(prompt.prompt_bufnr) then
        pcall(vim.api.nvim_buf_delete, prompt.prompt_bufnr, { force = true })
    end

    if
        restore_focus
        and prompt.source_winid
        and vim.api.nvim_win_is_valid(prompt.source_winid)
    then
        vim.api.nvim_set_current_win(prompt.source_winid)
    end
end

--- @return string
function InlineChat:_build_prompt_footer()
    local parts = {}
    local submit_key = find_keymap(Config.keymaps.prompt.submit, "i") or "<CR>"

    if submit_key then
        parts[#parts + 1] = submit_key .. " submit"
    end

    parts[#parts + 1] = "? keymaps"

    return table.concat(parts, "  ")
end

--- @param bufnr integer
--- @param extmark_id integer
--- @return {start_row: integer, start_col: integer, end_row: integer, end_col: integer, invalid: boolean}|nil
function InlineChat:_get_thread_range(bufnr, extmark_id)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        NS_INLINE_THREADS,
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

    return normalize_range(bufnr, range)
end

--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer|nil
function InlineChat:_find_matching_thread_extmark(bufnr, selection)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local start_row, start_col, end_row, end_col =
        selection_to_extmark_range(bufnr, selection)

    local extmarks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        NS_INLINE_THREADS,
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

--- @param bufnr integer
--- @param selection agentic.Selection
--- @return integer
function InlineChat:_ensure_thread_extmark(bufnr, selection)
    local existing_extmark_id =
        self:_find_matching_thread_extmark(bufnr, selection)
    if existing_extmark_id ~= nil then
        return existing_extmark_id
    end

    local start_row, start_col, end_row, end_col =
        selection_to_extmark_range(bufnr, selection)

    return vim.api.nvim_buf_set_extmark(
        bufnr,
        NS_INLINE_THREADS,
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

--- @param bufnr integer
--- @param request agentic.ui.InlineChat.ActiveRequest
function InlineChat:_sync_thread_history(bufnr, request)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local store = ensure_thread_store(bufnr)
    local range = self:_get_thread_range(bufnr, request.range_extmark_id)
    local selection = build_selection_snapshot(request.selection, range)
    local thread_id = thread_store_key(request.range_extmark_id)
    local thread = store[thread_id]
    local timestamp = current_timestamp()

    if thread == nil then
        --- @type agentic.ui.InlineChat.ThreadState
        local new_thread = {
            extmark_id = request.range_extmark_id,
            source_bufnr = bufnr,
            selection = build_selection_snapshot(selection),
            turns = {},
            updated_at = timestamp,
        }
        thread = new_thread
        store[thread_id] = thread
    end

    thread.selection = build_selection_snapshot(selection)
    thread.updated_at = timestamp

    local turn = thread.turns[request.thread_turn_index]
    if turn == nil then
        turn = create_thread_turn(request, selection)
        thread.turns[request.thread_turn_index] = turn
    else
        turn.selection = build_selection_snapshot(selection)
        turn.prompt = request.prompt
        turn.phase = request.phase
        turn.status_text = request.status_text
        turn.thought_text = request.thought_text
        turn.message_text = request.message_text
        turn.tool_label = request.tool_label
        turn.updated_at = timestamp
    end

    vim.b[bufnr][THREAD_STORE_KEY] = store
end

--- @param request agentic.ui.InlineChat.ActiveRequest
--- @return agentic.Selection
function InlineChat:_get_tracked_selection(request)
    local range =
        self:_get_thread_range(request.source_bufnr, request.range_extmark_id)
    return build_selection_snapshot(request.selection, range)
end

--- @param request {prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer, phase?: "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed", status_text?: string}
function InlineChat:begin_request(request)
    self:_stop_close_timer()

    local range_extmark_id =
        self:_ensure_thread_extmark(request.source_bufnr, request.selection)
    local store = ensure_thread_store(request.source_bufnr)
    local thread = store[thread_store_key(range_extmark_id)]
    local thread_turn_index = thread and (#thread.turns + 1) or 1

    self._active_request = {
        source_bufnr = request.source_bufnr,
        source_winid = request.source_winid,
        selection = vim.deepcopy(request.selection),
        prompt = request.prompt,
        range_extmark_id = range_extmark_id,
        overlay_extmark_id = nil,
        thread_turn_index = thread_turn_index,
        phase = request.phase or "busy",
        status_text = request.status_text or "Starting inline request",
        thought_text = "",
        message_text = "",
        tool_label = nil,
        progress_id = nil,
        close_timer = nil,
    }

    self:_sync_thread_history(request.source_bufnr, self._active_request)
    self:_render_active_request()
    self:_update_progress()
end

function InlineChat:refresh()
    if self._active_request then
        self:_sync_thread_history(
            self._active_request.source_bufnr,
            self._active_request
        )
        self:_render_active_request()
    end
end

--- @param update agentic.acp.SessionUpdateMessage
function InlineChat:handle_session_update(update)
    local request = self._active_request
    if not request then
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
    else
        return
    end

    self:_sync_thread_history(request.source_bufnr, request)
    self:_render_active_request()
    self:_update_progress()
end

--- @param tool_call table
function InlineChat:handle_tool_call(tool_call)
    local request = self._active_request
    if not request then
        return
    end

    request.phase = "tool"
    request.tool_label = build_tool_label(tool_call)
    request.status_text = "Running " .. request.tool_label
    self:_sync_thread_history(request.source_bufnr, request)
    self:_render_active_request()
    self:_update_progress()
end

--- @param tool_call table
function InlineChat:handle_tool_call_update(tool_call)
    local request = self._active_request
    if not request then
        return
    end

    request.tool_label = build_tool_label(tool_call)

    if tool_call.status == "failed" then
        request.phase = "failed"
        request.status_text = "Tool failed: " .. request.tool_label
    elseif tool_call.status == "completed" then
        request.phase = "generating"
        request.status_text = "Completed " .. request.tool_label
    else
        request.phase = "tool"
        request.status_text = "Running " .. request.tool_label
    end

    self:_sync_thread_history(request.source_bufnr, request)
    self:_render_active_request()
    self:_update_progress()
end

function InlineChat:handle_permission_request()
    local request = self._active_request
    if not request then
        return
    end

    request.phase = "waiting"
    request.status_text = "Waiting for approval"
    self:_sync_thread_history(request.source_bufnr, request)
    self:_render_active_request()
    self:_update_progress()
end

--- @param response agentic.acp.PromptResponse|nil
--- @param err table|nil
function InlineChat:complete(response, err)
    local request = self._active_request
    if not request then
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

    self:_sync_thread_history(request.source_bufnr, request)
    self:_render_active_request()
    self:_update_progress(true)
    self:_schedule_close()
end

function InlineChat:_schedule_close()
    self:_stop_close_timer()

    local delay = Config.inline.result_ttl_ms
    if delay == nil or delay <= 0 then
        return
    end

    self._active_request.close_timer = vim.defer_fn(function()
        self:clear()
    end, delay)
end

function InlineChat:_stop_close_timer()
    local request = self._active_request
    if not request or not request.close_timer then
        return
    end

    pcall(function()
        request.close_timer:stop()
    end)
    pcall(function()
        request.close_timer:close()
    end)
    request.close_timer = nil
end

function InlineChat:_update_progress(is_terminal)
    local request = self._active_request
    if
        not request
        or not Config.inline.progress
        or not supports_progress_messages()
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

function InlineChat:_render_active_request()
    local request = self._active_request
    if not request or not vim.api.nvim_buf_is_valid(request.source_bufnr) then
        return
    end

    local selection = self:_get_tracked_selection(request)
    local range =
        self:_get_thread_range(request.source_bufnr, request.range_extmark_id)
    local line_count =
        math.max(1, vim.api.nvim_buf_line_count(request.source_bufnr))
    local anchor_line = math.max(
        0,
        math.min(
            line_count - 1,
            range and range.end_row or (selection.end_line - 1)
        )
    )
    local max_width = 72
    if
        request.source_winid and vim.api.nvim_win_is_valid(request.source_winid)
    then
        max_width =
            math.max(24, vim.api.nvim_win_get_width(request.source_winid) - 4)
    end

    local lines = self:_build_virtual_lines(request, selection, max_width)

    request.overlay_extmark_id = vim.api.nvim_buf_set_extmark(
        request.source_bufnr,
        NS_INLINE,
        anchor_line,
        0,
        {
            id = request.overlay_extmark_id,
            virt_lines = lines,
            virt_lines_above = false,
        }
    )
end

--- @param request agentic.ui.InlineChat.ActiveRequest
--- @param selection agentic.Selection
--- @param max_width integer
--- @return table[]
function InlineChat:_build_virtual_lines(request, selection, max_width)
    local config_context = self._get_config_context()
    local status_hl =
        Theme.get_spinner_hl_group(phase_to_spinner_state(request.phase))

    --- @type table[]
    local lines = {
        {
            faded_segment(
                "[Agentic Inline] ",
                Theme.HL_GROUPS.REVIEW_BANNER_ACCENT
            ),
            faded_segment(
                format_range(selection) .. " ",
                Theme.HL_GROUPS.REVIEW_BANNER
            ),
            faded_segment(request.status_text, status_hl),
        },
        {
            faded_segment("Prompt: ", Theme.HL_GROUPS.CARD_TITLE),
            faded_segment(
                truncate_text(request.prompt, max_width),
                Theme.HL_GROUPS.CARD_BODY
            ),
        },
    }

    if config_context and config_context ~= "" then
        lines[#lines + 1] = {
            faded_segment("Config: ", Theme.HL_GROUPS.CARD_TITLE),
            faded_segment(
                truncate_text(config_context, max_width),
                Theme.HL_GROUPS.CARD_DETAIL
            ),
        }
    end

    if request.tool_label and request.tool_label ~= "" then
        lines[#lines + 1] = {
            faded_segment("Tool: ", Theme.HL_GROUPS.CARD_TITLE),
            faded_segment(
                truncate_text(request.tool_label, max_width),
                Theme.HL_GROUPS.CARD_BODY
            ),
        }
    end

    if Config.inline.show_thoughts then
        local thought_lines = tail_lines(
            split_lines(request.thought_text),
            Config.inline.max_thought_lines
        )

        if #thought_lines > 0 then
            lines[#lines + 1] = {
                faded_segment("Thinking:", Theme.HL_GROUPS.THOUGHT_TEXT),
            }

            for _, line in ipairs(thought_lines) do
                lines[#lines + 1] = {
                    faded_segment(
                        "  " .. truncate_text(line, max_width),
                        Theme.HL_GROUPS.THOUGHT_TEXT
                    ),
                }
            end
        end
    end

    local response_lines = tail_lines(split_lines(request.message_text), 4)
    if #response_lines > 0 then
        lines[#lines + 1] = {
            faded_segment("Response:", Theme.HL_GROUPS.CARD_TITLE),
        }

        for _, line in ipairs(response_lines) do
            lines[#lines + 1] = {
                faded_segment(
                    "  " .. truncate_text(line, max_width),
                    Theme.HL_GROUPS.CARD_BODY
                ),
            }
        end
    end

    return lines
end

function InlineChat:clear()
    local request = self._active_request
    self:_close_prompt(true)
    self:_stop_close_timer()

    if
        request
        and request.progress_id
        and Config.inline.progress
        and supports_progress_messages()
    then
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
    end

    if
        request
        and request.overlay_extmark_id
        and vim.api.nvim_buf_is_valid(request.source_bufnr)
    then
        pcall(
            vim.api.nvim_buf_del_extmark,
            request.source_bufnr,
            NS_INLINE,
            request.overlay_extmark_id
        )
    end

    self._active_request = nil
end

function InlineChat:destroy()
    self:clear()
end

return InlineChat
