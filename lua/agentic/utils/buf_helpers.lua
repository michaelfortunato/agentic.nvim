local Logger = require("agentic.utils.logger")

--- @class agentic.utils.BufHelpers.KeymapOpts: vim.keymap.set.Opts
--- @field buffer? integer

--- @class agentic.utils.BufHelpers
local BufHelpers = {}

--- Executes a callback with the buffer set to modifiable.
--- Returns false when the buffer is invalid or the callback errors.
--- Otherwise returns the callback's own return value.
--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|false result
function BufHelpers.with_modifiable(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local original_modifiable =
        vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    local ok, response = pcall(callback, bufnr)

    vim.api.nvim_set_option_value(
        "modifiable",
        original_modifiable,
        { buf = bufnr }
    )

    if not ok then
        Logger.notify(
            "Error in with_modifiable: \n" .. tostring(response),
            vim.log.levels.ERROR,
            { title = "🐞 Error with modifiable callback" }
        )
        return false
    end

    return response
end

function BufHelpers.start_insert_on_last_char()
    vim.cmd("normal! G$")
    vim.cmd("startinsert!")
end

--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|nil
function BufHelpers.execute_on_buffer(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    return vim.api.nvim_buf_call(bufnr, function()
        return callback(bufnr)
    end)
end

--- Sets a keymap for a specific buffer.
--- @param bufnr integer
--- @param mode string|string[]
--- @param lhs string
--- @param rhs string|fun():any
--- @param opts vim.keymap.set.Opts|nil
function BufHelpers.keymap_set(bufnr, mode, lhs, rhs, opts)
    --- @type agentic.utils.BufHelpers.KeymapOpts
    local keymap_opts = vim.tbl_deep_extend("force", {}, opts or {})
    keymap_opts.buffer = bufnr
    vim.keymap.set(mode, lhs, rhs, keymap_opts)
end

--- Sets multiple keymaps from a KeymapValue config entry for a specific buffer.
--- Normalizes the config value (string, string[], or array of string/KeymapEntry)
--- and calls keymap_set for each binding.
--- @param keymaps agentic.UserConfig.KeymapValue
--- @param bufnr integer
--- @param callback fun():any
--- @param opts vim.keymap.set.Opts|nil
function BufHelpers.multi_keymap_set(keymaps, bufnr, callback, opts)
    if type(keymaps) == "string" then
        keymaps = { keymaps }
    end

    for _, key in ipairs(keymaps) do
        --- @type string|string[]
        local modes = "n"
        --- @type string
        local keymap

        if type(key) == "table" and key.mode then
            modes = key.mode
            keymap = key[1]
        else
            keymap = key --[[@as string]]
        end

        BufHelpers.keymap_set(bufnr, modes, keymap, callback, opts)
    end
end

--- Resolves the first configured keymap for a given mode.
--- Bare string bindings are treated as normal-mode bindings, which matches
--- multi_keymap_set's default behavior.
--- @param keymaps agentic.UserConfig.KeymapValue
--- @param mode string
--- @return string|nil
function BufHelpers.find_keymap(keymaps, mode)
    if type(keymaps) == "string" then
        return mode == "n" and keymaps or nil
    end

    if type(keymaps) ~= "table" then
        return nil
    end

    for _, keymap in ipairs(keymaps) do
        if type(keymap) == "string" and mode == "n" then
            return keymap
        end

        if type(keymap) == "table" then
            if keymap.mode == mode then
                return keymap[1]
            end

            local keymap_modes = keymap.mode
            if type(keymap_modes) == "table" then
                --- @cast keymap_modes string[]
                for _, candidate_mode in ipairs(keymap_modes) do
                    if candidate_mode == mode then
                        return keymap[1]
                    end
                end
            end
        end
    end

    return nil
end

--- @param bufnr integer
--- @return boolean
function BufHelpers.is_buffer_empty(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    if #lines == 0 then
        return true
    end

    -- Check if buffer contains only whitespace or a single empty line
    if #lines == 1 and lines[1]:match("^%s*$") then
        return true
    end

    -- Check if all lines are whitespace
    for _, line in ipairs(lines) do
        if line:match("%S") then
            return false
        end
    end

    return true
end

function BufHelpers.feed_ESC_key()
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "nx",
        false
    )
end

return BufHelpers
