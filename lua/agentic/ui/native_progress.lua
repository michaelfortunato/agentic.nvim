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

--- @return boolean supported
function M.is_supported()
    return vim.fn.has("nvim-0.12") == 1
end

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
--- @return integer|string|nil id
--- @return boolean ok
function M.update(opts)
    if not M.is_supported() then
        return nil, false
    end

    local ok, progress_id = pcall(
        vim.api.nvim_echo,
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

    if not ok then
        return nil, false
    end

    local numeric_progress_id = tonumber(progress_id)
    if numeric_progress_id ~= nil then
        return numeric_progress_id, true
    end

    if progress_id ~= nil then
        return tostring(progress_id), true
    end

    return opts.id, true
end

return M
