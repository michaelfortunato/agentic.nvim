local ToolCallDiff = require("agentic.ui.tool_call_diff")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_THOUGHT = vim.api.nvim_create_namespace("agentic_thought_chunks")
local NS_TRANSCRIPT_META =
    vim.api.nvim_create_namespace("agentic_transcript_meta")

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification"|"span" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)
--- @field display_prefix_len? integer Byte length of any diff marker prefix rendered before the content
--- @field start_col? integer
--- @field end_col? integer
--- @field hl_group? string

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean TODO: check if it's still necessary to replace all occurrences or the agents send multiple requests

--- @class agentic.ui.MessageWriter.ToolCallBlock
--- @field tool_call_id string
--- @field kind? agentic.acp.ToolKind
--- @field argument? string
--- @field file_path? string
--- @field extmark_id? integer Range extmark spanning the block
--- @field status? agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field collapsed? boolean

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _last_message_type? string
--- @field _should_auto_scroll_fn? fun(): boolean
--- @field _scroll_to_bottom_fn? fun()
--- @field _scroll_timer? uv.uv_timer_t
--- @field _scroll_scheduled? boolean
--- @field _content_changed_listeners table<integer, fun()>
--- @field _next_content_listener_id integer
--- @field _active_stream_block? {type: string, start_row: integer}
--- @field _current_turn_id integer
--- @field _active_turn_diff_cards table<string, string>
--- @field _turn_has_agent_header boolean
local MessageWriter = {}
MessageWriter.__index = MessageWriter

local DEFAULT_SCROLL_DEBOUNCE_MS = 150
local MAX_DIFF_CARD_HUNKS = 2
local MAX_DIFF_CARD_CHANGES = 4
local MAX_TOOL_PREVIEW_LINES = 2
local MAX_TOOL_PREVIEW_WIDTH = 96
local CARD_DETAIL_PREFIX = "  "
local CARD_NESTED_PREFIX = "    "

local DIFF_TOOL_KINDS = {
    edit = true,
    create = true,
    write = true,
}

local DIFF_ACTION_LABELS = {
    edit = "Edited",
    create = "Created",
    write = "Wrote",
}

local TOOL_ACTION_LABELS = {
    read = "Read",
    search = "Search",
    execute = "Run",
    fetch = "Fetch",
    think = "Think",
    delete = "Delete",
    move = "Move",
    switch_mode = "Switch Mode",
    create = "Create",
    write = "Write",
    edit = "Edit",
    WebSearch = "Search Web",
    SlashCommand = "Slash Command",
    SubAgent = "Sub-Agent",
    Skill = "Use Skill",
    other = "Tool",
}

local OUTPUT_SUMMARY_LABELS = {
    search = "result line",
    fetch = "result line",
    WebSearch = "result line",
    execute = "output line",
    SlashCommand = "output line",
    SubAgent = "update line",
    Skill = "update line",
    think = "thought line",
    other = "line",
}

local META_LINE_PATTERNS = {
    "^Agentic · ",
    "^Session · ",
    "^Started · ",
    "^User · ",
    "^Review · ",
    "^Agent · ",
    "^Files$",
    "^Code$",
    "^Diagnostics$",
    "^Turn complete · ",
    "^Stopped · ",
    "^Agent error · ",
}

local should_default_collapse
local is_diff_group_kind
local is_diff_group_candidate
local build_turn_diff_group_key
local aggregate_tool_statuses

--- @param line string
--- @return boolean
local function is_meta_line(line)
    if not line or line == "" then
        return false
    end

    for _, pattern in ipairs(META_LINE_PATTERNS) do
        if line:match(pattern) then
            return true
        end
    end

    return false
end

--- @param line string
--- @return boolean
local function is_reference_line(line)
    return line ~= nil and line:match("^  @") ~= nil
end

--- @param line string
--- @return integer|nil
local function get_meta_prefix_end_col(line)
    if not line or line == "" then
        return nil
    end

    local _, separator_end = line:find(" · ", 1, true)
    if separator_end then
        return separator_end
    end

    if line == "Files" or line == "Code" or line == "Diagnostics" then
        return #line
    end

    return nil
end

--- @param label string
--- @param value string
--- @return string
local function build_meta_line(label, value)
    return string.format("%s · %s", label, value)
end

--- @class agentic.ui.MessageWriter.Opts
--- @field should_auto_scroll? fun(): boolean
--- @field scroll_to_bottom? fun()

