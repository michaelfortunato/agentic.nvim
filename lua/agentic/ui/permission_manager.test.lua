--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local SessionEvents = require("agentic.session.session_events")
local SessionState = require("agentic.session.session_state")

describe("agentic.ui.PermissionManager", function()
    --- @type agentic.ui.PermissionManager
    local PermissionManager
    --- @type agentic.ui.Chooser
    local Chooser
    --- @type integer
    local bufnr
    --- @type agentic.session.SessionState
    local session_state
    --- @type agentic.ui.PermissionManager
    local pm
    --- @type TestStub
    local chooser_show_stub
    --- @type TestStub
    local chooser_close_stub
    --- @type agentic.acp.PermissionOption[]|nil
    local shown_items
    --- @type agentic.ui.Chooser.Opts|nil
    local shown_opts
    --- @type fun(choice: any|nil)|nil
    local shown_callback

    --- @param tool_call_id string
    --- @param options agentic.acp.PermissionOption[]|nil
    --- @return agentic.acp.RequestPermission
    local function make_request(tool_call_id, options)
        return {
            sessionId = "test-session",
            toolCall = {
                toolCallId = tool_call_id,
            },
            options = options or {
                {
                    optionId = "allow-once",
                    name = "Allow once",
                    kind = "allow_once",
                },
                {
                    optionId = "reject-once",
                    name = "Reject once",
                    kind = "reject_once",
                },
            },
        }
    end

    --- @param tool_call_id string
    --- @param kind agentic.acp.ToolKind|nil
    local function add_tool_call(tool_call_id, kind)
        session_state:dispatch(
            SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                tool_call_id = tool_call_id,
                kind = kind or "edit",
                status = "pending",
                file_path = "/tmp/demo.lua",
                diff = { old = { "a" }, new = { "b" } },
            })
        )
    end

    before_each(function()
        PermissionManager = require("agentic.ui.permission_manager")
        Chooser = require("agentic.ui.chooser")

        chooser_show_stub = spy.stub(Chooser, "show")
        chooser_show_stub:invokes(function(items, opts, on_choice)
            shown_items = items
            shown_opts = opts
            shown_callback = on_choice
            return true
        end)

        chooser_close_stub = spy.stub(Chooser, "close")

        bufnr = vim.api.nvim_create_buf(false, true)
        session_state = SessionState:new()
        pm = PermissionManager:new(session_state)
    end)

    after_each(function()
        chooser_show_stub:revert()
        chooser_close_stub:revert()

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("shows sorted approval options in the chooser", function()
        add_tool_call("tc-1", "edit")

        pm:add_request(
            make_request("tc-1", {
                {
                    optionId = "reject-once",
                    name = "Reject once",
                    kind = "reject_once",
                },
                {
                    optionId = "allow-once",
                    name = "Allow once",
                    kind = "allow_once",
                },
            }),
            spy.new(function() end) --[[@as function]]
        )

        assert.spy(chooser_show_stub).was.called(1)
        assert.equal("tc-1", pm.current_request.toolCallId)
        assert.equal(0, #pm.queue)
        assert.equal("Approve edit?", shown_opts.prompt)
        assert.equal(false, shown_opts.show_title)
        assert.equal("allow-once", shown_items[1].optionId)
        assert.equal("reject-once", shown_items[2].optionId)
        assert.truthy(
            shown_opts.format_item(shown_items[1]):find("Allow once", 1, true)
        )
    end)

    it("uses the diff review handler instead of opening the chooser", function()
        local callback = spy.new(function() end) --[[@as function]]
        local review_handler = spy.new(function()
            return true
        end)

        add_tool_call("tc-review-1", "edit")
        pm:set_diff_review_handler(review_handler --[[@as function]])
        pm:add_request(make_request("tc-review-1"), callback)

        assert.spy(review_handler).was.called(1)
        assert.spy(chooser_show_stub).was.called(0)
        assert.equal("tc-review-1", pm.current_request.toolCallId)

        pm:complete_current_request("allow-once")

        assert.spy(callback).was.called(1)
        assert.equal("allow-once", callback.calls[1][1])
        assert.is_nil(pm.current_request)
    end)

    it("completes the request when a choice is selected", function()
        local callback = spy.new(function() end) --[[@as function]]

        add_tool_call("tc-2", "edit")
        pm:add_request(make_request("tc-2"), callback)

        shown_callback(shown_items[1])

        assert.spy(callback).was.called(1)
        assert.equal("allow-once", callback.calls[1][1])
        assert.is_nil(pm.current_request)
        assert.equal(0, #pm.queue)
        assert.spy(chooser_close_stub).was.called(1)
    end)

    it("dismisses the request when the chooser is cancelled", function()
        local callback = spy.new(function() end) --[[@as function]]

        add_tool_call("tc-3", "edit")
        pm:add_request(make_request("tc-3"), callback)

        shown_callback(nil)

        assert.spy(callback).was.called(1)
        assert.is_nil(callback.calls[1][1])
        assert.is_nil(pm.current_request)
        assert.equal(0, #pm.queue)
        assert.spy(chooser_close_stub).was.called(1)
    end)

    it("maps escape to the default reject option", function()
        local callback = spy.new(function() end) --[[@as function]]

        add_tool_call("tc-escape-1", "edit")
        pm:add_request(
            make_request("tc-escape-1", {
                {
                    optionId = "allow-once",
                    name = "Allow once",
                    kind = "allow_once",
                },
                {
                    optionId = "reject-once",
                    name = "Reject once",
                    kind = "reject_once",
                },
            }),
            callback
        )

        shown_callback(shown_opts.escape_choice)

        assert.spy(callback).was.called(1)
        assert.equal("reject-once", callback.calls[1][1])
        assert.is_nil(pm.current_request)
        assert.equal(0, #pm.queue)
    end)

    it(
        "ignores duplicate permission requests for the same tool call",
        function()
            local callback = spy.new(function() end) --[[@as function]]
            local request = make_request("tc-dup-1")

            add_tool_call("tc-dup-1", "edit")
            pm:add_request(request, callback)
            pm:add_request(request, callback)

            assert.is_not_nil(pm.current_request)
            assert.equal("tc-dup-1", pm.current_request.toolCallId)
            assert.equal(0, #pm.queue)
            assert.spy(chooser_show_stub).was.called(1)
        end
    )

    it("clear() cancels current and queued requests", function()
        local callback_1 = spy.new(function() end) --[[@as function]]
        local callback_2 = spy.new(function() end) --[[@as function]]

        add_tool_call("tc-clear-1", "edit")
        add_tool_call("tc-clear-2", "write")

        pm:add_request(make_request("tc-clear-1"), callback_1)
        pm:add_request(make_request("tc-clear-2"), callback_2)

        assert.equal("tc-clear-1", pm.current_request.toolCallId)
        assert.equal(1, #pm.queue)

        pm:clear()

        assert.spy(callback_1).was.called(1)
        assert.is_nil(callback_1.calls[1][1])
        assert.spy(callback_2).was.called(1)
        assert.is_nil(callback_2.calls[1][1])
        assert.is_nil(pm.current_request)
        assert.equal(0, #pm.queue)
        assert.spy(chooser_close_stub).was.called(1)
    end)

    it("does not mutate transcript lines when shown or cleared", function()
        vim.api.nvim_buf_set_lines(
            bufnr,
            0,
            -1,
            false,
            { "line 1", "line 2", "line 3" }
        )

        local lines_before = vim.api.nvim_buf_line_count(bufnr)

        add_tool_call("tc-lines-1", "edit")
        pm:add_request(
            make_request("tc-lines-1"),
            spy.new(function() end) --[[@as function]]
        )

        assert.equal(lines_before, vim.api.nvim_buf_line_count(bufnr))

        pm:clear()

        assert.equal(lines_before, vim.api.nvim_buf_line_count(bufnr))
    end)
end)
