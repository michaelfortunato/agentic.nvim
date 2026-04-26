local States = require("agentic.states")
local Config = require("agentic.config")

--- Agentic slash command item stored per prompt buffer.
--- @class agentic.acp.CompletionItem
--- @field word string Command name without trigger
--- @field menu string Description shown in completion menu
--- @field info string Full description shown in popup window
--- @field kind string Type/category of completion item
--- @field icase number 1 for case-insensitive, 0 for case-sensitive

--- @class agentic.acp.SlashCommands
local SlashCommands = {}

local BLINK_SOURCE_ID = "agentic_slash_commands"
local blink_provider_registered = false
local blink_filetype_registered = false
local skip_auto_show_by_buffer = {}

--- @class agentic.acp.SlashCommands.BlinkAPI
--- @field show fun(opts: {providers?: string[]}|nil)
--- @field add_source_provider fun(source_id: string, source_config: table)
--- @field add_filetype_source fun(filetype: string, source_id: string)

--- @param value any
--- @param fallback string
--- @return string trigger
local function single_character_trigger(value, fallback)
    if type(value) == "string" and #value == 1 and not value:match("%s") then
        return value
    end

    return fallback
end

--- @param text string
--- @return string pattern
local function escape_pattern(text)
    return (text:gsub("([^%w])", "%%%1"))
end

--- @return string trigger
function SlashCommands.get_trigger()
    return single_character_trigger(
        Config.completion and Config.completion.slash_trigger,
        "/"
    )
end

--- @param cmd agentic.acp.AvailableCommand
--- @return boolean
local function is_valid_command(cmd)
    return type(cmd.name) == "string"
        and type(cmd.description) == "string"
        and cmd.name ~= ""
        and cmd.description ~= ""
        and not cmd.name:match("%s")
        and cmd.name ~= "clear"
end

--- @param cmd agentic.acp.AvailableCommand
--- @return agentic.acp.CompletionItem
local function to_completion_item(cmd)
    return {
        word = cmd.name,
        menu = cmd.description,
        info = cmd.description,
        kind = SlashCommands.get_trigger(),
        icase = 1,
    }
end

