local assert = require("tests.helpers.assert")

describe("agentic.session.SessionSelectors", function()
    local InteractionModel
    local SessionReducer
    local SessionSelectors

    local function initial_state()
        return SessionReducer.initial_state({
            session_id = "session-1",
            title = "Demo",
            timestamp = 1,
            turns = {},
        })
    end

    before_each(function()
        package.loaded["agentic.session.session_reducer"] = nil
        package.loaded["agentic.session.session_selectors"] = nil
        package.loaded["agentic.session.interaction_model"] = nil

        InteractionModel = require("agentic.session.interaction_model")
        SessionReducer = require("agentic.session.session_reducer")
        SessionSelectors = require("agentic.session.session_selectors")
    end)

    local function set_tool_calls(state, tool_calls)
        state.interaction.turns = {}
        InteractionModel.append_request(state.interaction.turns, {
            text = "inspect",
            timestamp = 1,
        })
        for _, tool_call in ipairs(tool_calls) do
            InteractionModel.upsert_tool_call(
                state.interaction.turns,
                "Codex ACP",
                tool_call
            )
        end
    end

    it("resolves waiting activity before tool activity", function()
        local state = initial_state()
        state.permissions.current_request = { toolCallId = "tc-1" }
        set_tool_calls(state, {
            {
                tool_call_id = "tc-1",
                argument = "search README",
                kind = "search",
                status = "in_progress",
            },
        })

        local activity = SessionSelectors.get_chat_activity(state, {
            is_generating = true,
        })

        assert.equal("waiting", activity)
    end)

    it("maps active search-like tools to searching", function()
        local state = initial_state()
        set_tool_calls(state, {
            {
                tool_call_id = "tc-1",
                argument = "grep foo",
                kind = "grep",
                status = "in_progress",
            },
        })

        local activity = SessionSelectors.get_chat_activity(state, {
            is_generating = true,
        })

        assert.equal("searching", activity)
    end)

    it("does not infer searching from arbitrary kind substrings", function()
        local state = initial_state()
        set_tool_calls(state, {
            {
                tool_call_id = "tc-guess",
                argument = "custom search helper",
                kind = "custom_search_tool",
                status = "in_progress",
            },
        })

        local activity = SessionSelectors.get_chat_activity(state, {
            is_generating = true,
        })

        assert.equal("generating", activity)
    end)

    it("surfaces active tool detail while searching", function()
        local state = initial_state()
        set_tool_calls(state, {
            {
                tool_call_id = "tc-1",
                kind = "read",
                status = "in_progress",
                file_path = "/Users/michaelfortunato/projects/demo/file_picker.lua",
            },
        })

        local activity = SessionSelectors.get_chat_activity_info(state, {
            is_generating = true,
        })

        assert.same({
            state = "searching",
            detail = "~/projects/demo/file_picker.lua",
        }, activity)
    end)

    it("maps active non-search tools to generating", function()
        local state = initial_state()
        set_tool_calls(state, {
            {
                tool_call_id = "tc-1",
                argument = "edit app.lua",
                kind = "edit",
                status = "pending",
            },
        })

        local activity = SessionSelectors.get_chat_activity(state, {
            is_generating = true,
        })

        assert.equal("generating", activity)
    end)

    it(
        "keeps surfacing active tool activity even if generation state lags",
        function()
            local state = initial_state()
            set_tool_calls(state, {
                {
                    tool_call_id = "tc-1",
                    argument = "make test",
                    kind = "execute",
                    status = "in_progress",
                },
            })

            local activity = SessionSelectors.get_chat_activity_info(state, {
                is_generating = false,
            })

            assert.same({
                state = "generating",
                detail = "make test",
            }, activity)
        end
    )

    it(
        "falls back to agent phase when generating without active tools",
        function()
            local activity =
                SessionSelectors.get_chat_activity(initial_state(), {
                    is_generating = true,
                    agent_phase = "thinking",
                })

            assert.equal("thinking", activity)
        end
    )

    it("returns nil when not generating", function()
        local activity = SessionSelectors.get_chat_activity(initial_state(), {
            is_generating = false,
            agent_phase = "thinking",
        })

        assert.is_nil(activity)
    end)

    it(
        "builds the interaction session from state, including session-scoped mode",
        function()
            local state = initial_state()
            state.session.current_mode_id = "plan"
            state.interaction.turns = {}
            InteractionModel.append_request(state.interaction.turns, {
                text = "hi",
                timestamp = 10,
                content = {
                    { type = "text", text = "hi" },
                },
            })
            InteractionModel.upsert_plan(state.interaction.turns, "Codex ACP", {
                {
                    content = "Read the file",
                    priority = "high",
                    status = "pending",
                },
            })

            local interaction = SessionSelectors.get_interaction_session(state)

            assert.equal("plan", interaction.current_mode_id)
            assert.equal("plan", interaction.turns[1].response.nodes[1].type)
        end
    )
end)
