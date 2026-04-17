local SkillPicker = require("agentic.ui.skill_picker")

--- @class agentic.ui.SkillPickerBlinkSource.Context
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

--- @param item agentic.ui.SkillPicker.Item
--- @param index integer
--- @param context agentic.ui.SkillPickerBlinkSource.Context
--- @param mention_start_col integer
--- @return table
local function to_completion_item(item, index, context, mention_start_col)
    --- @type table
    local completion_item = {
        label = item.name,
        data = {
            name = item.name,
        },
        detail = item.source,
        documentation = item.description ~= "" and {
            kind = "markdown",
            value = item.description,
        } or nil,
        kind = vim.lsp.protocol.CompletionItemKind.Module,
        filterText = item.filter_text,
        sortText = string.format("%04d", index),
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
        textEdit = {
            newText = "$" .. item.name,
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
    return { "$" }
end

--- @param context agentic.ui.SkillPickerBlinkSource.Context
--- @param callback fun(response: table)
function Source:get_completions(context, callback)
    local picker = SkillPicker.get_instance(context.bufnr)
    if not picker then
        callback(empty_response())
        return function() end
    end

    local mention =
        SkillPicker.get_active_skill_mention(context.line, context.cursor[2])
    if not mention then
        callback(empty_response())
        return function() end
    end

    picker:request_source_items(function(matches)
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

    return function() end
end

--- @param context agentic.ui.SkillPickerBlinkSource.Context
--- @param _item table
--- @param callback fun()
--- @param default_implementation fun()
function Source:execute(context, _item, callback, default_implementation)
    local picker = SkillPicker.get_instance(context.bufnr)
    if picker then
        picker:skip_next_auto_show()
    end

    default_implementation()
    callback()
end

return Source
