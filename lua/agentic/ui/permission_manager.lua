local Chooser = require("agentic.ui.chooser")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local PermissionOption = require("agentic.utils.permission_option")
local ReviewState = require("agentic.ui.diff_preview.review_state")
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

--- Global interactive flow coordination.
--- Only one permission/review flow may be active at a time.
local GLOBAL_FLOW_STATE = {
    active_manager = nil,
    queued_managers = {},
}

--- @class agentic.ui.PermissionManager.PermissionRequest
--- @field sessionId string|nil
--- @field toolCallId string
--- @field request agentic.acp.RequestPermission
--- @field callback fun(option_id: string|nil)

--- @class agentic.ui.PermissionManager
--- @field session_state agentic.session.SessionState
--- @field queue agentic.ui.PermissionManager.PermissionRequest[]
--- @field current_request? agentic.ui.PermissionManager.PermissionRequest Currently displayed request
--- @field _chooser_tabpage? integer
--- @field _diff_review_handler? fun(current_request: agentic.ui.PermissionManager.PermissionRequest): agentic.ui.DiffPreview.ShowResult|nil
--- @field _state_listener_id? integer
--- @field _destroyed boolean
local PermissionManager = {}
PermissionManager.__index = PermissionManager

--- @param request agentic.ui.PermissionManager.PermissionRequest|nil
--- @return string|nil
local function get_review_key_for_request(request)
    if not request then
        return nil
    end

    return ReviewState.create_review_key(request.sessionId, request.toolCallId)
end

--- @param request agentic.ui.PermissionManager.PermissionRequest|nil
--- @param option_id string|nil
local function resolve_review_from_chooser(request, option_id)
    local review_key = get_review_key_for_request(request)
    if
        not review_key
        or not ReviewState.should_resolve_from_chooser(review_key)
    then
        return false
    end

    local permission_state = PermissionOption.get_state_for_option_id(
        request and request.request and request.request.options or nil,
        option_id
    )
    local decision = permission_state == "approved" and "accept" or "reject"

    return ReviewState.resolve_all_pending(review_key, decision, {
        skip_permission_callback = true,
    })
end

--- @param manager agentic.ui.PermissionManager
--- @return boolean
local function is_queued_manager(manager)
    for _, queued_manager in ipairs(GLOBAL_FLOW_STATE.queued_managers) do
        if queued_manager == manager then
            return true
        end
    end

    return false
end

--- @param manager agentic.ui.PermissionManager
local function remove_queued_manager(manager)
    for index, queued_manager in ipairs(GLOBAL_FLOW_STATE.queued_managers) do
        if queued_manager == manager then
            table.remove(GLOBAL_FLOW_STATE.queued_managers, index)
            return
        end
    end
end

local function activate_next_manager()
    while #GLOBAL_FLOW_STATE.queued_managers > 0 do
        local manager = table.remove(GLOBAL_FLOW_STATE.queued_managers, 1)
        if manager and not manager._destroyed then
            GLOBAL_FLOW_STATE.active_manager = manager
            manager:_process_next()
            if manager.current_request ~= nil or #manager.queue > 0 then
                return
            end
        end
    end

    GLOBAL_FLOW_STATE.active_manager = nil
end

--- @param session_state agentic.session.SessionState|nil
--- @return agentic.ui.PermissionManager
function PermissionManager:new(session_state)
    local instance = setmetatable({
        session_state = session_state or SessionState:new(),
        queue = {},
        current_request = nil,
        _chooser_tabpage = nil,
        _diff_review_handler = nil,
        _state_listener_id = nil,
        _destroyed = false,
    }, self)

    instance:_sync_state()
    instance._state_listener_id = instance.session_state:subscribe(
        function(state)
            PermissionManager._sync_state(instance, state)
        end
    )

    return instance
end

