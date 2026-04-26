--- StatusAnimation reports AgenticChat activity.
---
--- ## Usage
--- ```lua
--- local StatusAnimation = require("agentic.ui.status_animation")
--- local animator = StatusAnimation:new(bufnr)
--- animator:start("generating")
--- -- later...
--- animator:stop()
--- ```
---

local Config = require("agentic.config")
local NativeProgress = require("agentic.ui.native_progress")
local Theme = require("agentic.theme")

local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")
local PROGRESS_TITLE = "Agentic Chat"
local PROGRESS_SOURCE = "agentic.nvim.chat"

--- @type table<agentic.Theme.SpinnerState, number>
local PROGRESS_PERCENT = {
    busy = 5,
    thinking = 20,
    generating = 55,
    searching = 72,
    waiting = 85,
}

--- @type table<agentic.Theme.SpinnerState, number>
local TIMING = {
    generating = 320,
    thinking = 340,
    searching = 380,
    busy = 200,
    waiting = 650,
}

local STATE_LABELS = {
    generating = "Working",
    thinking = "Thinking",
    searching = "Using tools",
    busy = "Starting session",
    waiting = "Waiting for approval",
}

--- @param state agentic.Theme.SpinnerState
--- @param detail string|nil
--- @return string
local function format_activity_label(state, detail)
    local label = STATE_LABELS[state] or state
    if detail and detail ~= "" then
        return string.format("%s · %s", label, detail)
    end

    return label
end

--- @class agentic.ui.StatusAnimation
--- @field _bufnr number Buffer number where animation is rendered
--- @field _state? agentic.Theme.SpinnerState Current animation state
--- @field _detail? string Optional secondary detail for the current state
--- @field _next_frame_handle? uv.uv_timer_t One-shot deferred function handle from vim.defer_fn
--- @field _spinner_idx number Current spinner frame index
--- @field _extmark_id? number Current extmark ID
--- @field _attached boolean
--- @field _render_scheduled boolean
--- @field _progress_id? integer|string Native progress message id
--- @field _progress_reported boolean
--- @field _use_native_progress boolean
local StatusAnimation = {}
StatusAnimation.__index = StatusAnimation

--- @param bufnr number
--- @return agentic.ui.StatusAnimation
function StatusAnimation:new(bufnr)
    local instance = setmetatable({
        _bufnr = bufnr,
        _state = nil,
        _detail = nil,
        _next_frame_handle = nil,
        _spinner_idx = 1,
        _extmark_id = nil,
        _attached = false,
        _render_scheduled = false,
        _progress_id = nil,
        _progress_reported = false,
        _use_native_progress = NativeProgress.is_supported(),
    }, StatusAnimation)

    if not instance._use_native_progress then
        instance:_attach()
    end

    return instance
end

--- Start or update the current activity state.
--- @param state agentic.Theme.SpinnerState
--- @param opts {detail?: string|nil}|nil
function StatusAnimation:start(state, opts)
    opts = opts or {}
    local changed = self._state ~= state or self._detail ~= opts.detail

    self._state = state
    self._detail = opts.detail

    if changed then
        self._spinner_idx = 1
    end

    if self._use_native_progress then
        if not changed then
            return
        end

        self:_update_progress()
        return
    end

    self:_render_frame()
end

function StatusAnimation:stop()
    self._state = nil
    self._detail = nil

    if self._use_native_progress then
        self:_dismiss_progress()
        return
    end

    self:_stop_timer()

    if self._extmark_id then
        pcall(
            vim.api.nvim_buf_del_extmark,
            self._bufnr,
            NS_ANIMATION,
            self._extmark_id
        )
    end

    self._extmark_id = nil
end

function StatusAnimation:_dismiss_progress()
    if not self._progress_id and not self._progress_reported then
        return
    end

    NativeProgress.update({
        id = self._progress_id,
        title = PROGRESS_TITLE,
        source = PROGRESS_SOURCE,
        message = "dismissed",
        status = "success",
        percent = 100,
        hl_group = Theme.HL_GROUPS.ACTIVITY_TEXT,
    })

    self._progress_id = nil
    self._progress_reported = false
end

function StatusAnimation:_update_progress()
    if not self._state then
        return
    end

    local progress_id, ok = NativeProgress.update({
        id = self._progress_id,
        title = PROGRESS_TITLE,
        source = PROGRESS_SOURCE,
        message = format_activity_label(self._state, self._detail),
        status = "running",
        percent = PROGRESS_PERCENT[self._state] or PROGRESS_PERCENT.generating,
        hl_group = Theme.HL_GROUPS.ACTIVITY_TEXT,
    })

    if ok then
        self._progress_reported = true
    end

    if ok and self._progress_id == nil and progress_id ~= nil then
        self._progress_id = progress_id
    end
end

function StatusAnimation:_attach()
    if self._attached or not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    self._attached = vim.api.nvim_buf_attach(self._bufnr, false, {
        on_lines = function()
            if self._state then
                self:_queue_render()
            end
        end,
        on_detach = function()
            self._attached = false
            self._render_scheduled = false
            self:_stop_timer()
        end,
    })
end

function StatusAnimation:_queue_render()
    if self._render_scheduled then
        return
    end

    self._render_scheduled = true
    vim.schedule(function()
        self._render_scheduled = false
        if self._state then
            self:_render_frame()
        end
    end)
end

function StatusAnimation:_stop_timer()
    if not self._next_frame_handle then
        return
    end

    pcall(function()
        self._next_frame_handle:stop()
    end)
    pcall(function()
        self._next_frame_handle:close()
    end)
    self._next_frame_handle = nil
end

function StatusAnimation:_render_frame()
    if not self._state or not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local spinner_chars = Config.spinner_chars[self._state]
        or Config.spinner_chars.generating

    local char = spinner_chars[self._spinner_idx] or spinner_chars[1]

    self._spinner_idx = (self._spinner_idx % #spinner_chars) + 1

    local hl_group = Theme.get_spinner_hl_group(self._state)
    local text_hl_group = Theme.get_activity_text_hl_group()
    local lines = vim.api.nvim_buf_get_lines(self._bufnr, 0, -1, false)
    local line_num = math.max(0, #lines - 1)

    local virt_text = {
        { char, hl_group },
        {
            " " .. format_activity_label(self._state, self._detail),
            text_hl_group,
        },
    }

    local delay = TIMING[self._state] or TIMING.generating

    self:_stop_timer()
    self._extmark_id =
        vim.api.nvim_buf_set_extmark(self._bufnr, NS_ANIMATION, line_num, 0, {
            id = self._extmark_id,
            virt_lines = { virt_text },
            virt_lines_above = false,
        })

    self._next_frame_handle = vim.defer_fn(function()
        self:_render_frame()
    end, delay)
end

return StatusAnimation
