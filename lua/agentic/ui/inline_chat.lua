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
--- @field submission_id? integer
--- @field source_bufnr integer
--- @field source_winid integer
--- @field selection agentic.Selection
--- @field prompt string
--- @field config_context? string
--- @field range_extmark_id integer
--- @field thread_turn_index integer
--- @field phase "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed"
--- @field status_text string
--- @field thought_text string
--- @field message_text string
--- @field tool_label? string
--- @field overlay_hidden boolean
--- @field progress_id? integer

--- @class agentic.ui.InlineChat.ThreadTurn
--- @field selection agentic.Selection
--- @field prompt string
--- @field config_context? string
--- @field phase "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed"
--- @field status_text string
--- @field thought_text string
--- @field message_text string
--- @field tool_label? string
--- @field overlay_hidden boolean
--- @field created_at integer
--- @field updated_at integer

--- @class agentic.ui.InlineChat.ThreadState
--- @field extmark_id integer
--- @field source_bufnr integer
--- @field selection agentic.Selection
--- @field turns agentic.ui.InlineChat.ThreadTurn[]
--- @field updated_at integer

--- @alias agentic.ui.InlineChat.ThreadStore table<string, agentic.ui.InlineChat.ThreadState>

--- @class agentic.ui.InlineChat.ThreadRuntime
--- @field source_bufnr integer
--- @field source_winid integer
--- @field range_extmark_id integer
--- @field overlay_extmark_id? integer
--- @field close_timer? uv.uv_timer_t

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
--- @field _queued_requests table<integer, agentic.ui.InlineChat.ActiveRequest>
--- @field _thread_runtimes table<string, agentic.ui.InlineChat.ThreadRuntime>
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

--- @param phase string|nil
--- @return boolean
local function is_terminal_phase(phase)
    return phase == "completed" or phase == "failed"
end

--- @return boolean
local function supports_progress_messages()
    return vim.fn.has("nvim-0.12") == 1
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
--- @param extmark_id integer
--- @return string
local function thread_runtime_key(bufnr, extmark_id)
    return string.format("%d:%d", bufnr, extmark_id)
end

--- @param row integer
--- @param col integer
--- @param other_row integer
--- @param other_col integer
--- @return boolean
local function position_lte(row, col, other_row, other_col)
    if row ~= other_row then
        return row < other_row
    end

    return col <= other_col
end

--- @param first {start_row: integer, start_col: integer, end_row: integer, end_col: integer}
--- @param second {start_row: integer, start_col: integer, end_row: integer, end_col: integer}
--- @return boolean
local function ranges_overlap(first, second)
    if
        position_lte(
            first.end_row,
            first.end_col,
            second.start_row,
            second.start_col
        )
    then
        return false
    end

    if
        position_lte(
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
        if selection.start_col ~= nil or selection.end_col ~= nil then
            snapshot.start_col = range.start_col + 1
            if range.end_col >= 0 then
                snapshot.end_col = range.end_col
            end
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
        config_context = request.config_context,
        phase = request.phase,
        status_text = request.status_text,
        thought_text = request.thought_text,
        message_text = request.message_text,
        tool_label = request.tool_label,
        overlay_hidden = request.overlay_hidden,
        created_at = timestamp,
        updated_at = timestamp,
    }

    return turn
end

--- @param text string|nil
--- @return string|nil
local function latest_line(text)
    local lines = split_lines(text)
    return lines[#lines]
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
local function build_queue_status(position, waiting_for_session)
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
        _queued_requests = {},
        _thread_runtimes = {},
    }, self)

    return instance
end

--- @return boolean
function InlineChat:is_active()
    return self._active_request ~= nil
        and not is_terminal_phase(self._active_request.phase)
end

--- @return boolean
function InlineChat:is_prompt_open()
    return self._prompt ~= nil
        and vim.api.nvim_win_is_valid(self._prompt.prompt_winid)
end

--- @param selection agentic.Selection
--- @return boolean opened
function InlineChat:open(selection)
    self:_close_prompt(true)

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

