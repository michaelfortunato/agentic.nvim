local BufHelpers = require("agentic.utils.buf_helpers")
local Chooser = require("agentic.ui.chooser")
local Config = require("agentic.config")
local List = require("agentic.utils.list")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentConfigOptions
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- @field thought_level? agentic.acp.ConfigOption
--- @field legacy_agent_modes agentic.acp.AgentModes
--- @field legacy_agent_models agentic.acp.AgentModels
--- @field _options agentic.acp.ConfigOption[]
--- @field _options_by_id table<string, agentic.acp.ConfigOption>
--- @field _set_mode_callback fun(mode_id: string, is_legacy: boolean)
--- @field _set_model_callback fun(model_id: string, is_legacy: boolean)
--- @field _set_config_option_callback fun(config_id: string, value: string)
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

--- @param target agentic.acp.ConfigOption|nil
--- @param value string
--- @return agentic.acp.ConfigOption.Option|nil
local function get_option_value(target, value)
    if not target or not target.options or #target.options == 0 then
        return nil
    end

    for _, option in ipairs(target.options) do
        if option.value == value then
            return option
        end
    end

    return nil
end

--- @param option agentic.acp.ConfigOption|nil
--- @return boolean
local function has_select_options(option)
    return option ~= nil and option.options ~= nil and #option.options > 0
end

--- @param option agentic.acp.ConfigOption
--- @return string
local function get_selector_prompt(option)
    return string.format("Select %s (applies live):", option.name)
end

--- @param option agentic.acp.ConfigOption
--- @return string
local function get_current_value_name(option)
    local current = get_option_value(option, option.currentValue)
    return current and current.name or option.currentValue or "unknown"
end

