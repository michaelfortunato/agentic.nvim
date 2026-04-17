local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local CardRenderer = require("agentic.ui.message_writer.card_renderer")
local Decorations = require("agentic.ui.message_writer.decorations")
local TranscriptRenderer =
    require("agentic.ui.message_writer.transcript_renderer")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")

--- @alias agentic.ui.MessageWriter.HighlightRangeType "comment"|"old"|"new"|"new_modification"|"span"
--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type agentic.ui.MessageWriter.HighlightRangeType Type of highlight to apply
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
--- @field turn_id? integer
--- @field group_key? string
--- @field extmark_id? integer Range extmark spanning the block
--- @field status? agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field permission_state? "requested"|"approved"|"rejected"|"dismissed"|nil
--- @field content_items? agentic.acp.ACPToolCallContent[]
--- @field content_nodes? agentic.session.ToolCallContentNode[]
--- @field terminal_id? string
--- @field collapsed? boolean
--- @field public _diff_sources? table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field public _diff_source_order? string[]

--- @class agentic.ui.MessageWriter.RequestContentBlock
--- @field block_id string
--- @field extmark_id? integer
--- @field content_node agentic.session.InteractionContentNode
--- @field collapsed boolean

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field public _request_content_blocks table<string, agentic.ui.MessageWriter.RequestContentBlock>
--- @field _should_auto_scroll_fn? fun(): boolean
--- @field _scroll_to_bottom_fn? fun()
--- @field _scroll_timer? uv.uv_timer_t
--- @field _scroll_scheduled? boolean
--- @field _content_changed_listeners table<integer, fun()>
--- @field _next_content_listener_id integer
--- @field public _current_turn_id integer
--- @field public _active_turn_diff_cards table<string, string>
--- @field public _provider_name? string
--- @field public _with_modifiable_and_notify_change fun(self: agentic.ui.MessageWriter, fn: fun(bufnr: integer): boolean|nil)
--- @field _last_interaction_session? agentic.session.InteractionSession
--- @field _last_render_opts? table|nil
local MessageWriter = {}
MessageWriter.__index = MessageWriter

local DEFAULT_SCROLL_DEBOUNCE_MS = 150

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

    return setmetatable({
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
    return CardRenderer.get_active_diff_group_id(self, tool_call_block)
end

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_merge_diff_source(tracker, tool_call_block)
    CardRenderer.merge_diff_source(self, tracker, tool_call_block)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_initialize_diff_group(tool_call_block)
    return CardRenderer.initialize_diff_group(self, tool_call_block)
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
    Decorations.apply_thought_block_highlights(self, start_row, end_row)
end

--- @param start_row integer
--- @param lines string[]
function MessageWriter:_apply_transcript_meta_highlights(start_row, lines)
    Decorations.apply_transcript_meta_highlights(self, start_row, lines)
end

--- @param bufnr integer
--- @return boolean
function MessageWriter:_check_auto_scroll(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return true
    end

    local threshold = Config.auto_scroll and Config.auto_scroll.threshold
    if threshold == nil or threshold <= 0 then
        return false
    end

    local winid = wins[1]
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

    timer = assert(vim.uv.new_timer())
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
--- @param render_width integer|nil
--- @return string[]
--- @return agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_prepare_block_lines(tool_call_block, render_width)
    return CardRenderer.prepare_block_lines(self, tool_call_block, render_width)
end

--- @param buffer_line integer
--- @return agentic.ui.MessageWriter.ToolCallBlock|agentic.ui.MessageWriter.RequestContentBlock|nil
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

--- @param bufnr integer
--- @param start_row integer
--- @param end_row integer
--- @param kind string
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_apply_block_highlights(
    bufnr,
    start_row,
    end_row,
    kind,
    highlight_ranges
)
    Decorations.apply_block_highlights(
        self,
        bufnr,
        start_row,
        end_row,
        kind,
        highlight_ranges
    )
end

--- @param start_row integer
--- @param boundaries agentic.ui.MessageWriter.ChunkBoundary[]|nil
function MessageWriter:_apply_chunk_boundary_highlights(start_row, boundaries)
    Decorations.apply_chunk_boundary_highlights(self, start_row, boundaries)
end

--- @param start_row integer
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_apply_diff_highlights(start_row, highlight_ranges)
    Decorations.apply_diff_highlights(self, start_row, highlight_ranges)
end

--- @param tracker agentic.ui.MessageWriter.RequestContentBlock
--- @param render_width integer|nil
--- @return string[]
--- @return agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_prepare_request_content_block_lines(
    tracker,
    render_width
)
    return CardRenderer.prepare_request_content_block_lines(
        self,
        tracker,
        render_width
    )
end

--- @param node agentic.session.InteractionToolCallNode
--- @param previous_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @return agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_build_tool_call_block_from_node(node, previous_blocks)
    return CardRenderer.build_tool_call_block_from_node(
        self,
        node,
        previous_blocks
    )
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param previous_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param ordered_items table[]
function MessageWriter:_register_interaction_tool_block(
    tool_call_block,
    previous_blocks,
    ordered_items
)
    CardRenderer.register_interaction_tool_block(
        self,
        tool_call_block,
        previous_blocks,
        ordered_items
    )
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

    local render_state = TranscriptRenderer.build_render_state(
        self,
        interaction_session,
        opts,
        previous_blocks,
        previous_request_blocks
    )

    Decorations.apply_render_state(self, render_state)
end

return MessageWriter
