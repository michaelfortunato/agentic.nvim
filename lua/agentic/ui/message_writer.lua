local ToolCallDiff = require("agentic.ui.tool_call_diff")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffPreview = require("agentic.ui.diff_preview")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_STATUS = vim.api.nvim_create_namespace("agentic_status_footer")

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)
--- @field display_prefix_len? integer Byte length of any diff marker prefix rendered before the content

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
--- @field decoration_extmark_ids? integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field status? agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff

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
local MessageWriter = {}
MessageWriter.__index = MessageWriter

local DEFAULT_SCROLL_DEBOUNCE_MS = 150
local MAX_DIFF_CARD_HUNKS = 2
local MAX_DIFF_CARD_CHANGES = 4

local DIFF_TOOL_KINDS = {
    edit = true,
    create = true,
    write = true,
}

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
    }, self)

    return instance
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

--- Writes a full message to the chat buffer and append two blank lines after
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    local text = update.content
        and update.content.type == "text"
        and update.content.text

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function()
        self:_append_lines(lines)
        self:_append_lines({ "", "" })
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

    if
        self._last_message_type == "agent_thought_chunk"
        and update.sessionUpdate == "agent_message_chunk"
    then
        -- Different message type, add newline before appending, to create visual separation
        -- only for thought -> message
        text = "\n\n" .. text
    end

    self._last_message_type = update.sessionUpdate

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local last_line = vim.api.nvim_buf_line_count(bufnr) - 1

        local current_line = vim.api.nvim_buf_get_lines(
            bufnr,
            last_line,
            last_line + 1,
            false
        )[1] or ""
        local start_col = #current_line

        local lines_to_write = vim.split(text, "\n", { plain = true })

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
            Logger.debug("Failed to set text in buffer", err, lines_to_write)
        end
    end)
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
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_and_notify_change(function(bufnr)
        local kind = tool_call_block.kind

        -- Always add a leading blank line for spacing the previous message chunk
        self:_append_lines({ "" })

        local start_row = vim.api.nvim_buf_line_count(bufnr)
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

        tool_call_block.decoration_extmark_ids =
            ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = end_row - 1,
                footer_line = end_row,
                hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
            })

        tool_call_block.extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
            })

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        self:_apply_header_highlight(start_row, tool_call_block.status)
        self:_apply_status_footer(end_row, tool_call_block.status)

        self:_append_lines({ "", "" })
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

    -- Some ACP providers don't send the diff on the first tool_call
    local already_has_diff = tracker.diff ~= nil
    local previous_body = tracker.body

    tracker = vim.tbl_deep_extend("force", tracker, tool_call_block)

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
        -- Diff blocks don't change after the initial render
        -- only update status highlights - don't replace content
        if already_has_diff then
            if old_end_row > vim.api.nvim_buf_line_count(bufnr) then
                Logger.debug("Footer line index out of bounds", {
                    old_end_row = old_end_row,
                    line_count = vim.api.nvim_buf_line_count(bufnr),
                })
                return false
            end

            -- Re-write header line so updated kind/argument are visible
            local header = self:_build_header_line(tracker)
            vim.api.nvim_buf_set_lines(
                bufnr,
                start_row,
                start_row + 1,
                false,
                { header }
            )

            self:_clear_decoration_extmarks(tracker.decoration_extmark_ids)
            tracker.decoration_extmark_ids =
                self:_render_decorations(start_row, old_end_row)

            self:_clear_status_namespace(start_row, old_end_row)
            self:_apply_status_highlights_if_present(
                start_row,
                old_end_row,
                tracker.status
            )

            return false
        end

        self:_clear_decoration_extmarks(tracker.decoration_extmark_ids)
        self:_clear_status_namespace(start_row, old_end_row)

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

        tracker.decoration_extmark_ids =
            self:_render_decorations(start_row, new_end_row)

        self:_apply_status_highlights_if_present(
            start_row,
            new_end_row,
            tracker.status
        )
    end)
end

--- Build the header line string for a tool call block
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string header
function MessageWriter:_build_header_line(tool_call_block)
    local kind = tool_call_block.kind or "other"
    local argument = tool_call_block.argument or ""

    if DIFF_TOOL_KINDS[kind] and tool_call_block.file_path then
        local basename = vim.fs.basename(tool_call_block.file_path)
        if basename and basename ~= "" then
            argument = basename
        end
    end

    -- Sanitize argument to prevent newlines in the header line
    -- nvim_buf_set_lines doesn't accept array items with embedded newlines
    argument = argument:gsub("\n", "\\n")

    return string.format(" %s(%s) ", kind, argument)
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
local function append_comment_line(lines, highlight_ranges, text)
    table.insert(lines, text)
    highlight_ranges[#highlight_ranges + 1] = {
        type = "comment",
        line_index = #lines - 1,
    }
end

--- @class agentic.ui.MessageWriter.DiffCardStats
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

