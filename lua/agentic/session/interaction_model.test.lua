local assert = require("tests.helpers.assert")

describe("agentic.session.InteractionModel", function()
    local InteractionModel

    before_each(function()
        package.loaded["agentic.session.interaction_model"] = nil
        InteractionModel = require("agentic.session.interaction_model")
    end)

    it(
        "groups request, thought, tool call, response, and result under one turn",
        function()
            local turns = {}

            InteractionModel.append_request(turns, {
                text = "hi",
                timestamp = 10,
                content = {
                    { type = "text", text = "hi" },
                },
            })
            InteractionModel.append_response_content(
                turns,
                "thought",
                "Codex ACP",
                { type = "text", text = "reading files" }
            )
            InteractionModel.upsert_tool_call(turns, "Codex ACP", {
                tool_call_id = "tc-1",
                kind = "read",
                status = "completed",
                argument = "Read README.md",
                file_path = "README.md",
                body = { "line 1", "line 2" },
            })
            InteractionModel.append_response_content(
                turns,
                "message",
                "Codex ACP",
                { type = "text", text = "done" }
            )
            InteractionModel.set_turn_result(turns, {
                stop_reason = "end_turn",
                timestamp = 20,
            }, "Codex ACP")

            local session = InteractionModel.from_persisted_session({
                session_id = "session-1",
                title = "Demo",
                timestamp = 1,
                current_mode_id = "code",
                config_options = {},
                available_commands = {},
                turns = turns,
            })

            assert.equal(1, #session.turns)
            assert.equal("hi", session.turns[1].request.text)
            assert.equal("Codex ACP", session.turns[1].response.provider_name)
            assert.same(
                { "thought", "tool_call", "message" },
                vim.tbl_map(function(node)
                    return node.type
                end, session.turns[1].response.nodes)
            )
            assert.equal("end_turn", session.turns[1].result.stop_reason)
        end
    )

    it("preserves original ACP request content when available", function()
        local turns = {}
        InteractionModel.append_request(turns, {
            text = "review this",
            timestamp = 10,
            content = {
                { type = "text", text = "review this" },
                {
                    type = "resource_link",
                    uri = "file:///tmp/demo.lua",
                    name = "demo.lua",
                },
            },
        })

        assert.equal(2, #turns[1].request.content)
        assert.equal("resource_link", turns[1].request.content[2].type)
        assert.same(
            { "request_text", "request_content" },
            vim.tbl_map(function(node)
                return node.type
            end, turns[1].request.nodes)
        )
    end)

    it("normalizes persisted turns with structured request nodes", function()
        local session = InteractionModel.from_persisted_session({
            turns = {
                {
                    index = 1,
                    request = {
                        kind = "user",
                        text = "inspect this",
                        timestamp = 10,
                        content = {
                            { type = "text", text = "inspect this" },
                            {
                                type = "resource_link",
                                uri = "file:///tmp/demo.lua",
                                name = "demo.lua",
                            },
                        },
                    },
                    response = {
                        provider_name = "Codex ACP",
                        nodes = {},
                    },
                },
            },
        })

        assert.same(
            { "request_text", "request_content" },
            vim.tbl_map(function(node)
                return node.type
            end, session.turns[1].request.nodes)
        )
        assert.equal(
            "resource_link_content",
            session.turns[1].request.nodes[2].content_node.type
        )
    end)

    it("classifies XML-wrapped request text content in the model", function()
        local session = InteractionModel.from_persisted_session({
            turns = {
                {
                    index = 1,
                    request = {
                        kind = "user",
                        text = "inspect this",
                        timestamp = 10,
                        content = {
                            { type = "text", text = "inspect this" },
                            {
                                type = "text",
                                text = table.concat({
                                    "<selected_code>",
                                    "<path>/tmp/demo.lua</path>",
                                    "</selected_code>",
                                }, "\n"),
                            },
                        },
                    },
                    response = {
                        provider_name = "Codex ACP",
                        nodes = {},
                    },
                },
            },
        })

        local structured_text = session.turns[1].request.nodes[2].content_node
        assert.equal("text_content", structured_text.type)
        assert.equal("xml_wrapped", structured_text.text_structure)
        assert.equal("selected_code", structured_text.xml_root_tag)
    end)

    it(
        "keeps ACP tool content subtypes instead of flattening them away",
        function()
            local turns = {}
            InteractionModel.append_request(turns, {
                text = "inspect",
                timestamp = 10,
            })
            InteractionModel.upsert_tool_call(turns, "Codex ACP", {
                tool_call_id = "tc-1",
                kind = "execute",
                status = "completed",
                argument = "Run test command",
                content_items = {
                    {
                        type = "content",
                        content = {
                            type = "text",
                            text = "hello\nworld",
                        },
                    },
                    {
                        type = "terminal",
                        terminalId = "term-1",
                    },
                },
            })

            local tool_call = turns[1].response.nodes[1]
            assert.equal("tool_call", tool_call.type)
            assert.same(
                { "content_output", "terminal_output" },
                vim.tbl_map(function(node)
                    return node.type
                end, tool_call.content_nodes)
            )
            assert.equal("term-1", tool_call.content_nodes[2].terminal_id)
        end
    )

    it(
        "carries session-scoped ACP context on the interaction session",
        function()
            local session = InteractionModel.from_persisted_session({
                session_id = "session-1",
                title = "Demo",
                timestamp = 1,
                current_mode_id = "plan",
                config_options = {
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "plan",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            {
                                value = "plan",
                                name = "Plan",
                                description = "",
                            },
                        },
                    },
                },
                available_commands = {
                    {
                        name = "review",
                        description = "Review changes",
                    },
                },
                turns = {},
            })

            assert.equal("plan", session.current_mode_id)
            assert.equal(1, #session.config_options)
            assert.equal(1, #session.available_commands)
            assert.equal("review", session.available_commands[1].name)
        end
    )
end)
