local PersistedSession = require("agentic.session.persisted_session")
local Chooser = require("agentic.ui.chooser")
local Logger = require("agentic.utils.logger")
local SessionSelectors = require("agentic.session.session_selectors")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestore
local SessionRestore = {}

--- Checks if the current session already has interaction content.
--- @param current_session agentic.SessionManager|nil
--- @return boolean has_conflict
local function check_conflict(current_session)
    local state = current_session
        and current_session.session_state
        and current_session.session_state:get_state()

    return current_session ~= nil
        and current_session.session_id ~= nil
        and state ~= nil
        and SessionSelectors.has_interaction_content(state)
end

--- @param session_id string
--- @param tab_page_id integer
--- @param has_conflict boolean
--- @param current_session agentic.SessionManager|nil
local function do_restore(
    session_id,
    tab_page_id,
    has_conflict,
    current_session
)
    PersistedSession.load(session_id, function(history, err)
        if err or not history then
            Logger.notify(
                "Failed to load session: " .. (err or "unknown error"),
                vim.log.levels.WARN
            )
            return
        end

        local session = current_session
        if session == nil then
            session = SessionRegistry.new_session(tab_page_id)
        end

        if session == nil then
            return
        end

        if has_conflict and session.session_id then
            session.agent:cancel_session(session.session_id)
            session.widget:clear()
        end

        session:restore_session_data(
            history,
            { reuse_session = not has_conflict }
        )

        session.widget:show()
    end)
end

--- @param session_id string
--- @param tab_page_id integer
--- @param has_conflict boolean
--- @param current_session agentic.SessionManager|nil
local function restore_with_conflict_check(
    session_id,
    tab_page_id,
    has_conflict,
    current_session
)
    if has_conflict then
        Chooser.show({
            "Cancel",
            "Clear current session and restore",
        }, {
            prompt = "Current session has content. What would you like to do?",
        }, function(choice)
            if choice == "Clear current session and restore" then
                do_restore(
                    session_id,
                    tab_page_id,
                    has_conflict,
                    current_session
                )
            end
        end)
    else
        do_restore(session_id, tab_page_id, has_conflict, current_session)
    end
end

--- Show session picker and restore selected session
--- @param tab_page_id integer
--- @param current_session agentic.SessionManager|nil
function SessionRestore.show_picker(tab_page_id, current_session)
    PersistedSession.list_sessions(function(sessions)
        if #sessions == 0 then
            Logger.notify("No saved sessions found", vim.log.levels.INFO)
            return
        end

        local items = {}
        for _, s in ipairs(sessions) do
            local date = os.date("%Y-%m-%d %H:%M", s.timestamp or 0)
            local title = s.title or "(no title)"

            table.insert(items, {
                display = string.format("%s - %s", date, title),
                session_id = s.session_id,
            })
        end

        Chooser.show(items, {
            prompt = "Select session to restore:",
            format_item = function(item)
                return item.display
            end,
        }, function(choice)
            if choice then
                restore_with_conflict_check(
                    choice.session_id,
                    tab_page_id,
                    check_conflict(current_session),
                    current_session
                )
            end
        end)
    end)
end

return SessionRestore
