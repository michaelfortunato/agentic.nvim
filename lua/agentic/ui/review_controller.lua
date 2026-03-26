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
--- @field _state_listener_id? integer
local ReviewController = {}
ReviewController.__index = ReviewController

--- @param session_state agentic.session.SessionState
--- @param widget agentic.ui.ChatWidget
--- @return agentic.ui.ReviewController
function ReviewController:new(session_state, widget)
    local instance = setmetatable({
        session_state = session_state,
        widget = widget,
        _state_listener_id = nil,
    }, self)

    instance._state_listener_id = session_state:subscribe(function(state, event)
        instance:_handle_state_event(state, event)
    end)

    return instance
end

--- @param tracker table|nil
--- @return boolean
function ReviewController._is_reviewable(tracker)
    return tracker ~= nil
        and DIFF_PREVIEW_KINDS[tracker.kind] == true
        and tracker.diff ~= nil
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

    if event.type == "tools/upsert" then
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

    DiffPreview.show_diff({
        file_path = tracker.file_path,
        diff = tracker.diff,
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
