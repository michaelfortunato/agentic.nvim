local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")
local Chooser = require("agentic.ui.chooser")

--- @class agentic.SessionRegistry
--- @field sessions table<integer, agentic.SessionManager|nil> Weak map: instance id -> SessionManager instance
--- @field _next_instance_id integer
--- @field _window_active_sessions table<integer, integer|nil> Editor window id -> instance id
local SessionRegistry = {
    sessions = setmetatable({}, { __mode = "v" }),
    _next_instance_id = 0,
    _window_active_sessions = {},
}

--- @param tab_page_id integer|nil
--- @return integer
local function normalize_tab_page_id(tab_page_id)
    return tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
end

--- @param sessions agentic.SessionManager[]
local function sort_sessions(sessions)
    table.sort(sessions, function(left, right)
        return (left.instance_id or 0) < (right.instance_id or 0)
    end)
end

--- @param winid integer|nil
--- @return integer|nil
local function normalize_window_id(winid)
    if winid == nil then
        return nil
    end

    if not vim.api.nvim_win_is_valid(winid) then
        return nil
    end

    return winid
end

--- @param session agentic.SessionManager|nil
--- @param winid integer|nil
function SessionRegistry.set_active_session(session, winid)
    if not session or not session.instance_id then
        return
    end

    local resolved_winid = normalize_window_id(winid)
    if resolved_winid == nil then
        return
    end

    SessionRegistry._window_active_sessions[resolved_winid] =
        session.instance_id
end

