local assert = require("tests.helpers.assert")

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

    local function get_rendered_lines()
        local extmarks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            InlineChat.NS_INLINE,
            0,
            -1,
            { details = true }
        )

        local details = extmarks[1] and extmarks[1][4]
        local virt_lines = details and details.virt_lines or {}
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
end)
