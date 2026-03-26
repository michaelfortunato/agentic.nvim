local PersistedSession = require("agentic.session.persisted_session")
local Logger = require("agentic.utils.logger")
local SessionReducer = require("agentic.session.session_reducer")
local SessionSelectors = require("agentic.session.session_selectors")

--- @class agentic.session.SessionState
--- @field state agentic.session.State
--- @field _listeners table<integer, fun(state: agentic.session.State, event: table|nil)>
--- @field _next_listener_id integer
local SessionState = {}
SessionState.__index = SessionState

--- @param opts {persisted_session?: agentic.session.PersistedSession|agentic.session.PersistedSession.StorageData|nil}|nil
--- @return agentic.session.SessionState
function SessionState:new(opts)
    opts = opts or {}

    local persisted_session = opts.persisted_session or PersistedSession:new()
    local instance = setmetatable({
        state = SessionReducer.initial_state({
            session_id = persisted_session.session_id,
            title = persisted_session.title,
            timestamp = persisted_session.timestamp,
            current_mode_id = persisted_session.current_mode_id,
            config_options = persisted_session.config_options,
            available_commands = persisted_session.available_commands,
            turns = persisted_session.turns,
        }),
        _listeners = {},
        _next_listener_id = 1,
    }, self)

    return instance
end

--- @return agentic.session.State
function SessionState:get_state()
    return self.state
end

--- @return agentic.session.PersistedSession.StorageData
function SessionState:get_persisted_session_data()
    return SessionSelectors.get_persisted_session_data(self.state)
end

--- @param callback fun(err: string|nil)|nil
function SessionState:save_persisted_session_data(callback)
    PersistedSession.save_data(self:get_persisted_session_data(), callback)
end

--- @param event table|nil
--- @return agentic.session.State
function SessionState:dispatch(event)
    self.state = SessionReducer.reduce(self.state, event)
    self:_notify(event)
    return self.state
end

--- @param persisted_session agentic.session.PersistedSession|agentic.session.PersistedSession.StorageData|nil
--- @return agentic.session.State
function SessionState:replace_persisted_session_data(persisted_session)
    persisted_session = persisted_session or PersistedSession:new()
    self.state = SessionReducer.initial_state({
        session_id = persisted_session.session_id,
        title = persisted_session.title,
        timestamp = persisted_session.timestamp,
        current_mode_id = persisted_session.current_mode_id,
        config_options = persisted_session.config_options,
        available_commands = persisted_session.available_commands,
        turns = persisted_session.turns,
    })
    self:_notify({ type = "session/replace_persisted_session_data" })
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
