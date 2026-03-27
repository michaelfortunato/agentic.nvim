local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.ACPClient", function()
    local ACPClient

    before_each(function()
        package.loaded["agentic.acp.acp_client"] = nil
        ACPClient = require("agentic.acp.acp_client")
    end)

    local function make_client()
        local send_spy = spy.new(function() end)
        local client = setmetatable({
            callbacks = {},
            provider_config = { name = "codex-acp" },
            transport = { send = send_spy },
            subscribers = {},
        }, { __index = ACPClient })

        return client, send_spy
    end

    it(
        "routes method notifications without ids to the notification path",
        function()
            local client = make_client()
            local handle_notification_stub =
                spy.stub(client, "_handle_notification")
            local handle_request_stub = spy.stub(client, "_handle_request")

            client:_handle_message({
                jsonrpc = "2.0",
                method = "session/update",
                params = {
                    sessionId = "session-1",
                    update = {
                        sessionUpdate = "plan",
                        entries = {},
                    },
                },
            })

            assert.stub(handle_notification_stub).was.called(1)
            assert.stub(handle_request_stub).was.called(0)

            handle_notification_stub:revert()
            handle_request_stub:revert()
        end
    )

    it("routes method requests with ids to the request path", function()
        local client = make_client()
        local handle_notification_stub =
            spy.stub(client, "_handle_notification")
        local handle_request_stub = spy.stub(client, "_handle_request")

        client:_handle_message({
            jsonrpc = "2.0",
            id = 12,
            method = "session/request_permission",
            params = {
                sessionId = "session-1",
                options = {},
                toolCall = {
                    toolCallId = "tc-1",
                    title = "Edit file",
                },
            },
        })

        assert.stub(handle_request_stub).was.called(1)
        assert.stub(handle_notification_stub).was.called(0)

        handle_notification_stub:revert()
        handle_request_stub:revert()
    end)

    it("schedules response callbacks in fast event context", function()
        local client = make_client()
        local callback_spy = spy.new(function() end)
        local captured_callback = nil
        local in_fast_event_stub = spy.stub(vim, "in_fast_event")
        local schedule_stub = spy.stub(vim, "schedule")

        in_fast_event_stub:returns(true)
        schedule_stub:invokes(function(fn)
            captured_callback = fn
        end)

        client.callbacks[7] = callback_spy

        client:_handle_message({
            jsonrpc = "2.0",
            id = 7,
            result = {
                sessionId = "session-1",
            },
        })

        assert.spy(schedule_stub).was.called(1)
        assert.spy(callback_spy).was.called(0)
        assert.is_not_nil(captured_callback)
        --- @cast captured_callback fun()

        captured_callback()

        assert.spy(callback_spy).was.called(1)
        assert.equal("session-1", callback_spy.calls[1][1].sessionId)

        schedule_stub:revert()
        in_fast_event_stub:revert()
    end)

    it("returns a json-rpc error for unsupported client requests", function()
        local client, send_spy = make_client()

        client:_handle_request(42, "fs/read_text_file", {
            sessionId = "session-1",
            path = "/tmp/demo.lua",
        })

        assert.spy(send_spy).was.called(1)

        local response = vim.json.decode(send_spy.calls[1][2])
        assert.equal("2.0", response.jsonrpc)
        assert.equal(42, response.id)
        assert.equal(-32601, response.error.code)
        assert.equal(
            "Unsupported ACP client request: fs/read_text_file",
            response.error.message
        )
    end)

    it("responds to permission dismissal with a cancelled outcome", function()
        local client, send_spy = make_client()
        client.__with_subscriber = function(_, _session_id, callback)
            callback({
                on_tool_call_update = function() end,
                on_request_permission = function(_request, respond)
                    respond(nil)
                end,
            })
        end

        client:__handle_request_permission(7, {
            sessionId = "session-1",
            options = {},
            toolCall = {
                toolCallId = "tc-1",
                title = "Edit file",
            },
        })

        assert.spy(send_spy).was.called(1)
        local response = vim.json.decode(send_spy.calls[1][2])
        assert.equal("cancelled", response.result.outcome.outcome)
    end)

    it("responds to permission approval with the selected option id", function()
        local client, send_spy = make_client()
        client.__with_subscriber = function(_, _session_id, callback)
            callback({
                on_tool_call_update = function() end,
                on_request_permission = function(_request, respond)
                    respond("allow_once")
                end,
            })
        end

        client:__handle_request_permission(8, {
            sessionId = "session-1",
            options = {},
            toolCall = {
                toolCallId = "tc-1",
                title = "Edit file",
            },
        })

        assert.spy(send_spy).was.called(1)
        local response = vim.json.decode(send_spy.calls[1][2])
        assert.equal("selected", response.result.outcome.outcome)
        assert.equal("allow_once", response.result.outcome.optionId)
    end)

    it("does not synthesize tool output from rawInput or locations", function()
        local client = make_client()

        local message = client:__build_tool_call_message({
            toolCallId = "tc-raw-1",
            title = "Edit demo.lua",
            kind = "edit",
            status = "pending",
            rawInput = {
                file_path = "/tmp/demo.lua",
                new_string = "new text",
                old_string = "old text",
            },
            locations = {
                { path = "/tmp/demo.lua" },
            },
        })

        assert.is_nil(message.diff)
        assert.is_nil(message.file_path)
        assert.is_nil(message.body)
    end)

    it("queues ready callbacks until the client reaches ready state", function()
        local callback_spy = spy.new(function() end)
        local client = setmetatable({
            state = "initializing",
            _ready_callbacks = {},
        }, { __index = ACPClient })

        client:on_ready(function(client_instance)
            callback_spy(client_instance)
        end)

        assert.spy(callback_spy).was.called(0)

        client:_notify_ready()

        assert.spy(callback_spy).was.called(1)
        assert.equal(client, callback_spy.calls[1][1])
    end)
end)
