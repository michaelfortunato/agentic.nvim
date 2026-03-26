--- StatusAnimation module for displaying chat activity in AgenticChat.
---
--- This module renders a stable bottom-of-buffer activity line using extmarks
--- and a subdued timer-based accent. The state label is the source of truth;
--- animation is only a visual hint.
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
local Theme = require("agentic.theme")

local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

--- @type table<agentic.Theme.SpinnerState, number>
local TIMING = {
    generating = 320,
    thinking = 520,
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

--- @class agentic.ui.StatusAnimation
--- @field _bufnr number Buffer number where animation is rendered
--- @field _state? agentic.Theme.SpinnerState Current animation state
--- @field _detail? string Optional secondary detail for the current state
--- @field _next_frame_handle? uv.uv_timer_t One-shot deferred function handle from vim.defer_fn
--- @field _spinner_idx number Current spinner frame index
--- @field _extmark_id? number Current extmark ID
--- @field _attached boolean
--- @field _render_scheduled boolean
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
    }, StatusAnimation)

    instance:_attach()
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

    self:_render_frame()
end

function StatusAnimation:stop()
    self._state = nil
    self._detail = nil

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

    local label = STATE_LABELS[self._state] or self._state
    if self._detail and self._detail ~= "" then
        label = string.format("%s · %s", label, self._detail)
    end

    local hl_group = Theme.get_spinner_hl_group(self._state)
    local text_hl_group = Theme.get_activity_text_hl_group()
    local lines = vim.api.nvim_buf_get_lines(self._bufnr, 0, -1, false)
    local line_num = math.max(0, #lines - 1)

    local virt_text = {
        { "  ", "Normal" },
        { char, hl_group },
        { "  " .. label, text_hl_group },
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
