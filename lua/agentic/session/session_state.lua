local ChatHistory = require("agentic.ui.chat_history")
local Logger = require("agentic.utils.logger")
local SessionReducer = require("agentic.session.session_reducer")
local SessionSelectors = require("agentic.session.session_selectors")

--- @class agentic.session.SessionState
--- @field state agentic.session.State
--- @field _history agentic.ui.ChatHistory
--- @field _listeners table<integer, fun(state: agentic.session.State, event: table|nil)>
--- @field _next_listener_id integer
local SessionState = {}
SessionState.__index = SessionState

--- @param opts {chat_history?: agentic.ui.ChatHistory|nil}|nil
--- @return agentic.session.SessionState
function SessionState:new(opts)
    opts = opts or {}

    local history = opts.chat_history or ChatHistory:new()
    local instance = setmetatable({
        state = SessionReducer.initial_state({
            session_id = history.session_id,
            title = history.title,
            timestamp = history.timestamp,
            messages = history.messages,
        }),
        _history = history,
        _listeners = {},
        _next_listener_id = 1,
    }, self)

    instance:_sync_history()
    return instance
end

--- @return agentic.session.State
function SessionState:get_state()
    return self.state
end

--- @return agentic.ui.ChatHistory
function SessionState:get_history()
    return self._history
end

--- @param event table|nil
--- @return agentic.session.State
function SessionState:dispatch(event)
    self.state = SessionReducer.reduce(self.state, event)
    self:_sync_history()
    self:_notify(event)
    return self.state
end

--- @param history agentic.ui.ChatHistory|nil
--- @return agentic.session.State
function SessionState:replace_history(history)
    self._history = history or ChatHistory:new()
    self.state = SessionReducer.initial_state({
        session_id = self._history.session_id,
        title = self._history.title,
        timestamp = self._history.timestamp,
        messages = self._history.messages,
    })
    self:_sync_history()
    self:_notify({ type = "session/replace_history" })
    return self.state
end

--- @param listener fun(state: agentic.session.State, event: table|nil)
--- @return integer
function SessionState:subscribe(listener)
    local listener_id = self._next_listener_id
    self._next_listener_id = self._next_listener_id + 1
    self._listeners[listener_id] = listener
    return listener_id
end

--- @param listener_id integer|nil
function SessionState:unsubscribe(listener_id)
    if listener_id == nil then
        return
    end
    self._listeners[listener_id] = nil
end

function SessionState:_sync_history()
    local data = SessionSelectors.get_chat_history_data(self.state)
    self._history.session_id = data.session_id
    self._history.title = data.title
    self._history.timestamp = data.timestamp
    self._history.messages = data.messages
end

--- @param event table|nil
function SessionState:_notify(event)
    for listener_id, listener in pairs(self._listeners) do
        local ok, err = pcall(listener, self.state, event)
        if not ok then
            Logger.debug(
                string.format(
                    "SessionState listener %s failed: %s",
                    listener_id,
                    err
                )
            )
        end
    end
end

return SessionState