--- @param state agentic.session.State|nil
function PermissionManager:_sync_state(state)
    state = state or self.session_state:get_state()
    self.queue = SessionSelectors.get_permission_queue(state)
    local current_request = SessionSelectors.get_current_permission(state)
    --- @cast current_request agentic.ui.PermissionManager.PermissionRequest|nil
    self.current_request = current_request
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
    if
        self.current_request
        and self.current_request.toolCallId == tool_call_id
    then
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
        self:_request_global_turn()
    end
end

function PermissionManager:_process_next()
    if GLOBAL_FLOW_STATE.active_manager ~= self then
        return
    end

    if self.current_request or #self.queue == 0 then
        return
    end

    self.session_state:dispatch(SessionEvents.show_next_permission())

    local current = self.current_request
    if not current then
        return
    end

    if self._diff_review_handler then
        local ok, activation = pcall(self._diff_review_handler, current)
        if ok and activation and activation.interactive == true then
            return
        end
    end

    self:_show_current_request_chooser()
end

function PermissionManager:_request_global_turn()
    if self._destroyed then
        return
    end

    if GLOBAL_FLOW_STATE.active_manager == self then
        self:_process_next()
        return
    end

    if GLOBAL_FLOW_STATE.active_manager == nil then
        GLOBAL_FLOW_STATE.active_manager = self
        self:_process_next()
        if self.current_request == nil and #self.queue == 0 then
            activate_next_manager()
        end
        return
    end

    if not is_queued_manager(self) then
        GLOBAL_FLOW_STATE.queued_managers[#GLOBAL_FLOW_STATE.queued_managers + 1] =
            self
    end
end

function PermissionManager:_release_global_turn()
    remove_queued_manager(self)

    if GLOBAL_FLOW_STATE.active_manager == self then
        GLOBAL_FLOW_STATE.active_manager = nil
        activate_next_manager()
    end
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
        local kind = PermissionOption.get_kind(option)
        if kind == "reject_once" or kind == "reject_always" then
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
        show_title = false,
        format_item = function(option)
            return self:_format_option(option)
        end,
        max_height = math.min(#options, 6),
        escape_choice = self:_find_default_reject_option(options),
    }, function(choice)
        self:_complete_request(choice and choice.optionId or nil)
    end)
end

function PermissionManager:_show_current_request_chooser()
    local current = self.current_request
    if not current then
        return
    end

    local request = current.request
    local sorted_options =
        PermissionManager._sort_permission_options(request.options)
    self:_show_chooser(current.toolCallId, sorted_options)
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
        local priority_a = PERMISSION_KIND_PRIORITY[PermissionOption.get_kind(a)]
            or 999
        local priority_b = PERMISSION_KIND_PRIORITY[PermissionOption.get_kind(b)]
            or 999
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
    resolve_review_from_chooser(current, option_id)
    current.callback(option_id)

    self.session_state:dispatch(SessionEvents.complete_current_permission())
    if #self.queue > 0 then
        self:_process_next()
        if self.current_request ~= nil then
            return
        end
    end

    self:_release_global_turn()
end

--- @param handler fun(current_request: agentic.ui.PermissionManager.PermissionRequest): agentic.ui.DiffPreview.ShowResult|nil
function PermissionManager:set_diff_review_handler(handler)
    self._diff_review_handler = handler
end

function PermissionManager:show_current_request_chooser()
    if not self.current_request then
        return
    end

    self:_show_current_request_chooser()
end

--- @param option_id string|nil
function PermissionManager:complete_current_request(option_id)
    self:_complete_request(option_id)
end

--- Clear all displayed buttons and keymaps, cancel all pending requests
function PermissionManager:clear()
    local current = self.current_request
    local queue = self.queue

    self:_close_chooser()

    if current then
        resolve_review_from_chooser(current, nil)
        pcall(current.callback, nil)
    end

    for _, item in ipairs(queue) do
        pcall(item.callback, nil)
    end

    self.session_state:dispatch(SessionEvents.clear_permissions())
    self:_release_global_turn()
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
    self._destroyed = true
    self:_release_global_turn()
    self.session_state:unsubscribe(self._state_listener_id)
    self._state_listener_id = nil
end

return PermissionManager
