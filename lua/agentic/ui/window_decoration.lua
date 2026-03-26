--- Window decoration module for managing window titles and highlights.
---
--- This module provides utilities to render Agentic window labels and in-buffer context.
---
--- ## Lualine Compatibility
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
local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.ui.WindowDecoration
local WindowDecoration = {}
local NS_CHAT_CONTEXT = vim.api.nvim_create_namespace("agentic_chat_context")
local CHAT_CONTEXT_LINE_COUNT_KEY = "agentic_chat_context_line_count"

--- @type agentic.ui.ChatWidget.Headers
local WINDOW_HEADERS = {
    chat = {
        title = "󰻞 Agentic Chat",
    },
    queue = {
        title = "Agentic Queue",
        suffix = "<CR>: actions · !: send now · d: remove · Esc: prompt",
    },
    input = { title = "󰦨 Prompt", suffix = "<C-s>: submit" },
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

--- @param text string
--- @param max_width integer
--- @return string[]
local function wrap_context_text(text, max_width)
    max_width = math.max(8, max_width)

    --- @param segment string
    --- @return string[]
    local function wrap_segment(segment)
        local lines = {}
        local current = ""

        local function push_current()
            if current ~= "" then
                lines[#lines + 1] = current
                current = ""
            end
        end

        local function split_long_word(word)
            local pieces = {}
            local remaining = word

            while remaining ~= "" do
                local piece = remaining
                while
                    piece ~= ""
                    and vim.fn.strdisplaywidth(piece) > max_width
                do
                    piece = vim.fn.strcharpart(
                        piece,
                        0,
                        math.max(1, vim.fn.strchars(piece) - 1)
                    )
                end

                pieces[#pieces + 1] = piece
                remaining = vim.fn.strcharpart(
                    remaining,
                    vim.fn.strchars(piece)
                )
            end

            return pieces
        end

        for word in segment:gmatch("%S+") do
            local words = { word }
            if vim.fn.strdisplaywidth(word) > max_width then
                words = split_long_word(word)
            end

            for _, wrapped_word in ipairs(words) do
                local candidate = current == "" and wrapped_word
                    or (current .. " " .. wrapped_word)
                if vim.fn.strdisplaywidth(candidate) <= max_width then
                    current = candidate
                else
                    push_current()
                    current = wrapped_word
                end
            end
        end

        push_current()
        return lines
    end

    local lines = {}
    local current = nil
    local segments = vim.split(text, " | ", { plain = true })

    for _, segment in ipairs(segments) do
        local wrapped_segment = wrap_segment(segment)
        for line_index, segment_line in ipairs(wrapped_segment) do
            if not current then
                current = segment_line
            elseif line_index == 1 then
                local candidate = current .. " | " .. segment_line
                if vim.fn.strdisplaywidth(candidate) <= max_width then
                    current = candidate
                else
                    lines[#lines + 1] = current
                    current = segment_line
                end
            else
                lines[#lines + 1] = current
                current = segment_line
            end
        end
    end

    if current and current ~= "" then
        lines[#lines + 1] = current
    end

    return lines
end

--- @param bufnr integer
--- @param winid integer
--- @param context string|nil
local function set_chat_context(bufnr, winid, context)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local existing_count = vim.b[bufnr][CHAT_CONTEXT_LINE_COUNT_KEY] or 0
    local new_lines = {}
    local wrapped = {}

    if context and context ~= "" then
        local max_width = math.max(12, vim.api.nvim_win_get_width(winid) - 4)
        wrapped = wrap_context_text(context, max_width)

        for _, line in ipairs(wrapped) do
            new_lines[#new_lines + 1] = line
        end

        if #wrapped > 0 then
            new_lines[#new_lines + 1] = ""
        end
    end

    local existing_lines = existing_count > 0
            and vim.api.nvim_buf_get_lines(bufnr, 0, existing_count, false)
        or {}
    if vim.deep_equal(existing_lines, new_lines) then
        vim.api.nvim_buf_clear_namespace(bufnr, NS_CHAT_CONTEXT, 0, -1)
        for line_idx = 0, #wrapped - 1 do
            vim.api.nvim_buf_add_highlight(
                bufnr,
                NS_CHAT_CONTEXT,
                Theme.HL_GROUPS.WIN_BAR_CONTEXT,
                line_idx,
                0,
                -1
            )
        end
        return
    end

    BufHelpers.with_modifiable(bufnr, function()
        local is_empty = existing_count == 0 and BufHelpers.is_buffer_empty(bufnr)
        vim.api.nvim_buf_set_lines(
            bufnr,
            0,
            is_empty and -1 or existing_count,
            false,
            new_lines
        )
    end)

    vim.b[bufnr][CHAT_CONTEXT_LINE_COUNT_KEY] = #new_lines
    vim.api.nvim_buf_clear_namespace(bufnr, NS_CHAT_CONTEXT, 0, -1)
    for line_idx = 0, #wrapped - 1 do
        vim.api.nvim_buf_add_highlight(
            bufnr,
            NS_CHAT_CONTEXT,
            Theme.HL_GROUPS.WIN_BAR_CONTEXT,
            line_idx,
            0,
            -1
        )
    end
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
--- @param _header_parts agentic.ui.ChatWidget.HeaderParts|nil
--- @param _header_text string
local function set_winbar(winid, header_parts, header_text)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    vim.api.nvim_set_option_value("winbar", "", { win = winid })
end

--- Sets the buffer name based on header text and tab count
--- @param bufnr integer Buffer number
--- @param header_parts agentic.ui.ChatWidget.HeaderParts|nil
--- @param header_text string|nil Resolved header text
--- @param tab_page_id integer Tab page ID for suffix
local function set_buffer_name(bufnr, header_parts, header_text, tab_page_id)
    local base_name = header_parts and header_parts.title or header_text
    if not base_name or base_name == "" then
        return
    end

    -- Determine if we should show tab suffix based on total tab count
    local total_tabs = #vim.api.nvim_list_tabpages()

    --- @type string|nil
    local buf_name
    if total_tabs > 1 then
        buf_name = string.format("%s (Tab %d)", base_name, tab_page_id)
    else
        buf_name = base_name
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

        local rendered_parts = header_parts and vim.deepcopy(header_parts) or nil
        if window_name == "chat" and rendered_parts then
            set_chat_context(bufnr, winid, rendered_parts.context)
            rendered_parts.context = nil
            header_text = concat_header_parts(rendered_parts)
        else
            set_chat_context(bufnr, winid, nil)
        end

        local text = (header_text and header_text ~= "") and header_text or ""

        WindowDecoration.apply_window_style(winid)
        set_winbar(winid, rendered_parts or header_parts, text)
        set_buffer_name(bufnr, rendered_parts or header_parts, header_text, tab_page_id)
    end)
end

return WindowDecoration
