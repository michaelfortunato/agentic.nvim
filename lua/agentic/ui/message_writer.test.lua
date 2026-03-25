--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer
    local uv_new_timer_stub
    local schedule_wrap_stub
    local fake_timer

    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll

    local function make_fake_timer()
        local timer = {
            start_calls = {},
            stop_call_count = 0,
            close_call_count = 0,
            callback = nil,
            closed = false,
        }

        function timer:start(timeout, repeat_ms, callback)
            table.insert(self.start_calls, {
                timeout = timeout,
                repeat_ms = repeat_ms,
                callback = callback,
            })
            self.callback = callback
        end

        function timer:stop()
            self.stop_call_count = self.stop_call_count + 1
        end

        function timer:close()
            self.close_call_count = self.close_call_count + 1
            self.closed = true
        end

        function timer:is_closing()
            return self.closed
        end

        function timer:fire()
            if self.callback then
                self.callback()
            end
        end

        return timer
    end

    before_each(function()
        original_auto_scroll = Config.auto_scroll
        MessageWriter = require("agentic.ui.message_writer")

        fake_timer = make_fake_timer()
        uv_new_timer_stub = spy.stub(vim.uv, "new_timer")
        uv_new_timer_stub:returns(fake_timer)
        schedule_wrap_stub = spy.stub(vim, "schedule_wrap")
        schedule_wrap_stub:invokes(function(fn)
            return fn
        end)

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        if writer then
            writer:destroy()
        end
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        schedule_wrap_stub:revert()
        uv_new_timer_stub:revert()
    end)

    --- @param line_count integer
    --- @param cursor_line integer
    local function setup_buffer(line_count, cursor_line)
        local lines = {}
        for i = 1, line_count do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    end

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_message_update(text)
        return {
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param id string
    --- @param status agentic.acp.ToolCallStatus
    --- @param body? string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_tool_call_block(id, status, body)
        return {
            tool_call_id = id,
            status = status,
            kind = "execute",
            argument = "ls",
            body = body or { "output" },
        }
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when the visible window end is within threshold of buffer end",
            function()
                setup_buffer(20, 1)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it(
            "returns false when the window viewport is far from buffer end",
            function()
                setup_buffer(100, 1)
                assert.is_false(writer:_check_auto_scroll(bufnr))
            end
        )

        it("returns false when threshold is disabled (zero or nil)", function()
            setup_buffer(1, 1)

            Config.auto_scroll = { threshold = 0, debounce_ms = 150 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)

        it("uses win_findbuf to check the chat view across tabpages", function()
            setup_buffer(100, 1)

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()

            assert.is_false(writer:_check_auto_scroll(bufnr))

            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)
    end)

    describe("_auto_scroll", function()
        it("restarts debounce timer when follow mode stays enabled", function()
            writer._should_auto_scroll_fn = function()
                return true
            end

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._scroll_scheduled)
            assert.equal(1, #fake_timer.start_calls)

            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            assert.equal(3, #fake_timer.start_calls)
        end)

        it("stops a pending scroll when follow mode is turned off", function()
            local follow_output = true
            writer._should_auto_scroll_fn = function()
                return follow_output
            end

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._scroll_scheduled)

            follow_output = false
            writer:_auto_scroll(bufnr)

            assert.is_false(writer._scroll_scheduled)
            assert.equal(2, fake_timer.stop_call_count)
        end)

        it("uses the scroll callback when follow mode stays enabled", function()
            local scroll_spy = spy.new(function() end)
            writer._should_auto_scroll_fn = function()
                return true
            end
            writer._scroll_to_bottom_fn = scroll_spy --[[@as function]]

            writer:_auto_scroll(bufnr)
            fake_timer:fire()

            assert.spy(scroll_spy).was.called(1)
            assert.is_false(writer._scroll_scheduled)
        end)

        it("skips the debounced scroll when follow mode is lost", function()
            local follow_output = true
            local scroll_spy = spy.new(function() end)
            writer._should_auto_scroll_fn = function()
                return follow_output
            end
            writer._scroll_to_bottom_fn = scroll_spy --[[@as function]]

            writer:_auto_scroll(bufnr)
            follow_output = false
            fake_timer:fire()

            assert.spy(scroll_spy).was.called(0)
            assert.is_false(writer._scroll_scheduled)
        end)

        it(
            "fallback scroll moves the chat window even from another tabpage",
            function()
                setup_buffer(20, 20)
                writer._should_auto_scroll_fn = function()
                    return true
                end

                local new_lines = {}
                for i = 1, 30 do
                    new_lines[i] = "streamed line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)

                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()

                writer:_auto_scroll(bufnr)
                fake_timer:fire()

                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")
            end
        )
    end)

    describe("auto-scroll with public write methods", function()
        it(
            "write_message schedules scrolling when follow mode is enabled",
            function()
                writer._should_auto_scroll_fn = function()
                    return true
                end

                local long_text = {}
                for i = 1, 50 do
                    long_text[i] = "message line " .. i
                end

                writer:write_message(
                    make_message_update(table.concat(long_text, "\n"))
                )

                assert.is_true(writer._scroll_scheduled)
                assert.equal(1, #fake_timer.start_calls)
            end
        )

        it(
            "write_tool_call_block schedules scrolling when follow mode is enabled",
            function()
                writer._should_auto_scroll_fn = function()
                    return true
                end

                local body = {}
                for i = 1, 20 do
                    body[i] = "file" .. i .. ".lua"
                end

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-1",
                    status = "pending",
                    kind = "execute",
                    argument = "ls -la",
                    body = body,
                }
                writer:write_tool_call_block(block)

                assert.is_true(writer._scroll_scheduled)
                assert.equal(1, #fake_timer.start_calls)
                assert.is_true(vim.api.nvim_buf_line_count(bufnr) > 20)
            end
        )

        it(
            "write_message does not schedule scrolling when follow mode is disabled",
            function()
                writer._should_auto_scroll_fn = function()
                    return false
                end

                writer:write_message(
                    make_message_update("new content\nmore content")
                )

                assert.is_false(writer._scroll_scheduled)
                assert.equal(0, #fake_timer.start_calls)
            end
        )
    end)

    describe("destroy", function()
        it("stops and closes the scroll timer", function()
            writer:_auto_scroll(bufnr)

            writer:destroy()

            assert.equal(1, fake_timer.close_call_count)
            assert.is_false(writer._scroll_scheduled)
            assert.is_nil(writer._scroll_timer)
        end)
    end)

    describe("content changed listeners", function()
        it("fires listeners when notified", function()
            local callback_spy = spy.new(function() end)
            writer:add_content_changed_listener(callback_spy --[[@as function]])

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(1)
        end)

        it(
            "fires listeners for each write method that produces content",
            function()
                local block = make_tool_call_block("cb-setup", "pending")
                writer:write_tool_call_block(block)

                local callback_spy = spy.new(function() end)
                writer:add_content_changed_listener(
                    callback_spy --[[@as function]]
                )

                writer:write_message(make_message_update("hello"))
                writer:write_message_chunk(make_message_update("chunk"))
                writer:write_tool_call_block(
                    make_tool_call_block("cb-1", "pending")
                )
                writer:update_tool_call_block({
                    tool_call_id = "cb-setup",
                    status = "completed",
                    body = { "done" },
                })

                assert.spy(callback_spy).was.called(4)
            end
        )

        it("does not fire listeners when content is empty", function()
            local callback_spy = spy.new(function() end)
            writer:add_content_changed_listener(
                callback_spy --[[@as function]]
            )

            writer:write_message(make_message_update(""))
            writer:write_message_chunk(make_message_update(""))

            assert.spy(callback_spy).was.called(0)
        end)

        it("removes only the targeted additional listener", function()
            local first_spy = spy.new(function() end)
            local second_spy = spy.new(function() end)

            local first_id = writer:add_content_changed_listener(
                first_spy --[[@as function]]
            )
            writer:add_content_changed_listener(second_spy --[[@as function]])

            writer:remove_content_changed_listener(first_id)
            writer:_notify_content_changed()

            assert.spy(first_spy).was.called(0)
            assert.spy(second_spy).was.called(1)
        end)
    end)

    describe("_prepare_block_lines", function()
        local FileSystem
        local read_stub
        local path_stub
        local original_diff_preview_enabled

        before_each(function()
            FileSystem = require("agentic.utils.file_system")
            read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
            path_stub = spy.stub(FileSystem, "to_absolute_path")
            path_stub:invokes(function(path)
                return path
            end)
            original_diff_preview_enabled = Config.diff_preview.enabled
        end)

        after_each(function()
            read_stub:revert()
            path_stub:revert()
            Config.diff_preview.enabled = original_diff_preview_enabled
        end)

        it("creates highlight ranges for pure insertion hunks", function()
            Config.diff_preview.enabled = false
            read_stub:returns({ "line1", "line2", "line3" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-hl",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "line1", "line2", "line3" },
                    new = { "line1", "inserted", "line2", "line3" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local found_inserted = false
            for _, line in ipairs(lines) do
                if line == "+ inserted" then
                    found_inserted = true
                    break
                end
            end
            assert.is_true(found_inserted)
            assert.is_true(vim.tbl_contains(lines, "@@ insert near line 2 @@"))

            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new"
            end, highlight_ranges)
            assert.is_true(#new_ranges > 0)
            assert.equal("inserted", new_ranges[1].new_line)
            assert.equal(2, new_ranges[1].display_prefix_len)
        end)

        it("renders modifications as explicit old/new line pairs", function()
            Config.diff_preview.enabled = false
            read_stub:returns({ "old value" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-mod",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "old value" },
                    new = { "new value" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local old_line_index = vim.fn.index(lines, "- old value")
            local new_line_index = vim.fn.index(lines, "+ new value")

            assert.is_true(vim.tbl_contains(lines, "@@ line 1 @@"))
            assert.is_true(old_line_index >= 0)
            assert.is_true(new_line_index > old_line_index)

            local old_ranges = vim.tbl_filter(function(r)
                return r.type == "old"
            end, highlight_ranges)
            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new_modification"
            end, highlight_ranges)

            assert.equal("old value", old_ranges[1].old_line)
            assert.equal("new value", old_ranges[1].new_line)
            assert.equal("old value", new_ranges[1].old_line)
            assert.equal("new value", new_ranges[1].new_line)
            assert.equal(2, old_ranges[1].display_prefix_len)
            assert.equal(2, new_ranges[1].display_prefix_len)
        end)

        it(
            "keeps the chat diff card compact when buffer review is available",
            function()
                read_stub:returns({
                    "a1",
                    "a2",
                    "a3",
                    "a4",
                    "a5",
                    "a6",
                })

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-summary",
                    status = "pending",
                    kind = "edit",
                    argument = "/test.lua",
                    file_path = "/test.lua",
                    diff = {
                        old = { "a1", "a2", "a3", "a4", "a5", "a6" },
                        new = { "b1", "b2", "b3", "b4", "b5", "b6" },
                    },
                }

                local lines = writer:_prepare_block_lines(block)
                local summary_index =
                    vim.fn.index(lines, "1 hunk · 6 modified lines")
                local hint_index =
                    vim.fn.index(lines, "Review in buffer: ]c next, [c prev")

                assert.is_true(vim.tbl_contains(lines, "/test.lua"))
                assert.is_true(summary_index >= 0)
                assert.is_true(hint_index > summary_index)
                assert.is_false(vim.tbl_contains(lines, "@@ lines 1-6 @@"))
                assert.is_false(vim.tbl_contains(lines, "- a1"))
                assert.is_false(vim.tbl_contains(lines, "+ b1"))
                assert.is_false(
                    vim.tbl_contains(
                        lines,
                        "... 2 more changes in buffer review"
                    )
                )
            end
        )

        it("summarizes larger diffs before showing a compact sample", function()
            Config.diff_preview.enabled = false
            read_stub:returns({
                "a1",
                "a2",
                "a3",
                "a4",
                "a5",
                "a6",
            })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-summary",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "a1", "a2", "a3", "a4", "a5", "a6" },
                    new = { "b1", "b2", "b3", "b4", "b5", "b6" },
                },
            }

            local lines = writer:_prepare_block_lines(block)
            local summary_index =
                vim.fn.index(lines, "1 hunk · 6 modified lines")
            local hunk_index = vim.fn.index(lines, "@@ lines 1-6 @@")

            assert.is_true(vim.tbl_contains(lines, "/test.lua"))
            assert.is_true(summary_index >= 0)
            assert.is_true(hunk_index > summary_index)
            assert.is_true(
                vim.tbl_contains(lines, "... 2 more changes in buffer review")
            )
            assert.is_true(vim.tbl_contains(lines, "- a4"))
            assert.is_true(vim.tbl_contains(lines, "+ b4"))
            assert.is_false(vim.tbl_contains(lines, "- a5"))
            assert.is_false(vim.tbl_contains(lines, "+ b5"))
        end)

        it("limits transcript samples when a diff spans many hunks", function()
            Config.diff_preview.enabled = false
            read_stub:returns({
                "a1",
                "keep1",
                "a2",
                "keep2",
                "a3",
                "keep3",
            })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-many-hunks",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "a1", "keep1", "a2", "keep2", "a3", "keep3" },
                    new = { "b1", "keep1", "b2", "keep2", "b3", "keep3" },
                },
            }

            local lines = writer:_prepare_block_lines(block)

            assert.is_true(
                vim.tbl_contains(lines, "3 hunks · 3 modified lines")
            )
            assert.is_true(vim.tbl_contains(lines, "@@ line 1 @@"))
            assert.is_true(vim.tbl_contains(lines, "@@ line 3 @@"))
            assert.is_false(vim.tbl_contains(lines, "@@ line 5 @@"))
            assert.is_true(
                vim.tbl_contains(lines, "... 1 more change in buffer review")
            )
        end)
    end)
end)
