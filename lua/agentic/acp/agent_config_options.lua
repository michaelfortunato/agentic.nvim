local BufHelpers = require("agentic.utils.buf_helpers")
local Chooser = require("agentic.ui.chooser")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentConfigOptions
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- @field thought_level? agentic.acp.ConfigOption
--- @field approval_preset? agentic.acp.ConfigOption
--- @field _options agentic.acp.ConfigOption[]
--- @field _options_by_id table<string, agentic.acp.ConfigOption>
--- @field _provider_config agentic.acp.ACPProviderConfig|nil
--- @field _set_config_option_callback fun(config_id: string, value: string)
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

--- @param option agentic.acp.ConfigOption|nil
--- @return boolean
local function is_select_option(option)
    return option ~= nil and (option.type == nil or option.type == "select")
end

--- @param option agentic.acp.ConfigOption|nil
--- @return agentic.acp.ConfigOption.Option[]
local function flatten_option_values(option)
    local options = option and option.options or nil
    if
        not is_select_option(option)
        or type(options) ~= "table"
        or #options == 0
    then
        return {}
    end

    local first = options[1]
    if type(first) == "table" and first.options ~= nil then
        local flattened = {}
        for _, group in ipairs(options) do
            for _, grouped_option in ipairs(group.options or {}) do
                flattened[#flattened + 1] = grouped_option
            end
        end
        return flattened
    end

    return options
end

--- @param option agentic.acp.ConfigOption|nil
--- @param current_value string|nil
--- @return agentic.acp.ConfigOption.Option[] ordered_options
local function get_ordered_option_values(option, current_value)
    local ordered_options = vim.list_extend({}, flatten_option_values(option))

    if not current_value or current_value == "" then
        return ordered_options
    end

    for index, candidate in ipairs(ordered_options) do
        if candidate.value == current_value then
            table.remove(ordered_options, index)
            table.insert(ordered_options, 1, candidate)
            break
        end
    end

    return ordered_options
end

--- @param option agentic.acp.ConfigOption|nil
--- @param value string
--- @return agentic.acp.ConfigOption.Option|nil
local function get_option_value(option, value)
    local options = flatten_option_values(option)
    if #options == 0 then
        return nil
    end

    for _, candidate in ipairs(options) do
        if candidate.value == value then
            return candidate
        end
    end

    return nil
end

--- @param option agentic.acp.ConfigOption|nil
--- @return boolean
local function has_select_options(option)
    return is_select_option(option) and #flatten_option_values(option) > 0
end

--- @param option agentic.acp.ConfigOption|nil
--- @return string
local function get_option_display_name(option)
    return option and option.name or "unknown"
end

--- @param option agentic.acp.ConfigOption
--- @return string
local function get_selector_prompt(option)
    return string.format(
        "Select %s (applies live):",
        get_option_display_name(option)
    )
end

--- @param option agentic.acp.ConfigOption
--- @return string
local function get_current_value_name(option)
    local current = get_option_value(option, option.currentValue)
    return current and current.name or option.currentValue or "unknown"
end

--- @param text string|nil
--- @return string
local function normalize_option_label(text)
    return vim.trim((text or ""):lower())
end

--- @param provider_config agentic.acp.ACPProviderConfig|nil
--- @return boolean
local function is_codex_provider(provider_config)
    if not provider_config then
        return false
    end

    local command = provider_config.command
    local command_name = type(command) == "string" and vim.fs.basename(command)
        or ""
    if normalize_option_label(command_name) == "codex-acp" then
        return true
    end

    local provider_name = normalize_option_label(provider_config.name)
    return provider_name == "codex acp" or provider_name == "codex"
end

--- @param option agentic.acp.ConfigOption|nil
--- @param provider_config agentic.acp.ACPProviderConfig|nil
--- @return boolean
local function is_approval_preset_option(option, provider_config)
    if not option then
        return false
    end

    local category = normalize_option_label(option.category)
    if category == "approval_preset" or category == "approval preset" then
        return true
    end

    return is_codex_provider(provider_config)
        and category == "mode"
        and normalize_option_label(option.name) == "approval preset"
end

--- @param parts string[]
--- @param label string
--- @param value string|nil
local function append_summary_part(parts, label, value)
    if value and value ~= "" then
        parts[#parts + 1] = string.format("%s: %s", label, value)
    end
end

--- @param buffers agentic.ui.ChatWidget.BufNrs
--- @param set_config_option_callback? fun(config_id: string, value: string)
--- @return agentic.acp.AgentConfigOptions
function AgentConfigOptions:new(buffers, set_config_option_callback)
    self = setmetatable({
        mode = nil,
        model = nil,
        thought_level = nil,
        approval_preset = nil,
        _options = {},
        _options_by_id = {},
        _provider_config = nil,
        _set_config_option_callback = set_config_option_callback
            or function() end,
    }, self)

    for _, bufnr in pairs(buffers) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_mode,
            bufnr,
            function()
                self:show_config_selector()
            end,
            { desc = "Agentic: Session Config" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_model,
            bufnr,
            function()
                self:show_model_selector()
            end,
            { desc = "Agentic: Select Model" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_thought_level,
            bufnr,
            function()
                self:show_thought_level_selector()
            end,
            { desc = "Agentic: Select Reasoning Effort" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_approval_preset,
            bufnr,
            function()
                self:show_approval_preset_selector()
            end,
            { desc = "Agentic: Select Approval Preset" }
        )
    end

    return self
end

function AgentConfigOptions:clear()
    self.mode = nil
    self.model = nil
    self.thought_level = nil
    self.approval_preset = nil
    self._options = {}
    self._options_by_id = {}
    self._provider_config = nil
end

--- @param config_options agentic.acp.ConfigOption[]|nil
--- @param provider_config agentic.acp.ACPProviderConfig|nil
function AgentConfigOptions:set_options(config_options, provider_config)
    self:clear()
    self._provider_config = provider_config

    if not config_options then
        return
    end

    for _, option in ipairs(config_options) do
        self._options[#self._options + 1] = option
        self._options_by_id[option.id] = option

        if option.category == "mode" then
            self.mode = option
        elseif option.category == "model" then
            self.model = option
        elseif option.category == "thought_level" then
            self.thought_level = option
        end

        if is_approval_preset_option(option, self._provider_config) then
            self.approval_preset = option
        end
    end
end

--- @param target_mode string|nil
function AgentConfigOptions:set_initial_mode(target_mode)
    if not target_mode or target_mode == "" then
        Logger.debug("not setting initial mode", target_mode)
        return
    end

    local mode_option = self:get_mode_option()
    local mode = get_option_value(mode_option, target_mode)
    if mode and mode_option then
        if target_mode ~= mode_option.currentValue then
            self._set_config_option_callback(mode_option.id, target_mode)
        end
        return
    end

    local current = mode_option and mode_option.currentValue or "unknown"
    Logger.notify(
        string.format(
            "Configured default_mode ‘%s’ not available. Using provider’s default ‘%s’",
            target_mode,
            current
        ),
        vim.log.levels.WARN,
        { title = "Agentic" }
    )
end

--- @param config_id string
--- @return agentic.acp.ConfigOption|nil
function AgentConfigOptions:get_config_option(config_id)
    return self._options_by_id[config_id]
end

--- @param config_id string
--- @param value string
--- @return string|nil
function AgentConfigOptions:get_config_value_name(config_id, value)
    local option = self:get_config_option(config_id)
    local config_value = get_option_value(option, value)
    return config_value and config_value.name or nil
end

--- @param config_id string
--- @return string|nil
function AgentConfigOptions:get_config_option_name(config_id)
    local option = self:get_config_option(config_id)
    return option and get_option_display_name(option) or nil
end

--- @return string|nil
function AgentConfigOptions:get_header_context()
    local parts = {}

    for _, option in ipairs(self._options) do
        if has_select_options(option) then
            append_summary_part(
                parts,
                get_option_display_name(option),
                get_current_value_name(option)
            )
        end
    end

    if #parts == 0 then
        return nil
    end

    return table.concat(parts, " | ")
end

--- @return agentic.acp.ConfigOption|nil
function AgentConfigOptions:get_mode_option()
    return self.mode
end

--- @return agentic.acp.ConfigOption|nil
function AgentConfigOptions:get_model_option()
    return self.model
end

--- @return agentic.acp.ConfigOption|nil
function AgentConfigOptions:get_thought_level_option()
    return self.thought_level
end

--- @return agentic.acp.ConfigOption|nil
function AgentConfigOptions:get_approval_preset_option()
    return self.approval_preset
end

--- @param mode_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_mode(mode_value)
    return get_option_value(self:get_mode_option(), mode_value)
end

--- @param mode_id string|nil
function AgentConfigOptions:set_current_mode(mode_id)
    local mode_option = self:get_mode_option()
    if not mode_id or not mode_option then
        return
    end

    mode_option.currentValue = mode_id
end

--- @return boolean shown
function AgentConfigOptions:show_mode_selector()
    local mode_option = self:get_mode_option()
    local shown = self:_show_selector(
        mode_option,
        get_selector_prompt(mode_option or { name = "Agent Mode" }),
        function(value)
            if mode_option then
                self._set_config_option_callback(mode_option.id, value)
            end
        end
    )

    if not shown then
        Logger.notify(
            "This provider does not support mode switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return shown
end

--- @return boolean shown
function AgentConfigOptions:show_model_selector()
    local model_option = self:get_model_option()
    local shown = self:_show_selector(
        model_option,
        get_selector_prompt(model_option or { name = "Model" }),
        function(value)
            if model_option then
                self._set_config_option_callback(model_option.id, value)
            end
        end
    )

    if not shown then
        Logger.notify(
            "This provider does not support model switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return shown
end

--- @return boolean shown
function AgentConfigOptions:show_thought_level_selector()
    local thought_level_option = self:get_thought_level_option()
    local shown = self:_show_selector(
        thought_level_option,
        get_selector_prompt(
            thought_level_option or { name = "Reasoning Effort" }
        ),
        function(value)
            if thought_level_option then
                self._set_config_option_callback(thought_level_option.id, value)
            end
        end
    )

    if not shown then
        Logger.notify(
            "This provider does not support reasoning effort switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return shown
end

--- @return boolean shown
function AgentConfigOptions:show_approval_preset_selector()
    local approval_preset_option = self:get_approval_preset_option()
    local shown = self:_show_selector(
        approval_preset_option,
        get_selector_prompt(
            approval_preset_option or { name = "Approval Preset" }
        ),
        function(value)
            if approval_preset_option then
                self._set_config_option_callback(
                    approval_preset_option.id,
                    value
                )
            end
        end
    )

    if not shown then
        Logger.notify(
            "This provider does not support approval preset switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return shown
end

--- @return boolean shown
function AgentConfigOptions:show_config_selector()
    local items = {}

    for _, option in ipairs(self._options) do
        if has_select_options(option) then
            items[#items + 1] = option
        end
    end

    if #items == 0 then
        Logger.notify(
            "This provider does not expose configurable session options",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return false
    end

    Chooser.show(items, {
        prompt = "Session config (applies live):",
        format_item = function(item)
            --- @cast item agentic.acp.ConfigOption
            return Chooser.format_named_item(
                get_option_display_name(item),
                get_current_value_name(item),
                false
            )
        end,
        max_height = math.min(#items, 8),
    }, function(selected_option)
        if selected_option then
            self:_show_config_option_selector(selected_option)
        end
    end)

    return true
end

--- @param option agentic.acp.ConfigOption
function AgentConfigOptions:_show_config_option_selector(option)
    self:_show_selector(option, get_selector_prompt(option), function(value)
        self._set_config_option_callback(option.id, value)
    end)
end

--- @param target agentic.acp.ConfigOption|nil
--- @param prompt string
--- @param handle_change fun(value: string): any
--- @return boolean shown
function AgentConfigOptions:_show_selector(target, prompt, handle_change)
    if not has_select_options(target) then
        return false
    end

    --- @cast target agentic.acp.ConfigOption
    local current_value = target.currentValue

    local ordered_options = get_ordered_option_values(target, current_value)

    Chooser.show(ordered_options, {
        prompt = prompt,
        format_item = function(item)
            --- @cast item agentic.acp.ConfigOption.Option
            return Chooser.format_named_item(
                item.name,
                item.description,
                item.value == current_value
            )
        end,
    }, function(selected_option)
        if selected_option and selected_option.value ~= current_value then
            handle_change(selected_option.value)
        end
    end)

    return true
end

return AgentConfigOptions
