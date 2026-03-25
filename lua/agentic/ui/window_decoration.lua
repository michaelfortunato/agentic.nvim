--- Window decoration module for managing window titles, statuslines, and highlights.
---
--- This module provides utilities to render headers (winbar) and statuslines for windows.
---
--- ## Lualine Compatibility
---
--- If you're using lualine or similar statusline plugins, ensure windows have their
--- statusline set to prevent the plugin from hijacking them:
---
--- ```lua
--- vim.api.nvim_set_option_value("statusline", " ", { win = winid })
--- ```
---
--- Alternatively, configure lualine to ignore specific filetypes:
--- ```lua
--- require('lualine').setup({
---   options = {
---     disabled_filetypes = {
---       statusline = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles', 'AgenticDiagnostics' },
---       winbar = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles', 'AgenticDiagnostics' },
---     }
---   }
--- })
--- ```

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

--- @class agentic.ui.WindowDecoration
local WindowDecoration = {}

--- @type agentic.ui.ChatWidget.Headers
local WINDOW_HEADERS = {
    chat = {
        title = "󰻞 Agentic Chat",
    },
    input = { title = "󰦨 Prompt", suffix = "<S-Tab>: config · <C-s>: submit" },
    code = {
        title = "󰪸 Selected Code Snippets",
        suffix = "d: remove block",
    },
    files = {
        title = " Referenced Files",
        suffix = "d: remove file",
    },
    diagnostics = {
        title = " Diagnostics",
        suffix = "d: remove diagnostic",
    },
    todos = {
        title = " Tasks list",
    },
}

--- @class agentic.ui.WindowDecoration.Config
--- @field align? "left"|"center"|"right" Header text alignment
--- @field hl? string Highlight group for the header text
--- @field reverse_hl? string Highlight group for the separator
local default_config = {
    align = "left",
    hl = Theme.HL_GROUPS.WIN_BAR_TITLE,
    reverse_hl = Theme.HL_GROUPS.WIN_BAR_HINT,
}

--- Concatenates header parts (title, context, suffix) into a single string
--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @return string header_text
local function concat_header_parts(parts)
    local pieces = { parts.title }
    if parts.context ~= nil and parts.context ~= "" then
        table.insert(pieces, parts.context)
    end
    if parts.suffix ~= nil and parts.suffix ~= "" then
        table.insert(pieces, parts.suffix)
    end
    return table.concat(pieces, " | ")
end

--- @param text string
--- @return string
local function escape_status_text(text)
    return tostring(text):gsub("%%", "%%%%")
end

--- @param option string
--- @return table<string, string>
local function parse_option_map(option)
    local items = {}
    for entry in vim.gsplit(option or "", ",", { plain = true }) do
        if entry ~= "" then
            local key, value = entry:match("^([^:]+):(.*)$")
            if key and value then
                items[key] = value
            end
        end
    end
    return items
end

