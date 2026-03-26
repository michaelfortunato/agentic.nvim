local FloatingMessage = require("agentic.ui.floating_message")

--- @class agentic.ui.KeymapHelp.Entry
--- @field lhs string
--- @field desc string
--- @field modes string[]

--- @class agentic.ui.KeymapHelp
local KeymapHelp = {}

local HELP_MODES = { "n", "i", "v", "x", "s", "o", "c", "t" }
local MODE_ORDER = {
    n = 1,
    i = 2,
    v = 3,
    x = 4,
    s = 5,
    o = 6,
    c = 7,
    t = 8,
}

--- @param desc string|nil
--- @return string|nil
local function normalize_desc(desc)
    if type(desc) ~= "string" then
        return nil
    end

    local trimmed = vim.trim(desc)
    if trimmed == "" then
        return nil
    end

    local normalized = trimmed:gsub("^Agentic:?%s*", "")
    return normalized
end

--- @param modes string[]
--- @param mode string
local function add_mode(modes, mode)
    for _, existing in ipairs(modes) do
        if existing == mode then
            return
        end
    end

    modes[#modes + 1] = mode
end

--- @param bufnr integer
--- @return agentic.ui.KeymapHelp.Entry[]
local function collect_entries(bufnr)
    --- @type table<string, agentic.ui.KeymapHelp.Entry>
    local entries_by_key = {}

    for _, mode in ipairs(HELP_MODES) do
        local keymaps = vim.api.nvim_buf_get_keymap(bufnr, mode)
        for _, keymap in ipairs(keymaps) do
            local desc = normalize_desc(keymap.desc)
            if desc then
                local entry_key = string.format("%s\0%s", keymap.lhs, desc)
                local entry = entries_by_key[entry_key]

                if not entry then
                    entry = {
                        lhs = keymap.lhs,
                        desc = desc,
                        modes = {},
                    }
                    entries_by_key[entry_key] = entry
                end

                add_mode(entry.modes, keymap.mode or mode)
            end
        end
    end

    --- @type agentic.ui.KeymapHelp.Entry[]
    local entries = {}
    for _, entry in pairs(entries_by_key) do
        table.sort(entry.modes, function(left, right)
            return (MODE_ORDER[left] or 99) < (MODE_ORDER[right] or 99)
        end)
        entries[#entries + 1] = entry
    end

    table.sort(entries, function(left, right)
        local left_mode = left.modes[1] or ""
        local right_mode = right.modes[1] or ""

        if left_mode ~= right_mode then
            return (MODE_ORDER[left_mode] or 99)
                < (MODE_ORDER[right_mode] or 99)
        end

        if left.lhs ~= right.lhs then
            return left.lhs < right.lhs
        end

        return left.desc < right.desc
    end)

    return entries
end

--- @param bufnr integer
--- @return string[]
local function build_body(bufnr)
    local entries = collect_entries(bufnr)
    if #entries == 0 then
        return {
            "No buffer-local Agentic keymaps are registered for this window.",
        }
    end

    local lines = {
        "Available keymaps:",
        "",
    }

    for _, entry in ipairs(entries) do
        lines[#lines + 1] = string.format(
            "- `%s` [%s] %s",
            entry.lhs,
            table.concat(entry.modes, "/"),
            entry.desc
        )
    end

    return lines
end

--- @param bufnr integer
--- @param opts {title?: string, width_ratio?: number}|nil
function KeymapHelp.show_for_buffer(bufnr, opts)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    opts = opts or {}

    FloatingMessage.show({
        body = build_body(bufnr),
        title = opts.title or " Agentic Keymaps ",
        width_ratio = opts.width_ratio or 0.45,
        filetype = "markdown",
    })
end

return KeymapHelp
