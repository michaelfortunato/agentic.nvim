local ProviderUtils = require("agentic.acp.provider_utils")
local SlashCommands = require("agentic.acp.slash_commands")

--- @class agentic.acp.CodexLocalCommands
local CodexLocalCommands = {}

--- @param session agentic.SessionManager
--- @return boolean
local function is_codex_session(session)
    return ProviderUtils.is_codex_provider(
        session and session.agent and session.agent.provider_config or nil
    )
end

--- @param session agentic.SessionManager
--- @return table<string, boolean>
local function get_agent_command_names(session)
    local names = {}
    local state = session
            and session.session_state
            and session.session_state.get_state
            and session.session_state:get_state()
        or nil
    local commands = state
            and state.session
            and state.session.available_commands
        or {}

    for _, command in ipairs(commands) do
        if command.name then
            names[command.name] = true
        end
    end

    return names
end

--- @param session agentic.SessionManager
--- @return agentic.acp.AvailableCommand[]
function CodexLocalCommands.get_available_commands(session)
    if not is_codex_session(session) then
        return {}
    end

    local existing = get_agent_command_names(session)
    local config_options = session.config_options
    local commands = {}

    if
        not existing.permissions
        and config_options
        and config_options.get_approval_preset_option
        and config_options:get_approval_preset_option()
    then
        commands[#commands + 1] = {
            name = "permissions",
            description = "Codex-only Agentic shortcut: change approval preset",
        }
    end

    if
        not existing.model
        and config_options
        and (
            (
                config_options.get_model_option
                and config_options:get_model_option() ~= nil
            )
            or (
                config_options.get_thought_level_option
                and config_options:get_thought_level_option() ~= nil
            )
        )
    then
        commands[#commands + 1] = {
            name = "model",
            description = "Codex-only Agentic shortcut: change model or reasoning effort",
        }
    end

    if
        not existing.skills
        and session.skill_picker
        and session.skill_picker.has_skills
        and session.skill_picker:has_skills()
    then
        commands[#commands + 1] = {
            name = "skills",
            description = "Codex-only Agentic shortcut: list available skills",
        }
    end

    return commands
end

--- @param session agentic.SessionManager
--- @param command_name string
--- @return boolean
local function is_available_local_command(session, command_name)
    for _, command in ipairs(CodexLocalCommands.get_available_commands(session)) do
        if command.name == command_name then
            return true
        end
    end

    return false
end

--- @param session agentic.SessionManager
--- @return boolean
local function show_model_shortcut(session)
    local config_options = session.config_options
    if not config_options then
        return false
    end

    local has_model = config_options.get_model_option
        and config_options:get_model_option() ~= nil
    local has_thought_level = config_options.get_thought_level_option
        and config_options:get_thought_level_option() ~= nil

    if
        has_model
        and has_thought_level
        and config_options.show_config_selector
    then
        return config_options:show_config_selector()
    end

    if has_model and config_options.show_model_selector then
        return config_options:show_model_selector()
    end

    if has_thought_level and config_options.show_thought_level_selector then
        return config_options:show_thought_level_selector()
    end

    return false
end

--- @param session agentic.SessionManager
--- @param input_text string
--- @return boolean handled
function CodexLocalCommands.handle_input(session, input_text)
    if not is_codex_session(session) then
        return false
    end

    local command_name = SlashCommands.get_input_command_name(input_text)
    if
        not command_name
        or not is_available_local_command(session, command_name)
    then
        return false
    end

    if command_name == "permissions" then
        if
            session.config_options
            and session.config_options.show_approval_preset_selector
        then
            session.config_options:show_approval_preset_selector()
            return true
        end

        return false
    end

    if command_name == "model" then
        return show_model_shortcut(session)
    end

    if command_name == "skills" then
        if session.skill_picker and session.skill_picker.show_selector then
            session.skill_picker:show_selector(function(skill)
                if
                    not skill
                    or not session.widget
                    or not session.widget.set_input_text
                then
                    return
                end

                session.widget:set_input_text("$" .. skill.name .. " ")
                if session.widget.focus_input then
                    session.widget:focus_input()
                end
            end)
            return true
        end

        return false
    end

    return false
end

return CodexLocalCommands