--- @param bufnr integer
--- @param opts agentic.ui.MessageWriter.Opts|nil
--- @return agentic.ui.MessageWriter
function MessageWriter:new(bufnr, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    opts = opts or {}

    local instance = setmetatable({
        bufnr = bufnr,
        tool_call_blocks = {},
        _last_message_type = nil,
        _should_auto_scroll_fn = opts.should_auto_scroll,
        _scroll_to_bottom_fn = opts.scroll_to_bottom,
        _scroll_timer = nil,
        _scroll_scheduled = false,
        _content_changed_listeners = {},
        _next_content_listener_id = 0,
        _active_stream_block = nil,
        _current_turn_id = 0,
        _active_turn_diff_cards = {},
        _turn_has_agent_header = false,
    }, self)

    return instance
end

function MessageWriter:begin_turn()
    self._current_turn_id = self._current_turn_id + 1
    self._active_turn_diff_cards = {}
    self._turn_has_agent_header = false
end

function MessageWriter:reset()
    self.tool_call_blocks = {}
    self._active_stream_block = nil
    self._last_message_type = nil
    self._current_turn_id = 0
    self._active_turn_diff_cards = {}
    self._turn_has_agent_header = false
end

--- @param callback fun()
--- @return integer
function MessageWriter:add_content_changed_listener(callback)
    self._next_content_listener_id = self._next_content_listener_id + 1
    self._content_changed_listeners[self._next_content_listener_id] = callback
    return self._next_content_listener_id
end

--- @param listener_id integer|nil
function MessageWriter:remove_content_changed_listener(listener_id)
    if listener_id == nil then
        return
    end

    self._content_changed_listeners[listener_id] = nil
end

function MessageWriter:_notify_content_changed()
    for _, callback in pairs(self._content_changed_listeners) do
        callback()
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string|nil
function MessageWriter:_get_active_diff_group_id(tool_call_block)
    if not is_diff_group_candidate(tool_call_block) then
        return nil
    end

    local group_key =
        build_turn_diff_group_key(self._current_turn_id, tool_call_block.file_path)
    return self._active_turn_diff_cards[group_key]
end

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_merge_diff_source(tracker, tool_call_block)
    tracker.turn_id = tracker.turn_id or self._current_turn_id
    tracker.group_key = tracker.group_key
        or build_turn_diff_group_key(tracker.turn_id, tracker.file_path)
    tracker._diff_sources = tracker._diff_sources or {}
    tracker._diff_source_order = tracker._diff_source_order or {}

    local source_id = tool_call_block.tool_call_id
    local source = tracker._diff_sources[source_id]
    if not source then
        source = { tool_call_id = source_id }
        tracker._diff_sources[source_id] = source
        tracker._diff_source_order[#tracker._diff_source_order + 1] = source_id
    end

    local merged = vim.tbl_deep_extend("force", source, tool_call_block)
    merged.group_key = nil
    merged._diff_sources = nil
    merged._diff_source_order = nil
    tracker._diff_sources[source_id] = merged
    self.tool_call_blocks[source_id] = tracker

    local statuses = {}
    for _, ordered_id in ipairs(tracker._diff_source_order) do
        local current = tracker._diff_sources[ordered_id]
        if current and current.status then
            statuses[#statuses + 1] = current.status
        end
    end

    tracker.file_path = tool_call_block.file_path or tracker.file_path
    tracker.kind = tool_call_block.kind or tracker.kind
    tracker.argument = tool_call_block.argument or tracker.argument
    tracker.status = aggregate_tool_statuses(statuses) or tool_call_block.status
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_initialize_diff_group(tool_call_block)
    tool_call_block.turn_id = self._current_turn_id
    tool_call_block.group_key = build_turn_diff_group_key(
        self._current_turn_id,
        tool_call_block.file_path
    )
    tool_call_block._diff_sources = {}
    tool_call_block._diff_source_order = {}

    self._active_turn_diff_cards[tool_call_block.group_key] =
        tool_call_block.tool_call_id
    self:_merge_diff_source(tool_call_block, tool_call_block)

    return tool_call_block
end

--- Wraps BufHelpers.with_modifiable and fires _notify_content_changed after.
--- The callback may return false to suppress the notification (e.g. on early-return without edits).
--- with_modifiable returns false for invalid buffers, which also suppresses notification.
--- @param fn fun(bufnr: integer): boolean|nil
function MessageWriter:_with_modifiable_and_notify_change(fn)
    local result = BufHelpers.with_modifiable(self.bufnr, fn)
    if result ~= false then
        self:_notify_content_changed()
    end
end

function MessageWriter:_reset_stream_block()
    self._last_message_type = nil
    self._active_stream_block = nil
end

--- @return integer start_row
function MessageWriter:_ensure_block_gap()
    if BufHelpers.is_buffer_empty(self.bufnr) then
        return 0
    end

    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local trailing_blank_count = 0

    while trailing_blank_count < line_count do
        local line_index = line_count - trailing_blank_count - 1
        local line = vim.api.nvim_buf_get_lines(
            self.bufnr,
            line_index,
            line_index + 1,
            false
        )[1]

        if line ~= "" then
            break
        end

        trailing_blank_count = trailing_blank_count + 1
    end

    if trailing_blank_count == 0 then
        self:_append_lines({ "" })
    elseif trailing_blank_count > 1 then
        vim.api.nvim_buf_set_lines(
            self.bufnr,
            line_count - trailing_blank_count + 1,
            line_count,
            false,
            {}
        )
    end

    return vim.api.nvim_buf_line_count(self.bufnr)
end

--- @param start_row integer
--- @param end_row integer
function MessageWriter:_apply_thought_block_highlights(start_row, end_row)
    if start_row > end_row then
        return
    end

    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_THOUGHT,
        start_row,
        end_row + 1
    )

    for line_idx = start_row, end_row do
        local line = vim.api.nvim_buf_get_lines(
            self.bufnr,
            line_idx,
            line_idx + 1,
            false
        )[1]

        if line and #line > 0 then
            vim.api.nvim_buf_set_extmark(self.bufnr, NS_THOUGHT, line_idx, 0, {
                end_col = #line,
                hl_group = "Comment",
            })
        end
    end
end

--- @param start_row integer
--- @param lines string[]
function MessageWriter:_apply_transcript_meta_highlights(start_row, lines)
    if not lines or #lines == 0 then
        return
    end

    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_TRANSCRIPT_META,
        start_row,
        start_row + #lines
    )

    for index, line in ipairs(lines) do
        local line_idx = start_row + index - 1
        if is_meta_line(line) then
            local end_col = get_meta_prefix_end_col(line) or #line
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                NS_TRANSCRIPT_META,
                line_idx,
                0,
                {
                    end_col = end_col,
                    hl_group = "Comment",
                }
            )
        elseif is_reference_line(line) then
            vim.api.nvim_buf_set_extmark(
                self.bufnr,
                NS_TRANSCRIPT_META,
                line_idx,
                2,
                {
                    end_col = #line,
                    hl_group = "Directory",
                }
            )
        end
    end
