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
        vim.api.nvim_buf_set_name(bufnr, "/tmp/inline_chat_test.lua")
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
                text = "Inspecting the selected lines",
            },
        })

        local lines = get_rendered_lines()
        assert.truthy(vim.tbl_contains(lines, "Thinking:"))
        assert.truthy(
            vim.tbl_contains(lines, "  Inspecting the selected lines")
        )
        assert.truthy(vim.tbl_contains(lines, "Config: Mode: Code"))

        local thread_extmarks = get_thread_extmarks()
        assert.equal(1, #thread_extmarks)

        local thread = get_thread_store()[tostring(thread_extmarks[1][1])]
        assert.is_not_nil(thread)
        assert.equal("Refactor this", thread.turns[1].prompt)
        assert.equal("Thinking", thread.turns[1].status_text)
        assert.equal(
            "Inspecting the selected lines",
            thread.turns[1].thought_text
        )

        local overlay_extmark = get_overlay_extmarks()[1]
        local first_segment = overlay_extmark[4].virt_lines[1][1]
        assert.same({
            Theme.HL_GROUPS.REVIEW_BANNER_ACCENT,
            Theme.HL_GROUPS.INLINE_FADE,
        }, first_segment[2])
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

        local prompt = inline._prompt
        assert.is_not_nil(prompt)
        vim.api.nvim_buf_set_lines(
            prompt.prompt_bufnr,
            0,
            -1,
            false,
            { "Refactor this line" }
        )

        inline:_submit_prompt()

        assert.spy(on_submit_spy).was.called(1)
        assert.spy(set_current_win_spy).was.called(1)
        assert.equal(winid, set_current_win_spy.calls[1][1])

        set_current_win_spy:revert()
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
                "[Agentic Inline] inline_chat_test.lua:1:7-1:11 Starting inline request"
            )
        )
    end)

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
            { id = 1, inline_request = {} },
            { id = 2, inline_request = {} },
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
            { id = 1, inline_request = {} },
            { id = 2, inline_request = {} },
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
                "[Agentic Inline] inline_chat_test.lua:1-1 Waiting for approval"
            )
        )
        assert.truthy(vim.tbl_contains(lines, "Tool: edit replace value"))

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
                    "[Agentic Inline] inline_chat_test.lua:3-3 Starting inline request"
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
end)
