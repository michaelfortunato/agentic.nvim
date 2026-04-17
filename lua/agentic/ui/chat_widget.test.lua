local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local KeymapHelp = require("agentic.ui.keymap_help")
local Logger = require("agentic.utils.logger")
local WidgetLayout = require("agentic.ui.widget_layout")

describe("agentic.ui.ChatWidget", function()
    --- @type agentic.ui.ChatWidget
    local ChatWidget

    ChatWidget = require("agentic.ui.chat_widget")

    after_each(function()
        pcall(function()
            vim.cmd("silent! stopinsert")
        end)
        pcall(function()
            vim.cmd("silent! tabonly")
        end)
        pcall(function()
            vim.cmd("silent! only")
        end)
    end)

    --- Helper to populate a dynamic buffer with content
    --- @param widget agentic.ui.ChatWidget
    --- @param name string
    --- @param content string[]
    local function fill_buffer(widget, name, content)
        local bufnr = widget.buf_nrs[name]
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    end

    -- Tests that behave identically regardless of layout position
    for _, position in ipairs({ "right", "left", "bottom" }) do
        -- Bottom layout uses 2 to avoid touching the screen edge
        local padding = position == "bottom" and 2 or 1

        describe(string.format("(%s layout)", position), function()
            local tab_page_id
            local widget
            local original_position
            local original_move_cursor_setting

            before_each(function()
                original_position = Config.windows.position
                original_move_cursor_setting =
                    Config.settings.move_cursor_to_chat_on_submit
                Config.windows.position = position

                vim.cmd("tabnew")
                tab_page_id = vim.api.nvim_get_current_tabpage()

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    tab_page_id,
                    on_submit_spy --[[@as function]]
                )
            end)

            after_each(function()
                if widget then
                    pcall(function()
                        widget:destroy()
                    end)
                end
                pcall(function()
                    vim.cmd("tabclose")
                end)

                Config.windows.position = original_position
                Config.settings.move_cursor_to_chat_on_submit =
                    original_move_cursor_setting
            end)

            it("creates widget with valid buffer IDs", function()
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.chat))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.input))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.code))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.files))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.queue))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.todos))
            end)

            it(
                "initializes prompt header hints from the current keymaps",
                function()
                    assert.equal("?: keymaps", widget.headers.chat.suffix)
                    assert.equal(
                        "?: keymaps · <CR>: submit",
                        widget.headers.input.suffix
                    )
                end
            )

            it("set_input_text replaces the prompt buffer content", function()
                widget:set_input_text("first line\nsecond line")

                assert.same(
                    { "first line", "second line" },
                    vim.api.nvim_buf_get_lines(
                        widget.buf_nrs.input,
                        0,
                        -1,
                        false
                    )
                )
            end)

            it(
                "binds ? to open keymap help for the current widget buffer",
                function()
                    local help_stub = spy.stub(KeymapHelp, "show_for_buffer")

                    widget:show({ focus_prompt = false })
                    vim.api.nvim_set_current_win(widget.win_nrs.chat)

                    local mapping = vim.fn.maparg("?", "n", false, true)
                    mapping.callback()

                    assert.spy(help_stub).was.called(1)
                    assert.equal(widget.buf_nrs.chat, help_stub.calls[1][1])

                    help_stub:revert()
                end
            )

            it("submits the prompt with <CR> in insert mode", function()
                local on_submit_spy = spy.new(function() end)
                widget.on_submit_input = on_submit_spy --[[@as function]]

                widget:show({ focus_prompt = true })
                fill_buffer(widget, "input", { "hello from insert enter" })

                vim.api.nvim_set_current_win(widget.win_nrs.input)
                vim.cmd("startinsert")

                local mapping = vim.fn.maparg("<CR>", "i", false, true)
                mapping.callback()

                assert.spy(on_submit_spy).was.called(1)
                assert
                    .spy(on_submit_spy).was
                    .called_with("hello from insert enter")
            end)

            it(
                "does not attach treesitter highlighters to side buffers",
                function()
                    for _, name in ipairs({
                        "todos",
                        "code",
                        "files",
                        "queue",
                        "diagnostics",
                        "input",
                    }) do
                        assert.is_nil(
                            vim.treesitter.highlighter.active[widget.buf_nrs[name]]
                        )
                    end
                end
            )

            it(
                "show() creates chat and input windows only when buffers are empty",
                function()
                    assert.is_falsy(widget:is_open())

                    widget:show()

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                    )
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.input)
                    )
                    assert.is_nil(widget.win_nrs.code)
                    assert.is_nil(widget.win_nrs.files)
                    assert.is_nil(widget.win_nrs.queue)
                    assert.is_nil(widget.win_nrs.todos)
                end
            )

            it("uses a hanging indent for wrapped chat lines", function()
                widget:show({ focus_prompt = false })

                assert.is_true(vim.wo[widget.win_nrs.chat].breakindent)
                assert.equal(
                    "shift:2",
                    vim.wo[widget.win_nrs.chat].breakindentopt
                )
            end)

            it(
                "<CR> toggles a chat card from a preview line, not just its header",
                function()
                    local MessageWriter = require("agentic.ui.message_writer")
                    local writer = MessageWriter:new(widget.buf_nrs.chat)

                    widget:bind_message_writer(writer)
                    widget:show({ focus_prompt = false })

                    writer:render_interaction_session({
                        session_id = "session-1",
                        title = "Test Session",
                        timestamp = os.time(),
                        config_options = {},
                        available_commands = {},
                        turns = {
                            {
                                index = 1,
                                request = {
                                    kind = "user",
                                    surface = "chat",
                                    text = "",
                                    content = {},
                                    content_nodes = {},
                                    nodes = {},
                                },
                                response = {
                                    provider_name = "Codex ACP",
                                    nodes = {
                                        {
                                            type = "tool_call",
                                            tool_call_id = "toggle-execute",
                                            title = "rg -n queue lua/agentic",
                                            kind = "execute",
                                            status = "completed",
                                            content_nodes = {
                                                {
                                                    type = "content_output",
                                                    content_node = {
                                                        type = "text_content",
                                                        text = table.concat({
                                                            "lua/agentic/ui/queue_list.lua:45:Queued messages",
                                                            "lua/agentic/session_manager.lua:643:Queue: 3",
                                                            "lua/agentic/ui/window_decoration.lua:35:Queue",
                                                        }, "\n"),
                                                        text_structure = "plain",
                                                        content = {
                                                            type = "text",
                                                            text = table.concat(
                                                                {
                                                                    "lua/agentic/ui/queue_list.lua:45:Queued messages",
                                                                    "lua/agentic/session_manager.lua:643:Queue: 3",
                                                                    "lua/agentic/ui/window_decoration.lua:35:Queue",
                                                                },
                                                                "\n"
                                                            ),
                                                        },
                                                    },
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    })

                    vim.cmd("stopinsert")
                    vim.api.nvim_set_current_win(widget.win_nrs.chat)
                    local lines = vim.api.nvim_buf_get_lines(
                        widget.buf_nrs.chat,
                        0,
                        -1,
                        false
                    )
                    local preview_line =
                        vim.fn.index(lines, "    3 output lines")
                    assert.is_true(preview_line >= 0)
                    vim.api.nvim_win_set_cursor(
                        widget.win_nrs.chat,
                        { preview_line + 1, 0 }
                    )
                    local mapping = vim.fn.maparg("<CR>", "n", false, true)
                    mapping.callback()

                    lines = vim.api.nvim_buf_get_lines(
                        widget.buf_nrs.chat,
                        0,
                        -1,
                        false
                    )

                    assert.is_true(
                        vim.tbl_contains(
                            lines,
                            "    lua/agentic/ui/window_decoration.lua:35:Queue"
                        )
                    )
                    assert.is_true(vim.tbl_contains(lines, "    <CR> collapse"))

                    writer:destroy()
                end
            )

            it("hide() closes all windows and preserves buffers", function()
                widget:show()

                local chat_win = widget.win_nrs.chat
                local input_win = widget.win_nrs.input
                local chat_buf = widget.buf_nrs.chat
                local input_buf = widget.buf_nrs.input

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(chat_win))
                assert.is_false(vim.api.nvim_win_is_valid(input_win))
                assert.is_nil(widget.win_nrs.chat)
                assert.is_nil(widget.win_nrs.input)
                assert.is_falsy(widget:is_open())

                assert.equal(chat_buf, widget.buf_nrs.chat)
                assert.equal(input_buf, widget.buf_nrs.input)
                assert.is_true(vim.api.nvim_buf_is_valid(chat_buf))
                assert.is_true(vim.api.nvim_buf_is_valid(input_buf))
            end)

            it("show() is idempotent when called multiple times", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat

                widget:show()

                assert.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it(
                "open_left_window can create a review window without stealing focus",
                function()
                    widget:show({ focus_prompt = false })

                    local original_winid = vim.api.nvim_get_current_win()
                    local review_bufnr = vim.api.nvim_create_buf(false, true)

                    local review_winid =
                        widget:open_left_window(review_bufnr, false)

                    assert.truthy(review_winid)
                    assert.is_true(vim.api.nvim_win_is_valid(review_winid))
                    assert.equal(original_winid, vim.api.nvim_get_current_win())
                    assert.equal(
                        review_bufnr,
                        vim.api.nvim_win_get_buf(review_winid)
                    )

                    vim.api.nvim_buf_delete(review_bufnr, { force = true })
                end
            )

            it("hide() is safe when called multiple times", function()
                widget:show()
                widget:hide()

                assert.has_no_errors(function()
                    widget:hide()
                end)
            end)

            it("show() after hide() creates new windows", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat
                widget:hide()

                widget:show()

                assert.are_not.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_false(vim.api.nvim_win_is_valid(first_chat_win))
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it("refresh_layout recreates widget windows", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat

                widget:refresh_layout({ focus_prompt = false })

                assert.are_not.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it("windows are created in correct tabpage", function()
                widget:show()

                assert.equal(
                    tab_page_id,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.chat)
                )
                assert.equal(
                    tab_page_id,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.input)
                )
            end)

            it(
                "identifies widget buffers and fallback editor windows",
                function()
                    local original_win = vim.api.nvim_get_current_win()
                    local original_buf = vim.api.nvim_get_current_buf()

                    widget:show({ focus_prompt = false })

                    assert.is_true(widget:owns_buffer(widget.buf_nrs.chat))
                    assert.is_false(widget:owns_buffer(original_buf))
                    assert.equal(
                        original_win,
                        widget:find_first_non_widget_window()
                    )
                    assert.equal(
                        original_win,
                        widget:find_first_editor_window()
                    )
                end
            )

            it("hide() stops insert mode", function()
                widget:show()
                vim.api.nvim_set_current_win(widget.win_nrs.input)
                vim.cmd("startinsert")

                widget:hide()

                assert.are_not.equal("i", vim.fn.mode())
            end)

            it("focus_input restores chat to the latest message", function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                local lines = {}
                for i = 1, 40 do
                    lines[i] = "chat line " .. i
                end

                fill_buffer(widget, "chat", lines)
                fill_buffer(widget, "code", { "local value = 1" })

                widget:show({ focus_prompt = false })

                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
                vim.api.nvim_set_current_win(widget.win_nrs.code)

                widget:focus_input()

                assert.equal(
                    widget.win_nrs.input,
                    vim.api.nvim_get_current_win()
                )
                assert.equal(
                    #lines,
                    vim.api.nvim_win_get_cursor(widget.win_nrs.chat)[1]
                )

                schedule_stub:revert()
            end)

            it(
                "scroll_chat_to_bottom follows output without taking focus",
                function()
                    local lines = {}
                    for i = 1, 60 do
                        lines[i] = "chat line " .. i
                    end

                    fill_buffer(widget, "chat", lines)
                    widget:show({ focus_prompt = false })

                    vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
                    vim.api.nvim_set_current_win(widget.win_nrs.input)

                    widget:scroll_chat_to_bottom()

                    assert.equal(
                        widget.win_nrs.input,
                        vim.api.nvim_get_current_win()
                    )
                    assert.equal(
                        #lines,
                        vim.api.nvim_win_get_cursor(widget.win_nrs.chat)[1]
                    )
                    assert.is_true(widget:should_follow_chat_output())
                end
            )

            it("tracks follow mode from the chat viewport", function()
                local lines = {}
                for i = 1, 100 do
                    lines[i] = "chat line " .. i
                end

                fill_buffer(widget, "chat", lines)
                widget:show({ focus_prompt = false })
                widget:scroll_chat_to_bottom()

                assert.is_true(widget:should_follow_chat_output())

                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
                assert.is_false(widget:_update_chat_follow_output())
                assert.is_false(widget:should_follow_chat_output())
            end)

            it("restores a paused chat view after hide and show", function()
                local lines = {}
                for i = 1, 100 do
                    lines[i] = "chat line " .. i
                end

                fill_buffer(widget, "chat", lines)
                widget:show({ focus_prompt = false })

                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
                widget:_update_chat_follow_output()
                widget:_store_chat_view()

                widget:hide()
                widget:show({ focus_prompt = false })

                assert.is_false(widget:should_follow_chat_output())
                assert.equal(
                    1,
                    vim.api.nvim_win_get_cursor(widget.win_nrs.chat)[1]
                )
            end)

            it(
                "shows unread output context while follow mode is paused",
                function()
                    local lines = {}
                    local content_changed_callback

                    for i = 1, 100 do
                        lines[i] = "chat line " .. i
                    end

                    widget:bind_message_writer({
                        add_content_changed_listener = function(_, callback)
                            content_changed_callback = callback
                            return 1
                        end,
                        remove_content_changed_listener = function() end,
                    })

                    fill_buffer(widget, "chat", lines)
                    widget:show({ focus_prompt = false })
                    widget:scroll_chat_to_bottom()

                    vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
                    widget:_update_chat_follow_output()
                    content_changed_callback()

                    assert.equal(
                        "New output below",
                        widget:_get_effective_header_context("chat")
                    )

                    widget:scroll_chat_to_bottom()
                    assert.is_nil(widget:_get_effective_header_context("chat"))
                end
            )

            it(
                "submit keeps a paused chat viewport untouched when chat focus is disabled",
                function()
                    local lines = {}
                    local on_submit_spy = spy.new(function() end)

                    for i = 1, 100 do
                        lines[i] = "chat line " .. i
                    end

                    widget.on_submit_input = on_submit_spy --[[@as function]]
                    fill_buffer(widget, "chat", lines)
                    widget:show({ focus_prompt = false })
                    widget:scroll_chat_to_bottom()

                    vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
                    widget:_update_chat_follow_output()
                    vim.api.nvim_set_current_win(widget.win_nrs.input)
                    vim.api.nvim_buf_set_lines(
                        widget.buf_nrs.input,
                        0,
                        -1,
                        false,
                        { "test prompt" }
                    )

                    widget:_submit_input()

                    assert.spy(on_submit_spy).was.called(1)
                    assert.equal(
                        widget.win_nrs.input,
                        vim.api.nvim_get_current_win()
                    )
                    assert.equal(
                        1,
                        vim.api.nvim_win_get_cursor(widget.win_nrs.chat)[1]
                    )
                    assert.is_false(widget:should_follow_chat_output())
                end
            )

            it(
                "submit keeps the prompt in insert mode when chat focus is disabled",
                function()
                    local on_submit_spy = spy.new(function() end)

                    widget.on_submit_input = on_submit_spy --[[@as function]]
                    widget:show({ focus_prompt = false })
                    vim.api.nvim_set_current_win(widget.win_nrs.input)
                    vim.api.nvim_buf_set_lines(
                        widget.buf_nrs.input,
                        0,
                        -1,
                        false,
                        { "test prompt" }
                    )

                    vim.cmd("startinsert")
                    widget:_submit_input()

                    local ok = vim.wait(200, function()
                        return vim.fn.mode() == "i"
                    end)

                    assert.spy(on_submit_spy).was.called(1)
                    assert.equal(
                        widget.win_nrs.input,
                        vim.api.nvim_get_current_win()
                    )
                    assert.is_true(ok)
                    assert.equal("i", vim.fn.mode())

                    vim.cmd("stopinsert")
                end
            )

            it(
                "submit resumes follow mode only when chat focus on submit is enabled",
                function()
                    local schedule_stub = spy.stub(vim, "schedule")
                    local lines = {}

                    schedule_stub:invokes(function(fn)
                        fn()
                    end)
                    Config.settings.move_cursor_to_chat_on_submit = true

                    for i = 1, 100 do
                        lines[i] = "chat line " .. i
                    end

                    fill_buffer(widget, "chat", lines)
                    widget:show({ focus_prompt = false })
                    widget:scroll_chat_to_bottom()

                    vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
                    widget:_update_chat_follow_output()
                    vim.api.nvim_set_current_win(widget.win_nrs.input)
                    vim.api.nvim_buf_set_lines(
                        widget.buf_nrs.input,
                        0,
                        -1,
                        false,
                        { "test prompt" }
                    )

                    widget:_submit_input()

                    assert.equal(
                        widget.win_nrs.chat,
                        vim.api.nvim_get_current_win()
                    )
                    assert.equal(
                        #lines,
                        vim.api.nvim_win_get_cursor(widget.win_nrs.chat)[1]
                    )
                    assert.is_true(widget:should_follow_chat_output())

                    schedule_stub:revert()
                end
            )

            describe("dynamic window creation", function()
                local test_cases = {
                    {
                        name = "code",
                        content = { "local foo = 'bar'", "print(foo)" },
                    },
                    {
                        name = "files",
                        content = { "file1.lua", "file2.lua" },
                    },
                    {
                        name = "todos",
                        content = { "todo1", "todo2" },
                    },
                }

                for _, tc in ipairs(test_cases) do
                    it(
                        string.format(
                            "creates %s window when buffer has content",
                            tc.name
                        ),
                        function()
                            fill_buffer(widget, tc.name, tc.content)
                            widget:show()

                            assert.is_true(
                                vim.api.nvim_win_is_valid(
                                    widget.win_nrs[tc.name]
                                )
                            )
                            assert.equal(
                                tab_page_id,
                                vim.api.nvim_win_get_tabpage(
                                    widget.win_nrs[tc.name]
                                )
                            )
                        end
                    )
                end
            end)

            it("hide() closes all dynamic windows when they exist", function()
                for _, name in ipairs({ "files", "code", "todos" }) do
                    fill_buffer(widget, name, { "content" })
                end

                widget:show()

                local files_win = widget.win_nrs.files
                local code_win = widget.win_nrs.code
                local todos_win = widget.win_nrs.todos

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(files_win))
                assert.is_false(vim.api.nvim_win_is_valid(code_win))
                assert.is_false(vim.api.nvim_win_is_valid(todos_win))
                assert.is_nil(widget.win_nrs.files)
                assert.is_nil(widget.win_nrs.code)
                assert.is_nil(widget.win_nrs.todos)
            end)

            it(
                "hide() creates a fallback window when only widget windows remain",
                function()
                    widget:show({ focus_prompt = false })

                    local original_win = widget:find_first_editor_window()
                    assert.truthy(original_win)
                    vim.api.nvim_win_close(original_win, true)

                    assert.has_no_errors(function()
                        widget:hide()
                    end)

                    local remaining_wins =
                        vim.api.nvim_tabpage_list_wins(tab_page_id)
                    assert.equal(1, #remaining_wins)
                    assert.is_nil(widget.win_nrs.chat)
                    assert.is_nil(widget.win_nrs.input)
                end
            )

            it("caps window height at max_height", function()
                local lines = {}
                for i = 1, 23 do
                    lines[i] = "line" .. i
                end
                fill_buffer(widget, "code", lines)

                widget:show()

                local height = vim.api.nvim_win_get_height(widget.win_nrs.code)
                assert.equal(15, height)
            end)

            it(
                string.format("dynamic window uses %d line(s) padding", padding),
                function()
                    fill_buffer(widget, "code", { "line1", "line2", "line3" })

                    widget:show()

                    local height =
                        vim.api.nvim_win_get_height(widget.win_nrs.code)
                    assert.equal(3 + padding, height)
                end
            )

            it("resizes window when content changes", function()
                fill_buffer(widget, "code", { "line1", "line2", "line3" })

                widget:show()
                assert.equal(
                    3 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    3,
                    3,
                    false,
                    { "line4", "line5", "line6", "line7" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    7 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            it("shrinks window when content is removed", function()
                fill_buffer(
                    widget,
                    "code",
                    { "line1", "line2", "line3", "line4", "line5" }
                )

                widget:show()
                assert.equal(
                    5 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1", "line2" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    2 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            describe("show() re-renders dynamic windows", function()
                it("closes window when buffer becomes empty", function()
                    fill_buffer(widget, "code", { "line1" })

                    widget:show()
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )

                    vim.api.nvim_buf_set_lines(
                        widget.buf_nrs.code,
                        0,
                        -1,
                        false,
                        {}
                    )

                    widget:show({ focus_prompt = false })

                    assert.is_nil(widget.win_nrs.code)
                end)

                it("creates window on show when content exists", function()
                    fill_buffer(widget, "code", { "line1" })

                    assert.has_no_errors(function()
                        widget:show({ focus_prompt = false })
                    end)

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )
                end)
            end)
        end)
    end

    -- Right and left layouts behave identically, only split direction differs
    for _, side in ipairs({ "right", "left" }) do
        describe(string.format("(%s layout) specific", side), function()
            local widget
            local original_position

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = side

                vim.cmd("tabnew")

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    vim.api.nvim_get_current_tabpage(),
                    on_submit_spy --[[@as function]]
                )
            end)

            after_each(function()
                if widget then
                    pcall(function()
                        widget:destroy()
                    end)
                end
                pcall(function()
                    vim.cmd("tabclose")
                end)

                Config.windows.position = original_position
            end)

            it("input splits below chat", function()
                widget:show()

                local chat_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.chat)
                local input_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.input)

                -- Input row should be greater than chat row (below)
                assert.is_true(input_pos[1] > chat_pos[1])
                -- Same column position
                assert.equal(chat_pos[2], input_pos[2])
            end)

            it("input has fixed height", function()
                widget:show()

                local input_height =
                    vim.api.nvim_win_get_height(widget.win_nrs.input)
                assert.equal(Config.windows.input.height, input_height)
            end)

            it("queue opens between chat and input when populated", function()
                fill_buffer(widget, "queue", { "1. queued prompt" })

                widget:show()

                local chat_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.chat)
                local queue_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.queue)
                local input_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.input)

                assert.is_true(queue_pos[1] > chat_pos[1])
                assert.is_true(input_pos[1] > queue_pos[1])
                assert.equal(chat_pos[2], queue_pos[2])
                assert.equal(queue_pos[2], input_pos[2])
            end)
        end)
    end

    describe("(bottom layout) specific", function()
        local widget
        local original_position

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "bottom"

            vim.cmd("tabnew")

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end
            pcall(function()
                vim.cmd("tabclose")
            end)

            Config.windows.position = original_position
        end)

        it("input splits right of chat", function()
            widget:show()

            local chat_pos = vim.api.nvim_win_get_position(widget.win_nrs.chat)
            local input_pos =
                vim.api.nvim_win_get_position(widget.win_nrs.input)

            -- Same row (horizontal split)
            assert.equal(chat_pos[1], input_pos[1])
            -- Input column should be greater than chat column (to the right)
            assert.is_true(input_pos[2] > chat_pos[2])
        end)

        it("input width follows the configured stack width policy", function()
            widget:show()

            local chat_width = vim.api.nvim_win_get_width(widget.win_nrs.chat)
            local input_width = vim.api.nvim_win_get_width(widget.win_nrs.input)
            local total_width = chat_width + input_width
            local expected = WidgetLayout.calculate_stack_width(total_width)

            assert.equal(expected, input_width)
        end)

        it(
            "queue occupies the top of the right stack when populated",
            function()
                fill_buffer(widget, "queue", { "1. queued prompt" })

                widget:show()

                local chat_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.chat)
                local queue_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.queue)
                local input_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.input)

                assert.is_true(queue_pos[2] > chat_pos[2])
                assert.equal(queue_pos[2], input_pos[2])
                assert.is_true(input_pos[1] > queue_pos[1])
            end
        )
    end)

    describe("sync scopes", function()
        local first_widget
        local second_widget
        local first_tab
        local second_tab
        local original_position

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "right"

            vim.cmd("tabnew")
            first_tab = vim.api.nvim_get_current_tabpage()
            first_widget = ChatWidget:new(first_tab, function() end)
            first_widget:show({ focus_prompt = false })

            vim.cmd("tabnew")
            second_tab = vim.api.nvim_get_current_tabpage()
            second_widget = ChatWidget:new(second_tab, function() end)
            second_widget:show({ focus_prompt = false })
        end)

        after_each(function()
            if second_widget then
                pcall(function()
                    second_widget:destroy()
                end)
            end

            if first_widget then
                pcall(function()
                    first_widget:destroy()
                end)
            end

            pcall(function()
                vim.cmd("tabonly")
            end)
            Config.windows.position = original_position
        end)

        it("keeps header state isolated per widget tabpage", function()
            first_widget:render_header("chat", "First tab")
            second_widget:render_header("chat", "Second tab")
            second_widget:_set_header_overlay("chat", "Unread below")

            assert.equal(
                "First tab",
                first_widget:_get_effective_header_context("chat")
            )
            assert.equal(
                "Unread below · Second tab",
                second_widget:_get_effective_header_context("chat")
            )

            vim.api.nvim_set_current_tabpage(first_tab)
            assert.equal(
                "First tab",
                first_widget:_get_effective_header_context("chat")
            )

            vim.api.nvim_set_current_tabpage(second_tab)
            assert.equal(
                "Unread below · Second tab",
                second_widget:_get_effective_header_context("chat")
            )
        end)
    end)

    describe("rotate_layout", function()
        local widget
        local original_position
        local show_stub
        local notify_stub

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "right"

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )

            show_stub = spy.stub(widget, "show")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            show_stub:revert()
            notify_stub:revert()

            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end

            Config.windows.position = original_position
        end)

        it("uses default layouts when none provided", function()
            Config.windows.position = "right"

            widget:rotate_layout()

            assert.equal("bottom", Config.windows.position)
        end)

        it("uses default layouts when empty array provided", function()
            Config.windows.position = "right"

            widget:rotate_layout({})

            assert.equal("bottom", Config.windows.position)
        end)

        it(
            "stays on same layout and warns when only one is provided",
            function()
                Config.windows.position = "bottom"

                widget:rotate_layout({ "bottom" })

                assert.equal("bottom", Config.windows.position)
                assert.spy(notify_stub).was.called(1)
                local msg = notify_stub.calls[1][1]
                assert.is_true(msg:find("Only one layout") ~= nil)
            end
        )

        it("rotates through all layouts in order", function()
            local layouts = { "right", "bottom", "left" }

            Config.windows.position = "right"
            widget:rotate_layout(layouts)
            assert.equal("bottom", Config.windows.position)

            widget:rotate_layout(layouts)
            assert.equal("left", Config.windows.position)

            widget:rotate_layout(layouts)
            assert.equal("right", Config.windows.position)
        end)

        it("falls back to first layout when current is not in list", function()
            Config.windows.position = "bottom"

            widget:rotate_layout({ "right", "left" })

            assert.equal("right", Config.windows.position)
        end)

        it("calls show with focus_prompt false", function()
            widget:rotate_layout()

            assert.spy(show_stub).was.called(1)
            local call_args = show_stub.calls[1]
            -- call_args[1] is self, call_args[2] is the opts table
            assert.equal(false, call_args[2].focus_prompt)
        end)
    end)
end)