--- @param items table<string, string>
--- @return string
local function serialize_option_map(items)
    local parts = {}
    for key, value in pairs(items) do
        parts[#parts + 1] = key .. ":" .. value
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @param base_hl string
--- @return string
local function build_structured_status_text(parts, base_hl)
    local segments = {
        string.format(
            "%%#%s# %s ",
            Theme.HL_GROUPS.WIN_BAR_TITLE,
            escape_status_text(parts.title)
        ),
    }

    if parts.context and parts.context ~= "" then
        segments[#segments + 1] = string.format(
            "%%#%s# %s ",
            Theme.HL_GROUPS.WIN_BAR_CONTEXT,
            escape_status_text(parts.context)
        )
    end

    local text = string.format("%%#%s#", base_hl) .. table.concat(segments)

    if parts.suffix and parts.suffix ~= "" then
        text = text
            .. "%="
            .. string.format(
                "%%#%s# %s ",
                Theme.HL_GROUPS.WIN_BAR_HINT,
                escape_status_text(parts.suffix)
            )
    end

    return text
end

--- @param text string
--- @param base_hl string
--- @return string
local function build_fallback_status_text(text, base_hl)
    return string.format("%%#%s# %s ", base_hl, escape_status_text(text))
end

--- Gets or initializes headers for a tabpage
--- @param tab_page_id integer
--- @return agentic.ui.ChatWidget.Headers
function WindowDecoration.get_headers_state(tab_page_id)
    if vim.t[tab_page_id].agentic_headers == nil then
        vim.t[tab_page_id].agentic_headers = vim.deepcopy(WINDOW_HEADERS)
    end
    return vim.t[tab_page_id].agentic_headers
end

--- Sets headers for a tabpage
--- @param tab_page_id integer
--- @param headers agentic.ui.ChatWidget.Headers
function WindowDecoration.set_headers_state(tab_page_id, headers)
    if vim.api.nvim_tabpage_is_valid(tab_page_id) then
        vim.t[tab_page_id].agentic_headers = headers
    end
end

--- Resolves the final header state applying user customization
--- @param dynamic_header agentic.ui.ChatWidget.HeaderParts Runtime header parts
--- @param window_name string Window name for Config.headers lookup and error messages
--- @return agentic.ui.ChatWidget.HeaderParts|nil header_parts Structured header data when available
--- @return string|nil header_text The resolved header text or nil for empty
--- @return string|nil error_message Error message if user function failed
local function resolve_header(dynamic_header, window_name)
    local user_header = Config.headers and Config.headers[window_name]
    -- No user customization: use default parts
    if user_header == nil then
        return vim.deepcopy(dynamic_header),
            concat_header_parts(dynamic_header),
            nil
    end

    -- User function: call it and validate return
    if type(user_header) == "function" then
        local ok, result = pcall(user_header, dynamic_header)
        if not ok then
            return vim.deepcopy(dynamic_header),
                concat_header_parts(dynamic_header),
                string.format(
                    "Error in custom header function for '%s': %s",
                    window_name,
                    result
                )
        end
        if result == nil or result == "" then
            return nil, nil, nil -- User explicitly wants no header
        end
        if type(result) ~= "string" then
            return vim.deepcopy(dynamic_header),
                concat_header_parts(dynamic_header),
                string.format(
                    "Custom header function for '%s' must return string|nil, got %s",
                    window_name,
                    type(result)
                )
        end
        return nil, result, nil
    end

    -- User table: merge with dynamic header
    if type(user_header) == "table" then
        local merged = vim.tbl_extend("force", dynamic_header, user_header) --[[@as agentic.ui.ChatWidget.HeaderParts]]
        return merged, concat_header_parts(merged), nil
    end

    -- Invalid type: warn and use default
    return vim.deepcopy(dynamic_header),
        concat_header_parts(dynamic_header),
        string.format(
            "Header for '%s' must be function|table|nil, got %s",
            window_name,
            type(user_header)
        )
end

--- @param winid integer
--- @param header_parts agentic.ui.ChatWidget.HeaderParts|nil
--- @param header_text string
local function set_winbar(winid, header_parts, header_text)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    if header_text == "" then
        vim.api.nvim_set_option_value("winbar", " ", { win = winid })
        return
    end

    local opts = default_config
    local winbar_text
    if header_parts then
        winbar_text = build_structured_status_text(header_parts, opts.hl)
    else
        winbar_text = build_fallback_status_text(header_text, opts.hl)
    end

    vim.api.nvim_set_option_value("winbar", winbar_text, { win = winid })
end

--- @param winid integer
--- @param header_parts agentic.ui.ChatWidget.HeaderParts|nil
--- @param header_text string
local function set_statusline(winid, header_parts, header_text)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    if header_text == "" then
        vim.api.nvim_set_option_value("statusline", " ", { win = winid })
        return
    end

    local statusline_text
    if header_parts then
        statusline_text = build_structured_status_text(
            header_parts,
            Theme.HL_GROUPS.STATUS_LINE
        )
    else
        statusline_text =
            build_fallback_status_text(header_text, Theme.HL_GROUPS.STATUS_LINE)
    end

    vim.api.nvim_set_option_value(
        "statusline",
        statusline_text,
        { win = winid }
    )
end

--- Sets the buffer name based on header text and tab count
--- @param bufnr integer Buffer number
--- @param header_text string|nil Resolved header text
--- @param tab_page_id integer Tab page ID for suffix
local function set_buffer_name(bufnr, header_text, tab_page_id)
    if not header_text or header_text == "" then
        return
    end

    -- Determine if we should show tab suffix based on total tab count
    local total_tabs = #vim.api.nvim_list_tabpages()

    --- @type string|nil
    local buf_name
    if total_tabs > 1 then
        buf_name = string.format("%s (Tab %d)", header_text, tab_page_id)
    else
        buf_name = header_text
    end

    vim.api.nvim_buf_set_name(bufnr, buf_name)
end

--- @param winid integer
function WindowDecoration.apply_window_style(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    local winhl = parse_option_map(vim.wo[winid].winhighlight)
    winhl.WinSeparator = Theme.HL_GROUPS.WIN_SEPARATOR
    winhl.StatusLine = Theme.HL_GROUPS.STATUS_LINE
    winhl.StatusLineNC = Theme.HL_GROUPS.STATUS_LINE

    vim.api.nvim_set_option_value(
        "winhighlight",
        serialize_option_map(winhl),
        { win = winid }
    )
end

--- Renders a header for a window, handling user customization, winbar, and buffer naming
--- Derives all context from bufnr: winid, tab_page_id, and dynamic header from vim.t
--- @param bufnr integer Buffer number - stable reference to derive window and tab context
--- @param window_name string Name of the window (for Config.headers lookup and error messages)
--- @param context string|nil Optional context to set in header (e.g., "Mode: chat", "3 files")
function WindowDecoration.render_header(bufnr, window_name, context)
    vim.schedule(function()
        local winid = vim.fn.bufwinid(bufnr)
        if winid == -1 then
            -- Buffer not displayed in any window, skip rendering
            return
        end

        local tab_page_id = vim.api.nvim_win_get_tabpage(winid)

        local headers = WindowDecoration.get_headers_state(tab_page_id)
        local dynamic_header = headers[window_name]

        if not dynamic_header then
            Logger.debug(
                string.format(
                    "No header configuration found for window name '%s'",
                    window_name
                )
            )
            return
        end

        -- Set context if provided (must reassign to vim.t due to copy semantics)
        if context ~= nil then
            dynamic_header.context = context
            headers[window_name] = dynamic_header
            WindowDecoration.set_headers_state(tab_page_id, headers)
        end

        local header_parts, header_text, err =
            resolve_header(dynamic_header, window_name)

        if err then
            Logger.notify(err)
        end

        local text = (header_text and header_text ~= "") and header_text or ""

        WindowDecoration.apply_window_style(winid)
        set_winbar(winid, header_parts, text)
        set_statusline(winid, header_parts, text)
        set_buffer_name(bufnr, header_text, tab_page_id)
    end)
end

return WindowDecoration
