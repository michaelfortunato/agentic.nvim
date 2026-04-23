local States = require("agentic.states")

--- Neovim completion item structure (vim.fn.complete() dictionary format)
--- For complete list of properties, see |complete-items| in insert.txt help manual
--- @class agentic.acp.CompletionItem
--- @field word string The text to insert (mandatory)
--- @field menu string Description shown in completion menu
--- @field info string Full description shown in popup window
--- @field kind string Type/category of completion item
--- @field icase number 1 for case-insensitive, 0 for case-sensitive

--- @class agentic.acp.SlashCommands
local SlashCommands = {}

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
        kind = "/",
        icase = 1,
    }
end

--- @param commands agentic.acp.CompletionItem[]
--- @param base string
--- @return agentic.acp.CompletionItem[]
local function filter_commands(commands, base)
    if base == "" then
        return vim.deepcopy(commands)
    end

    local lowered_base = base:lower()
    --- @type agentic.acp.CompletionItem[]
    local matches = {}
    for _, command in ipairs(commands) do
        if command.word:lower():find(lowered_base, 1, true) == 1 then
            matches[#matches + 1] = command
        end
    end

    return matches
end

--- @param bufnr integer
--- @return string|nil base
local function get_slash_base(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor[1], false)
    if #lines == 0 then
        return nil
    end

    local cursor_col = cursor[2]
    local cursor_line = lines[#lines]
    if cursor_col == 0 and cursor_line:sub(1, 1) == "/" then
        cursor_col = 1
    end

    lines[#lines] = cursor_line:sub(1, cursor_col)
    return table.concat(lines, "\n"):match("^/(%S*)$")
end

--- Replace all commands with new list in completion format
--- Validates each command has required fields, skips invalid commands and commands with spaces
--- Filters out `clear` command (handled by specific agents internally)
--- Automatically adds `/new` command if not provided by agent
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
        --- @type agentic.acp.CompletionItem
        local new_command = {
            word = "new",
            menu = "Start a new session",
            info = "Start a new session",
            kind = "/",
            icase = 1,
        }
        table.insert(commands, new_command)
    end

    States.setSlashCommands(bufnr, commands)
end

--- Setup native Neovim completion for slash commands in the input buffer
--- @param bufnr integer The input buffer number
function SlashCommands.setup_completion(bufnr)
    vim.bo[bufnr].completeopt = "menu,menuone,noinsert,popup,fuzzy"

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
    local base = get_slash_base(target_bufnr)
    if not base then
        return false
    end

    local commands =
        filter_commands(States.getSlashCommands(target_bufnr), base)
    if #commands == 0 then
        return false
    end

    local ok = pcall(vim.fn.complete, 2, commands)
    return ok
end

return SlashCommands
