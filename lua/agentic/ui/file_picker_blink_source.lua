local FilePicker = require("agentic.ui.file_picker")

--- @class agentic.ui.FilePickerBlinkSource.Context
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

--- @param item table
--- @param index integer
--- @param context agentic.ui.FilePickerBlinkSource.Context
--- @param mention_start_col integer
--- @return table completion_item
local function to_completion_item(item, index, context, mention_start_col)
    local path = FilePicker.strip_trigger(item.word)

    --- @type table
    local completion_item = {
        label = path,
        data = {
            path = path,
        },
        kind = vim.lsp.protocol.CompletionItemKind.File,
        filterText = item._filter_text or path,
        sortText = string.format("%04d", index),
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
        textEdit = {
            newText = item.word,
            range = {
                start = {
                    line = context.cursor[1] - 1,
                    character = mention_start_col,
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
    return { FilePicker.get_trigger() }
end

--- @param context agentic.ui.FilePickerBlinkSource.Context
--- @param callback fun(response: table)
function Source:get_completions(context, callback)
    local picker = FilePicker.get_instance(context.bufnr)
    if not picker then
        callback(empty_response())
        return function() end
    end

    local mention =
        FilePicker.get_active_mention(context.line, context.cursor[2])
    if not mention then
        callback(empty_response())
        return function() end
    end

    local cancelled = false

    picker:request_source_items(function(matches)
        if cancelled then
            return
        end

        local items = {}
        for index, item in ipairs(matches) do
            items[index] =
                to_completion_item(item, index, context, mention.start_col)
        end

        callback({
            items = items,
            is_incomplete_forward = true,
            is_incomplete_backward = true,
        })
    end)

    return function()
        cancelled = true
    end
end

--- @param context agentic.ui.FilePickerBlinkSource.Context
--- @param item {data?: {path?: string}|nil}
--- @param callback fun()
--- @param default_implementation fun()
function Source:execute(context, item, callback, default_implementation)
    local picker = FilePicker.get_instance(context.bufnr)
    if picker then
        picker:skip_next_auto_show()
    end

    default_implementation()

    if picker and item.data and item.data.path then
        picker:handle_file_selected(item.data.path)
    end

    callback()
end

return Source
