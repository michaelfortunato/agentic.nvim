local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")
local SessionSelectors = require("agentic.session.session_selectors")

local DIFF_PREVIEW_KINDS = {
    edit = true,
    create = true,
    write = true,
}

--- @class agentic.ui.ReviewController
--- @field session_state agentic.session.SessionState
--- @field widget agentic.ui.ChatWidget
--- @field permission_manager agentic.ui.PermissionManager|nil
--- @field _state_listener_id? integer
local ReviewController = {}
ReviewController.__index = ReviewController

--- @param tracker table|nil
--- @return agentic.ui.MessageWriter.ToolCallDiff|nil
local function get_review_diff(tracker)
    if not tracker or not tracker.content_nodes then
        return nil
    end

    for _, content_node in ipairs(tracker.content_nodes) do
        if content_node.type == "diff_output" then
            return {
                old = vim.deepcopy(content_node.old_lines or {}),
                new = vim.deepcopy(content_node.new_lines or {}),
            }
        end
    end

    return nil
end

--- @param session_state agentic.session.SessionState
--- @param widget agentic.ui.ChatWidget
--- @param permission_manager agentic.ui.PermissionManager|nil
--- @return agentic.ui.ReviewController
function ReviewController:new(session_state, widget, permission_manager)
    local instance = setmetatable({
        session_state = session_state,
        widget = widget,
        permission_manager = permission_manager,
        _state_listener_id = nil,
    }, self)

    instance._state_listener_id = session_state:subscribe(function(state, event)
        instance:_handle_state_event(state, event)
    end)

    return instance
end

--- @param options agentic.acp.PermissionOption[]|nil
--- @param preferred_kinds string[]
--- @return string|nil
local function find_permission_option_id(options, preferred_kinds)
    if not options then
        return nil
    end

    for _, kind in ipairs(preferred_kinds) do
        for _, option in ipairs(options) do
            if option.kind == kind then
                return option.optionId
            end
        end
    end

    return nil
end

--- @param tracker table|nil
--- @return boolean
function ReviewController._is_reviewable(tracker)
    return tracker ~= nil
        and DIFF_PREVIEW_KINDS[tracker.kind] == true
        and get_review_diff(tracker) ~= nil
        and tracker.file_path ~= nil
end

--- @param state agentic.session.State
--- @param event table|nil
function ReviewController:_handle_state_event(state, event)
    if not event or not event.type then
        return
    end

    if event.type == "review/set_active_tool_call" then
        self:_show_active_review(state)
        return
    end

    if event.type == "interaction/upsert_tool_call" then
        local active_tool_call_id =
            SessionSelectors.get_active_review_tool_call_id(state)
        if
            active_tool_call_id
            and active_tool_call_id == event.tool_call.tool_call_id
        then
            self:_show_active_review(state)
        end
        return
    end

    if event.type == "review/clear_active_tool_call" then
        self:_clear_review_for_tool(
            state,
            event.tool_call_id,
            event.is_rejection
        )
    end
end

--- @param state agentic.session.State
function ReviewController:_show_active_review(state)
    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= self.widget.tab_page_id
    then
        return
    end

    local tracker = SessionSelectors.get_active_review_tool_call(state)
    if not self._is_reviewable(tracker) then
        return
    end

    local current_permission = SessionSelectors.get_current_permission(state)
    local review_actions = nil
    if
        current_permission
        and current_permission.toolCallId == tracker.tool_call_id
        and self.permission_manager
    then
        local accept_option_id = find_permission_option_id(
            current_permission.request and current_permission.request.options or nil,
            { "allow_once", "allow_always" }
        )
        local reject_option_id = find_permission_option_id(
            current_permission.request and current_permission.request.options or nil,
            { "reject_once", "reject_always" }
        )

        if accept_option_id and reject_option_id then
            review_actions = {
                on_accept = function()
                    self.permission_manager:complete_current_request(
                        accept_option_id
                    )
                end,
                on_reject = function()
                    self.permission_manager:complete_current_request(
                        reject_option_id
                    )
                end,
            }
        end
    end

    DiffPreview.show_diff({
        file_path = tracker.file_path,
        diff = get_review_diff(tracker),
        review_actions = review_actions,
        get_winid = function(bufnr)
            local winid = self.widget:find_first_non_widget_window()
            if not winid then
                return self.widget:open_left_window(bufnr, false)
            end

            local ok, err = pcall(vim.api.nvim_win_set_buf, winid, bufnr)
            if not ok then
                Logger.notify(
                    "Failed to set buffer in window: " .. tostring(err),
                    vim.log.levels.WARN
                )
                return nil
            end

            return winid
        end,
    })
end

--- @param current_request agentic.ui.PermissionManager.PermissionRequest
--- @return boolean
function ReviewController:activate_diff_review(current_request)
    local state = self.session_state:get_state()
    local tracker = SessionSelectors.get_tool_call(state, current_request.toolCallId)
    if not self._is_reviewable(tracker) then
        return false
    end

    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= self.widget.tab_page_id
    then
        return false
    end

    self:_show_active_review(state)
    return true
end

--- @param state agentic.session.State
--- @param tool_call_id string|nil
--- @param is_rejection boolean|nil
function ReviewController:_clear_review_for_tool(
    state,
    tool_call_id,
    is_rejection
)
    if not tool_call_id then
        return
    end

    local tracker = SessionSelectors.get_tool_call(state, tool_call_id)
    if not self._is_reviewable(tracker) then
        return
    end

    DiffPreview.clear_diff(tracker.file_path, is_rejection)
end

function ReviewController:destroy()
    self.session_state:unsubscribe(self._state_listener_id)
    self._state_listener_id = nil
end

return ReviewController
