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

local NativeProgress = require("agentic.ui.native_progress")
local Theme = require("agentic.theme")

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
--- @field _bufnr number Chat buffer number associated with this activity
--- @field _state? agentic.Theme.SpinnerState Current animation state
--- @field _detail? string Optional secondary detail for the current state
--- @field _progress_id? integer|string Native progress message id
local StatusAnimation = {}
StatusAnimation.__index = StatusAnimation

--- @param bufnr number
--- @return agentic.ui.StatusAnimation
function StatusAnimation:new(bufnr)
    local instance = setmetatable({
        _bufnr = bufnr,
        _state = nil,
        _detail = nil,
        _progress_id = nil,
    }, StatusAnimation)

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
        self:_update_progress()
        return
    end
end

function StatusAnimation:stop()
    self._state = nil
    self._detail = nil
    self:_dismiss_progress()
end

function StatusAnimation:_dismiss_progress()
    if not self._progress_id then
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
end

function StatusAnimation:_update_progress()
    if not self._state then
        return
    end

    local progress_id = NativeProgress.update({
        id = self._progress_id,
        title = PROGRESS_TITLE,
        source = PROGRESS_SOURCE,
        message = format_activity_label(self._state, self._detail),
        status = "running",
        percent = PROGRESS_PERCENT[self._state] or PROGRESS_PERCENT.generating,
        hl_group = Theme.HL_GROUPS.ACTIVITY_TEXT,
    })

    if self._progress_id == nil then
        self._progress_id = progress_id
    end
end

return StatusAnimation
