local SessionSelectors = {}
local InteractionModel = require("agentic.session.interaction_model")

local SEARCH_LIKE_TOOL_KINDS = {
    fetch = true,
    find = true,
    glob = true,
    grep = true,
    list = true,
    ls = true,
    read = true,
    search = true,
    websearch = true,
}

local TOOL_ACTIVITY_DETAIL_MAX_WIDTH = 72

--- @param text string|nil
--- @return string
local function sanitize_activity_detail(text)
    if not text or text == "" then
        return ""
    end

    local sanitized =
        text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return sanitized
end

--- @param text string
--- @return string
local function truncate_activity_detail(text)
    if #text <= TOOL_ACTIVITY_DETAIL_MAX_WIDTH then
        return text
    end

    return text:sub(1, TOOL_ACTIVITY_DETAIL_MAX_WIDTH - 3) .. "..."
end

--- @param tool_call table|nil
--- @return string|nil
local function get_tool_activity_detail(tool_call)
    if not tool_call then
        return nil
    end

    local argument = sanitize_activity_detail(tool_call.title)
    if argument ~= "" then
        return truncate_activity_detail(argument)
    end

    local file_path = sanitize_activity_detail(tool_call.file_path)
    if file_path ~= "" then
        return truncate_activity_detail(vim.fn.fnamemodify(file_path, ":~:."))
    end

    return nil
end

--- @param kind string|nil
--- @return boolean
local function is_search_like_tool_kind(kind)
    if type(kind) ~= "string" then
        return false
    end

    return SEARCH_LIKE_TOOL_KINDS[kind:lower()] == true
end

--- @param state agentic.session.State
--- @return table
function SessionSelectors.get_session_meta(state)
    return state.session
end

--- @param state agentic.session.State
--- @return table[]
function SessionSelectors.get_permission_queue(state)
    return state.permissions.queue
end

--- @param state agentic.session.State
--- @return table|nil
function SessionSelectors.get_current_permission(state)
    return state.permissions.current_request
end

--- @param state agentic.session.State
--- @param tool_call_id string
--- @return table|nil
function SessionSelectors.get_tool_call(state, tool_call_id)
    return InteractionModel.get_tool_call(state.interaction.turns, tool_call_id)
end

--- @param state agentic.session.State
--- @return table[]
function SessionSelectors.get_tool_calls(state)
    return InteractionModel.get_tool_calls(state.interaction.turns)
end

--- @param state agentic.session.State
--- @return table|nil
local function get_latest_active_tool_call(state)
    local tool_calls = SessionSelectors.get_tool_calls(state)
    for i = #tool_calls, 1, -1 do
        local tool_call = tool_calls[i]
        if
            tool_call
            and (
                tool_call.status == "pending"
                or tool_call.status == "in_progress"
            )
        then
            return tool_call
        end
    end

    return nil
end

--- @param state agentic.session.State
--- @return string|nil
function SessionSelectors.get_active_review_tool_call_id(state)
    return state.review.active_tool_call_id
end

--- @param state agentic.session.State
--- @return table|nil
function SessionSelectors.get_active_review_tool_call(state)
    local active_tool_call_id =
        SessionSelectors.get_active_review_tool_call_id(state)
    if not active_tool_call_id then
        return nil
    end

    return SessionSelectors.get_tool_call(state, active_tool_call_id)
end

--- @param state agentic.session.State
--- @return boolean
function SessionSelectors.has_pending_permissions(state)
    return state.permissions.current_request ~= nil
        or #state.permissions.queue > 0
end

--- @param state agentic.session.State
--- @param opts {session_starting?: boolean, is_generating?: boolean, agent_phase?: agentic.Theme.SpinnerState|nil}|nil
--- @return {state: agentic.Theme.SpinnerState, detail?: string|nil}|nil
function SessionSelectors.get_chat_activity_info(state, opts)
    opts = opts or {}

    if opts.session_starting then
        return { state = "busy" }
    end

    if SessionSelectors.has_pending_permissions(state) then
        return { state = "waiting" }
    end

    local tool_call = get_latest_active_tool_call(state)
    if tool_call then
        if is_search_like_tool_kind(tool_call.kind) then
            return {
                state = "searching",
                detail = get_tool_activity_detail(tool_call),
            }
        end

        return {
            state = "generating",
            detail = get_tool_activity_detail(tool_call),
        }
    end

    if not opts.is_generating then
        return nil
    end

    return {
        state = opts.agent_phase or "thinking",
    }
end

--- @param state agentic.session.State
--- @param opts {session_starting?: boolean, is_generating?: boolean, agent_phase?: agentic.Theme.SpinnerState|nil}|nil
--- @return agentic.Theme.SpinnerState|nil
function SessionSelectors.get_chat_activity(state, opts)
    local info = SessionSelectors.get_chat_activity_info(state, opts)
    return info and info.state or nil
end

--- @param state agentic.session.State
--- @return agentic.session.PersistedSession.StorageData
function SessionSelectors.get_persisted_session_data(state)
    local interaction_session = SessionSelectors.get_interaction_session(state)
    return {
        session_id = state.session.id,
        title = state.session.title,
        timestamp = state.session.timestamp,
        current_mode_id = state.session.current_mode_id,
        config_options = interaction_session.config_options,
        available_commands = interaction_session.available_commands,
        turns = interaction_session.turns,
    }
end

--- @param state agentic.session.State
--- @return agentic.session.InteractionSession
function SessionSelectors.get_interaction_session(state)
    return {
        session_id = state.session.id,
        title = state.session.title or "",
        timestamp = state.session.timestamp or os.time(),
        current_mode_id = state.session.current_mode_id,
        config_options = vim.deepcopy(state.session.config_options or {}),
        available_commands = vim.deepcopy(
            state.session.available_commands or {}
        ),
        turns = vim.deepcopy(state.interaction.turns or {}),
    }
end

--- @param state agentic.session.State
--- @return "chat"|"inline"|nil
function SessionSelectors.get_latest_request_surface(state)
    local turns = state and state.interaction and state.interaction.turns or {}
    local turn = turns[#turns]
    local request = turn and turn.request or nil
    local surface = request and request.surface or nil

    if surface == "chat" or surface == "inline" then
        return surface
    end

    return nil
end

--- @param state agentic.session.State
--- @return boolean
function SessionSelectors.has_inline_surface(state)
    return SessionSelectors.get_latest_request_surface(state) == "inline"
end

--- @param state agentic.session.State
--- @return agentic.acp.PlanEntry[]
function SessionSelectors.get_latest_plan_entries(state)
    local turns = state and state.interaction and state.interaction.turns or {}

    for turn_index = #turns, 1, -1 do
        local turn = turns[turn_index]
        local response = turn and turn.response or nil
        local nodes = response and response.nodes or {}

        for node_index = #nodes, 1, -1 do
            local node = nodes[node_index]
            if node and node.type == "plan" then
                return vim.deepcopy(node.entries or {})
            end
        end
    end

    return {}
end

--- @param state agentic.session.State
--- @return boolean
function SessionSelectors.has_interaction_content(state)
    return InteractionModel.has_content(
        (state.interaction and state.interaction.turns) or {}
    )
end

return SessionSelectors