--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @return agentic.ui.MessageWriter.DiffCardStats
--- @return agentic.ui.MessageWriter.DiffCardSample[]
--- @return integer sampled_changes
local function summarize_diff_blocks(diff_blocks)
    --- @type agentic.ui.MessageWriter.DiffCardStats
    local stats = {
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

--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param sample agentic.ui.MessageWriter.DiffCardSample
local function append_diff_card_sample(lines, highlight_ranges, sample)
    append_comment_line(lines, highlight_ranges, sample.label)

    for _, pair in ipairs(sample.pairs) do
        if pair.old_line and pair.new_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "old",
                pair.old_line,
                pair.old_line,
                pair.new_line,
                "- "
            )
            append_diff_line(
                lines,
                highlight_ranges,
                "new_modification",
                pair.new_line,
                pair.old_line,
                pair.new_line,
                "+ "
            )
        elseif pair.old_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "old",
                pair.old_line,
                pair.old_line,
                nil,
                "- "
            )
        elseif pair.new_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "new",
                pair.new_line,
                nil,
                pair.new_line,
                "+ "
            )
        end
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param lines string[]
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
local function append_diff_card(lines, highlight_ranges, tool_call_block)
    local diff_path = tool_call_block.file_path or ""
    local diff_blocks = ToolCallDiff.extract_diff_blocks({
        path = diff_path,
        old_text = tool_call_block.diff.old,
        new_text = tool_call_block.diff.new,
        replace_all = tool_call_block.diff.all,
    })

    if diff_path ~= "" then
        append_comment_line(
            lines,
            highlight_ranges,
            format_compact_path(diff_path)
        )
    end

    local stats, samples, sampled_changes = summarize_diff_blocks(diff_blocks)
    append_comment_line(lines, highlight_ranges, build_diff_summary_line(stats))

    local hint_lines = {}
    local hint_line_index =
        DiffPreview.add_navigation_hint(tool_call_block, hint_lines)
    if hint_line_index ~= nil then
        append_comment_line(
            lines,
            highlight_ranges,
            hint_lines[hint_line_index + 1]
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
            string.format(
                "... %s in buffer review",
                pluralize(total_changes - sampled_changes, "more change")
            )
        )
    end
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(tool_call_block)
    local kind = tool_call_block.kind

    local lines = {
        self:_build_header_line(tool_call_block),
    }

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    if kind == "read" then
        -- Count lines from content, we don't want to show full content that was read
        local line_count = tool_call_block.body and #tool_call_block.body or 0

        if line_count > 0 then
            table.insert(lines, string.format("Read %d lines", line_count))

            --- @type agentic.ui.MessageWriter.HighlightRange
            local range = {
                type = "comment",
                line_index = #lines - 1,
            }

            table.insert(highlight_ranges, range)
        end
    elseif tool_call_block.diff then
        append_diff_card(lines, highlight_ranges, tool_call_block)
    else
        if tool_call_block.body then
            vim.list_extend(lines, tool_call_block.body)
        end
    end

    table.insert(lines, "")

    return lines, highlight_ranges
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
    elseif kind ~= "edit" and kind ~= "switch_mode" then
        -- Apply Comment highlight for non-edit blocks without diffs
        for line_idx = start_row + 1, end_row - 1 do
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                line_idx,
                line_idx + 1,
                false
            )[1]
            if line and #line > 0 then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    line_idx,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
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
                        hl_group = "Comment",
                    }
                )
            end
        end
    end
end

--- @param header_line integer 0-indexed header line number
--- @param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_header_highlight(header_line, status)
    if not status or status == "" then
        return
    end

    local line = vim.api.nvim_buf_get_lines(
        self.bufnr,
        header_line,
        header_line + 1,
        false
    )[1]
    if not line then
        return
    end

    local hl_group = Theme.get_status_hl_group(status)
    vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, header_line, 0, {
        end_col = #line,
        hl_group = hl_group,
    })
end

--- @param footer_line integer 0-indexed footer line number
--- @param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_status_footer(footer_line, status)
    if
        not vim.api.nvim_buf_is_valid(self.bufnr)
        or not status
        or status == ""
    then
        return
    end

    local icons = Config.status_icons or {}

    local icon = icons[status] or ""
    local hl_group = Theme.get_status_hl_group(status)

    vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, footer_line, 0, {
        virt_text = {
            { string.format(" %s %s ", icon, status), hl_group },
        },
        virt_text_pos = "overlay",
    })
end

--- @param ids integer[]|nil
function MessageWriter:_clear_decoration_extmarks(ids)
    if not ids then
        return
    end

    for _, id in ipairs(ids) do
        pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NS_DECORATIONS, id)
    end
end

--- @param start_row integer
--- @param end_row integer
--- @return integer[] decoration_extmark_ids
function MessageWriter:_render_decorations(start_row, end_row)
    return ExtmarkBlock.render_block(self.bufnr, NS_DECORATIONS, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- @param start_row integer
--- @param end_row integer
function MessageWriter:_clear_status_namespace(start_row, end_row)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_STATUS,
        start_row,
        end_row + 1
    )
end

--- @param start_row integer
--- @param end_row integer
--- @param status string|nil
function MessageWriter:_apply_status_highlights_if_present(
    start_row,
    end_row,
    status
)
    if status then
        self:_apply_header_highlight(start_row, status)
        self:_apply_status_footer(end_row, status)
    end
end

return MessageWriter
