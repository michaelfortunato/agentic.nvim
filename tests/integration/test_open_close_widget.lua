local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Open and Close Chat Widget", function()
    local child = Child:new()

    --- Gets sorted filetypes for all windows in the given tabpage
    --- @param tabpage number
    --- @return string[]
    local function get_tabpage_filetypes(tabpage)
        local winids = child.api.nvim_tabpage_list_wins(tabpage)
        local filetypes = {}
        for _, winid in ipairs(winids) do
            local bufnr = child.api.nvim_win_get_buf(winid)
            local ft =
                child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
            table.insert(filetypes, ft)
        end
        table.sort(filetypes)
        return filetypes
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("Opens the widget with chat and prompt windows", function()
        local initial_winid = child.api.nvim_get_current_win()

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Should have: empty filetype (original window), AgenticChat, AgenticInput
        local filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

        -- 80 - default neovim headless width
        -- 32% of 80 = 25 (chat window)
        -- 1 separator
        -- Check that original window width is reduced (80 - 25 - 1 separator = 54)
        local original_width = child.api.nvim_win_get_width(initial_winid)
        assert.equal(54, original_width)
    end)

    it("toggles the widget to show and hide it", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Should have: empty filetype (original window), AgenticChat, AgenticInput
        local filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- After hide, should only have original window
        filetypes = get_tabpage_filetypes(0)
        assert.same({ "" }, filetypes)
    end)

    it("Creates independent widgets per tabpage", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Tab1 should have: empty filetype, AgenticChat, AgenticInput
        local tab1_filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, tab1_filetypes)

        local tab1_id = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")

        local tab2_id = child.api.nvim_get_current_tabpage()
        assert.is_not.equal(tab1_id, tab2_id)

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Tab2 should also have: empty filetype, AgenticChat, AgenticInput
        local tab2_filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, tab2_filetypes)

        local session_count = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])
        assert.equal(2, session_count)

        assert.has_no_errors(function()
            child.cmd("tabclose")
        end)

        local session_count_after = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])
        assert.equal(1, session_count_after)
    end)

    it("allows multiple independent sessions in the same tabpage", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        child.lua(
            [[ require("agentic").new_session({ auto_add_to_context = false }) ]]
        )
        child.flush()

        local tab_sessions = child.lua_get([[
            #require("agentic.session_registry").get_tab_sessions(vim.api.nvim_get_current_tabpage())
        ]])
        assert.equal(2, tab_sessions)

        local filetypes = get_tabpage_filetypes(0)
        local chat_count = 0
        local input_count = 0
        for _, filetype in ipairs(filetypes) do
            if filetype == "AgenticChat" then
                chat_count = chat_count + 1
            elseif filetype == "AgenticInput" then
                input_count = input_count + 1
            end
        end

        assert.equal(2, chat_count)
        assert.equal(2, input_count)
    end)

    it("loads another live session into the current chat widget", function()
        child.lua(
            [[ require("agentic").toggle({ auto_add_to_context = false }) ]]
        )
        child.flush()

        child.lua([[
(function()
    local session = require("agentic.session_registry").get_current_session()
    session.widget:set_input_text("first draft")
end)()
]])

        child.lua(
            [[ require("agentic").new_session({ auto_add_to_context = false }) ]]
        )
        child.flush()

        child.lua([[
(function()
    local session = require("agentic.session_registry").get_current_session()
    session.widget:set_input_text("second draft")
end)()
]])

        local before_swap = child.lua_get([[
(function()
    local registry = require("agentic.session_registry")
    local sessions = registry.get_tab_sessions(vim.api.nvim_get_current_tabpage())
    return {
        first_input_bufnr = sessions[1].widget.buf_nrs.input,
        second_input_bufnr = sessions[2].widget.buf_nrs.input,
    }
end)()
]])

        child.lua([[
(function()
    local registry = require("agentic.session_registry")
    local sessions = registry.get_tab_sessions(vim.api.nvim_get_current_tabpage())
    vim.api.nvim_set_current_win(sessions[2].widget.win_nrs.input)
    registry.load_session_into_current_widget(sessions[1])
end)()
]])
        child.flush()

        local after_swap = child.lua_get([[
(function()
    local registry = require("agentic.session_registry")
    local sessions = registry.get_tab_sessions(vim.api.nvim_get_current_tabpage())
    local current = registry.find_session_by_buf(vim.api.nvim_get_current_buf())
    return {
        first_input_bufnr = sessions[1].widget.buf_nrs.input,
        second_input_bufnr = sessions[2].widget.buf_nrs.input,
        first_input_lines = vim.api.nvim_buf_get_lines(sessions[1].widget.buf_nrs.input, 0, -1, false),
        second_input_lines = vim.api.nvim_buf_get_lines(sessions[2].widget.buf_nrs.input, 0, -1, false),
        current_instance_id = current and current.instance_id or nil,
        first_instance_id = sessions[1].instance_id,
    }
end)()
]])

        assert.equal(
            before_swap.second_input_bufnr,
            after_swap.first_input_bufnr
        )
        assert.equal(
            before_swap.first_input_bufnr,
            after_swap.second_input_bufnr
        )
        assert.same({ "first draft" }, after_swap.first_input_lines)
        assert.same({ "second draft" }, after_swap.second_input_lines)
        assert.equal(
            after_swap.first_instance_id,
            after_swap.current_instance_id
        )
    end)

    it("handles tabclose while in insert mode without errors", function()
        -- Open widget
        child.lua([[ require("agentic").toggle() ]])

        -- Enter insert mode in input buffer (triggers ModeChanged)
        child.cmd("startinsert")

        -- Create second tab
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])

        local mode = child.fn.mode()
        assert.equal(mode, "i")

        -- Close the second tab while in insert mode
        -- This should not error when ModeChanged fires during cleanup
        assert.has_no_errors(function()
            child.cmd("tabclose!")
            vim.uv.sleep(200)
        end)
    end)

    it("tabclose on widget tab leaves first tab clean", function()
        -- Start with clean first tab (no widget)
        local initial_windows = #child.api.nvim_tabpage_list_wins(0)

        -- Create second tab and open widget there
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Ensure cursor is in input buffer
        local current_bufnr = child.api.nvim_get_current_buf()
        local expected_input_bufnr = child.lua_get([[
(function()
    local tab_id = vim.api.nvim_get_current_tabpage()
    local session = require("agentic.session_registry").get_current_session(tab_id)
    return session.widget.buf_nrs.input
end)()
]])
        assert.equal(expected_input_bufnr, current_bufnr)

        -- Close the second tab
        assert.has_no_errors(function()
            child.cmd("tabclose")
            child.flush()
        end)

        -- Verify we're back on the first tab
        local current_tab = child.api.nvim_get_current_tabpage()
        assert.equal(1, current_tab)

        -- First tab should be clean (same number of windows as initially)
        local final_windows = #child.api.nvim_tabpage_list_wins(0)

        -- Debug: what windows exist?
        if final_windows ~= initial_windows then
            local winids = child.api.nvim_tabpage_list_wins(0)
            for i, winid in ipairs(winids) do
                local bufnr = child.api.nvim_win_get_buf(winid)
                local ft =
                    child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
                print(
                    string.format(
                        "Window %d: winid=%d bufnr=%d filetype='%s'",
                        i,
                        winid,
                        bufnr,
                        ft
                    )
                )
            end
        end

        assert.equal(initial_windows, final_windows)

        -- Should only have 1 window visible
        assert.equal(1, final_windows)
    end)
end)
