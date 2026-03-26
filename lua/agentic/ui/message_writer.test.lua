--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local Theme = require("agentic.theme")

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
    local original_debug

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
        original_debug = Config.debug
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
        Config.debug = original_debug
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

    --- @param turns agentic.session.InteractionTurn[]
    --- @param opts? table
    --- @return agentic.session.InteractionSession
    local function make_interaction_session(turns, opts)
        opts = opts or {}
        return {
            session_id = opts.session_id or "session-1",
            title = opts.title or "Test Session",
            timestamp = opts.timestamp or os.time(),
            current_mode_id = opts.current_mode_id,
            config_options = opts.config_options or {},
            available_commands = opts.available_commands or {},
            turns = turns or {},
        }
    end

    --- @param text string
    --- @return agentic.session.InteractionTextContentNode
    local function make_text_content_node(text)
        local trimmed = vim.trim(text)
        local lines = vim.split(trimmed, "\n", { plain = true })
        local open_tag = #lines >= 2
                and vim.trim(lines[1]):match("^<([%a_][%w_%-]*)>$")
            or nil
        local close_tag = #lines >= 2
                and vim.trim(lines[#lines]):match("^</([%a_][%w_%-]*)>$")
            or nil
        local xml_root_tag = open_tag == close_tag and open_tag or nil

        return {
            type = "text_content",
            text = text,
            text_structure = xml_root_tag and "xml_wrapped" or "plain",
            xml_root_tag = xml_root_tag,
            content = { type = "text", text = text },
        }
    end

    --- @param opts? table
    --- @return agentic.session.InteractionTurn
    local function make_turn(opts)
        opts = opts or {}
        local request_text = opts.request_text or ""
        local request_content = opts.request_content
        if not request_content then
            request_content = request_text ~= ""
                    and { { type = "text", text = request_text } }
                or {}
        end

        local request_content_nodes = vim.tbl_map(function(content)
            if content.type == "text" then
                local node = make_text_content_node(content.text or "")
                node.content = vim.deepcopy(content)
                return node
            end

            if content.type == "resource_link" then
                return {
                    type = "resource_link_content",
                    uri = content.uri,
                    name = content.name,
                    title = content.title,
                    description = content.description,
                    mime_type = content.mimeType,
                    size = content.size,
                    content = vim.deepcopy(content),
                }
            end

            if content.type == "resource" and content.resource then
                return {
                    type = "resource_content",
                    uri = content.resource.uri,
                    mime_type = content.resource.mimeType,
                    text = content.resource.text,
                    blob = content.resource.blob,
                    content = vim.deepcopy(content),
                }
            end

            if content.type == "image" then
                return {
                    type = "image_content",
                    mime_type = content.mimeType,
                    uri = content.uri,
                    content = vim.deepcopy(content),
                }
            end

            if content.type == "audio" then
                return {
                    type = "audio_content",
                    mime_type = content.mimeType,
                    content = vim.deepcopy(content),
                }
            end

            return {
                type = "unknown_content",
                content = vim.deepcopy(content),
            }
        end, request_content)

        local request_nodes = {}
        local rendered_primary_text = false
        for index, content_node in ipairs(request_content_nodes) do
            if
                not rendered_primary_text
                and request_text ~= ""
                and content_node.type == "text_content"
                and content_node.text == request_text
            then
                request_nodes[#request_nodes + 1] = {
                    type = "request_text",
                    text = content_node.text,
                    content_index = index,
                    content_node = vim.deepcopy(content_node),
                }
                rendered_primary_text = true
            else
                request_nodes[#request_nodes + 1] = {
                    type = "request_content",
                    content_index = index,
                    content_node = vim.deepcopy(content_node),
                }
            end
        end

        if #request_nodes == 0 and request_text ~= "" then
            request_nodes[#request_nodes + 1] = {
                type = "request_text",
                text = request_text,
                content_index = 1,
                content_node = make_text_content_node(request_text),
            }
        end

        return {
            index = opts.index or 1,
            request = {
                kind = opts.request_kind or "user",
                text = request_text,
                timestamp = opts.request_timestamp,
                content = request_content,
                content_nodes = request_content_nodes,
                nodes = request_nodes,
            },
            response = {
                provider_name = opts.provider_name or "Codex ACP",
                nodes = opts.nodes or {},
            },
            result = opts.result,
        }
    end

    --- @param text string
    --- @param provider_name? string
    --- @return agentic.session.InteractionMessageNode
    local function make_message_node(text, provider_name)
        return {
            type = "message",
            text = text,
            provider_name = provider_name or "Codex ACP",
            content = { { type = "text", text = text } },
            content_nodes = {
                make_text_content_node(text),
            },
        }
    end

    --- @param chunks string[]
    --- @param provider_name? string
    --- @return agentic.session.InteractionMessageNode
    local function make_chunked_message_node(chunks, provider_name)
        local content = vim.tbl_map(function(chunk)
            return {
                type = "text",
                text = chunk,
            }
        end, chunks)

        local content_nodes = vim.tbl_map(function(chunk)
            return make_text_content_node(chunk)
        end, chunks)

        return {
            type = "message",
            text = table.concat(chunks, ""),
            provider_name = provider_name or "Codex ACP",
            content = content,
            content_nodes = content_nodes,
        }
    end

    --- @param text string
    --- @param provider_name? string
    --- @return agentic.session.InteractionThoughtNode
    local function make_thought_node(text, provider_name)
        return {
            type = "thought",
            text = text,
            provider_name = provider_name or "Codex ACP",
            content = { { type = "text", text = text } },
            content_nodes = {
                make_text_content_node(text),
            },
        }
    end

    --- @param opts table
    --- @return agentic.session.InteractionToolCallNode
    local function make_tool_node(opts)
        opts = opts or {}
        local body_lines = opts.body_lines or {}
        local body_text = opts.body_text
        if body_text == nil and #body_lines > 0 then
            body_text = table.concat(body_lines, "\n")
        end

        local content_nodes = opts.content_nodes
        if not content_nodes and body_text and body_text ~= "" then
            content_nodes = {
                {
                    type = "content_output",
                    content_node = make_text_content_node(body_text),
                },
            }
        end

        return {
            type = "tool_call",
            tool_call_id = opts.tool_call_id or "tool-1",
            title = opts.title or opts.argument or "tool",
            kind = opts.kind or "execute",
            status = opts.status or "completed",
            file_path = opts.file_path,
            permission_state = opts.permission_state,
            terminal_id = opts.terminal_id,
            content_nodes = content_nodes or {},
        }
    end

    --- @param turns agentic.session.InteractionTurn[]
    --- @param opts? table
    local function render_session(turns, opts)
        local render_opts = opts
                and opts.welcome_lines
                and { welcome_lines = opts.welcome_lines }
            or nil
        writer:render_interaction_session(
            make_interaction_session(turns, opts),
            render_opts
        )
    end

    --- @param lines string[]
    --- @param target string
    --- @return integer
    local function find_line_index(lines, target)
        return vim.fn.index(lines, target)
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when the visible window end is within threshold of buffer end",
            function()
                local threshold = Config.auto_scroll
                        and Config.auto_scroll.threshold
                    or 0
                local visible_lines = vim.api.nvim_win_call(winid, function()
                    return vim.fn.line("w$")
                end)

                setup_buffer(visible_lines + threshold, 1)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it(
            "returns false when the window viewport is far from buffer end",
            function()
                local threshold = Config.auto_scroll
                        and Config.auto_scroll.threshold
                    or 0
                local visible_lines = vim.api.nvim_win_call(winid, function()
                    return vim.fn.line("w$")
                end)

                setup_buffer(visible_lines + threshold + 10, 1)
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

    describe("interaction tree rendering", function()
        it(
            "schedules scrolling when follow mode is enabled during tree render",
            function()
                writer._should_auto_scroll_fn = function()
                    return true
                end

                local long_text = {}
                for i = 1, 50 do
                    long_text[i] = "message line " .. i
                end

                render_session({
                    make_turn({
                        nodes = {
                            make_message_node(table.concat(long_text, "\n")),
                        },
                    }),
                })

                assert.is_true(writer._scroll_scheduled)
                assert.equal(1, #fake_timer.start_calls)
            end
        )

        it(
            "does not schedule scrolling when follow mode is disabled",
            function()
                writer._should_auto_scroll_fn = function()
                    return false
                end

                render_session({
                    make_turn({
                        nodes = {
                            make_message_node("new content\nmore content"),
                        },
                    }),
                })

                assert.is_false(writer._scroll_scheduled)
                assert.equal(0, #fake_timer.start_calls)
            end
        )

        it(
            "renders response nodes under the agent header without a blank gap",
            function()
                render_session({
                    make_turn({
                        request_text = "hi",
                        request_timestamp = os.time({
                            year = 2026,
                            month = 3,
                            day = 25,
                            hour = 23,
                            min = 41,
                            sec = 39,
                        }),
                        nodes = {
                            make_message_node("hi"),
                        },
                    }),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.same({
                    "User · 2026-03-25 23:41:39",
                    "  hi",
                    "",
                    "Agent · Codex ACP",
                    "  hi",
                }, lines)
            end
        )

        it(
            "coalesces adjacent agent text chunks before rendering lines",
            function()
                render_session({
                    make_turn({
                        request_text = "hi",
                        request_timestamp = os.time({
                            year = 2026,
                            month = 3,
                            day = 25,
                            hour = 23,
                            min = 41,
                            sec = 39,
                        }),
                        nodes = {
                            make_chunked_message_node({
                                "This",
                                " is",
                                " strong.",
                                "\nThe",
                                " main",
                                " point is clarity.",
                            }),
                        },
                    }),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.same({
                    "User · 2026-03-25 23:41:39",
                    "  hi",
                    "",
                    "Agent · Codex ACP",
                    "  This is strong.",
                    "  The main point is clarity.",
                }, lines)
            end
        )

        it(
            "marks merged agent chunk joins when debug mode is enabled",
            function()
                Config.debug = true

                render_session({
                    make_turn({
                        request_text = "hi",
                        request_timestamp = os.time({
                            year = 2026,
                            month = 3,
                            day = 25,
                            hour = 23,
                            min = 41,
                            sec = 39,
                        }),
                        nodes = {
                            make_chunked_message_node({
                                "This",
                                " is",
                                " strong.",
                                "\nThe",
                                " main",
                                " point is clarity.",
                            }),
                        },
                    }),
                })

                local ns =
                    vim.api.nvim_get_namespaces().agentic_chunk_boundaries
                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    ns,
                    0,
                    -1,
                    { details = true }
                )

                assert.equal(5, #extmarks)
                assert.is_true(vim.iter(extmarks):any(function(mark)
                    return mark[2] == 4
                        and mark[4]
                        and mark[4].hl_group
                            == Theme.HL_GROUPS.CHUNK_BOUNDARY
                end))
                assert.is_true(vim.iter(extmarks):any(function(mark)
                    return mark[2] == 5
                        and mark[4]
                        and mark[4].hl_group
                            == Theme.HL_GROUPS.CHUNK_BOUNDARY
                end))
            end
        )

        it(
            "applies transcript meta highlights to both user and agent headers",
            function()
                render_session({
                    make_turn({
                        request_text = "hi",
                        request_timestamp = os.time({
                            year = 2026,
                            month = 3,
                            day = 25,
                            hour = 23,
                            min = 41,
                            sec = 39,
                        }),
                        nodes = {
                            make_message_node("hi"),
                        },
                    }),
                })

                local ns = vim.api.nvim_get_namespaces().agentic_transcript_meta
                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    ns,
                    0,
                    -1,
                    { details = true }
                )

                assert.is_true(vim.iter(extmarks):any(function(mark)
                    return mark[2] == 0
                        and mark[4]
                        and mark[4].hl_group == Theme.HL_GROUPS.TRANSCRIPT_REQUEST_META
                        and mark[4].end_col == #"User · "
                end))

                assert.is_true(vim.iter(extmarks):any(function(mark)
                    return mark[2] == 3
                        and mark[4]
                        and mark[4].hl_group == Theme.HL_GROUPS.TRANSCRIPT_RESPONSE_META
                        and mark[4].end_col == #"Agent · "
                end))
            end
        )

        it(
            "renders thought nodes as separate children of the same response",
            function()
                render_session({
                    make_turn({
                        request_timestamp = os.time({
                            year = 2026,
                            month = 3,
                            day = 26,
                            hour = 10,
                            min = 58,
                            sec = 30,
                        }),
                        nodes = {
                            make_message_node("Working on it."),
                            make_thought_node("Checking the file"),
                            make_message_node("Done."),
                        },
                    }),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                assert.same({
                    "User · 2026-03-26 10:58:30",
                    "",
                    "Agent · Codex ACP",
                    "  Working on it.",
                    "",
                    "  Checking the file",
                    "",
                    "  Done.",
                }, lines)
            end
        )

        it("renders tool cards as children of the agent response", function()
            render_session({
                make_turn({
                    nodes = {
                        make_message_node("I am checking the queue."),
                        make_tool_node({
                            tool_call_id = "agent-child-tool",
                            kind = "read",
                            title = "Read lua/agentic/session/persisted_session.lua",
                            file_path = "lua/agentic/session/persisted_session.lua",
                            body_lines = {
                                'local Config = require("agentic.config")',
                                'local Logger = require("agentic.utils.logger")',
                            },
                        }),
                    },
                }),
            })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            assert.is_true(vim.tbl_contains(lines, "Agent · Codex ACP"))
            assert.is_true(
                vim.tbl_contains(lines, "  I am checking the queue.")
            )
            assert.is_true(
                vim.tbl_contains(
                    lines,
                    "  ▸ Read lua/agentic/session/persisted_session.lua"
                )
            )
            assert.is_true(
                vim.tbl_contains(lines, "    2 lines loaded into context")
            )
        end)

        it(
            "renders request content semantically from ACP content blocks",
            function()
                render_session({
                    make_turn({
                        request_text = "Explain this file.",
                        request_timestamp = os.time({
                            year = 2026,
                            month = 3,
                            day = 26,
                            hour = 11,
                            min = 14,
                            sec = 0,
                        }),
                        request_content = {
                            { type = "text", text = "Explain this file." },
                            {
                                type = "resource_link",
                                uri = "file:///tmp/persisted_session.lua",
                                name = "persisted_session.lua",
                            },
                        },
                        nodes = {
                            make_message_node("I am reading it now."),
                        },
                    }),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                assert.is_true(vim.tbl_contains(lines, "  Explain this file."))
                assert.is_true(vim.tbl_contains(lines, "  ▸ resource_link"))
                assert.is_true(
                    vim.tbl_contains(lines, "    persisted_session.lua")
                )
                assert.is_false(
                    vim.tbl_contains(
                        lines,
                        "    uri: file:///tmp/persisted_session.lua"
                    )
                )

                local line_index = find_line_index(lines, "  ▸ resource_link")
                assert.is_true(line_index >= 0)
                assert.is_true(writer:toggle_tool_block_at_line(line_index))

                local expanded_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.is_true(
                    vim.tbl_contains(
                        expanded_lines,
                        "    uri: file:///tmp/persisted_session.lua"
                    )
                )
                assert.is_true(
                    vim.tbl_contains(
                        expanded_lines,
                        "    name: persisted_session.lua"
                    )
                )
            end
        )

        it(
            "collapses auxiliary plain text request blocks by ACP type",
            function()
                render_session({
                    make_turn({
                        request_text = "Review this change.",
                        request_timestamp = os.time({
                            year = 2026,
                            month = 3,
                            day = 26,
                            hour = 11,
                            min = 14,
                            sec = 0,
                        }),
                        request_content = {
                            { type = "text", text = "Review this change." },
                            {
                                type = "text",
                                text = table.concat({
                                    "Follow repo conventions.",
                                    "Keep diffs small.",
                                }, "\n"),
                            },
                        },
                    }),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                assert.is_true(vim.tbl_contains(lines, "  Review this change."))
                assert.is_true(vim.tbl_contains(lines, "  ▸ text"))
                assert.is_true(
                    vim.tbl_contains(
                        lines,
                        "    Follow repo conventions. Keep diffs small. · 2 lines"
                    )
                )
                assert.is_false(
                    vim.tbl_contains(lines, "    Follow repo conventions.")
                )

                local line_index = find_line_index(lines, "  ▸ text")
                assert.is_true(line_index >= 0)
                assert.is_true(writer:toggle_tool_block_at_line(line_index))

                local expanded_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.is_true(
                    vim.tbl_contains(
                        expanded_lines,
                        "    Follow repo conventions."
                    )
                )
                assert.is_true(
                    vim.tbl_contains(expanded_lines, "    Keep diffs small.")
                )
            end
        )

        it("marks XML-like request text as structured text", function()
            render_session({
                make_turn({
                    request_text = "Explain this selection.",
                    request_timestamp = os.time({
                        year = 2026,
                        month = 3,
                        day = 26,
                        hour = 11,
                        min = 14,
                        sec = 0,
                    }),
                    request_content = {
                        { type = "text", text = "Explain this selection." },
                        {
                            type = "text",
                            text = table.concat({
                                "<selected_code>",
                                "<path>/tmp/test.lua</path>",
                                "<snippet>",
                                "print('hi')",
                                "</snippet>",
                                "</selected_code>",
                            }, "\n"),
                        },
                    },
                }),
            })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            assert.is_true(vim.tbl_contains(lines, "  ▸ text"))
            assert.is_true(
                vim.tbl_contains(
                    lines,
                    "    structured text · selected_code · 6 lines"
                )
            )
            assert.is_false(vim.tbl_contains(lines, "    <selected_code>"))

            local line_index = find_line_index(lines, "  ▸ text")
            assert.is_true(line_index >= 0)
            assert.is_true(writer:toggle_tool_block_at_line(line_index))

            local expanded_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(expanded_lines, "    <selected_code>")
            )
        end)

        it("renders environment info as attached embedded context", function()
            render_session({
                make_turn({
                    request_text = "What should I know before editing?",
                    request_timestamp = os.time({
                        year = 2026,
                        month = 3,
                        day = 26,
                        hour = 11,
                        min = 14,
                        sec = 0,
                    }),
                    request_content = {
                        {
                            type = "text",
                            text = "What should I know before editing?",
                        },
                        {
                            type = "resource",
                            resource = {
                                uri = "agentic://environment_info",
                                text = table.concat({
                                    "- Platform: test-os",
                                    "- Project root: /tmp/project",
                                }, "\n"),
                                mimeType = "text/plain",
                            },
                        },
                    },
                    nodes = {
                        make_message_node("I will use the attached context."),
                    },
                }),
            })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            assert.is_true(vim.tbl_contains(lines, "  ▸ resource"))
            assert.is_true(
                vim.tbl_contains(
                    lines,
                    "    environment_info · 2 lines · text/plain"
                )
            )
            assert.is_false(vim.tbl_contains(lines, "  - Platform: test-os"))

            local line_index = find_line_index(lines, "  ▸ resource")
            assert.is_true(line_index >= 0)
            assert.is_true(writer:toggle_tool_block_at_line(line_index))

            local expanded_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(
                    expanded_lines,
                    "    uri: agentic://environment_info"
                )
            )
            assert.is_true(
                vim.tbl_contains(expanded_lines, "      - Platform: test-os")
            )
        end)

        it(
            "renders tool content semantically from ACP content blocks",
            function()
                render_session({
                    make_turn({
                        nodes = {
                            make_tool_node({
                                tool_call_id = "resource-link-tool",
                                kind = "search",
                                title = "Search chat history",
                                status = "completed",
                                content_nodes = {
                                    {
                                        type = "content_output",
                                        content_node = {
                                            type = "resource_link_content",
                                            uri = "file:///tmp/persisted_session.lua",
                                            name = "persisted_session.lua",
                                            content = {
                                                type = "resource_link",
                                                uri = "file:///tmp/persisted_session.lua",
                                                name = "persisted_session.lua",
                                            },
                                        },
                                    },
                                },
                            }),
                        },
                    }),
                })

                local collapsed_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.is_true(
                    vim.tbl_contains(collapsed_lines, "    1 linked resource")
                )

                local tracker = writer.tool_call_blocks["resource-link-tool"]
                local tool_ns =
                    vim.api.nvim_get_namespaces().agentic_tool_blocks
                local pos = vim.api.nvim_buf_get_extmark_by_id(
                    bufnr,
                    tool_ns,
                    tracker.extmark_id,
                    { details = true }
                )

                assert.is_true(writer:toggle_tool_block_at_line(pos[1]))

                local expanded_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.is_true(
                    vim.tbl_contains(
                        expanded_lines,
                        "    @persisted_session.lua"
                    )
                )
            end
        )

        it(
            "coalesces adjacent text chunks inside tool content output",
            function()
                render_session({
                    make_turn({
                        nodes = {
                            make_tool_node({
                                tool_call_id = "chunked-tool-output",
                                kind = "search",
                                title = "Search log",
                                status = "completed",
                                content_nodes = {
                                    {
                                        type = "content_output",
                                        content_node = make_text_content_node(
                                            "match"
                                        ),
                                    },
                                    {
                                        type = "content_output",
                                        content_node = make_text_content_node(
                                            " found\nsecond result"
                                        ),
                                    },
                                },
                            }),
                        },
                    }),
                })

                local collapsed_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.is_true(
                    vim.tbl_contains(collapsed_lines, "    2 result lines")
                )
                assert.is_false(vim.tbl_contains(collapsed_lines, "    match"))

                local tracker = writer.tool_call_blocks["chunked-tool-output"]
                local tool_ns =
                    vim.api.nvim_get_namespaces().agentic_tool_blocks
                local pos = vim.api.nvim_buf_get_extmark_by_id(
                    bufnr,
                    tool_ns,
                    tracker.extmark_id,
                    { details = true }
                )

                assert.is_true(writer:toggle_tool_block_at_line(pos[1]))

                local expanded_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.is_true(
                    vim.tbl_contains(expanded_lines, "    match found")
                )
                assert.is_true(
                    vim.tbl_contains(expanded_lines, "    second result")
                )
                assert.is_false(vim.tbl_contains(expanded_lines, "    match"))
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
            "fires listeners when interaction-tree content is rendered",
            function()
                local callback_spy = spy.new(function() end)
                writer:add_content_changed_listener(
                    callback_spy --[[@as function]]
                )

                render_session({
                    make_turn({
                        nodes = {
                            make_message_node("hello"),
                            make_tool_node({
                                tool_call_id = "cb-1",
                                kind = "execute",
                                title = "rg -n queue lua/agentic",
                                body_lines = {
                                    "lua/agentic/ui/queue_list.lua:45",
                                },
                            }),
                        },
                    }),
                })

                assert.spy(callback_spy).was.called(1)
            end
        )

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
                collapsed = false,
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
                if line == "      + inserted" then
                    found_inserted = true
                    break
                end
            end
            assert.is_true(found_inserted)
            assert.is_true(
                vim.tbl_contains(lines, "    @@ insert near line 2 @@")
            )

            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new"
            end, highlight_ranges)
            assert.is_true(#new_ranges > 0)
            assert.equal("inserted", new_ranges[1].new_line)
            assert.equal(8, new_ranges[1].display_prefix_len)
        end)

        it("renders read cards as folded context summaries", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "read-summary",
                status = "completed",
                kind = "read",
                collapsed = true,
                argument = "Read lua/agentic/session/persisted_session.lua",
                file_path = "lua/agentic/session/persisted_session.lua",
                body = {
                    'local Config = require("agentic.config")',
                    'local Logger = require("agentic.utils.logger")',
                    'local FileSystem = require("agentic.utils.file_system")',
                },
            }

            local lines = writer:_prepare_block_lines(block)

            assert.is_true(
                vim.tbl_contains(
                    lines,
                    "  ▸ Read lua/agentic/session/persisted_session.lua"
                )
            )
            assert.is_true(
                vim.tbl_contains(lines, "    3 lines loaded into context")
            )
            assert.is_true(
                vim.tbl_contains(lines, "    Details hidden · <CR> expand")
            )
            assert.is_false(
                vim.tbl_contains(
                    lines,
                    '    local Config = require("agentic.config")'
                )
            )
            assert.is_false(vim.tbl_contains(lines, block.body[3]))
        end)

        it("renders execute cards as folded summary-first cards", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "execute-summary",
                status = "completed",
                kind = "execute",
                collapsed = true,
                argument = "rg -n queue lua/agentic",
                body = {
                    "lua/agentic/ui/queue_list.lua:45:Queued messages",
                    "lua/agentic/session_manager.lua:643:Queue: 3",
                    "lua/agentic/ui/window_decoration.lua:35:Queue",
                },
            }

            local lines = writer:_prepare_block_lines(block)

            assert.is_true(
                vim.tbl_contains(lines, "  ▸ Run rg -n queue lua/agentic")
            )
            assert.is_true(vim.tbl_contains(lines, "    3 output lines"))
            assert.is_true(
                vim.tbl_contains(lines, "    Details hidden · <CR> expand")
            )
            assert.is_false(
                vim.tbl_contains(
                    lines,
                    "    lua/agentic/ui/queue_list.lua:45:Queued messages"
                )
            )
            assert.is_false(
                vim.tbl_contains(
                    lines,
                    "lua/agentic/ui/window_decoration.lua:35:Queue"
                )
            )

            local expand_prompts = vim.tbl_filter(function(line)
                return line:find("<CR> expand", 1, true) ~= nil
            end, lines)
            assert.equal(1, #expand_prompts)
        end)

        it(
            "normalizes wrapped execute titles into action-first headers",
            function()
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "execute-normalized",
                    status = "completed",
                    kind = "execute",
                    collapsed = true,
                    argument = "execute(ls -la)",
                    body = { "file-a", "file-b" },
                }

                local lines = writer:_prepare_block_lines(block)

                assert.is_true(vim.tbl_contains(lines, "  ▸ Run ls -la"))
            end
        )

        it(
            "renders failed tool status inline instead of as overlay chrome",
            function()
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "execute-failed",
                    status = "failed",
                    kind = "execute",
                    collapsed = true,
                    argument = "rg -n queue lua/agentic",
                    body = {
                        "ripgrep: README.md: IO error",
                    },
                }

                local lines = writer:_prepare_block_lines(block)

                assert.is_true(
                    vim.tbl_contains(lines, "  ▸ Run rg -n queue lua/agentic")
                )
                assert.is_true(vim.tbl_contains(lines, "    1 error line"))
                assert.is_true(vim.tbl_contains(lines, "    failed"))
            end
        )

        it("renders modifications as explicit old/new line pairs", function()
            Config.diff_preview.enabled = false
            read_stub:returns({ "old value" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-mod",
                status = "pending",
                kind = "edit",
                collapsed = false,
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "old value" },
                    new = { "new value" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local old_line_index = vim.fn.index(lines, "      - old value")
            local new_line_index = vim.fn.index(lines, "      + new value")

            assert.is_true(vim.tbl_contains(lines, "    @@ line 1 @@"))
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
            assert.equal(8, old_ranges[1].display_prefix_len)
            assert.equal(8, new_ranges[1].display_prefix_len)
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
                local title_index =
                    vim.fn.index(lines, "  ▸ Edited /test.lua +6 -6")
                local summary_index =
                    vim.fn.index(lines, "    1 hunk · 6 modified lines")
                local hint_index = vim.fn.index(
                    lines,
                    "    Review in buffer: ]c next, [c prev, m yes, n no · <CR> expand"
                )

                assert.is_true(title_index >= 0)
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

        it(
            "keeps large chat diffs collapsed until the user expands them",
            function()
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
                    tool_call_id = "test-collapsed",
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

                assert.is_true(
                    vim.tbl_contains(lines, "  ▸ Edited /test.lua +6 -6")
                )
                assert.is_true(
                    vim.tbl_contains(lines, "    1 hunk · 6 modified lines")
                )
                assert.is_true(
                    vim.tbl_contains(lines, "    Details hidden · <CR> expand")
                )
                assert.is_false(vim.tbl_contains(lines, "@@ lines 1-6 @@"))
                assert.is_false(vim.tbl_contains(lines, "- a1"))
                assert.is_false(vim.tbl_contains(lines, "+ b1"))

                local expand_prompts = vim.tbl_filter(function(line)
                    return line:find("<CR> expand", 1, true) ~= nil
                end, lines)
                assert.equal(1, #expand_prompts)
            end
        )

        it("shows a compact sample once a diff card is expanded", function()
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
                collapsed = false,
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "a1", "a2", "a3", "a4", "a5", "a6" },
                    new = { "b1", "b2", "b3", "b4", "b5", "b6" },
                },
            }

            local lines = writer:_prepare_block_lines(block)
            local title_index =
                vim.fn.index(lines, "  ▾ Edited /test.lua +6 -6")
            local summary_index =
                vim.fn.index(lines, "    1 hunk · 6 modified lines")
            local hunk_index = vim.fn.index(lines, "    @@ lines 1-6 @@")

            assert.is_true(title_index >= 0)
            assert.is_true(summary_index >= 0)
            assert.is_true(hunk_index > summary_index)
            assert.is_true(
                vim.tbl_contains(
                    lines,
                    "    ... 2 more changes in buffer review"
                )
            )
            assert.is_true(vim.tbl_contains(lines, "      - a4"))
            assert.is_true(vim.tbl_contains(lines, "      + b4"))
            assert.is_false(vim.tbl_contains(lines, "      - a5"))
            assert.is_false(vim.tbl_contains(lines, "      + b5"))
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
                collapsed = false,
                argument = "/test.lua",
                file_path = "/test.lua",
                diff = {
                    old = { "a1", "keep1", "a2", "keep2", "a3", "keep3" },
                    new = { "b1", "keep1", "b2", "keep2", "b3", "keep3" },
                },
            }

            local lines = writer:_prepare_block_lines(block)

            assert.is_true(
                vim.tbl_contains(lines, "    3 hunks · 3 modified lines")
            )
            assert.is_true(vim.tbl_contains(lines, "    @@ line 1 @@"))
            assert.is_true(vim.tbl_contains(lines, "    @@ line 3 @@"))
            assert.is_false(vim.tbl_contains(lines, "    @@ line 5 @@"))
            assert.is_true(
                vim.tbl_contains(
                    lines,
                    "    ... 1 more change in buffer review"
                )
            )
        end)

        it("toggles diff details from collapsed to expanded", function()
            Config.diff_preview.enabled = false
            read_stub:returns({ "old value" })

            render_session({
                make_turn({
                    nodes = {
                        make_tool_node({
                            tool_call_id = "toggle-diff",
                            status = "pending",
                            kind = "edit",
                            title = "/test.lua",
                            file_path = "/test.lua",
                            content_nodes = {
                                {
                                    type = "diff_output",
                                    file_path = "/test.lua",
                                    old_lines = { "old value" },
                                    new_lines = { "new value" },
                                },
                            },
                        }),
                    },
                }),
            })

            local collapsed_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(
                    collapsed_lines,
                    "  ▸ Edited /test.lua +1 -1"
                )
            )
            assert.is_false(
                vim.tbl_contains(collapsed_lines, "      - old value")
            )

            local tracker = writer.tool_call_blocks["toggle-diff"]
            local tool_ns = vim.api.nvim_get_namespaces().agentic_tool_blocks
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                tool_ns,
                tracker.extmark_id,
                { details = true }
            )

            assert.is_true(writer:toggle_tool_block_at_line(pos[1]))

            local expanded_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(expanded_lines, "  ▾ Edited /test.lua +1 -1")
            )
            assert.is_true(
                vim.tbl_contains(expanded_lines, "      - old value")
            )
            assert.is_true(
                vim.tbl_contains(expanded_lines, "      + new value")
            )
        end)

        it("toggles execute previews from collapsed to expanded", function()
            render_session({
                make_turn({
                    nodes = {
                        make_tool_node({
                            tool_call_id = "toggle-execute",
                            kind = "execute",
                            title = "rg -n queue lua/agentic",
                            body_lines = {
                                "lua/agentic/ui/queue_list.lua:45:Queued messages",
                                "lua/agentic/session_manager.lua:643:Queue: 3",
                                "lua/agentic/ui/window_decoration.lua:35:Queue",
                            },
                        }),
                    },
                }),
            })

            local collapsed_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(
                    collapsed_lines,
                    "  ▸ Run rg -n queue lua/agentic"
                )
            )
            assert.is_false(
                vim.tbl_contains(
                    collapsed_lines,
                    "    lua/agentic/ui/queue_list.lua:45:Queued messages"
                )
            )
            assert.is_false(
                vim.tbl_contains(
                    collapsed_lines,
                    "lua/agentic/ui/window_decoration.lua:35:Queue"
                )
            )

            local tracker = writer.tool_call_blocks["toggle-execute"]
            local tool_ns = vim.api.nvim_get_namespaces().agentic_tool_blocks
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                tool_ns,
                tracker.extmark_id,
                { details = true }
            )

            assert.is_true(writer:toggle_tool_block_at_line(pos[1]))

            local expanded_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(
                    expanded_lines,
                    "  ▾ Run rg -n queue lua/agentic"
                )
            )
            assert.is_true(
                vim.tbl_contains(
                    expanded_lines,
                    "    lua/agentic/ui/window_decoration.lua:35:Queue"
                )
            )
            assert.is_true(
                vim.tbl_contains(expanded_lines, "    <CR> collapse")
            )
        end)

        it(
            "truncates collapsed execute titles with a right-side ellipsis",
            function()
                vim.api.nvim_win_set_width(winid, 44)

                render_session({
                    make_turn({
                        nodes = {
                            make_tool_node({
                                tool_call_id = "truncate-execute",
                                kind = "execute",
                                title = "git diff -- lua/agentic/ui/chat_widget.lua && printf '\\n__ CURRENT_CHAT_WIDGET __\\n' && sed -n '1,260p' lua/agentic/ui/chat_widget.lua",
                                body_lines = {
                                    "first line",
                                    "second line",
                                },
                            }),
                        },
                    }),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local title_line = nil
                for _, line in ipairs(lines) do
                    if vim.startswith(line, "  ▸ Run git diff") then
                        title_line = line
                        break
                    end
                end

                assert.is_not_nil(title_line)
                assert.equal("...", title_line:sub(-3))
                assert.is_true(
                    vim.fn.strdisplaywidth(title_line)
                        <= vim.api.nvim_win_get_width(winid) - 1
                )
                assert.is_false(
                    title_line:find("sed %-n '1,260p'", 1, false) ~= nil
                )
            end
        )

        it("toggles read previews from collapsed to expanded", function()
            render_session({
                make_turn({
                    nodes = {
                        make_tool_node({
                            tool_call_id = "toggle-read",
                            kind = "read",
                            title = "Read lua/agentic/session/persisted_session.lua",
                            file_path = "lua/agentic/session/persisted_session.lua",
                            body_lines = {
                                'local Config = require("agentic.config")',
                                'local Logger = require("agentic.utils.logger")',
                                'local FileSystem = require("agentic.utils.file_system")',
                            },
                        }),
                    },
                }),
            })

            local collapsed_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(
                    collapsed_lines,
                    "  ▸ Read lua/agentic/session/persisted_session.lua"
                )
            )
            assert.is_false(
                vim.tbl_contains(
                    collapsed_lines,
                    '    local Config = require("agentic.config")'
                )
            )
            assert.is_false(
                vim.tbl_contains(
                    collapsed_lines,
                    '    local FileSystem = require("agentic.utils.file_system")'
                )
            )

            local tracker = writer.tool_call_blocks["toggle-read"]
            local tool_ns = vim.api.nvim_get_namespaces().agentic_tool_blocks
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                tool_ns,
                tracker.extmark_id,
                { details = true }
            )

            assert.is_true(writer:toggle_tool_block_at_line(pos[1]))

            local expanded_lines =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(
                vim.tbl_contains(
                    expanded_lines,
                    "  ▾ Read lua/agentic/session/persisted_session.lua"
                )
            )
            assert.is_true(
                vim.tbl_contains(
                    expanded_lines,
                    '    local FileSystem = require("agentic.utils.file_system")'
                )
            )
            assert.is_true(
                vim.tbl_contains(expanded_lines, "    <CR> collapse")
            )
        end)

        it(
            "renders only one expand affordance for collapsed read cards",
            function()
                local block = {
                    tool_call_id = "single-read-expand",
                    status = "completed",
                    kind = "read",
                    collapsed = true,
                    argument = "Read lua/agentic/session/persisted_session.lua",
                    file_path = "lua/agentic/session/persisted_session.lua",
                    body = {
                        'local Config = require("agentic.config")',
                        'local Logger = require("agentic.utils.logger")',
                        'local FileSystem = require("agentic.utils.file_system")',
                    },
                }

                local lines = writer:_prepare_block_lines(block)
                local expand_prompts = vim.tbl_filter(function(line)
                    return line:find("<CR> expand", 1, true) ~= nil
                end, lines)

                assert.equal(1, #expand_prompts)
            end
        )

        it(
            "groups multiple diff edits for the same file within one turn",
            function()
                Config.diff_preview.enabled = false
                read_stub:returns({ "keep1", "keep2", "keep3", "keep4" })

                local turns = {
                    make_turn({
                        nodes = {
                            make_tool_node({
                                tool_call_id = "edit-1",
                                kind = "edit",
                                status = "completed",
                                title = "/test.lua",
                                file_path = "/test.lua",
                                content_nodes = {
                                    {
                                        type = "diff_output",
                                        file_path = "/test.lua",
                                        old_lines = {
                                            "keep1",
                                            "old one",
                                            "keep2",
                                            "keep3",
                                            "keep4",
                                        },
                                        new_lines = {
                                            "keep1",
                                            "new one",
                                            "keep2",
                                            "keep3",
                                            "keep4",
                                        },
                                    },
                                },
                            }),
                            make_tool_node({
                                tool_call_id = "edit-2",
                                kind = "edit",
                                status = "completed",
                                title = "/test.lua",
                                file_path = "/test.lua",
                                content_nodes = {
                                    {
                                        type = "diff_output",
                                        file_path = "/test.lua",
                                        old_lines = {
                                            "keep1",
                                            "new one",
                                            "keep2",
                                            "keep3",
                                            "old two",
                                            "keep4",
                                        },
                                        new_lines = {
                                            "keep1",
                                            "new one",
                                            "keep2",
                                            "keep3",
                                            "new two",
                                            "keep4",
                                        },
                                    },
                                },
                            }),
                        },
                    }),
                }

                render_session(turns)
                writer.tool_call_blocks["edit-1"].collapsed = false
                render_session(turns)

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                assert.equal(
                    writer.tool_call_blocks["edit-1"],
                    writer.tool_call_blocks["edit-2"]
                )
                assert.equal(
                    1,
                    vim.tbl_count(vim.tbl_filter(function(line)
                        return line == "  ▾ Edited /test.lua +2 -2"
                    end, lines))
                )
                assert.is_true(
                    vim.tbl_contains(
                        lines,
                        "    2 edits · 2 hunks · 2 modified lines"
                    )
                )
                assert.is_true(vim.tbl_contains(lines, "    @@ line 2 @@"))
                assert.is_true(vim.tbl_contains(lines, "    @@ line 5 @@"))
            end
        )

        it(
            "starts a new file card for the same file in a later turn",
            function()
                Config.diff_preview.enabled = false
                read_stub:returns({ "old value" })

                render_session({
                    make_turn({
                        index = 1,
                        nodes = {
                            make_tool_node({
                                tool_call_id = "turn-one",
                                kind = "edit",
                                status = "completed",
                                title = "/test.lua",
                                file_path = "/test.lua",
                                content_nodes = {
                                    {
                                        type = "diff_output",
                                        file_path = "/test.lua",
                                        old_lines = { "old value" },
                                        new_lines = { "new value" },
                                    },
                                },
                            }),
                        },
                    }),
                    make_turn({
                        index = 2,
                        nodes = {
                            make_tool_node({
                                tool_call_id = "turn-two",
                                kind = "edit",
                                status = "completed",
                                title = "/test.lua",
                                file_path = "/test.lua",
                                content_nodes = {
                                    {
                                        type = "diff_output",
                                        file_path = "/test.lua",
                                        old_lines = { "new value" },
                                        new_lines = { "newest value" },
                                    },
                                },
                            }),
                        },
                    }),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                assert.is_true(
                    writer.tool_call_blocks["turn-one"]
                        ~= writer.tool_call_blocks["turn-two"]
                )
                assert.equal(
                    2,
                    vim.tbl_count(vim.tbl_filter(function(line)
                        return line == "  ▸ Edited /test.lua +1 -1"
                    end, lines))
                )
            end
        )
    end)
end)
