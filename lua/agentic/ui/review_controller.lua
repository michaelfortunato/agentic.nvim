local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")
local PermissionOption = require("agentic.utils.permission_option")
local ReviewState = require("agentic.ui.diff_preview.review_state")
local SessionSelectors = require("agentic.session.session_selectors")

--- @param permission_manager agentic.ui.PermissionManager
--- @param option_id string
local function complete_current_request(permission_manager, option_id)
    permission_manager:complete_current_request(option_id)
end

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

--- @param tracker table|nil
--- @return string|nil
local function get_review_file_path(tracker)
    if not tracker then
        return nil
    end

    if tracker.file_path and tracker.file_path ~= "" then
        return tracker.file_path
    end

    for _, content_node in ipairs(tracker.content_nodes or {}) do
        if
            content_node.type == "diff_output"
            and content_node.file_path
            and content_node.file_path ~= ""
        then
            return content_node.file_path
        end
    end

    return nil
end

--- @param current_permission agentic.ui.PermissionManager.PermissionRequest|nil
--- @param tool_call_id string|nil
--- @return string|nil
local function get_review_key(current_permission, tool_call_id)
    if
        not current_permission
        or current_permission.toolCallId ~= tool_call_id
        or current_permission.sessionId == nil
    then
        return nil
    end

    return ReviewState.create_review_key(
        current_permission.sessionId,
        current_permission.toolCallId
    )
end

--- @param permission_manager agentic.ui.PermissionManager
--- @param current_permission agentic.ui.PermissionManager.PermissionRequest
--- @return agentic.ui.DiffPreview.ReviewActions|nil
local function build_review_actions(permission_manager, current_permission)
    local permission_request = current_permission.request
    local options = permission_request and permission_request.options or nil
    local accept_once_option_id =
        PermissionOption.find_option_id(options, { "allow_once" })
    local accept_always_option_id =
        PermissionOption.find_option_id(options, { "allow_always" })
    local reject_once_option_id =
        PermissionOption.find_option_id(options, { "reject_once" })
    local reject_always_option_id =
        PermissionOption.find_option_id(options, { "reject_always" })
    local accept_option_id = accept_once_option_id or accept_always_option_id
    local reject_option_id = reject_once_option_id or reject_always_option_id
    local accept_all_option_id = accept_always_option_id
        or accept_once_option_id
    local reject_all_option_id = reject_always_option_id
        or reject_once_option_id

    if not accept_option_id or not reject_option_id then
        return nil
    end

    local accept_action_id = accept_option_id
    local reject_action_id = reject_option_id
    local accept_all_action_id = accept_all_option_id or accept_option_id
    local reject_all_action_id = reject_all_option_id or reject_option_id

    return {
        on_accept = function()
            complete_current_request(permission_manager, accept_action_id)
        end,
        on_reject = function()
            complete_current_request(permission_manager, reject_action_id)
        end,
        on_accept_all = function()
            complete_current_request(permission_manager, accept_all_action_id)
        end,
        on_reject_all = function()
            complete_current_request(permission_manager, reject_all_action_id)
        end,
    }
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
        ReviewController._handle_state_event(instance, state, event)
    end)

    return instance
end

--- @param tracker table|nil
--- @return boolean
function ReviewController._is_reviewable(tracker)
    return tracker ~= nil
        and get_review_diff(tracker) ~= nil
        and get_review_file_path(tracker) ~= nil
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

    if event.type == "permissions/show_next" then
        local active_tool_call_id =
            SessionSelectors.get_active_review_tool_call_id(state)
        local current_permission =
            SessionSelectors.get_current_permission(state)
        --- @cast current_permission agentic.ui.PermissionManager.PermissionRequest|nil
        if
            active_tool_call_id
            and current_permission
            and current_permission.toolCallId == active_tool_call_id
        then
            self:_show_active_review(state)
        end
        return
    end

    if event.type == "review/clear_active_tool_call" then
        self:_clear_review_for_tool(
            state,
            event.tool_call_id,
            event.clear_reason
        )
    end
end

