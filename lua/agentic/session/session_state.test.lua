local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.session.SessionState", function()
    local SessionState
    local SessionEvents
    local SessionSelectors

    before_each(function()
        package.loaded["agentic.session.session_state"] = nil
        package.loaded["agentic.session.session_events"] = nil
        package.loaded["agentic.session.session_selectors"] = nil

        SessionState = require("agentic.session.session_state")
        SessionEvents = require("agentic.session.session_events")
        SessionSelectors = require("agentic.session.session_selectors")
    end)

    it("exposes session metadata as persisted session data", function()
        local store = SessionState:new()

        store:dispatch(SessionEvents.set_session_meta({
            session_id = "session-1",
            title = "A title",
            timestamp = 123,
        }))
        store:dispatch(SessionEvents.set_current_mode("plan"))

        store:dispatch(SessionEvents.append_interaction_request({
            kind = "user",
            surface = "inline",
            text = "hello",
            timestamp = 123,
            content = {
                { type = "text", text = "hello" },
            },
        }))

        local persisted = store:get_persisted_session_data()

        assert.equal("session-1", persisted.session_id)
        assert.equal("A title", persisted.title)
        assert.equal(123, persisted.timestamp)
        assert.equal("plan", persisted.current_mode_id)
        assert.equal(1, #persisted.turns)
        assert.equal("hello", persisted.turns[1].request.text)
        assert.equal("inline", persisted.turns[1].request.surface)
    end)

    it("appends agent chunks onto the current turn response message", function()
        local store = SessionState:new()

        store:dispatch(SessionEvents.append_interaction_request({
            kind = "user",
            text = "hello",
            timestamp = 1,
            content = {
                { type = "text", text = "hello" },
            },
        }))
        store:dispatch(
            SessionEvents.append_interaction_response(
                "message",
                "codex-acp",
                { type = "text", text = "hello" }
            )
        )
        store:dispatch(
            SessionEvents.append_interaction_response(
                "message",
                "codex-acp",
                { type = "text", text = " world" }
            )
        )

        local turns = store:get_persisted_session_data().turns
        assert.equal(1, #turns)
        assert.equal("hello world", turns[1].response.nodes[1].text)
    end)

    it(
        "loads persisted session data while preserving runtime session metadata when requested",
        function()
            local store = SessionState:new()
            store:dispatch(SessionEvents.set_session_meta({
                session_id = "active-session",
                timestamp = 999,
            }))
            store:dispatch(SessionEvents.set_current_mode("code"))

            local loaded_session = {
                session_id = "saved-session",
                title = "Saved title",
                timestamp = 111,
                current_mode_id = "plan",
                turns = {
                    {
                        index = 1,
                        request = {
                            kind = "user",
                            text = "restored",
                            timestamp = 111,
                            content = {
                                { type = "text", text = "restored" },
                            },
                            content_nodes = {},
                        },
                        response = {
                            provider_name = nil,
                            nodes = {},
                        },
                        result = nil,
                    },
                },
            }

            store:dispatch(
                SessionEvents.load_persisted_session(loaded_session, {
                    preserve_session_id = true,
                    preserve_timestamp = true,
                    preserve_current_mode_id = true,
                })
            )

            local persisted = store:get_persisted_session_data()
            assert.equal("active-session", persisted.session_id)
            assert.equal(999, persisted.timestamp)
            assert.equal("Saved title", persisted.title)
            assert.equal("code", persisted.current_mode_id)
            assert.equal("restored", persisted.turns[1].request.text)
        end
    )

    it(
        "queues and promotes permission requests through state transitions",
        function()
            local store = SessionState:new()
            local callback = function() end

            store:dispatch(SessionEvents.enqueue_permission({
                sessionId = "sess-1",
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

        store:dispatch(SessionEvents.append_interaction_request({
            kind = "user",
            text = "edit this",
            timestamp = 1,
            content = {
                { type = "text", text = "edit this" },
            },
        }))
        store:dispatch(SessionEvents.upsert_interaction_tool_call("Codex ACP", {
            tool_call_id = "tc-3",
            kind = "edit",
            status = "pending",
            file_path = "/tmp/demo.lua",
            diff = { old = { "a" }, new = { "b" } },
        }))
        store:dispatch(
            SessionEvents.set_interaction_tool_permission_state(
                "tc-3",
                "requested"
            )
        )
        store:dispatch(SessionEvents.set_review_target("tc-3"))

        local state = store:get_state()
        assert.equal(
            "requested",
            SessionSelectors.get_tool_call(state, "tc-3").permission_state
        )
        assert.equal("tc-3", state.review.active_tool_call_id)

        store:dispatch(SessionEvents.clear_review_target("tc-3", "rejected"))
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