end

--- @param update agentic.acp.SessionUpdateMessage
--- @param lines string[]
--- @return string[], integer
function MessageWriter:_prepend_agent_header_if_needed(update, lines)
    if not update.is_agent_reply or self._turn_has_agent_header then
        return lines, 0
    end

    local provider_name = update.provider_name or "Unknown provider"
    local prefixed_lines = { build_meta_line("Agent", provider_name) }
    vim.list_extend(prefixed_lines, lines)
    self._turn_has_agent_header = true

    return prefixed_lines, 1
end

--- Writes a full message to the chat buffer.
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    local text = update.content
        and update.content.type == "text"
        and update.content.text

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })
    lines = self:_prepend_agent_header_if_needed(update, lines)

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        self:_reset_stream_block()
        local start_row = self:_ensure_block_gap()
        self:_append_lines(lines)
        self:_apply_transcript_meta_highlights(start_row, lines)
    end)
end

--- Appends message chunks to the last line and column in the chat buffer
--- Some ACP providers stream chunks instead of full messages
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message_chunk(update)
    local text = update.content
        and update.content.type == "text"
        and update.content.text

    if not text or text == "" then
        return
    end

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local lines_to_write = vim.split(text, "\n", { plain = true })
        local starts_new_block = self._active_stream_block == nil
            or self._active_stream_block.type ~= update.sessionUpdate

        if starts_new_block then
            local header_count = 0
            lines_to_write, header_count =
                self:_prepend_agent_header_if_needed(update, lines_to_write)
            local start_row = self:_ensure_block_gap()
            self:_append_lines(lines_to_write)
            self:_apply_transcript_meta_highlights(start_row, lines_to_write)
            self._active_stream_block = {
                type = update.sessionUpdate,
                start_row = start_row + header_count,
            }
        else
            local last_line = vim.api.nvim_buf_line_count(bufnr) - 1
            local current_line = vim.api.nvim_buf_get_lines(
                bufnr,
                last_line,
                last_line + 1,
                false
            )[1] or ""
            local start_col = #current_line

            local success, err = pcall(
                vim.api.nvim_buf_set_text,
                bufnr,
                last_line,
                start_col,
                last_line,
                start_col,
                lines_to_write
            )

            if not success then
                Logger.debug(
                    "Failed to set text in buffer",
                    err,
                    lines_to_write
                )
            end
        end

        if
            update.sessionUpdate == "agent_thought_chunk"
            and self._active_stream_block
        then
            self:_apply_thought_block_highlights(
                self._active_stream_block.start_row,
                vim.api.nvim_buf_line_count(bufnr) - 1
            )
        end
    end)

    self._last_message_type = update.sessionUpdate
end

--- @param lines string[]
--- @return nil
function MessageWriter:_append_lines(lines)
    local start_line = BufHelpers.is_buffer_empty(self.bufnr) and 0 or -1

    local success, err = pcall(
        vim.api.nvim_buf_set_lines,
        self.bufnr,
        start_line,
        -1,
        false,
        lines
    )

    if not success then
        Logger.debug("Failed to append lines to buffer", err, lines)
    end
end

--- @param bufnr integer
--- @return boolean
function MessageWriter:_check_auto_scroll(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return true
    end
    local winid = wins[1]
    local threshold = Config.auto_scroll and Config.auto_scroll.threshold

    if threshold == nil or threshold <= 0 then
        return false
    end

    local last_visible_line = vim.api.nvim_win_call(winid, function()
        return vim.fn.line("w$")
    end)
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local distance_from_bottom = total_lines - last_visible_line

    return distance_from_bottom <= threshold
end

--- @param bufnr integer
--- @return boolean
function MessageWriter:_should_auto_scroll_now(bufnr)
    if self._should_auto_scroll_fn then
        return self._should_auto_scroll_fn()
    end

    return self:_check_auto_scroll(bufnr)
end

--- @return integer
function MessageWriter:_get_scroll_debounce_ms()
    local debounce_ms = Config.auto_scroll and Config.auto_scroll.debounce_ms

    if debounce_ms == nil then
        return DEFAULT_SCROLL_DEBOUNCE_MS
    end

    return math.max(0, math.floor(debounce_ms))
end

--- @return uv.uv_timer_t
function MessageWriter:_ensure_scroll_timer()
    local timer = self._scroll_timer

    if timer then
        local ok, is_closing = pcall(function()
            return timer:is_closing()
        end)

        if ok and not is_closing then
            return timer
        end
    end

    timer = vim.uv.new_timer()
    self._scroll_timer = timer

    return timer
end

--- @param bufnr integer Buffer number to scroll
function MessageWriter:_flush_auto_scroll(bufnr)
    self._scroll_scheduled = false

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    if not self:_should_auto_scroll_now(bufnr) then
        return
    end

    if self._scroll_to_bottom_fn then
        self._scroll_to_bottom_fn()
        return
    end

    local wins = vim.fn.win_findbuf(bufnr)
    if #wins > 0 then
        local last_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
        local success, err =
            pcall(vim.api.nvim_win_set_cursor, wins[1], { last_line, 0 })
        if not success then
            Logger.debug("Failed to move cursor to buffer end", err)
        end
    end
end

--- @param bufnr integer Buffer number to scroll
function MessageWriter:_auto_scroll(bufnr)
    if not self:_should_auto_scroll_now(bufnr) then
        self._scroll_scheduled = false

        local existing_timer = self._scroll_timer
        if existing_timer then
            pcall(function()
                existing_timer:stop()
            end)
        end

        return
    end

    local timer = self:_ensure_scroll_timer()
    local delay = self:_get_scroll_debounce_ms()

    self._scroll_scheduled = true

    timer:stop()
    timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            self:_flush_auto_scroll(bufnr)
        end)
    )