--- @param state agentic.session.State
--- @return agentic.ui.DiffPreview.ShowResult
function ReviewController:_show_active_review(state)
    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= self.widget.tab_page_id
    then
        return {
            interactive = false,
            bufnr = nil,
            review_key = nil,
            mode = "none",
        }
    end

    local tracker = SessionSelectors.get_active_review_tool_call(state)
    if not self._is_reviewable(tracker) then
        return {
            interactive = false,
            bufnr = nil,
            review_key = nil,
            mode = "none",
        }
    end
    --- @cast tracker agentic.session.InteractionToolCallNode

    local current_permission = SessionSelectors.get_current_permission(state)
    --- @cast current_permission agentic.ui.PermissionManager.PermissionRequest|nil
    local review_diff = get_review_diff(tracker)
    local tracker_file_path = get_review_file_path(tracker)
    local tracker_tool_call_id = tracker.tool_call_id
    if not review_diff or not tracker_file_path or not tracker_tool_call_id then
        return {
            interactive = false,
            bufnr = nil,
            review_key = nil,
            mode = "none",
        }
    end

    local review_key = get_review_key(current_permission, tracker_tool_call_id)
    local review_actions = nil
    if review_key and self.permission_manager then
        review_actions = build_review_actions(
            self.permission_manager --[[@as agentic.ui.PermissionManager]],
            current_permission --[[@as agentic.ui.PermissionManager.PermissionRequest]]
        )
    end

    return DiffPreview.show_diff({
        file_path = tracker_file_path,
        diff = review_diff,
        review_actions = review_actions,
        review_key = review_key,
        tool_call_id = tracker_tool_call_id,
        force_inline = review_actions ~= nil,
        on_detach = function(detach)
            self:_handle_preview_detach(detach)
        end,
        get_winid = function(bufnr)
            local winid = self.widget:find_first_editor_window()
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

--- @param detach agentic.ui.DiffPreview.DetachPayload
function ReviewController:_handle_preview_detach(detach)
    if not self.permission_manager or not detach.review_key then
        return
    end

    local state = self.session_state:get_state()
    local current_permission = SessionSelectors.get_current_permission(state)
    --- @cast current_permission agentic.ui.PermissionManager.PermissionRequest|nil
    if
        not current_permission
        or SessionSelectors.get_active_review_tool_call_id(state)
            ~= current_permission.toolCallId
    then
        return
    end

    local expected_review_key =
        get_review_key(current_permission, current_permission.toolCallId)
    if expected_review_key ~= detach.review_key then
        return
    end

    if detach.reason == "manual_clear" then
        self.permission_manager:show_current_request_chooser()
        return
    end

    if vim.api.nvim_get_current_tabpage() ~= self.widget.tab_page_id then
        self.permission_manager:show_current_request_chooser()
        return
    end

    local result = self:_show_active_review(state)
    if not result.interactive then
        self.permission_manager:show_current_request_chooser()
    end
end

--- @param current_request agentic.ui.PermissionManager.PermissionRequest
--- @return agentic.ui.DiffPreview.ShowResult
function ReviewController:activate_diff_review(current_request)
    local state = self.session_state:get_state()
    local tracker =
        SessionSelectors.get_tool_call(state, current_request.toolCallId)
    if not self._is_reviewable(tracker) then
        return {
            interactive = false,
            bufnr = nil,
            review_key = nil,
            mode = "none",
        }
    end
    --- @cast tracker agentic.session.InteractionToolCallNode

    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= self.widget.tab_page_id
    then
        return {
            interactive = false,
            bufnr = nil,
            review_key = nil,
            mode = "none",
        }
    end

    return self:_show_active_review(state)
end

--- @param state agentic.session.State
--- @param tool_call_id string|nil
--- @param clear_reason agentic.ui.DiffPreview.ClearReason|nil
function ReviewController:_clear_review_for_tool(
    state,
    tool_call_id,
    clear_reason
)
    if not tool_call_id then
        return
    end

    local tracker = SessionSelectors.get_tool_call(state, tool_call_id)
    if not self._is_reviewable(tracker) then
        return
    end
    --- @cast tracker agentic.session.InteractionToolCallNode

    local tracker_file_path = get_review_file_path(tracker)
    if not tracker_file_path then
        return
    end

    local current_permission = SessionSelectors.get_current_permission(state)
    --- @cast current_permission agentic.ui.PermissionManager.PermissionRequest|nil
    local review_key = get_review_key(current_permission, tool_call_id)
        or ReviewState.find_review_key_by_tool_call_id(tool_call_id)

    DiffPreview.clear_diff(tracker_file_path, {
        reason = clear_reason,
        review_key = review_key,
    })
end

function ReviewController:destroy()
    self.session_state:unsubscribe(self._state_listener_id)
    self._state_listener_id = nil
end

return ReviewController
