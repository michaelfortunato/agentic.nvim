local assert = require("tests.helpers.assert")
local Config = require("agentic.config")

describe("agentic.ui.ChatViewport", function()
    local ChatViewport = require("agentic.ui.chat_viewport")
    local NS_TEST_ACTIVITY =
        vim.api.nvim_create_namespace("agentic_chat_viewport_test_activity")

    --- @type agentic.ui.ChatViewport|nil
    local viewport
    --- @type number
    local winid
    --- @type number
    local bufnr
    --- @type number
    local original_height
    --- @type agentic.UserConfig.AutoScroll
    local original_auto_scroll

    before_each(function()
        original_auto_scroll = vim.deepcopy(Config.auto_scroll)
        original_height = vim.api.nvim_win_get_height(0)
        Config.auto_scroll = { threshold = 10, debounce_ms = 150 }

        vim.cmd("enew")
        vim.cmd("resize 5")

        winid = vim.api.nvim_get_current_win()
        bufnr = vim.api.nvim_get_current_buf()
        viewport = ChatViewport:new({
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            get_chat_winid = function()
                return winid
            end,
            set_unread_context = function() end,
        })
    end)

    after_each(function()
        if viewport then
            viewport:destroy()
            viewport = nil
        end

        Config.auto_scroll = original_auto_scroll

        pcall(function()
            vim.cmd("silent! only")
        end)
        pcall(vim.api.nvim_win_set_height, 0, original_height)
    end)

    it("reveals virtual activity lines when scrolling to the bottom", function()
        vim.api.nvim_buf_set_lines(
            bufnr,
            0,
            -1,
            false,
            { "1", "2", "3", "4", "5", "6", "7", "" }
        )
        vim.api.nvim_buf_set_extmark(bufnr, NS_TEST_ACTIVITY, 7, 0, {
            virt_lines = { { { "Working", "Comment" } } },
            virt_lines_above = false,
        })

        vim.api.nvim_win_set_cursor(winid, { 8, 0 })
        local before_topline = vim.api.nvim_win_call(winid, function()
            return vim.fn.line("w0")
        end)

        local active_viewport = viewport --[[@as agentic.ui.ChatViewport]]
        active_viewport:scroll_to_bottom()
        local after_topline = vim.api.nvim_win_call(winid, function()
            return vim.fn.line("w0")
        end)

        assert.equal(8, vim.api.nvim_win_get_cursor(winid)[1])
        assert.is_true(after_topline > before_topline)
    end)
end)