end

function MessageWriter:destroy()
    self._scroll_scheduled = false

    local timer = self._scroll_timer
    if not timer then
        return
    end

    self._scroll_timer = nil

    pcall(function()
        timer:stop()
    end)

    pcall(function()
        if not timer:is_closing() then
            timer:close()
        end
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    local existing_group_id = self:_get_active_diff_group_id(tool_call_block)
    if existing_group_id and existing_group_id ~= tool_call_block.tool_call_id then
        self.tool_call_blocks[tool_call_block.tool_call_id] =
            self.tool_call_blocks[existing_group_id]
        self:update_tool_call_block(tool_call_block)
        return
    end

    if is_diff_group_candidate(tool_call_block) then
        tool_call_block = self:_initialize_diff_group(tool_call_block)
    end

    if should_default_collapse(tool_call_block) and tool_call_block.collapsed == nil then
        tool_call_block.collapsed = true
    end

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        self:_reset_stream_block()
        local kind = tool_call_block.kind
        local start_row = self:_ensure_block_gap()
        local lines, highlight_ranges =
            self:_prepare_block_lines(tool_call_block)

        self:_append_lines(lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1

        self:_apply_block_highlights(
            bufnr,
            start_row,
            end_row,
            kind or "other",
            highlight_ranges
        )

        tool_call_block.extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
            })

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:update_tool_call_block(tool_call_block)
    local tracker = self.tool_call_blocks[tool_call_block.tool_call_id]

    if not tracker then
        Logger.debug(
            "Tool call block not found, ID: ",
            tool_call_block.tool_call_id
        )

        return
    end

    local previous_body = tracker.body
    local display_tool_call_id = tracker.tool_call_id

    if tracker._diff_sources and is_diff_group_candidate(tool_call_block) then
        self:_merge_diff_source(tracker, tool_call_block)
        tool_call_block = tracker
    end

    tracker = vim.tbl_deep_extend("force", tracker, tool_call_block)
    tracker.tool_call_id = display_tool_call_id
    tracker.refresh_body = nil

    if should_default_collapse(tracker) and tracker.collapsed == nil then
        tracker.collapsed = true
    end

    -- Merge body: append new to previous with divider if both exist and are different
    if
        previous_body
        and tool_call_block.body
        and not vim.deep_equal(previous_body, tool_call_block.body)
    then
        local merged = vim.list_extend({}, previous_body)
        vim.list_extend(merged, { "", "---", "" })
        vim.list_extend(merged, tool_call_block.body)
        tracker.body = merged
    end

    self.tool_call_blocks[tool_call_block.tool_call_id] = tracker

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.debug(
            "Extmark not found",
            { tool_call_id = tracker.tool_call_id }
        )
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.debug(
            "Could not determine end row of tool call block",
            { tool_call_id = tracker.tool_call_id, details = details }
        )
        return
    end

    self:_with_modifiable_and_notify_change(function(bufnr)
        local new_lines, highlight_ranges = self:_prepare_block_lines(tracker)

        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            start_row,
            old_end_row + 1
        )

        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                self:_apply_block_highlights(
                    bufnr,
                    start_row,
                    new_end_row,
                    tracker.kind,
                    highlight_ranges
                )
            end
        end)

        vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
            id = tracker.extmark_id,
            end_row = new_end_row,
            right_gravity = false,
        })
    end)
end

--- @param count integer
--- @param singular string
--- @param plural? string
--- @return string
local function pluralize(count, singular, plural)
    return string.format(
        "%d %s",
        count,
        count == 1 and singular or (plural or (singular .. "s"))
    )
end

--- @param path string
--- @return string
local function format_compact_path(path)
    local compact = vim.fn.fnamemodify(path, ":~:.")
    return compact ~= "" and compact or path
end

--- @param text string|nil
--- @return string
local function sanitize_single_line(text)
    if not text or text == "" then
        return ""
    end

    return text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- @param text string
--- @param prefix string
--- @return string
local function indent_text(text, prefix)
    if text == "" then
        return ""
    end

    return prefix .. text
end

--- @param text string
--- @param max_width integer
--- @return string
local function truncate_single_line(text, max_width)
    if #text <= max_width then
        return text
    end

    return text:sub(1, math.max(1, max_width - 3)) .. "..."
end

--- @param lines string[]|nil
--- @return integer
local function count_body_lines(lines)
    if not lines then
        return 0
    end

    return #lines
end

