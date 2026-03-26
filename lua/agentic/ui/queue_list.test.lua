local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.QueueList", function()
    local Chooser = require("agentic.ui.chooser")
    local QueueList = require("agentic.ui.queue_list")

    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.ui.QueueList
    local queue_list
    --- @type TestSpy
    local steer_spy
    --- @type TestSpy
    local send_now_spy
    --- @type TestSpy
    local remove_spy
    --- @type TestSpy
    local cancel_spy
    --- @type TestStub|nil
    local chooser_show_stub

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 24,
            height = 8,
            row = 0,
            col = 0,
        })

        steer_spy = spy.new(function() end)
        send_now_spy = spy.new(function() end)
        remove_spy = spy.new(function() end)
        cancel_spy = spy.new(function() end)

        queue_list = QueueList:new(bufnr, {
            on_steer = steer_spy --[[@as fun(submission_id: integer)]],
            on_send_now = send_now_spy --[[@as fun(submission_id: integer)]],
            on_remove = remove_spy --[[@as fun(submission_id: integer)]],
            on_cancel = cancel_spy --[[@as fun()]],
        })
    end)

    after_each(function()
        if chooser_show_stub then
            chooser_show_stub:revert()
            chooser_show_stub = nil
        end

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("renders one line per queue entry with ellipsis when needed", function()
        queue_list:set_items({
            {
                id = 1,
                input_text = "this is a very long queued follow up prompt that should be truncated",
            },
            {
                id = 2,
                input_text = "short prompt",
            },
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.equal(4, #lines)
        assert.equal("Queue · 2 pending", lines[1])
        assert.equal("<CR> choose · ! now · d remove", lines[2])
        assert.truthy(lines[3]:match("^1%. "))
        assert.truthy(lines[3]:match("%.%.%.$"))
        assert.is_nil(lines[3]:match("\n"))
        assert.equal("2. short prompt", lines[4])
        assert.is_true(
            vim.fn.strdisplaywidth(lines[3])
                <= vim.api.nvim_win_get_width(winid)
        )
    end)

    it("routes actions from the selected line", function()
        queue_list:set_items({
            { id = 7, input_text = "first" },
            { id = 11, input_text = "second" },
        })

        vim.api.nvim_set_current_win(winid)
        vim.api.nvim_win_set_cursor(winid, { 4, 0 })

        assert.equal(11, queue_list:_get_submission_id_at_cursor())

        queue_list:_run_action(remove_spy --[[@as fun(submission_id: integer)]])
        queue_list:_run_action(
            send_now_spy --[[@as fun(submission_id: integer)]]
        )
        queue_list:_run_action(steer_spy --[[@as fun(submission_id: integer)]])

        assert.spy(remove_spy).was.called(1)
        assert.equal(11, remove_spy.calls[1][1])
        assert.spy(send_now_spy).was.called(1)
        assert.equal(11, send_now_spy.calls[1][1])
        assert.spy(steer_spy).was.called(1)
        assert.equal(11, steer_spy.calls[1][1])
    end)

    it("routes header actions to the first queued message", function()
        queue_list:set_items({
            { id = 7, input_text = "first" },
            { id = 11, input_text = "second" },
        })

        vim.api.nvim_set_current_win(winid)
        vim.api.nvim_win_set_cursor(winid, { 1, 0 })

        assert.equal(7, queue_list:_get_submission_id_at_cursor())

        queue_list:_run_action(steer_spy --[[@as fun(submission_id: integer)]])

        assert.spy(steer_spy).was.called(1)
        assert.equal(7, steer_spy.calls[1][1])
    end)

    it("routes cancel back to the prompt", function()
        queue_list:_run_cancel(cancel_spy --[[@as fun()]])

        assert.spy(cancel_spy).was.called(1)
    end)

    it("opens a chooser for the selected queued message", function()
        local chosen_callback

        chooser_show_stub = spy.stub(Chooser, "show")
        chooser_show_stub:invokes(function(items, opts, on_choice)
            chosen_callback = on_choice
            assert.equal("Queue action", opts.prompt)
            assert.equal("Steer", items[1].name)
            assert.equal("Send Now", items[2].name)
            assert.equal("Remove", items[3].name)
            return true
        end)

        queue_list:set_items({
            { id = 7, input_text = "first" },
            { id = 11, input_text = "second" },
        })

        vim.api.nvim_set_current_win(winid)
        vim.api.nvim_win_set_cursor(winid, { 2, 0 })

        queue_list:_open_action_menu()

        assert.spy(chooser_show_stub).was.called(1)
        assert.is_not_nil(chosen_callback)

        chosen_callback({
            id = "remove",
        })

        assert.spy(remove_spy).was.called(1)
        assert.equal(7, remove_spy.calls[1][1])
        assert.spy(send_now_spy).was.called(0)
        assert.spy(steer_spy).was.called(0)
    end)
end)
