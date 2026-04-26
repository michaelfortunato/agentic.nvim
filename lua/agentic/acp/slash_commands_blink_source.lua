local SlashCommands = require("agentic.acp.slash_commands")
local States = require("agentic.states")

--- @class agentic.acp.SlashCommandsBlinkSource.Context
--- @field bufnr integer
--- @field line string
--- @field cursor integer[]

local Source = {}
Source.__index = Source

local function empty_response()
    return {
        items = {},
        is_incomplete_forward = false,
        is_incomplete_backward = false,
    }
end

--- @param command agentic.acp.CompletionItem
--- @param index integer
--- @param context agentic.acp.SlashCommandsBlinkSource.Context
--- @param command_start_col integer
--- @return table completion_item
local function to_completion_item(command, index, context, command_start_col)
    local trigger = SlashCommands.get_trigger()

    --- @type table
    local completion_item = {
        label = command.word,
        detail = command.menu,
        documentation = command.info ~= "" and {
            kind = "markdown",
            value = command.info,
        } or nil,
        kind = vim.lsp.protocol.CompletionItemKind.Function,
        filterText = command.word,
        sortText = string.format("%04d", index),
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
        textEdit = {
            newText = trigger .. command.word,
            range = {
                start = {
                    line = context.cursor[1] - 1,
                    character = command_start_col,
                },
                ["end"] = {
                    line = context.cursor[1] - 1,
                    character = context.cursor[2],
                },
            },
        },
    }

    return completion_item
end

function Source.new(_opts)
    return setmetatable({}, Source)
end

function Source:enabled()
    return vim.bo.filetype == "AgenticInput"
end

function Source:get_trigger_characters()
    return { SlashCommands.get_trigger() }
end

--- @param context agentic.acp.SlashCommandsBlinkSource.Context
--- @param callback fun(response: table)
function Source:get_completions(context, callback)
    local command = SlashCommands.get_active_command(
        context.line,
        context.cursor[2],
        context.cursor[1]
    )
    if not command then
        callback(empty_response())
        return function() end
    end

    local items = {}
    for index, item in ipairs(States.getSlashCommands(context.bufnr)) do
        items[index] =
            to_completion_item(item, index, context, command.start_col)
    end

    callback({
        items = items,
        is_incomplete_forward = true,
        is_incomplete_backward = true,
    })

    return function() end
end

--- @param context agentic.acp.SlashCommandsBlinkSource.Context
--- @param _item table
--- @param callback fun()
--- @param default_implementation fun()
function Source:execute(context, _item, callback, default_implementation)
    SlashCommands.skip_next_auto_show(context.bufnr)
    default_implementation()
    callback()
end

return Source