--- @param body string[]|nil
--- @return string[]
local function build_preview_lines(body)
    if not body or #body == 0 then
        return {}
    end

    local preview = {}

    for _, line in ipairs(body) do
        local normalized = sanitize_single_line(line)
        if normalized ~= "" then
            preview[#preview + 1] =
                truncate_single_line(normalized, MAX_TOOL_PREVIEW_WIDTH)
        end

        if #preview >= MAX_TOOL_PREVIEW_LINES then
            break
        end
    end

    if #preview == 0 then
        preview[1] = truncate_single_line(
            sanitize_single_line(body[1] or ""),
            MAX_TOOL_PREVIEW_WIDTH
        )
    end

    return preview
end

--- @param kind string|nil
--- @return string
local function get_tool_action_label(kind)
    return TOOL_ACTION_LABELS[kind or ""] or TOOL_ACTION_LABELS.other
end

--- @param value string|nil
--- @return string
local function normalize_tool_token(value)
    return (value or ""):lower():gsub("[%s_%-]", "")
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param title string
--- @return string
local function normalize_tool_title(tool_call_block, title)
    local head, inner = title:match("^([^%(]+)%((.*)%)$")
    if head and inner then
        local normalized_head = normalize_tool_token(head)
        local normalized_kind = normalize_tool_token(tool_call_block.kind)
        local normalized_action =
            normalize_tool_token(get_tool_action_label(tool_call_block.kind))

        if
            normalized_head ~= ""
            and (
                normalized_head == normalized_kind
                or normalized_head == normalized_action
            )
        then
            title = sanitize_single_line(inner)
        end
    end

    return title
end

--- @param kind string|nil
--- @return string
local function get_output_summary_label(kind)
    return OUTPUT_SUMMARY_LABELS[kind or ""] or OUTPUT_SUMMARY_LABELS.other
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param line_count integer
--- @return string
local function build_output_summary(tool_call_block, line_count)
    if tool_call_block.status == "failed" then
        return pluralize(line_count, "error line")
    end

    return pluralize(line_count, get_output_summary_label(tool_call_block.kind))
end

--- @param kind string|nil
--- @return boolean
is_diff_group_kind = function(kind)
    return DIFF_TOOL_KINDS[kind or ""] == true
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return boolean
is_diff_group_candidate = function(tool_call_block)
    return tool_call_block ~= nil
        and is_diff_group_kind(tool_call_block.kind)
        and tool_call_block.file_path ~= nil
        and tool_call_block.file_path ~= ""
end

--- @param turn_id integer
--- @param file_path string
--- @return string
build_turn_diff_group_key = function(turn_id, file_path)
    return string.format("%d::%s", turn_id, file_path)
end

--- @param statuses string[]
--- @return string|nil
aggregate_tool_statuses = function(statuses)
    local has_in_progress = false
    local has_pending = false
    local has_completed = false

    for _, status in ipairs(statuses) do
        if status == "failed" then
            return "failed"
        end
        if status == "in_progress" then
            has_in_progress = true
        elseif status == "pending" then
            has_pending = true
        elseif status == "completed" then
            has_completed = true
        end
    end

    if has_in_progress then
        return "in_progress"
    end
    if has_pending then
        return "pending"
    end
    if has_completed then
        return "completed"
    end

    return nil
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string
local function build_tool_title(tool_call_block)
    local action = get_tool_action_label(tool_call_block.kind)
    local title = normalize_tool_title(
        tool_call_block,
        sanitize_single_line(tool_call_block.argument)
    )

    if tool_call_block.file_path and tool_call_block.file_path ~= "" then
        if tool_call_block.kind == "read" then
            return string.format("%s %s", action, format_compact_path(tool_call_block.file_path))
        end
    end

    if title ~= "" then
        if tool_call_block.kind == "execute" then
            local normalized_title = normalize_tool_token(title)
            local normalized_action = normalize_tool_token(action)

            if not vim.startswith(normalized_title, normalized_action) then
                return string.format("%s %s", action, title)
            end
        end

        return title
    end

    if tool_call_block.file_path and tool_call_block.file_path ~= "" then
        return string.format("%s %s", action, format_compact_path(tool_call_block.file_path))
    end

    return action
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return boolean
should_default_collapse = function(tool_call_block)
    if tool_call_block.diff then
        return true
    end

    if tool_call_block.kind == "read" then
        return false
    end

    return count_body_lines(tool_call_block.body) > MAX_TOOL_PREVIEW_LINES
end

local append_comment_line
local append_spanned_line
local append_status_line
local append_highlighted_line

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
local function append_tool_header(lines, highlight_ranges, tool_call_block)
    local is_collapsible = tool_call_block.collapsed ~= nil
    local prefix = is_collapsible and (tool_call_block.collapsed and "▸ " or "▾ ")
        or ""

    append_spanned_line(lines, highlight_ranges, {
        { prefix, "Comment" },
        { build_tool_title(tool_call_block), Theme.HL_GROUPS.CARD_TITLE },
    })
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
local function append_read_card(lines, highlight_ranges, tool_call_block)
    append_tool_header(lines, highlight_ranges, tool_call_block)

    local line_count = count_body_lines(tool_call_block.body)
    if line_count > 0 then
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(
                string.format(
                    "%s loaded into context",
                    pluralize(line_count, "line")
                ),
                CARD_DETAIL_PREFIX
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
local function append_result_card(lines, highlight_ranges, tool_call_block)
    append_tool_header(lines, highlight_ranges, tool_call_block)

    local body = tool_call_block.body or {}
    local line_count = count_body_lines(body)

    if line_count == 0 then
        return
    end

    append_highlighted_line(
        lines,
        highlight_ranges,
        indent_text(
            build_output_summary(tool_call_block, line_count),
            CARD_DETAIL_PREFIX
        ),
        Theme.HL_GROUPS.CARD_DETAIL
    )

    if tool_call_block.collapsed == false then
        for _, line in ipairs(body) do
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text(line, CARD_DETAIL_PREFIX),
                Theme.HL_GROUPS.CARD_BODY
            )
        end
        append_spanned_line(lines, highlight_ranges, {
            { CARD_DETAIL_PREFIX, nil },
            { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
        })
        return
    end

    local preview_lines = build_preview_lines(body)
    for _, line in ipairs(preview_lines) do
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(line, CARD_DETAIL_PREFIX),
            Theme.HL_GROUPS.CARD_BODY
        )
    end

    local hidden_count = math.max(line_count - #preview_lines, 0)
    if hidden_count > 0 and tool_call_block.collapsed ~= nil then
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text(
                    string.format("%s · ", pluralize(hidden_count, "more line")),
                    CARD_DETAIL_PREFIX
                ),
                Theme.HL_GROUPS.CARD_DETAIL,
            },
            { "<CR> expand", Theme.HL_GROUPS.CARD_DETAIL },
        })
    end