--- Replace all commands with new list in completion format
--- Validates each command has required fields, skips invalid commands and commands with spaces
--- Filters out `clear` command (handled by specific agents internally)
--- Automatically adds `new` command if not provided by agent
--- @param bufnr integer
--- @param available_commands agentic.acp.AvailableCommand[]
--- @param opts {local_commands?: agentic.acp.AvailableCommand[]|nil}|nil
function SlashCommands.setCommands(bufnr, available_commands, opts)
    opts = opts or {}

    --- @type agentic.acp.CompletionItem[]
    local commands = {}
    local seen_names = {}

    local has_new_command = false

    for _, cmd in ipairs(available_commands) do
        if is_valid_command(cmd) then
            if cmd.name == "new" then
                has_new_command = true
            end

            commands[#commands + 1] = to_completion_item(cmd)
            seen_names[cmd.name] = true
        end
    end

    for _, cmd in ipairs(opts.local_commands or {}) do
        if is_valid_command(cmd) and not seen_names[cmd.name] then
            commands[#commands + 1] = to_completion_item(cmd)
            seen_names[cmd.name] = true
        end
    end

    -- Add /new command if not provided by agent
    if not has_new_command then
        table.insert(
            commands,
            to_completion_item({
                name = "new",
                description = "Start a new session",
            })
        )
    end

    States.setSlashCommands(bufnr, commands)
end

--- @param line string
--- @param cursor_col integer
--- @param cursor_line integer|nil
--- @return { start_col: integer, query: string }|nil command
function SlashCommands.get_active_command(line, cursor_col, cursor_line)
    if cursor_line and cursor_line ~= 1 then
        return nil
    end

    local trigger = SlashCommands.get_trigger()
    local resolved_cursor_col = cursor_col
    if cursor_col == 0 and (line or ""):sub(1, #trigger) == trigger then
        resolved_cursor_col = #trigger
    end

    local before_cursor = (line or ""):sub(1, resolved_cursor_col)
    if not vim.startswith(before_cursor, trigger) then
        return nil
    end

    local query = before_cursor:sub(#trigger + 1)
    if query:match("%s") then
        return nil
    end

    return {
        start_col = 0,
        query = query,
    }
end

--- @param input_text string
--- @return string|nil command_name
function SlashCommands.get_input_command_name(input_text)
    return (input_text or ""):match(
        "^" .. escape_pattern(SlashCommands.get_trigger()) .. "([^%s]+)"
    )
end

--- @param bufnr integer
--- @param command_name string|nil
--- @return boolean known
function SlashCommands.is_known_command(bufnr, command_name)
    if not command_name then
        return false
    end

    for _, command in ipairs(States.getSlashCommands(bufnr)) do
        if command.word == command_name then
            return true
        end
    end

    return false
end

--- Converts a custom configured trigger back to ACP's slash syntax.
--- @param bufnr integer
--- @param input_text string
--- @return string normalized_input
function SlashCommands.normalize_input(bufnr, input_text)
    local trigger = SlashCommands.get_trigger()
    if trigger == "/" then
        return input_text
    end

    local command_name = SlashCommands.get_input_command_name(input_text)
    if not SlashCommands.is_known_command(bufnr, command_name) then
        return input_text
    end

    return "/" .. input_text:sub(#trigger + 1)
end

--- @return agentic.acp.SlashCommands.BlinkAPI|nil blink
function SlashCommands._get_blink()
    local ok, blink = pcall(require, "blink.cmp")
    if not ok then
        return nil
    end

    return blink
end

--- @return boolean open
function SlashCommands._is_blink_menu_open()
    local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
    if not ok_menu or not menu or not menu.win or not menu.win.is_open then
        return false
    end

    return menu.win:is_open()
end

--- @return agentic.acp.SlashCommands.BlinkAPI|nil blink
function SlashCommands._ensure_blink_registered()
    local blink = SlashCommands._get_blink()
    if not blink then
        return nil
    end

    if not blink_provider_registered then
        local ok_config, blink_config = pcall(require, "blink.cmp.config")
        local already_registered = ok_config
            and blink_config.sources
            and blink_config.sources.providers
            and blink_config.sources.providers[BLINK_SOURCE_ID] ~= nil

        if not already_registered then
            blink.add_source_provider(BLINK_SOURCE_ID, {
                name = "Agentic Commands",
                module = "agentic.acp.slash_commands_blink_source",
                async = false,
            })
        end

        blink_provider_registered = true
    end

    if not blink_filetype_registered then
        blink.add_filetype_source("AgenticInput", BLINK_SOURCE_ID)
        blink_filetype_registered = true
    end

    return blink
end

--- @param bufnr integer
function SlashCommands.skip_next_auto_show(bufnr)
    skip_auto_show_by_buffer[bufnr] = true
    vim.schedule(function()
        skip_auto_show_by_buffer[bufnr] = nil
    end)
end

--- Setup blink completion for slash commands in the input buffer.
--- @param bufnr integer The input buffer number
function SlashCommands.setup_completion(bufnr)
    SlashCommands._ensure_blink_registered()

    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = bufnr,
        callback = function()
            SlashCommands.trigger_completion(bufnr)
        end,
    })
end

--- @param bufnr integer|nil
--- @return boolean triggered
function SlashCommands.trigger_completion(bufnr)
    local target_bufnr = bufnr or vim.api.nvim_get_current_buf()
    if skip_auto_show_by_buffer[target_bufnr] then
        skip_auto_show_by_buffer[target_bufnr] = nil
        return false
    end

    if #States.getSlashCommands(target_bufnr) == 0 then
        return false
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(
        target_bufnr,
        cursor[1] - 1,
        cursor[1],
        false
    )[1] or ""
    local command = SlashCommands.get_active_command(line, cursor[2], cursor[1])
    if not command or SlashCommands._is_blink_menu_open() then
        return false
    end

    local blink = SlashCommands._ensure_blink_registered()
    if not blink then
        return false
    end

    blink.show({
        providers = { BLINK_SOURCE_ID },
    })
    return true
end

return SlashCommands
