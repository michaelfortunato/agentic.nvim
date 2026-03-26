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
local NS_CHUNK_BOUNDARIES =
    vim.api.nvim_create_namespace("agentic_chunk_boundaries")

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification"|"span" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)
--- @field display_prefix_len? integer Byte length of any diff marker prefix rendered before the content
--- @field start_col? integer
--- @field end_col? integer
--- @field hl_group? string

--- @class agentic.ui.MessageWriter.ChunkBoundary
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field col integer Byte column within the rendered line

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean

--- @class agentic.ui.MessageWriter.ToolCallBlock
--- @field tool_call_id string
--- @field kind? agentic.acp.ToolKind
--- @field argument? string
--- @field file_path? string
--- @field extmark_id? integer Range extmark spanning the block
--- @field status? agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field permission_state? "requested"|"approved"|"rejected"|"dismissed"|nil
--- @field content_items? agentic.acp.ACPToolCallContent[]
--- @field content_nodes? agentic.session.ToolCallContentNode[]
--- @field terminal_id? string
--- @field collapsed? boolean

--- @class agentic.ui.MessageWriter.RequestContentBlock
--- @field block_id string
--- @field extmark_id? integer
--- @field content_node agentic.session.InteractionContentNode
--- @field collapsed boolean

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _request_content_blocks table<string, agentic.ui.MessageWriter.RequestContentBlock>
--- @field _should_auto_scroll_fn? fun(): boolean
--- @field _scroll_to_bottom_fn? fun()
--- @field _scroll_timer? uv.uv_timer_t
--- @field _scroll_scheduled? boolean
--- @field _content_changed_listeners table<integer, fun()>
--- @field _next_content_listener_id integer
--- @field _current_turn_id integer
--- @field _active_turn_diff_cards table<string, string>
--- @field _provider_name? string
--- @field _last_interaction_session? agentic.session.InteractionSession
--- @field _last_render_opts? table|nil
local MessageWriter = {}
MessageWriter.__index = MessageWriter

local DEFAULT_SCROLL_DEBOUNCE_MS = 150
local MAX_DIFF_CARD_HUNKS = 2
local MAX_DIFF_CARD_CHANGES = 4
local INDENT_UNIT = "  "
local ENVIRONMENT_INFO_URI = "agentic://environment_info"
local HIERARCHY_LEVEL = {
    root = 0,
    detail = 1,
    nested = 2,
}

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

local TRANSCRIPT_PARENT_META_PATTERNS = {
    "^User · ",
    "^Review · ",
    "^Agent · ",
    "^Agent error · ",
}

local should_default_collapse
local is_diff_group_kind
local is_diff_group_candidate
local build_turn_diff_group_key
local aggregate_tool_statuses
local apply_transcript_hierarchy
local apply_block_hierarchy
local indent_prefix
local indent_text
local pluralize
local format_compact_path

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

--- @param line string|nil
--- @return string
local function get_transcript_meta_hl_group(line)
    if not line then
        return Theme.HL_GROUPS.TRANSCRIPT_SYSTEM_META
    end

    if line:match("^User · ") or line:match("^Review · ") then
        return Theme.HL_GROUPS.TRANSCRIPT_REQUEST_META
    end

    if line:match("^Agent · ") then
        return Theme.HL_GROUPS.TRANSCRIPT_RESPONSE_META
    end

    return Theme.HL_GROUPS.TRANSCRIPT_SYSTEM_META
end

--- @param line string|nil
--- @return integer|nil
local function get_transcript_body_level(line)
    if not line or line == "" then
        return nil
    end

    for _, pattern in ipairs(TRANSCRIPT_PARENT_META_PATTERNS) do
        if line:match(pattern) then
            return HIERARCHY_LEVEL.detail
        end
    end

    return nil
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

--- @param provider_name string|nil
--- @return string[]
function MessageWriter:_build_agent_header_lines(provider_name)
    return {
        build_meta_line(
            "Agent",
            provider_name or self._provider_name or "Unknown provider"
        ),
    }
end

--- @class agentic.ui.MessageWriter.Opts
--- @field should_auto_scroll? fun(): boolean
--- @field scroll_to_bottom? fun()
--- @field provider_name? string

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
        _request_content_blocks = {},
        _should_auto_scroll_fn = opts.should_auto_scroll,
        _scroll_to_bottom_fn = opts.scroll_to_bottom,
        _scroll_timer = nil,
        _scroll_scheduled = false,
        _content_changed_listeners = {},
        _next_content_listener_id = 0,
        _current_turn_id = 0,
        _active_turn_diff_cards = {},
        _provider_name = opts.provider_name,
        _last_interaction_session = nil,
        _last_render_opts = nil,
    }, self)

    return instance
end

function MessageWriter:reset()
    self.tool_call_blocks = {}
    self._request_content_blocks = {}
    self._current_turn_id = 0
    self._active_turn_diff_cards = {}
    self._last_interaction_session = nil
    self._last_render_opts = nil
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

    local group_key = build_turn_diff_group_key(
        self._current_turn_id,
        tool_call_block.file_path
    )
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
                hl_group = Theme.HL_GROUPS.THOUGHT_TEXT,
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
                    hl_group = get_transcript_meta_hl_group(line),
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
                    hl_group = Theme.HL_GROUPS.RESOURCE_LINK,
                }
            )
        end
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
--- @param count integer
--- @param singular string
--- @param plural? string
--- @return string
pluralize = function(count, singular, plural)
    return string.format(
        "%d %s",
        count,
        count == 1 and singular or (plural or (singular .. "s"))
    )
end

--- @param path string
--- @return string
format_compact_path = function(path)
    local compact = vim.fn.fnamemodify(path, ":~:.")
    return compact ~= "" and compact or path
end

--- @param text string|nil
--- @return string
local function sanitize_single_line(text)
    if not text or text == "" then
        return ""
    end

    return text:gsub("\n", " ")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

--- @param text string|nil
--- @param max_length integer|nil
--- @return string
local function truncate_single_line(text, max_length)
    local sanitized = sanitize_single_line(text)
    if not max_length or max_length <= 0 then
        return sanitized
    end

    if vim.fn.strdisplaywidth(sanitized) <= max_length then
        return sanitized
    end

    local ellipsis = "..."
    local limit = math.max(1, max_length - vim.fn.strdisplaywidth(ellipsis))
    local truncated = sanitized

    while truncated ~= "" and vim.fn.strdisplaywidth(truncated) > limit do
        truncated =
            vim.fn.strcharpart(truncated, 0, vim.fn.strchars(truncated) - 1)
    end

    if truncated == "" then
        return ellipsis
    end

    return truncated .. ellipsis
end