end

--- @param diff_block agentic.ui.ToolCallDiff.DiffBlock
--- @return string
local function build_diff_block_label(diff_block)
    if #diff_block.old_lines == 0 then
        return string.format("@@ insert near line %d @@", diff_block.start_line)
    end

    if diff_block.start_line == diff_block.end_line then
        return string.format("@@ line %d @@", diff_block.start_line)
    end

    return string.format(
        "@@ lines %d-%d @@",
        diff_block.start_line,
        diff_block.end_line
    )
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param line_type agentic.ui.MessageWriter.HighlightRange.type
--- @param line_text string
--- @param old_line? string
--- @param new_line? string
--- @param prefix string
local function append_diff_line(
    lines,
    highlight_ranges,
    line_type,
    line_text,
    old_line,
    new_line,
    prefix
)
    local display_line = prefix .. line_text
    table.insert(lines, display_line)

    highlight_ranges[#highlight_ranges + 1] = {
        line_index = #lines - 1,
        type = line_type,
        old_line = old_line,
        new_line = new_line,
        display_prefix_len = #prefix,
    }
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param text string
append_comment_line = function(lines, highlight_ranges, text)
    table.insert(lines, text)
    highlight_ranges[#highlight_ranges + 1] = {
        type = "comment",
        line_index = #lines - 1,
    }
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param text string
--- @param hl_group string
append_highlighted_line = function(lines, highlight_ranges, text, hl_group)
    table.insert(lines, text)
    highlight_ranges[#highlight_ranges + 1] = {
        type = "span",
        line_index = #lines - 1,
        start_col = 0,
        end_col = #text,
        hl_group = hl_group,
    }
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param spans table[]
append_spanned_line = function(lines, highlight_ranges, spans)
    local line_index = #lines
    local line = {}
    local start_col = 0

    for _, span in ipairs(spans) do
        local text = span[1] or ""
        local hl_group = span[2]
        line[#line + 1] = text

        if hl_group and text ~= "" then
            highlight_ranges[#highlight_ranges + 1] = {
                type = "span",
                line_index = line_index,
                start_col = start_col,
                end_col = start_col + #text,
                hl_group = hl_group,
            }
        end

        start_col = start_col + #text
    end

    table.insert(lines, table.concat(line))
end

--- @param status string|nil
--- @return boolean
local function should_render_status_line(status)
    return status == "failed"
end

--- @param status string
--- @return string
local function format_status_label(status)
    return status:gsub("_", " ")
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param status string
append_status_line = function(lines, highlight_ranges, status)
    append_spanned_line(lines, highlight_ranges, {
        { CARD_DETAIL_PREFIX, nil },
        { format_status_label(status), Theme.get_status_hl_group(status) },
    })
end

--- @class agentic.ui.MessageWriter.DiffCardStats
--- @field edit_count integer
--- @field hunk_count integer
--- @field modifications integer
--- @field additions integer
--- @field deletions integer

--- @class agentic.ui.MessageWriter.DiffCardSample
--- @field label string
--- @field pairs agentic.ui.ToolCallDiff.ChangedPair[]

--- @param stats agentic.ui.MessageWriter.DiffCardStats
--- @return string
local function build_diff_summary_line(stats)
    local parts = { pluralize(stats.hunk_count, "hunk") }

    if stats.modifications > 0 then
        parts[#parts + 1] = pluralize(stats.modifications, "modified line")
    end
    if stats.additions > 0 then
        parts[#parts + 1] = pluralize(stats.additions, "added line")
    end
    if stats.deletions > 0 then
        parts[#parts + 1] = pluralize(stats.deletions, "deleted line")
    end

    return table.concat(parts, " · ")
end

--- @param stats agentic.ui.MessageWriter.DiffCardStats
--- @return integer additions
--- @return integer deletions
local function build_diff_totals(stats)
    local additions = stats.additions + stats.modifications
    local deletions = stats.deletions + stats.modifications
    return additions, deletions
end

--- @param kind string|nil
--- @return string
local function get_diff_action_label(kind)
    return DIFF_ACTION_LABELS[kind or ""] or "Changed"
end

--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @return agentic.ui.MessageWriter.DiffCardStats
--- @return agentic.ui.MessageWriter.DiffCardSample[]
--- @return integer sampled_changes
local function summarize_diff_blocks(diff_blocks)
    --- @type agentic.ui.MessageWriter.DiffCardStats
    local stats = {
        edit_count = 1,
        hunk_count = #diff_blocks,
        modifications = 0,
        additions = 0,
        deletions = 0,
    }

    --- @type agentic.ui.MessageWriter.DiffCardSample[]
    local samples = {}
    local sampled_changes = 0

    for _, block in ipairs(diff_blocks) do
        local filtered = ToolCallDiff.filter_unchanged_lines(
            block.old_lines,
            block.new_lines
        )

        for _, pair in ipairs(filtered.pairs) do
            if pair.old_line and pair.new_line then
                stats.modifications = stats.modifications + 1
            elseif pair.old_line then
                stats.deletions = stats.deletions + 1
            elseif pair.new_line then
                stats.additions = stats.additions + 1
            end
        end

        if
            #filtered.pairs > 0
            and #samples < MAX_DIFF_CARD_HUNKS
            and sampled_changes < MAX_DIFF_CARD_CHANGES
        then
            --- @type agentic.ui.ToolCallDiff.ChangedPair[]
            local sample_pairs = {}

            for _, pair in ipairs(filtered.pairs) do
                if sampled_changes >= MAX_DIFF_CARD_CHANGES then
                    break
                end

                sample_pairs[#sample_pairs + 1] = pair
                sampled_changes = sampled_changes + 1
            end

            if #sample_pairs > 0 then
                samples[#samples + 1] = {
                    label = build_diff_block_label(block),
                    pairs = sample_pairs,
                }
            end
        end
    end

    return stats, samples, sampled_changes
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.ui.MessageWriter.DiffCardStats
--- @return agentic.ui.MessageWriter.DiffCardSample[]
--- @return integer
local function summarize_diff_tracker(tool_call_block)
    if not tool_call_block._diff_sources or not tool_call_block._diff_source_order then
        return summarize_diff_blocks(ToolCallDiff.extract_diff_blocks({
            path = tool_call_block.file_path or "",
            old_text = tool_call_block.diff.old,
            new_text = tool_call_block.diff.new,
            replace_all = tool_call_block.diff.all,
        }))
    end

    --- @type agentic.ui.MessageWriter.DiffCardStats
    local stats = {
        edit_count = 0,
        hunk_count = 0,
        modifications = 0,
        additions = 0,
        deletions = 0,
    }
    --- @type agentic.ui.MessageWriter.DiffCardSample[]
    local samples = {}
    local sampled_changes = 0

    for _, source_id in ipairs(tool_call_block._diff_source_order) do
        local source = tool_call_block._diff_sources[source_id]
        if source and source.diff then
            local source_blocks = ToolCallDiff.extract_diff_blocks({
                path = source.file_path or tool_call_block.file_path or "",
                old_text = source.diff.old,
                new_text = source.diff.new,
                replace_all = source.diff.all,
            })
            local source_stats, source_samples, source_sampled_changes =
                summarize_diff_blocks(source_blocks)

            if source_stats.hunk_count > 0 then
                stats.edit_count = stats.edit_count + 1
            end
            stats.hunk_count = stats.hunk_count + source_stats.hunk_count
            stats.modifications = stats.modifications + source_stats.modifications
            stats.additions = stats.additions + source_stats.additions
            stats.deletions = stats.deletions + source_stats.deletions

            for _, sample in ipairs(source_samples) do
                samples[#samples + 1] = sample
            end
            sampled_changes = sampled_changes + source_sampled_changes
        end
    end

    return stats, samples, sampled_changes
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param sample agentic.ui.MessageWriter.DiffCardSample
local function append_diff_card_sample(lines, highlight_ranges, sample)
    append_comment_line(
        lines,
        highlight_ranges,
        indent_text(sample.label, CARD_DETAIL_PREFIX)
    )

    for _, pair in ipairs(sample.pairs) do
        if pair.old_line and pair.new_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "old",
                pair.old_line,
                pair.old_line,
                pair.new_line,
                CARD_NESTED_PREFIX .. "- "
            )
            append_diff_line(
                lines,
                highlight_ranges,
                "new_modification",
                pair.new_line,
                pair.old_line,
                pair.new_line,
                CARD_NESTED_PREFIX .. "+ "
            )
        elseif pair.old_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "old",
                pair.old_line,
                pair.old_line,
                nil,
                CARD_NESTED_PREFIX .. "- "
            )
        elseif pair.new_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "new",
                pair.new_line,
                nil,
                pair.new_line,
                CARD_NESTED_PREFIX .. "+ "
            )
        end
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
local function append_diff_card(lines, highlight_ranges, tool_call_block)
    local diff_path = tool_call_block.file_path or ""
    local stats, samples, sampled_changes
    if tool_call_block.diff or tool_call_block._diff_sources then
        stats, samples, sampled_changes = summarize_diff_tracker(tool_call_block)
    else
        stats = {
            edit_count = 1,
            hunk_count = 0,
            modifications = 0,
            additions = 0,
            deletions = 0,
        }
        samples = {}
        sampled_changes = 0
    end
    local additions, deletions = build_diff_totals(stats)
    local is_collapsed = tool_call_block.collapsed ~= false

    append_spanned_line(lines, highlight_ranges, {
        { is_collapsed and "▸ " or "▾ ", "Comment" },
        { get_diff_action_label(tool_call_block.kind) .. " ", "Comment" },
        {
            diff_path ~= "" and format_compact_path(diff_path) or "untitled",
            "Directory",
        },
        { " ", "Comment" },
        { string.format("+%d", additions), Theme.HL_GROUPS.DIFF_ADD },
        { " ", "Comment" },
        { string.format("-%d", deletions), Theme.HL_GROUPS.DIFF_DELETE },
    })

    local summary = build_diff_summary_line(stats)
    if stats.edit_count > 1 then
        summary = string.format(
            "%s · %s",
            pluralize(stats.edit_count, "edit"),
            summary
        )
    end
    append_highlighted_line(
        lines,
        highlight_ranges,
        indent_text(summary, CARD_DETAIL_PREFIX),
        Theme.HL_GROUPS.CARD_DETAIL
    )

    local hint_lines = {}
    local hint_line_index =
        DiffPreview.add_navigation_hint(tool_call_block, hint_lines)
    if hint_line_index ~= nil then
        local hint = hint_lines[hint_line_index + 1]
        if is_collapsed then
            append_spanned_line(lines, highlight_ranges, {
                {
                    indent_text(hint .. " · ", CARD_DETAIL_PREFIX),
                    Theme.HL_GROUPS.CARD_DETAIL,
                },
                { "<CR> expand", Theme.HL_GROUPS.CARD_DETAIL },
            })
        else
            append_spanned_line(lines, highlight_ranges, {
                {
                    indent_text(hint .. " · ", CARD_DETAIL_PREFIX),
                    Theme.HL_GROUPS.CARD_DETAIL,
                },
                { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
            })
        end
    elseif is_collapsed then
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text("Details hidden · ", CARD_DETAIL_PREFIX),
                Theme.HL_GROUPS.CARD_DETAIL,
            },
            { "<CR> expand", Theme.HL_GROUPS.CARD_DETAIL },
        })
    else
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text("Inline details expanded · ", CARD_DETAIL_PREFIX),
                Theme.HL_GROUPS.CARD_DETAIL,
            },
            { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
        })
    end

    if is_collapsed then
        return
    end

    if #samples == 0 then
        append_comment_line(
            lines,
            highlight_ranges,
            indent_text(
            tool_call_block.status == "pending"
                and "Preparing change preview"
                or "No diff details available",
                CARD_DETAIL_PREFIX
            )
        )
        return
    end

    for _, sample in ipairs(samples) do
        append_diff_card_sample(lines, highlight_ranges, sample)
    end

    local total_changes = stats.modifications
        + stats.additions
        + stats.deletions
    if total_changes > sampled_changes then
        append_comment_line(
            lines,
            highlight_ranges,
            indent_text(
                string.format(
                    "... %s in buffer review",
                    pluralize(total_changes - sampled_changes, "more change")
                ),
                CARD_DETAIL_PREFIX
            )
        )
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(tool_call_block)
    local kind = tool_call_block.kind

    local lines = {}

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    if kind == "read" then
        append_read_card(lines, highlight_ranges, tool_call_block)
    elseif tool_call_block.diff then
        append_diff_card(lines, highlight_ranges, tool_call_block)
    else
        append_result_card(lines, highlight_ranges, tool_call_block)
    end

    if should_render_status_line(tool_call_block.status) then
        append_status_line(lines, highlight_ranges, tool_call_block.status)
    end

    table.insert(lines, "")

    return lines, highlight_ranges
