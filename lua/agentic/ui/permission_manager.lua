local Chooser = require("agentic.ui.chooser")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionEvents = require("agentic.session.session_events")
local SessionSelectors = require("agentic.session.session_selectors")
local SessionState = require("agentic.session.session_state")

-- Priority order for permission option kinds based on ACP tool-calls documentation
-- Lower number = higher priority (appears first)
-- Order from https://agentclientprotocol.com/protocol/tool-calls.md:
-- 1. allow_once - Allow this operation only this time
-- 2. allow_always - Allow this operation and remember the choice
-- 3. reject_once - Reject this operation only this time
-- 4. reject_always - Reject this operation and remember the choice
local PERMISSION_KIND_PRIORITY = {
    allow_once = 1,
    allow_always = 2,
    reject_once = 3,
    reject_always = 4,
}

--- @class agentic.ui.PermissionManager
--- @field session_state agentic.session.SessionState
--- @field queue table[] Queue of pending requests {toolCallId, request, callback}
--- @field current_request? agentic.ui.PermissionManager.PermissionRequest Currently displayed request
--- @field _chooser_tabpage? integer
--- @field _state_listener_id? integer
local PermissionManager = {}
PermissionManager.__index = PermissionManager

--- @param session_state agentic.session.SessionState|nil
--- @return agentic.ui.PermissionManager
function PermissionManager:new(session_state)
    local instance = setmetatable({
        session_state = session_state or SessionState:new(),
        queue = {},
        current_request = nil,
        _chooser_tabpage = nil,
        _state_listener_id = nil,
    }, self)

    instance:_sync_state()
    instance._state_listener_id =
        instance.session_state:subscribe(function(state)
            instance:_sync_state(state)
        end)

    return instance
end

--- @param state agentic.session.State|nil
function PermissionManager:_sync_state(state)
    state = state or self.session_state:get_state()
    self.queue = SessionSelectors.get_permission_queue(state)
    self.current_request = SessionSelectors.get_current_permission(state)
end

--- Add a new permission request to the queue to be processed sequentially
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function PermissionManager:add_request(request, callback)
    if not request.toolCall or not request.toolCall.toolCallId then
        Logger.debug(
            "PermissionManager: Invalid request - missing toolCall.toolCallId"
        )
        return
    end

    local tool_call_id = request.toolCall.toolCallId
    if self.current_request and self.current_request.toolCallId == tool_call_id then
        Logger.debug(
            "PermissionManager: ignoring duplicate permission request",
            tool_call_id
        )
        return
    end

    for _, item in ipairs(self.queue) do
        if item.toolCallId == tool_call_id then
            Logger.debug(
                "PermissionManager: ignoring duplicate permission request",
                tool_call_id
            )
            return
        end
    end

    self.session_state:dispatch(
        SessionEvents.enqueue_permission(request, callback)
    )

    if not self.current_request then
        self:_process_next()
    end
end

function PermissionManager:_process_next()
    if self.current_request or #self.queue == 0 then
        return
    end

    self.session_state:dispatch(SessionEvents.show_next_permission())

    local current = self.current_request
    if not current then
        return
    end

    local request = current.request
    local sorted_options = self._sort_permission_options(request.options)
    self:_show_chooser(current.toolCallId, sorted_options)
end

--- @param tool_call_id string
--- @return string
function PermissionManager:_build_prompt(tool_call_id)
    local tool_call = SessionSelectors.get_tool_call(
        self.session_state:get_state(),
        tool_call_id
    )

    if tool_call and tool_call.kind then
        return string.format("Approve %s?", tool_call.kind)
    end

    return "Approval required"
end

--- @param option agentic.acp.PermissionOption
--- @return string
function PermissionManager:_format_option(option)
    local icon = Config.permission_icons[option.kind]
    if icon and icon ~= "" then
        return string.format("%s %s", icon, option.name)
    end

    return option.name
end

--- @param options agentic.acp.PermissionOption[]
--- @return agentic.acp.PermissionOption|nil
function PermissionManager:_find_default_reject_option(options)
    for _, option in ipairs(options) do
        if option.kind == "reject_once" or option.kind == "reject_always" then
            return option
        end
    end

    return nil
end

--- @param tool_call_id string
--- @param options agentic.acp.PermissionOption[]
function PermissionManager:_show_chooser(tool_call_id, options)
    self:_close_chooser()

    self._chooser_tabpage = vim.api.nvim_get_current_tabpage()
    Chooser.show(options, {
        prompt = self:_build_prompt(tool_call_id),
        format_item = function(option)
            return self:_format_option(option)
        end,
        max_height = math.min(#options, 6),
        escape_choice = self:_find_default_reject_option(options),
    }, function(choice)
        self:_complete_request(choice and choice.optionId or nil)
    end)
end

function PermissionManager:_close_chooser()
    if self._chooser_tabpage == nil then
        return
    end

    Chooser.close(self._chooser_tabpage)
    self._chooser_tabpage = nil
end

--- @param options agentic.acp.PermissionOption[]
--- @return agentic.acp.PermissionOption[]
function PermissionManager._sort_permission_options(options)
    local sorted = {}
    for _, option in ipairs(options) do
        table.insert(sorted, option)
    end

    table.sort(sorted, function(a, b)
        local priority_a = PERMISSION_KIND_PRIORITY[a.kind] or 999
        local priority_b = PERMISSION_KIND_PRIORITY[b.kind] or 999
        return priority_a < priority_b
    end)

    return sorted
end

--- Complete the current request and process next in queue
--- @param option_id string|nil
function PermissionManager:_complete_request(option_id)
    local current = self.current_request
    if not current then
        return
    end

    self:_close_chooser()
    current.callback(option_id)

    self.session_state:dispatch(SessionEvents.complete_current_permission())
    self:_process_next()
end

--- Clear all displayed buttons and keymaps, cancel all pending requests
function PermissionManager:clear()
    local current = self.current_request
    local queue = self.queue

    self:_close_chooser()

    if current then
        pcall(current.callback, nil)
    end

    for _, item in ipairs(queue) do
        pcall(item.callback, nil)
    end

    self.session_state:dispatch(SessionEvents.clear_permissions())
end

--- Remove permission request for a specific tool call ID (e.g., when tool call fails)
--- @param toolCallId string
function PermissionManager:remove_request_by_tool_call_id(toolCallId)
    if
        self.current_request
        and self.current_request.toolCallId == toolCallId
    then
        self:_complete_request(nil)
        return
    end

    self.session_state:dispatch(
        SessionEvents.remove_permission_by_tool_call_id(toolCallId)
    )
end

function PermissionManager:destroy()
    self:_close_chooser()
    self.session_state:unsubscribe(self._state_listener_id)
    self._state_listener_id = nil
end

return PermissionManager