--- @param render_width integer|nil
--- @param level integer
--- @param prefix string|nil
--- @return integer|nil
local function get_available_line_width(render_width, level, prefix)
    if not render_width or render_width <= 0 then
        return nil
    end

    local reserved =
        vim.fn.strdisplaywidth(indent_prefix(level) .. (prefix or ""))
    return math.max(1, render_width - reserved)
end

--- @param uri string|nil
--- @return string
local function format_content_uri(uri)
    if not uri or uri == "" then
        return "resource"
    end

    if uri == ENVIRONMENT_INFO_URI then
        return "environment_info"
    end

    if vim.startswith(uri, "file://") then
        local ok, path = pcall(vim.uri_to_fname, uri)
        if ok and path and path ~= "" then
            return format_compact_path(path)
        end
    end

    return sanitize_single_line(uri)
end

--- @param content_node agentic.session.InteractionContentNode
--- @return string
local function get_content_display_name(content_node)
    if content_node.type == "resource_link_content" then
        return content_node.title
            or content_node.name
            or format_content_uri(content_node.uri)
    end

    if content_node.type == "resource_content" then
        return format_content_uri(content_node.uri)
    end

    if content_node.type == "image_content" then
        return content_node.mime_type or "image"
    end

    if content_node.type == "audio_content" then
        return content_node.mime_type or "audio"
    end

    if content_node.type == "text_content" then
        local first_line =
            vim.split(content_node.text or "", "\n", { plain = true })[1]
        return sanitize_single_line(first_line)
    end

    return "content"
end

--- @param content_node agentic.session.InteractionContentNode
--- @return integer
local function count_content_lines(content_node)
    if content_node.type == "text_content" then
        return #vim.split(content_node.text or "", "\n", { plain = true })
    end

    if content_node.type == "resource_content" and content_node.text then
        return #vim.split(content_node.text, "\n", { plain = true })
    end

    return 0
end

--- @param text string|nil
--- @return string[]
local function split_content_lines(text)
    if not text or text == "" then
        return {}
    end

    return vim.split(text, "\n", { plain = true })
end

