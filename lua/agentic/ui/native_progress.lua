local Theme = require("agentic.theme")

local M = {}

--- @alias agentic.ui.NativeProgress.Status
--- | "running"
--- | "success"
--- | "failed"
--- | "cancel"

--- @class agentic.ui.NativeProgress.Update
--- @field id? integer|string
--- @field title string
--- @field source string
--- @field message string
--- @field status agentic.ui.NativeProgress.Status
--- @field percent integer
--- @field hl_group? string
--- @field data? table

--- @param percent integer
--- @return integer clamped_percent
local function clamp_percent(percent)
    return math.max(0, math.min(100, math.floor(tonumber(percent) or 0)))
end

--- Emits a native Nvim progress message.
---
--- Nvim turns progress messages into Progress events; the TUI renders those
--- Progress events as native terminal progress bars through OSC 9;4.
--- @param opts agentic.ui.NativeProgress.Update
--- @return integer|string id
function M.update(opts)
    local progress_id = vim.api.nvim_echo(
        {
            {
                opts.message,
                opts.hl_group or Theme.HL_GROUPS.ACTIVITY_TEXT,
            },
        },
        true,
        {
            id = opts.id,
            kind = "progress",
            source = opts.source,
            status = opts.status,
            percent = clamp_percent(opts.percent),
            title = opts.title,
            data = opts.data,
        }
    )

    return progress_id
end

return M