end

--- @param buffer_line integer
--- @return agentic.ui.MessageWriter.ToolCallBlock|nil
function MessageWriter:_find_tool_call_block_at_line(buffer_line)
    for _, tracker in pairs(self.tool_call_blocks) do
        if tracker.extmark_id then
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                self.bufnr,
                NS_TOOL_BLOCKS,
                tracker.extmark_id,
                { details = true }
            )

            local start_row = pos and pos[1]
            local end_row = pos and pos[3] and pos[3].end_row
            if
                start_row ~= nil
                and end_row ~= nil
                and buffer_line >= start_row
                and buffer_line <= end_row
            then
                return tracker
            end
        end
    end

    return nil
end

--- @param buffer_line integer
--- @return boolean toggled
function MessageWriter:toggle_diff_block_at_line(buffer_line)
    local tracker = self:_find_tool_call_block_at_line(buffer_line)
    if not tracker or tracker.collapsed == nil then
        return false
    end

    self:update_tool_call_block({
        tool_call_id = tracker.tool_call_id,
        collapsed = tracker.collapsed == false,
        refresh_body = true,
    })

    return true
end

--- Apply highlights to block content (either diff highlights or Comment for non-edit blocks)
--- @param bufnr integer
--- @param start_row integer Header line number
--- @param end_row integer Footer line number
--- @param kind string Tool call kind
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[] Diff highlight ranges
function MessageWriter:_apply_block_highlights(
    bufnr,
    start_row,
    end_row,
    kind,
    highlight_ranges
)
    if #highlight_ranges > 0 then
        self:_apply_diff_highlights(start_row, highlight_ranges)
    end
end

--- @param start_row integer
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_apply_diff_highlights(start_row, highlight_ranges)
    if not highlight_ranges or #highlight_ranges == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local buffer_line = start_row + hl_range.line_index
        local col_offset = hl_range.display_prefix_len or 0

        if hl_range.type == "old" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line,
                col_offset
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                nil,
                hl_range.new_line,
                col_offset
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line,
                col_offset
            )
        elseif hl_range.type == "comment" then
            local line = vim.api.nvim_buf_get_lines(
                self.bufnr,
                buffer_line,
                buffer_line + 1,
                false
            )[1]

            if line then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    buffer_line,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
                    }
                )
            end
        elseif
            hl_range.type == "span"
            and hl_range.start_col ~= nil
            and hl_range.end_col ~= nil
            and hl_range.hl_group
        then
            vim.api.nvim_buf_add_highlight(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                hl_range.hl_group,
                buffer_line,
                hl_range.start_col,
                hl_range.end_col
            )
        end
    end
end

return MessageWriter