--- @param request {submission_id?: integer|nil, prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer, phase?: "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed", status_text?: string}
--- @return agentic.ui.InlineChat.ActiveRequest
--- @return string
function InlineChat:_build_request_state(request)
    local range_extmark_id =
        self:_ensure_thread_extmark(request.source_bufnr, request.selection)
    local runtime_id, runtime = self:_ensure_thread_runtime(
        request.source_bufnr,
        request.source_winid,
        range_extmark_id
    )
    self:_stop_thread_close_timer(runtime)

    local store = ensure_thread_store(request.source_bufnr)
    local thread = store[thread_store_key(range_extmark_id)]
    local thread_turn_index = thread and (#thread.turns + 1) or 1

    --- @type agentic.ui.InlineChat.ActiveRequest
    local request_state = {
        submission_id = request.submission_id,
        source_bufnr = request.source_bufnr,
        source_winid = request.source_winid,
        selection = vim.deepcopy(request.selection),
        prompt = request.prompt,
        config_context = self._get_config_context(),
        range_extmark_id = range_extmark_id,
        thread_turn_index = thread_turn_index,
        phase = request.phase or "busy",
        status_text = request.status_text or "Starting inline request",
        thought_text = "",
        message_text = "",
        tool_label = nil,
        overlay_hidden = false,
        progress_id = nil,
    }

    return request_state, runtime_id
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

    -- Exit insert mode and close the prompt after the submit handler accepts it.
    if accepted then
        if vim.fn.mode():sub(1, 1) == "i" then
            vim.cmd.stopinsert()
        end
        self:_close_prompt(true)
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
    local submit_key = BufHelpers.find_keymap(Config.keymaps.prompt.submit, "i")
        or "<CR>"

    if submit_key then
        parts[#parts + 1] = submit_key .. " submit"
    end

    parts[#parts + 1] = "? keymaps"

    return table.concat(parts, "  ")
end

--- @param bufnr integer
--- @param source_winid integer
--- @param range_extmark_id integer
--- @return string runtime_id
--- @return agentic.ui.InlineChat.ThreadRuntime runtime
function InlineChat:_ensure_thread_runtime(
    bufnr,
    source_winid,
    range_extmark_id
)
    local runtime_id = thread_runtime_key(bufnr, range_extmark_id)
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

--- @param request agentic.ui.InlineChat.ActiveRequest
--- @return string
function InlineChat:_get_request_runtime_key(request)
    return thread_runtime_key(request.source_bufnr, request.range_extmark_id)
end

--- @param runtime agentic.ui.InlineChat.ThreadRuntime
function InlineChat:_stop_thread_close_timer(runtime)
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

--- @param request agentic.ui.InlineChat.ActiveRequest|nil
function InlineChat:_dismiss_progress(request)
    if
        not request
        or not request.progress_id
        or not Config.inline.progress
        or not supports_progress_messages()
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

--- @param runtime_id string
function InlineChat:_clear_thread_overlay(runtime_id)
    local runtime = self._thread_runtimes[runtime_id]
    if not runtime or not runtime.overlay_extmark_id then
        return
    end

    if vim.api.nvim_buf_is_valid(runtime.source_bufnr) then
        pcall(
            vim.api.nvim_buf_del_extmark,
            runtime.source_bufnr,
            NS_INLINE,
            runtime.overlay_extmark_id
        )
    end

    runtime.overlay_extmark_id = nil
end

--- @param runtime_id string
function InlineChat:_clear_thread_runtime(runtime_id)
    local runtime = self._thread_runtimes[runtime_id]
    if not runtime then
        return
    end

    self:_stop_thread_close_timer(runtime)
    self:_clear_thread_overlay(runtime_id)

    local active_request = self._active_request
    if
        active_request
        and is_terminal_phase(active_request.phase)
        and self:_get_request_runtime_key(active_request) == runtime_id
    then
        self:_dismiss_progress(active_request)
        self._active_request = nil
    end

    for submission_id, queued_request in pairs(self._queued_requests) do
        if self:_get_request_runtime_key(queued_request) == runtime_id then
            self._queued_requests[submission_id] = nil
        end
    end

    self._thread_runtimes[runtime_id] = nil
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
        turn.config_context = request.config_context
        turn.phase = request.phase
        turn.status_text = request.status_text
        turn.thought_text = request.thought_text
        turn.message_text = request.message_text
        turn.tool_label = request.tool_label
        turn.overlay_hidden = request.overlay_hidden
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

--- @param bufnr integer
--- @param range_extmark_id integer
--- @param removed_turn_index integer
function InlineChat:_shift_thread_turn_indices(
    bufnr,
    range_extmark_id,
    removed_turn_index
)
    local active_request = self._active_request
    if
        active_request
        and active_request.source_bufnr == bufnr
        and active_request.range_extmark_id == range_extmark_id
        and active_request.thread_turn_index > removed_turn_index
    then
        active_request.thread_turn_index = active_request.thread_turn_index - 1
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

--- @param bufnr integer
--- @param range_extmark_id integer
function InlineChat:_drop_thread(bufnr, range_extmark_id)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local store = ensure_thread_store(bufnr)
    store[thread_store_key(range_extmark_id)] = nil
    vim.b[bufnr][THREAD_STORE_KEY] = store

    pcall(
        vim.api.nvim_buf_del_extmark,
        bufnr,
        NS_INLINE_THREADS,
        range_extmark_id
    )

    self:_clear_thread_runtime(thread_runtime_key(bufnr, range_extmark_id))
end

--- @param bufnr integer
--- @param range_extmark_id integer
--- @param thread_turn_index integer
function InlineChat:_remove_thread_turn(
    bufnr,
    range_extmark_id,
    thread_turn_index
)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local store = ensure_thread_store(bufnr)
    local thread = store[thread_store_key(range_extmark_id)]
    if not thread then
        return
    end

    if thread_turn_index < 1 or thread_turn_index > #thread.turns then
        return
    end

    table.remove(thread.turns, thread_turn_index)
    self:_shift_thread_turn_indices(bufnr, range_extmark_id, thread_turn_index)

    if #thread.turns == 0 then
        self:_drop_thread(bufnr, range_extmark_id)
        return
    end

    thread.updated_at = current_timestamp()
    store[thread_store_key(range_extmark_id)] = thread
    vim.b[bufnr][THREAD_STORE_KEY] = store
    self:_render_thread(thread_runtime_key(bufnr, range_extmark_id))
end

--- @param request {submission_id: integer, prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}
function InlineChat:queue_request(request)
    local queued_request = self._queued_requests[request.submission_id]
    local runtime_id = nil

    if queued_request == nil then
        queued_request, runtime_id = self:_build_request_state({
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
        queued_request.selection = vim.deepcopy(request.selection)
        queued_request.prompt = request.prompt
        queued_request.config_context = self._get_config_context()
        queued_request.overlay_hidden = false
    end

    queued_request.phase = "busy"
    queued_request.status_text = "Queued next"
    self:_sync_thread_history(queued_request.source_bufnr, queued_request)
    self:_render_thread(
        runtime_id or self:_get_request_runtime_key(queued_request)
    )
end

--- @param queue_items agentic.SessionManager.QueuedSubmission[]
--- @param opts {waiting_for_session?: boolean|nil, interrupt_submission?: agentic.SessionManager.QueuedSubmission|nil}|nil
function InlineChat:sync_queued_requests(queue_items, opts)
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
            queued_request.status_text =
                build_queue_status(position, opts.waiting_for_session == true)
            queued_request.config_context = self._get_config_context()
            self:_sync_thread_history(
                queued_request.source_bufnr,
                queued_request
            )
            self:_render_thread(self:_get_request_runtime_key(queued_request))
        end
    end
end

--- @param source_bufnr integer
--- @param selection agentic.Selection
--- @return integer|nil
function InlineChat:find_overlapping_queued_submission(source_bufnr, selection)
    local start_row, start_col, end_row, end_col =
        selection_to_extmark_range(source_bufnr, selection)
    local target_range = normalize_range(source_bufnr, {
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
            local queued_range = self:_get_thread_range(
                queued_request.source_bufnr,
                queued_request.range_extmark_id
            )

            if queued_range == nil then
                local queued_start_row, queued_start_col, queued_end_row, queued_end_col =
                    selection_to_extmark_range(
                        queued_request.source_bufnr,
                        queued_request.selection
                    )
                queued_range = normalize_range(queued_request.source_bufnr, {
                    start_row = queued_start_row,
                    start_col = queued_start_col,
                    end_row = queued_end_row,
                    end_col = queued_end_col,
                })
            end

            if queued_range and ranges_overlap(target_range, queued_range) then
                return submission_id
            end
        end
    end

    return nil
end

--- @param submission_id integer
--- @return boolean
function InlineChat:remove_queued_submission(submission_id)
    local queued_request = self._queued_requests[submission_id]
    if queued_request == nil then
        return false
    end

    self._queued_requests[submission_id] = nil
    self:_remove_thread_turn(
        queued_request.source_bufnr,
        queued_request.range_extmark_id,
        queued_request.thread_turn_index
    )
    return true
end

--- @param request {submission_id?: integer|nil, prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer, phase?: "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed", status_text?: string}
function InlineChat:begin_request(request)
    local previous_request = self._active_request
    if previous_request and is_terminal_phase(previous_request.phase) then
        self:_dismiss_progress(previous_request)
    end

    local queued_request = request.submission_id ~= nil
            and self._queued_requests[request.submission_id]
        or nil
    local runtime_id = nil

    if queued_request ~= nil then
        self._queued_requests[request.submission_id] = nil
        queued_request.source_bufnr = request.source_bufnr
        queued_request.source_winid = request.source_winid
        queued_request.selection = vim.deepcopy(request.selection)
        queued_request.prompt = request.prompt
        queued_request.config_context = self._get_config_context()
        queued_request.phase = request.phase or "busy"
        queued_request.status_text = request.status_text
            or "Starting inline request"
        queued_request.tool_label = nil
        queued_request.overlay_hidden = false
        runtime_id = self:_get_request_runtime_key(queued_request)

        local _, runtime = self:_ensure_thread_runtime(
            queued_request.source_bufnr,
            queued_request.source_winid,
            queued_request.range_extmark_id
        )
        self:_stop_thread_close_timer(runtime)
        self._active_request = queued_request
    else
        self._active_request, runtime_id = self:_build_request_state({
            submission_id = request.submission_id,
            prompt = request.prompt,
            selection = request.selection,
            source_bufnr = request.source_bufnr,
            source_winid = request.source_winid,
            phase = request.phase,
            status_text = request.status_text,
        })
    end

    self:_sync_thread_history(request.source_bufnr, self._active_request)
    self:_render_thread(runtime_id)
    self:_update_progress(self._active_request)
end

function InlineChat:refresh()
    if self._active_request then
        self:_sync_thread_history(
            self._active_request.source_bufnr,
            self._active_request
        )
    end

    for _, queued_request in pairs(self._queued_requests) do
        self:_sync_thread_history(queued_request.source_bufnr, queued_request)
    end

    for runtime_id, _ in pairs(self._thread_runtimes) do
        self:_render_thread(runtime_id)
    end
end

--- @param update agentic.acp.SessionUpdateMessage
function InlineChat:handle_session_update(update)
    local request = self._active_request
    if not request or is_terminal_phase(request.phase) then
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
    self:_render_thread(self:_get_request_runtime_key(request))
    self:_update_progress(request)
end

--- @param tool_call table
function InlineChat:handle_tool_call(tool_call)
    local request = self._active_request
    if not request or is_terminal_phase(request.phase) then
        return
    end

    request.phase = "tool"
    request.tool_label = build_tool_label(tool_call)
    request.status_text = "Running " .. request.tool_label
    self:_sync_thread_history(request.source_bufnr, request)
    self:_render_thread(self:_get_request_runtime_key(request))
    self:_update_progress(request)
end

--- @param tool_call table
function InlineChat:handle_tool_call_update(tool_call)
    local request = self._active_request
    if not request or is_terminal_phase(request.phase) then
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
    self:_render_thread(self:_get_request_runtime_key(request))
    self:_update_progress(request)
end

function InlineChat:handle_permission_request()
    local request = self._active_request
    if not request or is_terminal_phase(request.phase) then
        return
    end

    request.phase = "waiting"
    request.status_text = "Waiting for approval"
    self:_sync_thread_history(request.source_bufnr, request)
    self:_render_thread(self:_get_request_runtime_key(request))
    self:_update_progress(request)
end

function InlineChat:handle_applied_edit()
    local request = self._active_request
    if
        not request
        or is_terminal_phase(request.phase)
        or request.overlay_hidden
    then
        return
    end

    request.overlay_hidden = true
    self:_sync_thread_history(request.source_bufnr, request)
    self:_clear_thread_overlay(self:_get_request_runtime_key(request))
end

--- @param response agentic.acp.PromptResponse|nil
--- @param err table|nil
function InlineChat:complete(response, err)
    local request = self._active_request
    if not request or is_terminal_phase(request.phase) then
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
    self:_render_thread(self:_get_request_runtime_key(request))
    self:_update_progress(request, true)
    self:_schedule_close(request)
end

--- @param request agentic.ui.InlineChat.ActiveRequest
function InlineChat:_schedule_close(request)
    local delay = Config.inline.result_ttl_ms
    if delay == nil or delay <= 0 then
        return
    end

    local runtime_id, runtime = self:_ensure_thread_runtime(
        request.source_bufnr,
        request.source_winid,
        request.range_extmark_id
    )
    self:_stop_thread_close_timer(runtime)
    runtime.close_timer = vim.defer_fn(function()
        self:_clear_thread_runtime(runtime_id)
    end, delay)
end

--- @param request agentic.ui.InlineChat.ActiveRequest|nil
--- @param is_terminal boolean|nil
function InlineChat:_update_progress(request, is_terminal)
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

--- @param runtime agentic.ui.InlineChat.ThreadRuntime
--- @return integer
function InlineChat:_get_max_width(runtime)
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

--- @param runtime_id string
function InlineChat:_render_thread(runtime_id)
    local runtime = self._thread_runtimes[runtime_id]
    if not runtime or not vim.api.nvim_buf_is_valid(runtime.source_bufnr) then
        return
    end

    local store = ensure_thread_store(runtime.source_bufnr)
    local thread = store[thread_store_key(runtime.range_extmark_id)]
    local turn = thread and thread.turns[#thread.turns] or nil

    if not turn then
        self:_clear_thread_overlay(runtime_id)
        return
    end

    if turn.overlay_hidden then
        self:_clear_thread_overlay(runtime_id)
        return
    end

    local range =
        self:_get_thread_range(runtime.source_bufnr, runtime.range_extmark_id)
    if not range or range.invalid then
        self:_clear_thread_overlay(runtime_id)
        return
    end

    local selection = build_selection_snapshot(turn.selection, range)
    local line_count =
        math.max(1, vim.api.nvim_buf_line_count(runtime.source_bufnr))
    local anchor_line = math.max(
        0,
        math.min(
            line_count - 1,
            range and range.end_row or (selection.end_line - 1)
        )
    )
    local max_width = self:_get_max_width(runtime)

    local lines = self:_build_virtual_lines(turn, selection, max_width)

    runtime.overlay_extmark_id = vim.api.nvim_buf_set_extmark(
        runtime.source_bufnr,
        NS_INLINE,
        anchor_line,
        0,
        {
            id = runtime.overlay_extmark_id,
            virt_lines = lines,
            virt_lines_above = false,
        }
    )
end

--- @param label string
--- @param text string
--- @param label_hl string|string[]|nil
--- @param text_hl string|string[]|nil
--- @param max_width integer
--- @return table
function InlineChat:_build_compact_line(
    label,
    text,
    label_hl,
    text_hl,
    max_width
)
    local label_text = label .. ": "
    local available_width =
        math.max(12, max_width - vim.fn.strdisplaywidth(label_text) - 4)

    return {
        faded_segment("  ", Theme.HL_GROUPS.REVIEW_BANNER),
        faded_segment(label_text, label_hl),
        faded_segment(truncate_text(text, available_width), text_hl),
    }
end

--- @param entry agentic.ui.InlineChat.ActiveRequest|agentic.ui.InlineChat.ThreadTurn
--- @param selection agentic.Selection
--- @param max_width integer
--- @return table[]
function InlineChat:_build_virtual_lines(entry, selection, max_width)
    local config_context = entry.config_context
    local status_hl =
        Theme.get_spinner_hl_group(phase_to_spinner_state(entry.phase))
    local latest_thought = Config.inline.show_thoughts
            and latest_line(entry.thought_text)
        or nil
    local latest_response = latest_line(entry.message_text)

    --- @type table[]
    local lines = {
        {
            faded_segment("  ", Theme.HL_GROUPS.REVIEW_BANNER),
            faded_segment(
                "[Agentic Inline] ",
                Theme.HL_GROUPS.REVIEW_BANNER_ACCENT
            ),
            faded_segment(
                format_range(selection) .. " ",
                Theme.HL_GROUPS.REVIEW_BANNER
            ),
            faded_segment(entry.status_text, status_hl),
        },
    }

    local detail_line = nil

    if entry.phase == "thinking" and latest_thought then
        detail_line = self:_build_compact_line(
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
        detail_line = self:_build_compact_line(
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
        detail_line = self:_build_compact_line(
            is_terminal_phase(entry.phase) and "Result" or "Response",
            latest_response,
            entry.phase == "failed" and Theme.HL_GROUPS.STATUS_FAILED
                or Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            result_hl,
            max_width
        )
    elseif latest_thought then
        detail_line = self:_build_compact_line(
            "Thinking",
            latest_thought,
            Theme.HL_GROUPS.THOUGHT_TEXT,
            Theme.HL_GROUPS.THOUGHT_TEXT,
            max_width
        )
    elseif entry.tool_label and entry.tool_label ~= "" then
        detail_line = self:_build_compact_line(
            "Tool",
            entry.tool_label,
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.ACTIVITY_TEXT,
            max_width
        )
    elseif entry.prompt ~= "" then
        detail_line = self:_build_compact_line(
            "Prompt",
            entry.prompt,
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.REVIEW_BANNER,
            max_width
        )
    elseif config_context and config_context ~= "" then
        detail_line = self:_build_compact_line(
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

function InlineChat:clear()
    self:_close_prompt(true)

    self:_dismiss_progress(self._active_request)

    local runtime_ids = vim.tbl_keys(self._thread_runtimes)
    for _, runtime_id in ipairs(runtime_ids) do
        self:_clear_thread_runtime(runtime_id)
    end

    self._active_request = nil
    self._queued_requests = {}
end

function InlineChat:destroy()
    self:clear()
end

return InlineChat
