local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local Theme = require("agentic.theme")
local InlineChat = require("agentic.ui.inline_chat")

describe("agentic.ui.InlineChat", function()
    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.UserConfig.Inline
    local saved_inline_config

    --- @param predicate fun(): boolean
    local function wait_for(predicate)
        assert.is_true(vim.wait(200, predicate))
    end

    local function extmark_lines(extmark)
        local details = extmark[4] or {}
        local virt_lines = details.virt_lines or {}
        local lines = {}

        for _, virt_line in ipairs(virt_lines) do
            local text = ""
            for _, segment in ipairs(virt_line) do
                text = text .. segment[1]
            end
            lines[#lines + 1] = text
        end

        return lines
    end

    local function get_overlay_extmarks()
        return vim.api.nvim_buf_get_extmarks(
            bufnr,
            InlineChat.NS_INLINE,
            0,
            -1,
            { details = true }
        )
    end

    local function get_rendered_lines()
        local extmark = get_overlay_extmarks()[1]
        return extmark and extmark_lines(extmark) or {}
    end

    local function get_rendered_overlays()
        local overlays = {}

        for _, extmark in ipairs(get_overlay_extmarks()) do
            overlays[#overlays + 1] = {
                id = extmark[1],
                row = extmark[2],
                lines = extmark_lines(extmark),
            }
        end

        return overlays
    end

    local function get_thread_extmarks()
        return vim.api.nvim_buf_get_extmarks(
            bufnr,
            InlineChat.NS_INLINE_THREADS,
            0,
            -1,
            { details = true }
        )
    end

    local function get_thread_store()
        return vim.b[bufnr][InlineChat.THREAD_STORE_KEY] or {}
    end

    before_each(function()
        bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(
            bufnr,
            vim.fn.tempname() .. "/inline_chat_test.lua"
        )
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "local value = 1",
            "return value",
        })
        winid = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(winid, bufnr)

        saved_inline_config = vim.deepcopy(Config.inline)
        Config.inline.progress = false
        Config.inline.result_ttl_ms = 0
        Config.inline.max_thought_lines = 4
        Config.inline.show_thoughts = true
    end)

    after_each(function()
        Config.inline = saved_inline_config

        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("renders thought chunks in the source buffer", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
            get_config_context = function()
                return "Mode: Code"
            end,
        })

        inline:begin_request({
            prompt = "Refactor this",
            selection = {
                lines = { "local value = 1", "return value" },
                start_line = 1,
                end_line = 2,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
            phase = "thinking",
            status_text = "Preparing inline request",
        })

        inline:handle_session_update({
            sessionUpdate = "agent_thought_chunk",
            content = {
                type = "text",
                text = "Inspecting the selected lines\nChoosing accept/reject wording",
            },
        })

        local lines = get_rendered_lines()
        assert.truthy(
            vim.tbl_contains(
                lines,
                "  Thinking: Choosing accept/reject wording"
            )
        )
        assert.is_false(
            vim.tbl_contains(lines, "  Inspecting the selected lines")
        )
        assert.is_false(vim.tbl_contains(lines, "Config: Mode: Code"))

        local thread_extmarks = get_thread_extmarks()
        assert.equal(1, #thread_extmarks)

        local thread = get_thread_store()[tostring(thread_extmarks[1][1])]
        assert.is_not_nil(thread)
        assert.equal("Refactor this", thread.turns[1].prompt)
        assert.equal("Thinking", thread.turns[1].status_text)
        assert.equal(
            "Inspecting the selected lines\nChoosing accept/reject wording",
            thread.turns[1].thought_text
        )

        local overlay_extmark = get_overlay_extmarks()[1]
        local first_segment = overlay_extmark[4].virt_lines[1][1]
        assert.same({
            Theme.HL_GROUPS.REVIEW_BANNER,
            Theme.HL_GROUPS.INLINE_FADE,
        }, first_segment[2])
        local second_segment = overlay_extmark[4].virt_lines[1][2]
        assert.same({
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.INLINE_FADE,
        }, second_segment[2])
    end)

    it("shows only the latest response line while generating", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:begin_request({
            prompt = "Change this",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        inline:handle_session_update({
            sessionUpdate = "agent_message_chunk",
            content = {
                type = "text",
                text = "First draft line\nLatest answer line",
            },
        })

        local lines = get_rendered_lines()
        assert.truthy(vim.tbl_contains(lines, "  Response: Latest answer line"))
        assert.is_false(vim.tbl_contains(lines, "  Response: First draft line"))
    end)

    it("restores focus to the source window after submitting", function()
        local on_submit_spy = spy.new(function()
            return true
        end)
        local set_current_win_spy = spy.on(vim.api, "nvim_set_current_win")

        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = on_submit_spy --[[@as function]],
        })

        inline:open({
            lines = { "local value = 1" },
            start_line = 1,
            end_line = 1,
            file_path = "/tmp/inline_chat_test.lua",
            file_type = "lua",
        })

        --- @diagnostic disable-next-line: invisible
        local prompt = inline._prompt
        assert.is_not_nil(prompt)
        --- @cast prompt agentic.ui.InlineChat.PromptState
        vim.api.nvim_buf_set_lines(
            prompt.prompt_bufnr,
            0,
            -1,
            false,
            { "Refactor this line" }
        )

        --- @diagnostic disable-next-line: invisible
        inline:_submit_prompt()

        assert.spy(on_submit_spy).was.called(1)
        assert.spy(set_current_win_spy).was.called(1)
        assert.equal(winid, set_current_win_spy.calls[1][1])

        set_current_win_spy:revert()
    end)

    it("closes the prompt and restores focus without submitting", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:open({
            lines = { "local value = 1" },
            start_line = 1,
            end_line = 1,
            file_path = "/tmp/inline_chat_test.lua",
            file_type = "lua",
        })

        --- @diagnostic disable-next-line: invisible
        local prompt = inline._prompt
        assert.is_not_nil(prompt)
        --- @cast prompt agentic.ui.InlineChat.PromptState

        vim.api.nvim_set_current_win(prompt.prompt_winid)
        --- @diagnostic disable-next-line: invisible
        inline:_close_prompt(true)

        assert.is_false(vim.api.nvim_win_is_valid(prompt.prompt_winid))
        assert.equal(winid, vim.api.nvim_get_current_win())
        assert.is_false(inline:is_prompt_open())
    end)

    it("returns to normal mode after submitting with <CR>", function()
        local on_submit_spy = spy.new(function()
            return true
        end)

        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = on_submit_spy --[[@as function]],
        })

        inline:open({
            lines = { "local value = 1" },
            start_line = 1,
            end_line = 1,
            file_path = "/tmp/inline_chat_test.lua",
            file_type = "lua",
        })

        --- @diagnostic disable-next-line: invisible
        local prompt = inline._prompt
        assert.is_not_nil(prompt)
        --- @cast prompt agentic.ui.InlineChat.PromptState
        vim.api.nvim_buf_set_lines(
            prompt.prompt_bufnr,
            0,
            -1,
            false,
            { "Refactor this line" }
        )
        vim.api.nvim_set_current_win(prompt.prompt_winid)

        local entered_insert = vim.wait(200, function()
            return vim.fn.mode():sub(1, 1) == "i"
        end)
        assert.is_true(entered_insert)

        local mapping = vim.fn.maparg("<CR>", "i", false, true)
        mapping.callback()

        local exited_insert = vim.wait(200, function()
            return vim.fn.mode():sub(1, 1) ~= "i"
        end)

        assert.spy(on_submit_spy).was.called(1)
        assert.is_true(exited_insert)
        assert.are_not.equal("i", vim.fn.mode():sub(1, 1))
        assert.equal(winid, vim.api.nvim_get_current_win())
    end)

    it("grows the inline prompt height when the text wraps", function()
        Config.inline.prompt_width = 24
        Config.inline.prompt_height = 1

        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:open({
            lines = { "local value = 1" },
            start_line = 1,
            end_line = 1,
            file_path = "/tmp/inline_chat_test.lua",
            file_type = "lua",
        })

        --- @diagnostic disable-next-line: invisible
        local prompt = inline._prompt
        assert.is_not_nil(prompt)
        --- @cast prompt agentic.ui.InlineChat.PromptState
        assert.equal(1, vim.api.nvim_win_get_height(prompt.prompt_winid))

        vim.api.nvim_set_current_win(prompt.prompt_winid)
        vim.api.nvim_buf_set_lines(
            prompt.prompt_bufnr,
            0,
            -1,
            false,
            { "This inline prompt should wrap across more than one row." }
        )

        vim.cmd("doautocmd <nomodeline> TextChangedI")

        wait_for(function()
            return vim.api.nvim_win_get_height(prompt.prompt_winid) > 1
        end)
    end)

    it("normalizes stale columns before submitting the prompt", function()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "short" })

        local on_submit_spy = spy.new(function()
            return true
        end)

        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = on_submit_spy --[[@as function]],
        })

        inline:open({
            lines = { "short" },
            start_line = 1,
            end_line = 1,
            start_col = 7,
            end_col = 11,
            file_path = "/tmp/inline_chat_test.lua",
            file_type = "lua",
        })

        --- @diagnostic disable-next-line: invisible
        local prompt = inline._prompt
        assert.is_not_nil(prompt)
        --- @cast prompt agentic.ui.InlineChat.PromptState
        vim.api.nvim_buf_set_lines(
            prompt.prompt_bufnr,
            0,
            -1,
            false,
            { "Refactor this line" }
        )

        --- @diagnostic disable-next-line: invisible
        inline:_submit_prompt()

        assert.spy(on_submit_spy).was.called(1)

        local submitted_request = on_submit_spy.calls[1][1]
        local selection = submitted_request.selection
        assert.equal(5, selection.start_col)
        assert.equal(5, selection.end_col)
    end)

    it("renders the tracked visual range for inline selections", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:begin_request({
            prompt = "Rename this symbol",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                start_col = 7,
                end_col = 11,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        local lines = get_rendered_lines()
        assert.truthy(
            vim.tbl_contains(
                lines,
                "  [Agentic Inline] inline_chat_test.lua:1:7-1:11 Starting inline request"
            )
        )
    end)

    it(
        "clamps stale inline columns before starting a second request",
        function()
            local inline = InlineChat:new({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                on_submit = function()
                    return true
                end,
            })

            --- @type agentic.Selection
            local selection = {
                lines = { "value" },
                start_line = 1,
                end_line = 1,
                start_col = 7,
                end_col = 11,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            }

            inline:begin_request({
                prompt = "First request",
                selection = selection,
                source_bufnr = bufnr,
                source_winid = winid,
            })
            inline:complete({ stopReason = "end_turn" }, nil)

            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "short" })

            assert.has_no_errors(function()
                inline:begin_request({
                    prompt = "Second request",
                    selection = selection,
                    source_bufnr = bufnr,
                    source_winid = winid,
                })
            end)

            local lines = get_rendered_lines()
            assert.truthy(
                vim.tbl_contains(
                    lines,
                    "  [Agentic Inline] inline_chat_test.lua:1:5-1:5 Starting inline request"
                )
            )
        end
    )

    it("renders multiple queued inline requests in the same tabpage", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:queue_request({
            submission_id = 1,
            prompt = "First queued request",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })
        inline:queue_request({
            submission_id = 2,
            prompt = "Second queued request",
            selection = {
                lines = { "return value" },
                start_line = 2,
                end_line = 2,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        inline:sync_queued_requests({
            {
                id = 1,
                input_text = "First queued request",
                prompt = { { type = "text", text = "First queued request" } },
                request = {
                    kind = "user",
                    text = "First queued request",
                    timestamp = 1,
                    content = {
                        { type = "text", text = "First queued request" },
                    },
                },
                inline_request = {},
            },
            {
                id = 2,
                input_text = "Second queued request",
                prompt = { { type = "text", text = "Second queued request" } },
                request = {
                    kind = "user",
                    text = "Second queued request",
                    timestamp = 2,
                    content = {
                        { type = "text", text = "Second queued request" },
                    },
                },
                inline_request = {},
            },
        }, {
            waiting_for_session = true,
        })

        local waiting_texts = vim.tbl_map(function(overlay)
            return table.concat(overlay.lines, "\n")
        end, get_rendered_overlays())
        assert.equal(2, #waiting_texts)
        assert.truthy(vim.iter(waiting_texts):any(function(text)
            return text:match("inline_chat_test%.lua:1%-1 Waiting for session")
        end))
        assert.truthy(vim.iter(waiting_texts):any(function(text)
            return text:match("inline_chat_test%.lua:2%-2 Waiting for session")
        end))

        inline:sync_queued_requests({
            {
                id = 1,
                input_text = "First queued request",
                prompt = { { type = "text", text = "First queued request" } },
                request = {
                    kind = "user",
                    text = "First queued request",
                    timestamp = 1,
                    content = {
                        { type = "text", text = "First queued request" },
                    },
                },
                inline_request = {},
            },
            {
                id = 2,
                input_text = "Second queued request",
                prompt = { { type = "text", text = "Second queued request" } },
                request = {
                    kind = "user",
                    text = "Second queued request",
                    timestamp = 2,
                    content = {
                        { type = "text", text = "Second queued request" },
                    },
                },
                inline_request = {},
            },
        })

        local queued_texts = vim.tbl_map(function(overlay)
            return table.concat(overlay.lines, "\n")
        end, get_rendered_overlays())
        assert.truthy(vim.iter(queued_texts):any(function(text)
            return text:match("inline_chat_test%.lua:1%-1 Queued next")
        end))
        assert.truthy(vim.iter(queued_texts):any(function(text)
            return text:match("inline_chat_test%.lua:2%-2 Queued #2")
        end))
    end)

    it("promotes a queued request without appending a second turn", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:queue_request({
            submission_id = 1,
            prompt = "Queued request",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        local thread_extmark_id = get_thread_extmarks()[1][1]

        inline:begin_request({
            submission_id = 1,
            prompt = "Queued request",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
            phase = "thinking",
            status_text = "Preparing inline request",
        })

        local thread = get_thread_store()[tostring(thread_extmark_id)]
        assert.is_not_nil(thread)
        assert.equal(1, #thread.turns)
        assert.equal("Preparing inline request", thread.turns[1].status_text)
    end)

    it("finds and removes queued requests by overlapping range", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:queue_request({
            submission_id = 1,
            prompt = "Queued request",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                start_col = 7,
                end_col = 12,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        local submission_id = inline:find_overlapping_queued_submission(bufnr, {
            lines = { "value" },
            start_line = 1,
            end_line = 1,
            start_col = 7,
            end_col = 12,
            file_path = "/tmp/inline_chat_test.lua",
            file_type = "lua",
        })
        assert.equal(1, submission_id)
        --- @cast submission_id integer
        assert.is_true(inline:remove_queued_submission(submission_id))
        assert.equal(0, #get_overlay_extmarks())
        assert.equal(0, #get_thread_extmarks())
    end)

    it("updates the status line for tool execution and approval", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:begin_request({
            prompt = "Change this",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        inline:handle_tool_call({
            kind = "edit",
            file_path = "/tmp/inline_chat_test.lua",
            argument = "replace value",
        })
        inline:handle_permission_request()

        local lines = get_rendered_lines()
        assert.truthy(
            vim.tbl_contains(
                lines,
                "  [Agentic Inline] inline_chat_test.lua:1-1 Waiting for approval"
            )
        )
        assert.truthy(vim.tbl_contains(lines, "  Tool: edit replace value"))

        inline:clear()
        local extmarks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            InlineChat.NS_INLINE,
            0,
            -1,
            {}
        )
        assert.equal(0, #extmarks)

        local thread_extmarks = get_thread_extmarks()
        assert.equal(1, #thread_extmarks)
        assert.is_not_nil(get_thread_store()[tostring(thread_extmarks[1][1])])
    end)

    it(
        "hides the ghost preview after an applied edit and keeps progress live",
        function()
            Config.inline.progress = true

            local progress_spy = spy.on(vim.api, "nvim_echo")
            local inline = InlineChat:new({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                on_submit = function()
                    return true
                end,
            })

            inline:begin_request({
                prompt = "Change this",
                selection = {
                    lines = { "local value = 1" },
                    start_line = 1,
                    end_line = 1,
                    file_path = "/tmp/inline_chat_test.lua",
                    file_type = "lua",
                },
                source_bufnr = bufnr,
                source_winid = winid,
            })

            inline:handle_tool_call({
                kind = "edit",
                file_path = "/tmp/inline_chat_test.lua",
                argument = "replace value",
            })
            inline:handle_applied_edit()
            local overlay_count_after_apply = #get_overlay_extmarks()

            inline:refresh()
            local overlay_count_after_refresh = #get_overlay_extmarks()

            inline:handle_session_update({
                sessionUpdate = "agent_message_chunk",
                content = {
                    type = "text",
                    text = "Applied the edit\nWrapping up",
                },
            })
            local overlay_count_after_message = #get_overlay_extmarks()

            local saw_generating_progress = false
            for _, call in ipairs(progress_spy.calls) do
                local chunks = call[1]
                local opts = call[3]
                local message = chunks and chunks[1] and chunks[1][1] or nil

                if
                    message == "Generating response"
                    and opts
                    and opts.kind == "progress"
                    and opts.status == "running"
                then
                    saw_generating_progress = true
                    break
                end
            end

            progress_spy:revert()
            assert.equal(0, overlay_count_after_apply)
            assert.equal(0, overlay_count_after_refresh)
            assert.equal(0, overlay_count_after_message)
            assert.is_true(saw_generating_progress)
        end
    )

    it(
        "hides the ghost preview immediately after an inline approval",
        function()
            local inline = InlineChat:new({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                on_submit = function()
                    return true
                end,
            })

            inline:begin_request({
                prompt = "Approve this edit",
                selection = {
                    lines = { "local value = 1" },
                    start_line = 1,
                    end_line = 1,
                    file_path = "/tmp/inline_chat_test.lua",
                    file_type = "lua",
                },
                source_bufnr = bufnr,
                source_winid = winid,
            })
            inline:handle_tool_call({
                kind = "edit",
                file_path = "/tmp/inline_chat_test.lua",
                argument = "replace value",
            })
            inline:handle_permission_request()

            inline:handle_permission_resolution({
                option_id = "allow_once",
                options = {
                    {
                        optionId = "allow_once",
                        kind = "allow_once",
                        name = "Allow once",
                    },
                    {
                        optionId = "reject_once",
                        kind = "reject_once",
                        name = "Reject once",
                    },
                },
            })

            assert.equal(0, #get_overlay_extmarks())

            inline:refresh()
            assert.equal(0, #get_overlay_extmarks())

            inline:handle_session_update({
                sessionUpdate = "agent_message_chunk",
                content = {
                    type = "text",
                    text = "Approved and continuing",
                },
            })

            assert.equal(0, #get_overlay_extmarks())
        end
    )

    it(
        "reopens the inline prompt on the tracked range after rejection",
        function()
            local inline = InlineChat:new({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                on_submit = function()
                    return true
                end,
            })

            inline:begin_request({
                prompt = "Reject this edit",
                selection = {
                    lines = { "return value" },
                    start_line = 2,
                    end_line = 2,
                    file_path = "/tmp/inline_chat_test.lua",
                    file_type = "lua",
                },
                source_bufnr = bufnr,
                source_winid = winid,
            })
            inline:handle_tool_call({
                kind = "edit",
                file_path = "/tmp/inline_chat_test.lua",
                argument = "replace value",
            })
            inline:handle_permission_request()

            inline:handle_permission_resolution({
                option_id = "reject_once",
                options = {
                    {
                        optionId = "allow_once",
                        kind = "allow_once",
                        name = "Allow once",
                    },
                    {
                        optionId = "reject_once",
                        kind = "reject_once",
                        name = "Reject once",
                    },
                },
            })

            assert.equal(0, #get_overlay_extmarks())

            wait_for(function()
                return inline:is_prompt_open()
            end)

            --- @diagnostic disable-next-line: invisible
            local prompt = inline._prompt
            assert.is_not_nil(prompt)
            --- @cast prompt agentic.ui.InlineChat.PromptState
            assert.equal(bufnr, prompt.source_bufnr)
            assert.equal(winid, prompt.source_winid)
            assert.equal(2, prompt.selection.start_line)
            assert.equal(2, prompt.selection.end_line)
            assert.same({ "return value" }, prompt.selection.lines)

            --- @diagnostic disable-next-line: invisible
            inline:_close_prompt(true)
        end
    )

    it(
        "keeps the inline overlay attached to the tracked range extmark",
        function()
            local inline = InlineChat:new({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                on_submit = function()
                    return true
                end,
            })

            inline:begin_request({
                prompt = "Shift with edits",
                selection = {
                    lines = { "return value" },
                    start_line = 2,
                    end_line = 2,
                    file_path = "/tmp/inline_chat_test.lua",
                    file_type = "lua",
                },
                source_bufnr = bufnr,
                source_winid = winid,
            })

            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, {
                "-- inserted before tracked range",
            })
            inline:refresh()

            local overlay_extmarks = get_overlay_extmarks()
            assert.equal(1, #overlay_extmarks)
            assert.equal(2, overlay_extmarks[1][2])

            local lines = get_rendered_lines()
            assert.truthy(
                vim.tbl_contains(
                    lines,
                    "  [Agentic Inline] inline_chat_test.lua:3-3 Starting inline request"
                )
            )
        end
    )

    it("clears the inline overlay when the tracked range is deleted", function()
        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:begin_request({
            prompt = "Track this range",
            selection = {
                lines = { "return value" },
                start_line = 2,
                end_line = 2,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})
        inline:refresh()

        assert.equal(0, #get_overlay_extmarks())
    end)

    it(
        "clears current-buffer inline artifacts without letting refresh re-render ghost text",
        function()
            local inline = InlineChat:new({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                on_submit = function()
                    return true
                end,
            })

            inline:begin_request({
                prompt = "Clear this request",
                selection = {
                    lines = { "local value = 1" },
                    start_line = 1,
                    end_line = 1,
                    file_path = "/tmp/inline_chat_test.lua",
                    file_type = "lua",
                },
                source_bufnr = bufnr,
                source_winid = winid,
            })
            inline:handle_session_update({
                sessionUpdate = "agent_message_chunk",
                content = {
                    type = "text",
                    text = "Preview text",
                },
            })

            assert.equal(1, #get_overlay_extmarks())
            assert.equal(1, #get_thread_extmarks())
            assert.equal(1, vim.tbl_count(get_thread_store()))

            inline:clear_buffer(bufnr)

            assert.equal(0, #get_overlay_extmarks())
            assert.equal(0, #get_thread_extmarks())
            assert.equal(0, vim.tbl_count(get_thread_store()))

            inline:refresh()

            assert.equal(0, #get_overlay_extmarks())
            assert.equal(0, #get_thread_extmarks())
        end
    )

    it("keeps thread stores buffer-local across source buffers", function()
        local second_bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(
            second_bufnr,
            vim.fn.tempname() .. "/inline_chat_second_test.lua"
        )
        vim.api.nvim_buf_set_lines(second_bufnr, 0, -1, false, {
            "local other = 2",
            "return other",
        })

        vim.cmd("vsplit")
        local second_winid = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(second_winid, second_bufnr)

        local first_inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })
        local second_inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        first_inline:begin_request({
            prompt = "First buffer request",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        second_inline:begin_request({
            prompt = "Second buffer request",
            selection = {
                lines = { "local other = 2" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_second_test.lua",
                file_type = "lua",
            },
            source_bufnr = second_bufnr,
            source_winid = second_winid,
        })

        --- @type agentic.ui.InlineChat.ThreadStore
        local first_store = vim.b[bufnr][InlineChat.THREAD_STORE_KEY] or {}
        --- @type agentic.ui.InlineChat.ThreadStore
        local second_store = vim.b[second_bufnr][InlineChat.THREAD_STORE_KEY]
            or {}
        --- @type agentic.ui.InlineChat.ThreadState|nil
        local first_thread = vim.tbl_values(first_store)[1]
        --- @type agentic.ui.InlineChat.ThreadState|nil
        local second_thread = vim.tbl_values(second_store)[1]

        assert.equal(1, vim.tbl_count(first_store))
        assert.equal(1, vim.tbl_count(second_store))
        assert.is_not_nil(first_thread)
        assert.is_not_nil(second_thread)
        --- @cast first_thread agentic.ui.InlineChat.ThreadState
        --- @cast second_thread agentic.ui.InlineChat.ThreadState
        assert.equal("First buffer request", first_thread.turns[1].prompt)
        assert.equal("Second buffer request", second_thread.turns[1].prompt)

        first_inline:clear()
        second_inline:clear()
        vim.cmd("only")
        vim.api.nvim_buf_delete(second_bufnr, { force = true })
    end)

    it(
        "keeps completed previews visible while a new inline request starts",
        function()
            local inline = InlineChat:new({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                on_submit = function()
                    return true
                end,
            })

            inline:begin_request({
                prompt = "First request",
                selection = {
                    lines = { "local value = 1" },
                    start_line = 1,
                    end_line = 1,
                    file_path = "/tmp/inline_chat_test.lua",
                    file_type = "lua",
                },
                source_bufnr = bufnr,
                source_winid = winid,
            })
            inline:complete({ stopReason = "end_turn" }, nil)

            inline:begin_request({
                prompt = "Second request",
                selection = {
                    lines = { "return value" },
                    start_line = 2,
                    end_line = 2,
                    file_path = "/tmp/inline_chat_test.lua",
                    file_type = "lua",
                },
                source_bufnr = bufnr,
                source_winid = winid,
            })

            local overlays = get_rendered_overlays()
            assert.equal(2, #overlays)

            local overlay_texts = vim.tbl_map(function(overlay)
                return table.concat(overlay.lines, "\n")
            end, overlays)

            assert.truthy(vim.iter(overlay_texts):any(function(text)
                return text:match(
                    "inline_chat_test%.lua:1%-1 Inline request complete"
                ) and text:match("Prompt: First request")
            end))
            assert.truthy(vim.iter(overlay_texts):any(function(text)
                return text:match(
                    "inline_chat_test%.lua:2%-2 Starting inline request"
                ) and text:match("Prompt: Second request")
            end))
        end
    )

    it("clears completed ghost text after the configured ttl", function()
        Config.inline.result_ttl_ms = 30

        local inline = InlineChat:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            on_submit = function()
                return true
            end,
        })

        inline:begin_request({
            prompt = "Short lived",
            selection = {
                lines = { "local value = 1" },
                start_line = 1,
                end_line = 1,
                file_path = "/tmp/inline_chat_test.lua",
                file_type = "lua",
            },
            source_bufnr = bufnr,
            source_winid = winid,
        })

        inline:complete({ stopReason = "end_turn" }, nil)

        wait_for(function()
            return #get_overlay_extmarks() == 0
        end)
        assert.equal(0, #get_overlay_extmarks())
    end)
end)
