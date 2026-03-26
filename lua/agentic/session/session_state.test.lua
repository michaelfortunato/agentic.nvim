local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.session.SessionState", function()
    --- @type agentic.session.session_state
    local SessionState
    --- @type agentic.session.session_events
    local SessionEvents

    before_each(function()
        package.loaded["agentic.session.session_state"] = nil
        package.loaded["agentic.session.session_events"] = nil

        SessionState = require("agentic.session.session_state")
        SessionEvents = require("agentic.session.session_events")
    end)

    it(
        "syncs session metadata and transcript messages into chat history",
        function()
            local store = SessionState:new()

            store:dispatch(SessionEvents.set_session_meta({
                session_id = "session-1",
                title = "A title",
                timestamp = 123,
            }))

            store:dispatch(SessionEvents.add_transcript_message({
                type = "user",
                text = "hello",
                timestamp = 123,
                provider_name = "codex-acp",
            }))

            local history = store:get_history()

            assert.equal("session-1", history.session_id)
            assert.equal("A title", history.title)
            assert.equal(123, history.timestamp)
            assert.equal(1, #history.messages)
            assert.equal("hello", history.messages[1].text)
        end
    )

    it(
        "appends agent chunks onto the last matching transcript message",
        function()
            local store = SessionState:new()

            store:dispatch(SessionEvents.append_agent_text({
                type = "agent",
                text = "hello",
                provider_name = "codex-acp",
            }))
            store:dispatch(SessionEvents.append_agent_text({
                type = "agent",
                text = " world",
                provider_name = "codex-acp",
            }))

            local messages = store:get_history().messages
            assert.equal(1, #messages)
            assert.equal("hello world", messages[1].text)
        end
    )

    it(
        "restores history while preserving runtime session metadata when requested",
        function()
            local store = SessionState:new()
            store:dispatch(SessionEvents.set_session_meta({
                session_id = "active-session",
                timestamp = 999,
            }))

            local loaded_history = {
                session_id = "saved-session",
                title = "Saved title",
                timestamp = 111,
                messages = {
                    { type = "user", text = "restored" },
                },
            }

            store:dispatch(SessionEvents.restore_history(loaded_history, {
                preserve_session_id = true,
                preserve_timestamp = true,
            }))

            local history = store:get_history()
            assert.equal("active-session", history.session_id)
            assert.equal(999, history.timestamp)
            assert.equal("Saved title", history.title)
            assert.equal("restored", history.messages[1].text)
        end
    )

    it(
        "queues and promotes permission requests through state transitions",
        function()
            local store = SessionState:new()
            local callback = function() end

            store:dispatch(SessionEvents.enqueue_permission({
                toolCall = { toolCallId = "tc-1" },
                options = {},
            }, callback))

            assert.equal(1, #store:get_state().permissions.queue)
            assert.is_nil(store:get_state().permissions.current_request)

            store:dispatch(SessionEvents.show_next_permission())

            assert.equal(0, #store:get_state().permissions.queue)
            assert.equal(
                "tc-1",
                store:get_state().permissions.current_request.toolCallId
            )

            store:dispatch(SessionEvents.complete_current_permission())
            assert.is_nil(store:get_state().permissions.current_request)
        end
    )

    it("tracks tool lifecycle and active review state", function()
        local store = SessionState:new()

        store:dispatch(SessionEvents.upsert_tool_call({
            tool_call_id = "tc-3",
            kind = "edit",
            status = "pending",
            file_path = "/tmp/demo.lua",
            diff = { old = { "a" }, new = { "b" } },
        }))
        store:dispatch(
            SessionEvents.set_tool_permission_state("tc-3", "requested")
        )
        store:dispatch(SessionEvents.set_review_target("tc-3"))

        local state = store:get_state()
        assert.equal("requested", state.tools.by_id["tc-3"].permission_state)
        assert.equal("tc-3", state.review.active_tool_call_id)

        store:dispatch(SessionEvents.clear_review_target("tc-3", true))
        assert.is_nil(store:get_state().review.active_tool_call_id)
    end)

    it("notifies subscribers after dispatch", function()
        local store = SessionState:new()
        local listener = spy.new(function() end)

        local listener_id = store:subscribe(listener)
        store:dispatch(SessionEvents.set_session_title("Fresh title"))

        assert.spy(listener).was.called(1)

        store:unsubscribe(listener_id)
        store:dispatch(SessionEvents.set_session_title("Another title"))

        assert.spy(listener).was.called(1)
    end)
end)