--- @param parts string[]
--- @param label string
--- @param value string|nil
local function append_summary_part(parts, label, value)
    if not value or value == "" then
        return
    end

    parts[#parts + 1] = string.format("%s: %s", label, value)
end

--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
--- @param set_mode_callback fun(mode_id: string, is_legacy: boolean)
--- @param set_model_callback fun(model_id: string, is_legacy: boolean)
--- @param set_config_option_callback? fun(config_id: string, value: string)
--- @return agentic.acp.AgentConfigOptions
function AgentConfigOptions:new(
    buffers,
    set_mode_callback,
    set_model_callback,
    set_config_option_callback
)
    local AgentModes = require("agentic.acp.agent_modes")
    local AgentModels = require("agentic.acp.agent_models")

    self = setmetatable({
        mode = nil,
        model = nil,
        thought_level = nil,
        legacy_agent_modes = AgentModes:new(),
        legacy_agent_models = AgentModels:new(),
        _options = {},
        _options_by_id = {},
        _set_mode_callback = set_mode_callback,
        _set_model_callback = set_model_callback,
        _set_config_option_callback = set_config_option_callback
            or function()
            end,
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
    end

    return self
end

function AgentConfigOptions:clear()
    self.mode = nil
    self.model = nil
    self.thought_level = nil
    self._options = {}
    self._options_by_id = {}
    self.legacy_agent_modes:clear()
    self.legacy_agent_models:clear()
end

--- @param configOptions agentic.acp.ConfigOption[]|nil
function AgentConfigOptions:set_options(configOptions)
    self:clear()

    if not configOptions then
        return
    end

    for _, option in ipairs(configOptions) do
        self._options[#self._options + 1] = option
        self._options_by_id[option.id] = option

        if option.category == "mode" then
            self.mode = option
        elseif option.category == "model" then
            self.model = option
        elseif option.category == "thought_level" then
            self.thought_level = option
        end
    end
end

--- Modes from providers that don't support the new Config Options
--- @param modes_info agentic.acp.ModesInfo
function AgentConfigOptions:set_legacy_modes(modes_info)
    self.legacy_agent_modes:set_modes(modes_info)
end

--- Models from providers that don't support the new Config Options
--- @param models_info agentic.acp.ModelsInfo
function AgentConfigOptions:set_legacy_models(models_info)
    self.legacy_agent_models:set_models(models_info)
end

--- @param target_mode string|nil
--- @param handle_mode_change fun(mode: string, is_legacy: boolean|nil): any
function AgentConfigOptions:set_initial_mode(target_mode, handle_mode_change)
    if not target_mode or target_mode == "" then
        Logger.debug("not setting initial mode", target_mode)
        return
    end

    local is_legacy = false
    local can_switch = false

    if self:get_mode(target_mode) ~= nil then
        can_switch = target_mode ~= self.mode.currentValue
        Logger.debug("Setting initial config mode", target_mode, can_switch)
    elseif self.legacy_agent_modes:get_mode(target_mode) ~= nil then
        is_legacy = true
        can_switch = target_mode ~= self.legacy_agent_modes.current_mode_id
        Logger.debug("Setting initial legacy mode", target_mode, can_switch)
    end

    if can_switch then
        handle_mode_change(target_mode, is_legacy)
    else
        local current = self.mode and self.mode.currentValue
            or self.legacy_agent_modes.current_mode_id
            or "unknown"
        Logger.notify(
            string.format(
                "Configured default_mode ‘%s’ not available. "
                    .. "Using provider’s default ‘%s’",
                target_mode,
                current
            ),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end
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

--- @return string|nil
function AgentConfigOptions:get_header_context()
    local parts = {}

    if #self._options > 0 then
        for _, option in ipairs(self._options) do
            if has_select_options(option) then
                append_summary_part(
                    parts,
                    option.name,
                    get_current_value_name(option)
                )
            end
        end
    else
        local legacy_mode = self.legacy_agent_modes:get_mode(
            self.legacy_agent_modes.current_mode_id or ""
        )
        append_summary_part(
            parts,
            "Mode",
            legacy_mode and legacy_mode.name
                or self.legacy_agent_modes.current_mode_id
        )

        local legacy_model = self.legacy_agent_models:get_model(
            self.legacy_agent_models.current_model_id or ""
        )
        append_summary_part(
            parts,
            "Model",
            legacy_model and legacy_model.name
                or self.legacy_agent_models.current_model_id
        )
    end

    if #parts == 0 then
        return nil
    end

    return table.concat(parts, " | ")
end

--- @param mode_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_mode(mode_value)
    return get_option_value(self.mode, mode_value)
end

--- @param mode_value string
--- @return string|nil mode_name
function AgentConfigOptions:get_mode_name(mode_value)
    local mode = self:get_mode(mode_value)

    if mode then
        return mode.name
    end

    local legacy_mode = self.legacy_agent_modes:get_mode(mode_value)

    if legacy_mode then
        return legacy_mode.name
    end

    return nil
end

--- @param model_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_model(model_value)
    return get_option_value(self.model, model_value)
end

--- @param handle_mode_change? fun(mode: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:show_mode_selector(handle_mode_change)
    handle_mode_change = handle_mode_change or self._set_mode_callback

    local shown = self:_show_selector(
        self.mode,
        get_selector_prompt(self.mode or {
            name = "Agent Mode",
        }),
        function(value)
            handle_mode_change(value, false)
        end
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_modes:show_mode_selector(
        function(mode)
            handle_mode_change(mode, true)
        end
    )

    if not legacy_shown then
        Logger.notify(
            "This provider does not support mode switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return legacy_shown
end

--- @param handle_model_change? fun(model_id: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:show_model_selector(handle_model_change)
    handle_model_change = handle_model_change or self._set_model_callback

    local shown = self:_show_selector(
        self.model,
        get_selector_prompt(self.model or {
            name = "Model",
        }),
        function(value)
            handle_model_change(value, false)
        end
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_models:show_model_selector(
        function(model_id)
            handle_model_change(model_id, true)
        end
    )

    if not legacy_shown then
        Logger.notify(
            "This provider does not support model switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return legacy_shown
end

--- @return boolean shown
function AgentConfigOptions:show_thought_level_selector()
    local shown = self:_show_selector(
        self.thought_level,
        get_selector_prompt(self.thought_level or {
            name = "Reasoning Effort",
        }),
        function(value)
            if not self.thought_level then
                return
            end

            self._set_config_option_callback(self.thought_level.id, value)
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
function AgentConfigOptions:show_config_selector()
    local items = self:_build_steering_items()
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
            if item.kind == "legacy_mode" then
                return Chooser.format_named_item(
                    "Mode",
                    self.legacy_agent_modes.current_mode_id,
                    false
                )
            end

            if item.kind == "legacy_model" then
                return Chooser.format_named_item(
                    "Model",
                    self.legacy_agent_models.current_model_id,
                    false
                )
            end

            return Chooser.format_named_item(
                item.option.name,
                get_current_value_name(item.option),
                false
            )
        end,
        max_height = math.min(#items, 8),
    }, function(selected_item)
        if not selected_item then
            return
        end

        if selected_item.kind == "legacy_mode" then
            self:show_mode_selector()
            return
        end

        if selected_item.kind == "legacy_model" then
            self:show_model_selector()
            return
        end

        self:_show_config_option_selector(selected_item.option)
    end)

    return true
end

--- @return table[]
function AgentConfigOptions:_build_steering_items()
    local items = {}

    if #self._options > 0 then
        for _, option in ipairs(self._options) do
            if has_select_options(option) then
                items[#items + 1] = {
                    kind = "config_option",
                    option = option,
                }
            end
        end
        return items
    end

    if #self.legacy_agent_modes._modes > 0 then
        items[#items + 1] = { kind = "legacy_mode" }
    end

    if #self.legacy_agent_models._models > 0 then
        items[#items + 1] = { kind = "legacy_model" }
    end

    return items
end

--- @param option agentic.acp.ConfigOption
function AgentConfigOptions:_show_config_option_selector(option)
    if option.category == "mode" then
        self:show_mode_selector()
        return
    end

    if option.category == "model" then
        self:show_model_selector()
        return
    end

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

    local ordered_options =
        List.move_to_head(target.options, "value", target.currentValue)

    Chooser.show(ordered_options, {
        prompt = prompt,
        format_item = function(item)
            --- @cast item agentic.acp.ConfigOption.Option
            return Chooser.format_named_item(
                item.name,
                item.description,
                item.value == target.currentValue
            )
        end,
    }, function(selected_option)
        if
            selected_option
            and selected_option.value ~= target.currentValue
        then
            handle_change(selected_option.value)
        end
    end)

    return true
end

return AgentConfigOptions