--- @param chunks string[]
--- @return string[] lines
--- @return agentic.ui.MessageWriter.ChunkBoundary[] boundaries
local function merge_text_chunks(chunks)
    local lines = {}

    --- @type agentic.ui.MessageWriter.ChunkBoundary[]
    local boundaries = {}

    if not chunks or #chunks == 0 then
        return lines, boundaries
    end

    local current_line = {}
    local current_col = 0
    local line_index = 0
    local has_any_chunk = false

    local function append_segment(segment)
        if segment == "" then
            return
        end

        current_line[#current_line + 1] = segment
        current_col = current_col + #segment
    end

    local function flush_line()
        lines[#lines + 1] = table.concat(current_line)
        current_line = {}
        current_col = 0
        line_index = line_index + 1
    end

    for chunk_index, chunk in ipairs(chunks) do
        if chunk ~= "" then
            has_any_chunk = true
            local start_col = 1

            while true do
                local newline_col = chunk:find("\n", start_col, true)
                if not newline_col then
                    append_segment(chunk:sub(start_col))
                    break
                end

                append_segment(chunk:sub(start_col, newline_col - 1))
                flush_line()
                start_col = newline_col + 1
            end
        end

        if chunk_index < #chunks then
            boundaries[#boundaries + 1] = {
                line_index = line_index,
                col = current_col,
            }
        end
    end

    if not has_any_chunk then
        return {}, {}
    end

    lines[#lines + 1] = table.concat(current_line)

    return lines, boundaries
end

--- @param buffered_text string|nil
--- @param append_line fun(line: string)
--- @return string|nil
local function flush_buffered_text_lines(buffered_text, append_line)
    if buffered_text == nil then
        return nil
    end

    for _, line in ipairs(split_content_lines(buffered_text)) do
        append_line(line)
    end

    return nil
end

--- @param level integer
--- @return string
indent_prefix = function(level)
    return string.rep(INDENT_UNIT, math.max(level or 0, 0))
end

--- @param text string
--- @param level integer
--- @return string
indent_text = function(text, level)
    if text == "" then
        return ""
    end

    return indent_prefix(level) .. text
end

--- @param lines string[]
--- @return string[]
apply_transcript_hierarchy = function(lines)
    local formatted = {}
    local body_level = nil

    for _, line in ipairs(lines) do
        if is_meta_line(line) then
            formatted[#formatted + 1] = line
            body_level = get_transcript_body_level(line)
        elseif line == "" then
            formatted[#formatted + 1] = ""
        elseif body_level ~= nil then
            formatted[#formatted + 1] = indent_text(line, body_level)
        else
            formatted[#formatted + 1] = line
        end
    end

    return formatted
end

--- @param lines string[]
--- @param base_level integer|nil
--- @return string[]
apply_block_hierarchy = function(lines, base_level)
    if not base_level or base_level <= 0 then
        return lines
    end

    local formatted = {}

    for _, line in ipairs(lines) do
        if line == "" then
            formatted[#formatted + 1] = ""
        else
            formatted[#formatted + 1] = indent_text(line, base_level)
        end
    end

    return formatted
end

--- @param chunk_boundaries agentic.ui.MessageWriter.ChunkBoundary[]|nil
--- @param lines string[]
--- @param base_level integer|nil
local function offset_chunk_boundaries(chunk_boundaries, lines, base_level)
    if not base_level or base_level <= 0 then
        return
    end

    local offset = #indent_prefix(base_level)
    if offset == 0 then
        return
    end

    for _, boundary in ipairs(chunk_boundaries or {}) do
        local line = lines[boundary.line_index + 1]
        if line and line ~= "" then
            boundary.col = boundary.col + offset
        end
    end
end

--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param lines string[]
--- @param base_level integer|nil
local function offset_highlight_ranges(highlight_ranges, lines, base_level)
    if not base_level or base_level <= 0 then
        return
    end

    local offset = #indent_prefix(base_level)
    if offset == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local line = lines[hl_range.line_index + 1]
        if line and line ~= "" then
            if hl_range.start_col ~= nil then
                hl_range.start_col = hl_range.start_col + offset
            end
            if hl_range.end_col ~= nil then
                hl_range.end_col = hl_range.end_col + offset
            end
            if hl_range.display_prefix_len ~= nil then
                hl_range.display_prefix_len = hl_range.display_prefix_len
                    + offset
            end
        end
    end
end

--- @param lines string[]|nil
--- @return integer
local function count_body_lines(lines)
    if not lines then
        return 0
    end

    return #lines
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
            return string.format(
                "%s %s",
                action,
                format_compact_path(tool_call_block.file_path)
            )
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
        return string.format(
            "%s %s",
            action,
            format_compact_path(tool_call_block.file_path)
        )
    end

    return action
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.session.ToolCallContentNode[]
local function get_tool_semantic_content_nodes(tool_call_block)
    return tool_call_block.content_nodes or {}
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return integer
local function count_tool_output_lines(tool_call_block)
    local line_count = 0
    local buffered_text = nil

    local function flush_text_count()
        line_count = line_count + #split_content_lines(buffered_text)
        buffered_text = nil
    end

    for _, content_node in
        ipairs(get_tool_semantic_content_nodes(tool_call_block))
    do
        if
            content_node.type == "content_output"
            and content_node.content_node
        then
            if content_node.content_node.type == "text_content" then
                buffered_text = (buffered_text or "")
                    .. (content_node.content_node.text or "")
            else
                flush_text_count()
                line_count = line_count
                    + count_content_lines(content_node.content_node)
            end
        else
            flush_text_count()
        end
    end

    flush_text_count()

    if line_count > 0 then
        return line_count
    end

    return count_body_lines(tool_call_block.body)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[]
local function build_tool_semantic_summaries(tool_call_block)
    local summaries = {}
    local resource_links = 0
    local resources = 0
    local images = 0
    local audio = 0
    local terminals = 0

    for _, content_node in
        ipairs(get_tool_semantic_content_nodes(tool_call_block))
    do
        if
            content_node.type == "content_output" and content_node.content_node
        then
            local semantic = content_node.content_node
            if semantic.type == "resource_link_content" then
                resource_links = resource_links + 1
            elseif semantic.type == "resource_content" then
                resources = resources + 1
            elseif semantic.type == "image_content" then
                images = images + 1
            elseif semantic.type == "audio_content" then
                audio = audio + 1
            end
        elseif content_node.type == "terminal_output" then
            terminals = terminals + 1
        end
    end

    local line_count = count_tool_output_lines(tool_call_block)
    if line_count > 0 then
        if tool_call_block.kind == "read" then
            summaries[#summaries + 1] = string.format(
                "%s loaded into context",
                pluralize(line_count, "line")
            )
        else
            summaries[#summaries + 1] =
                build_output_summary(tool_call_block, line_count)
        end
    end
    if resource_links > 0 then
        summaries[#summaries + 1] = pluralize(resource_links, "linked resource")
    end
    if resources > 0 then
        summaries[#summaries + 1] = pluralize(resources, "embedded resource")
    end
    if images > 0 then
        summaries[#summaries + 1] = pluralize(images, "image")
    end
    if audio > 0 then
        summaries[#summaries + 1] =
            pluralize(audio, "audio clip", "audio clips")
    end
    if terminals > 0 then
        summaries[#summaries + 1] = pluralize(terminals, "terminal")
    end

    return summaries
end

local append_comment_line
local append_spanned_line
local append_status_line
local append_highlighted_line

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param level integer
--- @param content_node agentic.session.InteractionContentNode
local function append_semantic_tool_content_node(
    lines,
    highlight_ranges,
    level,
    content_node
)
    if content_node.type == "text_content" then
        for _, line in ipairs(split_content_lines(content_node.text)) do
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text(line, level),
                Theme.HL_GROUPS.CARD_BODY
            )
        end
    elseif content_node.type == "resource_link_content" then
        append_spanned_line(lines, highlight_ranges, {
            { indent_prefix(level), nil },
            {
                "@" .. get_content_display_name(content_node),
                Theme.HL_GROUPS.RESOURCE_LINK,
            },
        })
        if content_node.description and content_node.description ~= "" then
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text(
                    sanitize_single_line(content_node.description),
                    level
                ),
                Theme.HL_GROUPS.CARD_DETAIL
            )
        end
    elseif content_node.type == "resource_content" then
        append_spanned_line(lines, highlight_ranges, {
            { indent_prefix(level), nil },
            {
                "@" .. get_content_display_name(content_node),
                Theme.HL_GROUPS.RESOURCE_LINK,
            },
        })
        local detail = "embedded context"
        local line_count = count_content_lines(content_node)
        if line_count > 0 then
            detail = detail .. " · " .. pluralize(line_count, "line")
        elseif content_node.blob then
            detail = detail .. " · binary data"
        end
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. sanitize_single_line(content_node.mime_type)
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(detail, level),
            Theme.HL_GROUPS.CARD_DETAIL
        )
        if content_node.text and content_node.text ~= "" then
            for _, line in ipairs(split_content_lines(content_node.text)) do
                append_highlighted_line(
                    lines,
                    highlight_ranges,
                    indent_text(line, level + 1),
                    Theme.HL_GROUPS.CARD_BODY
                )
            end
        end
    elseif content_node.type == "image_content" then
        local label = "image"
        if content_node.mime_type and content_node.mime_type ~= "" then
            label = label
                .. " · "
                .. sanitize_single_line(content_node.mime_type)
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(label, level),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    elseif content_node.type == "audio_content" then
        local label = "audio"
        if content_node.mime_type and content_node.mime_type ~= "" then
            label = label
                .. " · "
                .. sanitize_single_line(content_node.mime_type)
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(label, level),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    elseif content_node.type == "unknown_content" then
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(
                "content · "
                    .. sanitize_single_line(
                        content_node.content.type or "unknown"
                    ),
                level
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
local function append_tool_semantic_details(
    lines,
    highlight_ranges,
    tool_call_block
)
    local rendered_semantic_content = false
    local buffered_text = nil

    local function flush_text_output()
        if buffered_text == nil then
            return
        end

        rendered_semantic_content = true
        buffered_text = flush_buffered_text_lines(buffered_text, function(line)
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text(line, HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.CARD_BODY
            )
        end)
    end

    for _, content_node in
        ipairs(get_tool_semantic_content_nodes(tool_call_block))
    do
        if
            content_node.type == "content_output"
            and content_node.content_node
            and content_node.content_node.type == "text_content"
        then
            buffered_text = (buffered_text or "")
                .. (content_node.content_node.text or "")
        elseif
            content_node.type == "content_output" and content_node.content_node
        then
            flush_text_output()
            rendered_semantic_content = true
            append_semantic_tool_content_node(
                lines,
                highlight_ranges,
                HIERARCHY_LEVEL.detail,
                content_node.content_node
            )
        elseif content_node.type == "terminal_output" then
            flush_text_output()
            rendered_semantic_content = true
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text(
                    "terminal attached · "
                        .. sanitize_single_line(content_node.terminal_id),
                    HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.CARD_DETAIL
            )
        end
    end

    flush_text_output()

    if rendered_semantic_content or not tool_call_block.body then
        return
    end

    for _, line in ipairs(tool_call_block.body) do
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(line, HIERARCHY_LEVEL.detail),
            Theme.HL_GROUPS.CARD_BODY
        )
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return boolean
should_default_collapse = function(tool_call_block)
    if tool_call_block.diff then
        return true
    end

    if #get_tool_semantic_content_nodes(tool_call_block) > 0 then
        return true
    end

    return count_body_lines(tool_call_block.body) > 0
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param render_width integer|nil
local function append_tool_header(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    local is_collapsible = tool_call_block.collapsed ~= nil
    local prefix = is_collapsible
            and (tool_call_block.collapsed and "▸ " or "▾ ")
        or ""
    local title = truncate_single_line(
        build_tool_title(tool_call_block),
        get_available_line_width(render_width, HIERARCHY_LEVEL.detail, prefix)
    )

    append_spanned_line(lines, highlight_ranges, {
        { prefix, "Comment" },
        { title, Theme.HL_GROUPS.CARD_TITLE },
    })
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param render_width integer|nil
local function append_read_card(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    append_tool_header(lines, highlight_ranges, tool_call_block, render_width)

    local summaries = build_tool_semantic_summaries(tool_call_block)
    if #summaries == 0 then
        return
    end

    for _, summary in ipairs(summaries) do
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(
                truncate_single_line(
                    summary,
                    get_available_line_width(
                        render_width,
                        HIERARCHY_LEVEL.nested
                    )
                ),
                HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end

    if tool_call_block.collapsed == false then
        append_tool_semantic_details(lines, highlight_ranges, tool_call_block)
        append_spanned_line(lines, highlight_ranges, {
            { indent_prefix(HIERARCHY_LEVEL.detail), nil },
            { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
        })
        return
    end

    if tool_call_block.collapsed ~= nil then
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text("Details hidden · ", HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
        })
    end
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param render_width integer|nil
local function append_result_card(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    append_tool_header(lines, highlight_ranges, tool_call_block, render_width)

    local summaries = build_tool_semantic_summaries(tool_call_block)
    if #summaries == 0 then
        return
    end

    for _, summary in ipairs(summaries) do
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(
                truncate_single_line(
                    summary,
                    get_available_line_width(
                        render_width,
                        HIERARCHY_LEVEL.nested
                    )
                ),
                HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end

    if tool_call_block.collapsed == false then
        append_tool_semantic_details(lines, highlight_ranges, tool_call_block)
        append_spanned_line(lines, highlight_ranges, {
            { indent_prefix(HIERARCHY_LEVEL.detail), nil },
            { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
        })
        return
    end

    if tool_call_block.collapsed ~= nil then
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text("Details hidden · ", HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
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
--- @param hl_group? string
append_comment_line = function(lines, highlight_ranges, text, hl_group)
    table.insert(lines, text)
    highlight_ranges[#highlight_ranges + 1] = {
        type = "comment",
        line_index = #lines - 1,
        hl_group = hl_group,
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
        { indent_prefix(HIERARCHY_LEVEL.detail), nil },
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
    if
        not tool_call_block._diff_sources
        or not tool_call_block._diff_source_order
    then
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
            stats.modifications = stats.modifications
                + source_stats.modifications
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
        indent_text(sample.label, HIERARCHY_LEVEL.detail),
        Theme.HL_GROUPS.CARD_DETAIL
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
                indent_prefix(HIERARCHY_LEVEL.nested) .. "- "
            )
            append_diff_line(
                lines,
                highlight_ranges,
                "new_modification",
                pair.new_line,
                pair.old_line,
                pair.new_line,
                indent_prefix(HIERARCHY_LEVEL.nested) .. "+ "
            )
        elseif pair.old_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "old",
                pair.old_line,
                pair.old_line,
                nil,
                indent_prefix(HIERARCHY_LEVEL.nested) .. "- "
            )
        elseif pair.new_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "new",
                pair.new_line,
                nil,
                pair.new_line,
                indent_prefix(HIERARCHY_LEVEL.nested) .. "+ "
            )
        end
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param render_width integer|nil
local function append_diff_card(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    local diff_path = tool_call_block.file_path or ""
    local stats, samples, sampled_changes
    if tool_call_block.diff or tool_call_block._diff_sources then
        stats, samples, sampled_changes =
            summarize_diff_tracker(tool_call_block)
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
    local prefix = is_collapsed and "▸ " or "▾ "
    local action_text = get_diff_action_label(tool_call_block.kind) .. " "
    local additions_text = string.format("+%d", additions)
    local deletions_text = string.format("-%d", deletions)
    local path_text = truncate_single_line(
        diff_path ~= "" and format_compact_path(diff_path) or "untitled",
        get_available_line_width(
            render_width,
            HIERARCHY_LEVEL.detail,
            prefix
                .. action_text
                .. " "
                .. additions_text
                .. " "
                .. deletions_text
        )
    )

    append_spanned_line(lines, highlight_ranges, {
        { prefix, "Comment" },
        { action_text, "Comment" },
        { path_text, "Directory" },
        { " ", "Comment" },
        { additions_text, Theme.HL_GROUPS.DIFF_ADD },
        { " ", "Comment" },
        { deletions_text, Theme.HL_GROUPS.DIFF_DELETE },
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
        indent_text(summary, HIERARCHY_LEVEL.detail),
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
                    indent_text(hint .. " · ", HIERARCHY_LEVEL.detail),
                    Theme.HL_GROUPS.FOLD_HINT,
                },
                { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
            })
        else
            append_spanned_line(lines, highlight_ranges, {
                {
                    indent_text(hint .. " · ", HIERARCHY_LEVEL.detail),
                    Theme.HL_GROUPS.FOLD_HINT,
                },
                { "<CR> collapse", Theme.HL_GROUPS.FOLD_HINT },
            })
        end
    elseif is_collapsed then
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text("Details hidden · ", HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
        })
    else
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text(
                    "Inline details expanded · ",
                    HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> collapse", Theme.HL_GROUPS.FOLD_HINT },
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
                HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
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
                HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param render_width integer|nil
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(tool_call_block, render_width)
    local kind = tool_call_block.kind

    local lines = {}

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    if kind == "read" then
        append_read_card(lines, highlight_ranges, tool_call_block, render_width)
    elseif tool_call_block.diff then
        append_diff_card(lines, highlight_ranges, tool_call_block, render_width)
    else
        append_result_card(
            lines,
            highlight_ranges,
            tool_call_block,
            render_width
        )
    end

    if should_render_status_line(tool_call_block.status) then
        append_status_line(lines, highlight_ranges, tool_call_block.status)
    end

    table.insert(lines, "")

    offset_highlight_ranges(highlight_ranges, lines, HIERARCHY_LEVEL.detail)
    lines = apply_block_hierarchy(lines, HIERARCHY_LEVEL.detail)

    return lines, highlight_ranges
end

--- @param buffer_line integer
--- @return table|nil
function MessageWriter:_find_tool_call_block_at_line(buffer_line)
    for _, trackers in ipairs({
        self._request_content_blocks,
        self.tool_call_blocks,
    }) do
        for _, tracker in pairs(trackers) do
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
    end

    return nil
end

--- @param buffer_line integer
--- @return boolean toggled
function MessageWriter:toggle_tool_block_at_line(buffer_line)
    local tracker = self:_find_tool_call_block_at_line(buffer_line)
    if not tracker or tracker.collapsed == nil then
        return false
    end

    tracker.collapsed = tracker.collapsed == false

    if not self._last_interaction_session then
        return false
    end

    self:render_interaction_session(
        self._last_interaction_session,
        self._last_render_opts
    )

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
--- @param boundaries agentic.ui.MessageWriter.ChunkBoundary[]|nil
function MessageWriter:_apply_chunk_boundary_highlights(start_row, boundaries)
    if not Config.debug or not boundaries or #boundaries == 0 then
        return
    end

    for _, boundary in ipairs(boundaries) do
        local buffer_line = start_row + boundary.line_index
        local line = vim.api.nvim_buf_get_lines(
            self.bufnr,
            buffer_line,
            buffer_line + 1,
            false
        )[1] or ""

        if line ~= "" then
            local start_col = boundary.col
            local end_col = boundary.col + 1

            if boundary.col > 0 then
                start_col = boundary.col - 1
                end_col = boundary.col
            end

            start_col = math.max(0, math.min(start_col, #line - 1))
            end_col = math.max(start_col + 1, math.min(end_col, #line))

            if end_col > start_col then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    NS_CHUNK_BOUNDARIES,
                    buffer_line,
                    start_col,
                    {
                        end_col = end_col,
                        hl_group = Theme.HL_GROUPS.CHUNK_BOUNDARY,
                        right_gravity = false,
                    }
                )
            end
        end
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
                        hl_group = hl_range.hl_group
                            or Theme.HL_GROUPS.CARD_DETAIL,
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

--- @param lines string[]
--- @param content_nodes agentic.session.InteractionContentNode[]|nil
--- @param opts {show_embedded_text?: boolean|nil, chunk_boundaries?: agentic.ui.MessageWriter.ChunkBoundary[]|nil}
local function append_semantic_content_lines(lines, content_nodes, opts)
    opts = opts or {}
    local buffered_text_chunks = {}

    local function flush_text_content()
        local start_line = #lines
        local merged_lines, chunk_boundaries =
            merge_text_chunks(buffered_text_chunks)

        for _, line in ipairs(merged_lines) do
            lines[#lines + 1] = line
        end

        if opts.chunk_boundaries then
            for _, boundary in ipairs(chunk_boundaries) do
                opts.chunk_boundaries[#opts.chunk_boundaries + 1] = {
                    line_index = start_line + boundary.line_index,
                    col = boundary.col,
                }
            end
        end

        buffered_text_chunks = {}
    end

    for _, content_node in ipairs(content_nodes or {}) do
        if content_node.type == "text_content" then
            local text = content_node.text or ""
            if text ~= "" then
                buffered_text_chunks[#buffered_text_chunks + 1] = text
            end
        elseif content_node.type == "resource_link_content" then
            flush_text_content()
            local label = get_content_display_name(content_node)
            lines[#lines + 1] = "@" .. label
            if content_node.description and content_node.description ~= "" then
                lines[#lines + 1] = "linked resource · "
                    .. sanitize_single_line(content_node.description)
            elseif content_node.mime_type and content_node.mime_type ~= "" then
                lines[#lines + 1] = "linked resource · "
                    .. sanitize_single_line(content_node.mime_type)
            else
                lines[#lines + 1] = "linked resource"
            end
        elseif content_node.type == "resource_content" then
            flush_text_content()
            local label = get_content_display_name(content_node)
            lines[#lines + 1] = "@" .. label

            local detail = "embedded context"
            local line_count = count_content_lines(content_node)
            if line_count > 0 then
                detail = detail .. " · " .. pluralize(line_count, "line")
            elseif content_node.blob then
                detail = detail .. " · binary data"
            end
            if content_node.mime_type and content_node.mime_type ~= "" then
                detail = detail
                    .. " · "
                    .. sanitize_single_line(content_node.mime_type)
            end
            lines[#lines + 1] = detail

            if
                opts.show_embedded_text
                and content_node.text
                and content_node.text ~= ""
            then
                for _, line in ipairs(split_content_lines(content_node.text)) do
                    lines[#lines + 1] = line
                end
            end
        elseif content_node.type == "image_content" then
            flush_text_content()
            local label = "image"
            if content_node.mime_type and content_node.mime_type ~= "" then
                label = label
                    .. " · "
                    .. sanitize_single_line(content_node.mime_type)
            end
            if content_node.uri and content_node.uri ~= "" then
                label = label .. " · " .. format_content_uri(content_node.uri)
            end
            lines[#lines + 1] = label
        elseif content_node.type == "audio_content" then
            flush_text_content()
            local label = "audio"
            if content_node.mime_type and content_node.mime_type ~= "" then
                label = label
                    .. " · "
                    .. sanitize_single_line(content_node.mime_type)
            end
            lines[#lines + 1] = label
        elseif content_node.type == "unknown_content" then
            flush_text_content()
            local raw_type =
                sanitize_single_line(content_node.content.type or "unknown")
            lines[#lines + 1] = "content · " .. raw_type
        end
    end

    flush_text_content()
end

--- @param content_nodes agentic.session.InteractionContentNode[]|nil
--- @return string[]
--- @return agentic.ui.MessageWriter.ChunkBoundary[]
local function build_semantic_content_lines(content_nodes)
    local lines = {}

    --- @type agentic.ui.MessageWriter.ChunkBoundary[]
    local chunk_boundaries = {}

    append_semantic_content_lines(lines, content_nodes, {
        show_embedded_text = false,
        chunk_boundaries = chunk_boundaries,
    })
    return lines, chunk_boundaries
end

--- @param request agentic.session.InteractionRequest
--- @return string[]
local function build_request_header_lines(request)
    if not request then
        return {}
    end

    local timestamp = request.timestamp
            and os.date("%Y-%m-%d %H:%M:%S", request.timestamp)
        or os.date("%Y-%m-%d %H:%M:%S")
    local label = request.kind == "review" and "Review" or "User"

    return {
        build_meta_line(label, timestamp),
    }
end

--- @param content_node agentic.session.InteractionContentNode
--- @return string
local function get_request_content_type_label(content_node)
    if content_node.type == "text_content" then
        return "text"
    end

    if content_node.type == "resource_link_content" then
        return "resource_link"
    end

    if content_node.type == "resource_content" then
        return "resource"
    end

    if content_node.type == "image_content" then
        return "image"
    end

    if content_node.type == "audio_content" then
        return "audio"
    end

    return "unknown"
end

--- @param content_node agentic.session.InteractionContentNode
--- @return string[]
local function build_request_content_summaries(content_node)
    if content_node.type == "text_content" then
        local root_tag = content_node.xml_root_tag
        local line_count = count_content_lines(content_node)
        if root_tag then
            return {
                string.format(
                    "structured text · %s · %s",
                    root_tag,
                    pluralize(line_count, "line")
                ),
            }
        end

        local preview = truncate_single_line(content_node.text, 72)
        if preview ~= "" and line_count > 1 then
            preview = preview .. " · " .. pluralize(line_count, "line")
        elseif preview == "" then
            preview = pluralize(line_count, "line")
        end

        return { preview }
    end

    if content_node.type == "resource_link_content" then
        return {
            get_content_display_name(content_node),
        }
    end

    if content_node.type == "resource_content" then
        local detail = get_content_display_name(content_node)
        local line_count = count_content_lines(content_node)
        if line_count > 0 then
            detail = detail .. " · " .. pluralize(line_count, "line")
        elseif content_node.blob then
            detail = detail .. " · binary data"
        end
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. sanitize_single_line(content_node.mime_type)
        end

        return { detail }
    end

    if content_node.type == "image_content" then
        local detail = "image"
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. sanitize_single_line(content_node.mime_type)
        end
        if content_node.uri and content_node.uri ~= "" then
            detail = detail .. " · " .. format_content_uri(content_node.uri)
        end
        return { detail }
    end

    if content_node.type == "audio_content" then
        local detail = "audio"
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. sanitize_single_line(content_node.mime_type)
        end
        return { detail }
    end

    return {
        "content · "
            .. sanitize_single_line(content_node.content.type or "unknown"),
    }
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param label string
--- @param value string
--- @param level integer
local function append_request_field_line(
    lines,
    highlight_ranges,
    label,
    value,
    level
)
    append_spanned_line(lines, highlight_ranges, {
        { indent_text(label .. ": ", level), Theme.HL_GROUPS.CARD_DETAIL },
        { value, Theme.HL_GROUPS.CARD_BODY },
    })
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param content_node agentic.session.InteractionContentNode
local function append_request_content_details(
    lines,
    highlight_ranges,
    content_node
)
    if content_node.type == "text_content" then
        for _, line in ipairs(split_content_lines(content_node.text)) do
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text(line, HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.CARD_BODY
            )
        end
        return
    end

    if content_node.type == "resource_link_content" then
        append_request_field_line(
            lines,
            highlight_ranges,
            "uri",
            sanitize_single_line(content_node.uri),
            HIERARCHY_LEVEL.detail
        )
        append_request_field_line(
            lines,
            highlight_ranges,
            "name",
            sanitize_single_line(content_node.name),
            HIERARCHY_LEVEL.detail
        )
        if content_node.title and content_node.title ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "title",
                sanitize_single_line(content_node.title),
                HIERARCHY_LEVEL.detail
            )
        end
        if content_node.description and content_node.description ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "description",
                sanitize_single_line(content_node.description),
                HIERARCHY_LEVEL.detail
            )
        end
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                sanitize_single_line(content_node.mime_type),
                HIERARCHY_LEVEL.detail
            )
        end
        return
    end

    if content_node.type == "resource_content" then
        append_request_field_line(
            lines,
            highlight_ranges,
            "uri",
            sanitize_single_line(content_node.uri),
            HIERARCHY_LEVEL.detail
        )
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                sanitize_single_line(content_node.mime_type),
                HIERARCHY_LEVEL.detail
            )
        end
        if content_node.text and content_node.text ~= "" then
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text("text:", HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.CARD_DETAIL
            )
            for _, line in ipairs(split_content_lines(content_node.text)) do
                append_highlighted_line(
                    lines,
                    highlight_ranges,
                    indent_text(line, HIERARCHY_LEVEL.nested),
                    Theme.HL_GROUPS.CARD_BODY
                )
            end
        elseif content_node.blob then
            append_highlighted_line(
                lines,
                highlight_ranges,
                indent_text(
                    "blob: binary payload omitted",
                    HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.CARD_DETAIL
            )
        end
        return
    end

    if content_node.type == "image_content" then
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                sanitize_single_line(content_node.mime_type),
                HIERARCHY_LEVEL.detail
            )
        end
        if content_node.uri and content_node.uri ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "uri",
                sanitize_single_line(content_node.uri),
                HIERARCHY_LEVEL.detail
            )
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text("data: binary payload omitted", HIERARCHY_LEVEL.detail),
            Theme.HL_GROUPS.CARD_DETAIL
        )
        return
    end

    if content_node.type == "audio_content" then
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                sanitize_single_line(content_node.mime_type),
                HIERARCHY_LEVEL.detail
            )
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text("data: binary payload omitted", HIERARCHY_LEVEL.detail),
            Theme.HL_GROUPS.CARD_DETAIL
        )
        return
    end

    append_highlighted_line(
        lines,
        highlight_ranges,
        indent_text(
            "content type: "
                .. sanitize_single_line(content_node.content.type or "unknown"),
            HIERARCHY_LEVEL.detail
        ),
        Theme.HL_GROUPS.CARD_DETAIL
    )
end

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param tracker agentic.ui.MessageWriter.RequestContentBlock
--- @param render_width integer|nil
local function append_request_content_card(
    lines,
    highlight_ranges,
    tracker,
    render_width
)
    append_spanned_line(lines, highlight_ranges, {
        { tracker.collapsed and "▸ " or "▾ ", "Comment" },
        {
            get_request_content_type_label(tracker.content_node),
            Theme.HL_GROUPS.CARD_TITLE,
        },
    })

    for _, summary in
        ipairs(build_request_content_summaries(tracker.content_node))
    do
        append_highlighted_line(
            lines,
            highlight_ranges,
            indent_text(
                truncate_single_line(
                    summary,
                    get_available_line_width(
                        render_width,
                        HIERARCHY_LEVEL.nested
                    )
                ),
                HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end

    if tracker.collapsed then
        append_spanned_line(lines, highlight_ranges, {
            {
                indent_text("Details hidden · ", HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
        })
        return
    end

    append_request_content_details(
        lines,
        highlight_ranges,
        tracker.content_node
    )
    append_spanned_line(lines, highlight_ranges, {
        { indent_prefix(HIERARCHY_LEVEL.detail), nil },
        { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
    })
end

--- @param tracker agentic.ui.MessageWriter.RequestContentBlock
--- @param render_width integer|nil
--- @return string[]
--- @return agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_prepare_request_content_block_lines(
    tracker,
    render_width
)
    local lines = {}

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    append_request_content_card(lines, highlight_ranges, tracker, render_width)
    table.insert(lines, "")

    offset_highlight_ranges(highlight_ranges, lines, HIERARCHY_LEVEL.detail)
    lines = apply_block_hierarchy(lines, HIERARCHY_LEVEL.detail)

    return lines, highlight_ranges
end

--- @param turn_index integer
--- @param content_index integer
--- @return string
local function build_request_content_block_id(turn_index, content_index)
    return string.format("request:%d:%d", turn_index, content_index)
end

--- @param request agentic.session.InteractionRequest
--- @param turn_index integer
--- @param previous_blocks table<string, agentic.ui.MessageWriter.RequestContentBlock>
--- @return table[]
local function build_request_items(request, turn_index, previous_blocks)
    local items = {}

    for _, request_node in ipairs(request.nodes or {}) do
        if request_node.type == "request_text" then
            items[#items + 1] = {
                type = "lines",
                lines = split_content_lines(request_node.text),
            }
        else
            local block_id = build_request_content_block_id(
                turn_index,
                request_node.content_index
            )
            local previous = previous_blocks[block_id]

            --- @type agentic.ui.MessageWriter.RequestContentBlock
            local tracker = {
                block_id = block_id,
                content_node = vim.deepcopy(request_node.content_node),
                collapsed = previous and previous.collapsed or true,
            }

            if previous and previous.collapsed == false then
                tracker.collapsed = false
            end

            items[#items + 1] = {
                type = "request_content",
                tracker = tracker,
            }
        end
    end

    if #items == 0 and request.text ~= "" then
        items[#items + 1] = {
            type = "lines",
            lines = vim.split(request.text, "\n", { plain = true }),
        }
    end

    return items
end

--- @param request agentic.session.InteractionRequest
--- @return string[]
local function build_request_lines(request)
    return apply_transcript_hierarchy(build_request_header_lines(request))
end

--- @param result agentic.session.InteractionTurnResult
--- @return string[]
local function build_turn_result_lines(result)
    local lines = {}

    if result.error_text and result.error_text ~= "" then
        lines[#lines + 1] = build_meta_line("Agent error", "details below")
        for _, line in
            ipairs(vim.split(result.error_text, "\n", { plain = true }))
        do
            lines[#lines + 1] = line
        end
    elseif result.stop_reason == "cancelled" then
        lines[#lines + 1] = build_meta_line("Stopped", "user request")
    end

    lines[#lines + 1] = build_meta_line(
        "Turn complete",
        os.date("%Y-%m-%d %H:%M:%S", result.timestamp or os.time())
    )

    return apply_transcript_hierarchy(lines)
end

--- @param node agentic.session.InteractionPlanNode
--- @return string[]
local function build_plan_lines(node)
    local lines = {
        indent_text("Plan", HIERARCHY_LEVEL.detail),
    }

    for _, entry in ipairs(node.entries or {}) do
        local status = sanitize_single_line(entry.status or "pending")
        local content = sanitize_single_line(entry.content or "")
        if content ~= "" then
            lines[#lines + 1] = indent_text(
                string.format("[%s] %s", status, content),
                HIERARCHY_LEVEL.nested
            )
        end
    end

    return lines
end

--- @param node agentic.session.InteractionToolCallNode
--- @param previous_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @return agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_build_tool_call_block_from_node(node, previous_blocks)
    local block = {
        tool_call_id = node.tool_call_id or tostring(vim.loop.hrtime()),
        kind = node.kind,
        argument = node.title,
        status = node.status,
        file_path = node.file_path,
        terminal_id = node.terminal_id,
        body = {},
        diff = nil,
        content_nodes = vim.deepcopy(node.content_nodes or {}),
        collapsed = nil,
    }

    local function append_body_lines(lines)
        if not lines or #lines == 0 then
            return
        end

        if #block.body > 0 then
            vim.list_extend(block.body, { "", "---", "" })
        end

        for _, line in ipairs(lines) do
            block.body[#block.body + 1] = line
        end
    end

    local buffered_body_text = nil

    local function flush_body_text()
        if buffered_body_text == nil then
            return
        end

        append_body_lines(split_content_lines(buffered_body_text))
        buffered_body_text = nil
    end

    for _, content_node in ipairs(node.content_nodes or {}) do
        if
            content_node.type == "content_output"
            and content_node.content_node
            and content_node.content_node.type == "text_content"
        then
            buffered_body_text = (buffered_body_text or "")
                .. (content_node.content_node.text or "")
        elseif
            content_node.type == "diff_output"
            and content_node.old_lines
            and content_node.new_lines
        then
            flush_body_text()
            block.diff = {
                old = vim.deepcopy(content_node.old_lines),
                new = vim.deepcopy(content_node.new_lines),
            }
            block.file_path = content_node.file_path or block.file_path
        elseif content_node.type == "terminal_output" then
            flush_body_text()
            block.terminal_id = content_node.terminal_id
        end
    end

    flush_body_text()

    if #block.body == 0 then
        block.body = nil
    end

    local previous = previous_blocks[node.tool_call_id or ""]
    if previous and previous.collapsed ~= nil then
        block.collapsed = previous.collapsed
    end

    return block
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param previous_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param ordered_items table[]
function MessageWriter:_register_interaction_tool_block(
    tool_call_block,
    previous_blocks,
    ordered_items
)
    local existing_group_id = self:_get_active_diff_group_id(tool_call_block)
    if
        existing_group_id
        and existing_group_id ~= tool_call_block.tool_call_id
    then
        local tracker = self.tool_call_blocks[existing_group_id]
        if tracker then
            self:_merge_diff_source(tracker, tool_call_block)
        end
        return
    end

    if is_diff_group_candidate(tool_call_block) then
        tool_call_block = self:_initialize_diff_group(tool_call_block)
    end

    local previous = previous_blocks[tool_call_block.tool_call_id]
    if previous and previous.collapsed ~= nil then
        tool_call_block.collapsed = previous.collapsed
    end

    if
        should_default_collapse(tool_call_block)
        and tool_call_block.collapsed == nil
    then
        tool_call_block.collapsed = true
    end

    self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block
    ordered_items[#ordered_items + 1] = {
        type = "tool_call",
        tracker = tool_call_block,
    }
end

--- @param interaction_session agentic.session.InteractionSession
--- @param opts {welcome_lines?: string[]|nil}|nil
function MessageWriter:render_interaction_session(interaction_session, opts)
    opts = opts or {}
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    self:_auto_scroll(self.bufnr)

    local previous_blocks = self.tool_call_blocks
    local previous_request_blocks = self._request_content_blocks
    self:reset()
    self._last_interaction_session = vim.deepcopy(interaction_session)
    self._last_render_opts = vim.deepcopy(opts)
    local winid = vim.fn.bufwinid(self.bufnr)
    local render_width = nil
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
        render_width = math.max(8, vim.api.nvim_win_get_width(winid) - 1)
    end

    local lines = {}
    local meta_blocks = {}
    local thought_blocks = {}
    local fold_blocks = {}
    local chunk_boundary_blocks = {}

    local function append_block(block_lines, block_opts)
        if not block_lines or #block_lines == 0 then
            return
        end

        local join_with_previous = block_opts and block_opts.join_with_previous
        if not join_with_previous and #lines > 0 and lines[#lines] ~= "" then
            lines[#lines + 1] = ""
        end

        local start_row = #lines
        vim.list_extend(lines, block_lines)
        local end_row = #lines - 1

        if block_opts and block_opts.meta then
            meta_blocks[#meta_blocks + 1] = {
                start_row = start_row,
                lines = vim.deepcopy(block_lines),
            }
        end

        if block_opts and block_opts.thought then
            thought_blocks[#thought_blocks + 1] = {
                start_row = start_row,
                end_row = end_row,
            }
        end

        if block_opts and block_opts.fold then
            fold_blocks[#fold_blocks + 1] = {
                start_row = start_row,
                end_row = end_row,
                kind = block_opts.fold.kind,
                highlight_ranges = block_opts.fold.highlight_ranges,
                tracker = block_opts.fold.tracker,
            }
        end

        if block_opts and block_opts.chunk_boundaries then
            chunk_boundary_blocks[#chunk_boundary_blocks + 1] = {
                start_row = start_row,
                boundaries = vim.deepcopy(block_opts.chunk_boundaries),
            }
        end
    end

    append_block(opts.welcome_lines or {}, { meta = true })

    for _, turn in ipairs(interaction_session.turns or {}) do
        self._current_turn_id = turn.index
        self._active_turn_diff_cards = {}

        append_block(build_request_lines(turn.request), { meta = true })

        local request_items = build_request_items(
            turn.request,
            turn.index,
            previous_request_blocks
        )
        local joined_to_request_header = true
        for _, item in ipairs(request_items) do
            local join_with_previous = joined_to_request_header
            joined_to_request_header = false

            if item.type == "lines" then
                append_block(
                    apply_block_hierarchy(item.lines, HIERARCHY_LEVEL.detail),
                    { join_with_previous = join_with_previous }
                )
            elseif item.type == "request_content" and item.tracker then
                self._request_content_blocks[item.tracker.block_id] =
                    item.tracker
                local block_lines, highlight_ranges =
                    self:_prepare_request_content_block_lines(
                        item.tracker,
                        render_width
                    )
                append_block(block_lines, {
                    join_with_previous = join_with_previous,
                    fold = {
                        kind = "request_content",
                        highlight_ranges = highlight_ranges,
                        tracker = item.tracker,
                    },
                })
            end
        end

        local response_items = {}
        for _, node in ipairs(turn.response.nodes or {}) do
            if node.type == "tool_call" then
                local block =
                    self:_build_tool_call_block_from_node(node, previous_blocks)
                self:_register_interaction_tool_block(
                    block,
                    previous_blocks,
                    response_items
                )
            else
                response_items[#response_items + 1] = node
            end
        end

        local joined_to_response_header = false
        if #response_items > 0 and turn.response.provider_name then
            local header_lines =
                self:_build_agent_header_lines(turn.response.provider_name)
            append_block(header_lines, { meta = true })
            joined_to_response_header = true
        end

        for _, item in ipairs(response_items) do
            local join_with_previous = joined_to_response_header
            joined_to_response_header = false
            if item.type == "message" then
                local block_lines, chunk_boundaries =
                    build_semantic_content_lines(item.content_nodes)
                if #block_lines == 0 then
                    block_lines =
                        vim.split(item.text or "", "\n", { plain = true })
                    chunk_boundaries = {}
                end
                block_lines =
                    apply_block_hierarchy(block_lines, HIERARCHY_LEVEL.detail)
                offset_chunk_boundaries(
                    chunk_boundaries,
                    block_lines,
                    HIERARCHY_LEVEL.detail
                )
                append_block(block_lines, {
                    join_with_previous = join_with_previous,
                    chunk_boundaries = chunk_boundaries,
                })
            elseif item.type == "thought" then
                local block_lines, chunk_boundaries =
                    build_semantic_content_lines(item.content_nodes)
                if #block_lines == 0 then
                    block_lines =
                        vim.split(item.text or "", "\n", { plain = true })
                    chunk_boundaries = {}
                end
                block_lines =
                    apply_block_hierarchy(block_lines, HIERARCHY_LEVEL.detail)
                offset_chunk_boundaries(
                    chunk_boundaries,
                    block_lines,
                    HIERARCHY_LEVEL.detail
                )
                append_block(block_lines, {
                    thought = true,
                    join_with_previous = join_with_previous,
                    chunk_boundaries = chunk_boundaries,
                })
            elseif item.type == "plan" then
                append_block(build_plan_lines(item), {
                    join_with_previous = join_with_previous,
                })
            elseif item.type == "tool_call" and item.tracker then
                local block_lines, highlight_ranges =
                    self:_prepare_block_lines(item.tracker, render_width)
                append_block(block_lines, {
                    join_with_previous = join_with_previous,
                    fold = {
                        kind = item.tracker.kind or "other",
                        highlight_ranges = highlight_ranges,
                        tracker = item.tracker,
                    },
                })
            end
        end

        if turn.result then
            append_block(build_turn_result_lines(turn.result), { meta = true })
        end
    end

    self:_with_modifiable_and_notify_change(function(bufnr)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_TOOL_BLOCKS, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_DIFF_HIGHLIGHTS, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_THOUGHT, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_TRANSCRIPT_META, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_CHUNK_BOUNDARIES, 0, -1)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

        for _, block in ipairs(meta_blocks) do
            self:_apply_transcript_meta_highlights(block.start_row, block.lines)
        end

        for _, block in ipairs(thought_blocks) do
            self:_apply_thought_block_highlights(block.start_row, block.end_row)
        end

        for _, block in ipairs(chunk_boundary_blocks) do
            self:_apply_chunk_boundary_highlights(
                block.start_row,
                block.boundaries
            )
        end

        for _, block in ipairs(fold_blocks) do
            self:_apply_block_highlights(
                bufnr,
                block.start_row,
                block.end_row,
                block.kind or "other",
                block.highlight_ranges or {}
            )

            block.tracker.extmark_id = vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_TOOL_BLOCKS,
                block.start_row,
                0,
                {
                    end_row = block.end_row,
                    right_gravity = false,
                }
            )
        end
    end)
end

return MessageWriter