--- @param tab_page_id integer|nil
--- @return agentic.SessionManager[]
function SessionRegistry.get_tab_sessions(tab_page_id)
    local tab_id = normalize_tab_page_id(tab_page_id)

    --- @type agentic.SessionManager[]
    local sessions = {}
    for _, session in pairs(SessionRegistry.sessions) do
        if session and session.tab_page_id == tab_id then
            sessions[#sessions + 1] = session
        end
    end

    sort_sessions(sessions)
    return sessions
end

--- @param bufnr integer|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.find_session_by_buf(bufnr)
    if bufnr == nil then
        return nil
    end

    for _, session in pairs(SessionRegistry.sessions) do
        if
            session
            and session.widget
            and session.widget.owns_buffer
            and session.widget:owns_buffer(bufnr)
        then
            return session
        end
    end

    return nil
end

--- @param winid integer|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.find_session_by_win(winid)
    if winid == nil or not vim.api.nvim_win_is_valid(winid) then
        return nil
    end

    return SessionRegistry.find_session_by_buf(vim.api.nvim_win_get_buf(winid))
end

--- @param winid integer|nil
--- @return agentic.SessionManager|nil
local function get_active_session_for_window(winid)
    local resolved_winid = normalize_window_id(winid)
    if resolved_winid == nil then
        return nil
    end

    local active_instance_id =
        SessionRegistry._window_active_sessions[resolved_winid]
    local active_session = active_instance_id ~= nil
            and SessionRegistry.sessions[active_instance_id]
        or nil

    if active_session then
        return active_session
    end

    SessionRegistry._window_active_sessions[resolved_winid] = nil
    return nil
end

--- @param tab_page_id integer|nil
--- @return agentic.SessionManager|nil
local function resolve_context_session(tab_page_id)
    local current_session =
        SessionRegistry.find_session_by_buf(vim.api.nvim_get_current_buf())
    if
        current_session
        and (tab_page_id == nil or current_session.tab_page_id == tab_page_id)
    then
        return current_session
    end

    local current_winid = vim.api.nvim_get_current_win()
    local active_window_session = get_active_session_for_window(current_winid)
    if
        active_window_session
        and (
            tab_page_id == nil
            or active_window_session.tab_page_id == tab_page_id
        )
    then
        return active_window_session
    end

    return nil
end

--- @param tab_page_id integer
--- @return agentic.SessionManager|nil
local function create_session(tab_page_id)
    if not ACPHealth.check_configured_provider() then
        Logger.debug("Session creation aborted: No configured ACP provider")
        return nil
    end

    local SessionManager = require("agentic.session_manager")

    SessionRegistry._next_instance_id = SessionRegistry._next_instance_id + 1
    local instance_id = SessionRegistry._next_instance_id
    local instance = SessionManager:new(tab_page_id, {
        instance_id = instance_id,
    }) --[[@as agentic.SessionManager|nil]]

    if instance ~= nil then
        instance.instance_id = instance.instance_id or instance_id
        SessionRegistry.sessions[instance.instance_id] = instance
    end

    return instance
end

--- @param instance agentic.SessionManager|nil
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil
local function invoke_callback(instance, callback)
    if instance and callback then
        local ok, err = pcall(callback, instance)

        if not ok then
            Logger.notify("Session create callback error: " .. vim.inspect(err))
        end
    end

    return instance
end

--- @param session agentic.SessionManager|nil
--- @return string
local function get_session_picker_label(session)
    local state = session
        and session.session_state
        and session.session_state.get_state
        and session.session_state:get_state()
        or nil
    local title = state
        and state.session
        and vim.trim(state.session.title or "")
        or ""
    local session_id = session and session.session_id or nil
    local session_label = title ~= "" and title or "(untitled session)"
    local suffix = session_id and ("ACP " .. session_id)
        or "ACP session pending"

    return string.format(
        "#%s · Tab %d · %s · %s",
        tostring(session and session.instance_id or "?"),
        session and session.tab_page_id or 0,
        session_label,
        suffix
    )
end

--- @param tab_page_id integer|nil
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil session resolved from the current widget or invoking editor window
function SessionRegistry.get_current_session(tab_page_id, callback)
    local tab_id = normalize_tab_page_id(tab_page_id)
    local instance = resolve_context_session(tab_id)
    return invoke_callback(instance, callback)
end

--- @param tab_page_id integer|nil
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil session resolved from the current widget/editor context or a newly-created one
function SessionRegistry.get_session_for_tab_page(tab_page_id, callback)
    local tab_id = normalize_tab_page_id(tab_page_id)
    local instance = resolve_context_session(tab_id)

    if not instance then
        instance = create_session(tab_id)
    end

    return invoke_callback(instance, callback)
end

--- Creates an additional session in the given tab page.
--- @param tab_page_id integer|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.new_session(tab_page_id)
    local tab_id = normalize_tab_page_id(tab_page_id)
    return create_session(tab_id)
end

--- @param target agentic.SessionManager|integer|nil
--- @return agentic.SessionManager|nil
local function resolve_session_target(target)
    if type(target) == "table" then
        return target --[[@as agentic.SessionManager]]
    end

    if type(target) == "number" then
        local session = SessionRegistry.sessions[target]
        if session then
            return session
        end

        return resolve_context_session(target)
    end

    return SessionRegistry.get_current_session(nil)
end

--- Destroys a session instance and removes it from the registry.
--- If a tabpage id is passed, destroys the session resolved from the current UI context in that tab.
--- @param target agentic.SessionManager|integer|nil
function SessionRegistry.destroy_session(target)
    local session = resolve_session_target(target)
    if not session then
        return
    end

    local instance_id = session.instance_id
    if instance_id ~= nil then
        SessionRegistry.sessions[instance_id] = nil
    end

    for winid, active_instance_id in
        pairs(SessionRegistry._window_active_sessions)
    do
        if active_instance_id == instance_id then
            SessionRegistry._window_active_sessions[winid] = nil
        end
    end

    local ok, err = pcall(function()
        session:destroy()
    end)
    if not ok then
        Logger.debug("Session destroy error:", err)
    end
end

--- Destroys all tracked sessions in a tab page.
--- @param tab_page_id integer|nil
function SessionRegistry.destroy_sessions_for_tab(tab_page_id)
    local tab_id = normalize_tab_page_id(tab_page_id)
    local sessions = SessionRegistry.get_tab_sessions(tab_id)

    for _, session in ipairs(sessions) do
        SessionRegistry.destroy_session(session)
    end
end

--- @param current_session agentic.SessionManager|nil
--- @param on_selected fun(session: agentic.SessionManager|nil)
--- @return boolean shown
function SessionRegistry.select_live_session(current_session, on_selected)
    local tab_id = normalize_tab_page_id(nil)
    --- @type {session: agentic.SessionManager, label: string}[]
    local items = {}

    for _, session in ipairs(SessionRegistry.get_tab_sessions(tab_id)) do
        if session ~= current_session then
            items[#items + 1] = {
                session = session,
                label = get_session_picker_label(session),
            }
        end
    end

    if #items == 0 then
        on_selected(nil)
        return false
    end

    Chooser.show(items, {
        prompt = "Load live session into current chat widget:",
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        on_selected(choice and choice.session or nil)
    end)

    return true
end

--- @param target_session agentic.SessionManager|nil
--- @return boolean swapped
function SessionRegistry.load_session_into_current_widget(target_session)
    if not target_session then
        return false
    end

    local current_session = SessionRegistry.get_current_session(nil)
    if
        not current_session
        or current_session == target_session
        or not current_session.widget
        or not target_session.widget
    then
        return false
    end

    local current_editor_win = current_session.widget.find_first_editor_window
            and current_session.widget:find_first_editor_window()
        or nil
    local target_editor_win = target_session.widget.find_first_editor_window
            and target_session.widget:find_first_editor_window()
        or nil

    current_session:swap_widget(target_session)

    SessionRegistry.set_active_session(target_session, current_editor_win)
    SessionRegistry.set_active_session(current_session, target_editor_win)

    return true
end

--- @param on_selected fun(provider_name: agentic.UserConfig.ProviderName|nil) Callback that will be called with the selected provider name, if any
function SessionRegistry.select_provider(on_selected)
    local available_providers = ACPHealth.get_default_provider_names()

    --- @class _ProviderStatus
    --- @field name string
    --- @field installed boolean

    --- @type _ProviderStatus[]
    local sorted_providers = {}

    --- @type _ProviderStatus[]
    local not_installed = {}

    for _, provider_name in ipairs(available_providers) do
        local provider_config = Config.acp_providers[provider_name]
        if
            provider_config
            and ACPHealth.is_command_available(provider_config.command)
        then
            sorted_providers[#sorted_providers + 1] = {
                name = provider_name,
                installed = true,
            }
        else
            not_installed[#not_installed + 1] = {
                name = provider_name,
                installed = false,
            }
        end
    end

    vim.list_extend(sorted_providers, not_installed)

    Chooser.show(sorted_providers, {
        prompt = "Select an ACP provider for the new session:",
        --- @param item _ProviderStatus
        format_item = function(item)
            local label = item.name

            if label == Config.provider then
                label = label .. " (current)"
            elseif label == DefaultConfig.provider then
                label = label .. " (default)"
            end

            return label
                .. (item.installed and " ✓ available" or " ✗ not installed")
        end,
    }, function(selected_provider)
        on_selected(selected_provider and selected_provider.name)
    end)
end

return SessionRegistry
