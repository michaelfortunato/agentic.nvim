local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.Chooser", function()
    --- @type agentic.ui.Chooser
    local Chooser

    --- @type TestStub
    local list_uis_stub

    --- @param bufnr integer
    --- @param mode string
    --- @param lhs string
    --- @return table
    local function get_buffer_map(bufnr, mode, lhs)
        return vim.api.nvim_buf_call(bufnr, function()
            return vim.fn.maparg(lhs, mode, false, true)
        end)
    end

    before_each(function()
        Chooser = require("agentic.ui.chooser")
        list_uis_stub = spy.stub(vim.api, "nvim_list_uis")
        list_uis_stub:returns({
            {
                chan = 1,
            },
        })
    end)

    after_each(function()
        Chooser.close(vim.api.nvim_get_current_tabpage())
        list_uis_stub:revert()
    end)

    it(
        "uses buffer-local enter mappings to confirm the current item",
        function()
            local selected_choice = nil
            local origin_winid = vim.api.nvim_get_current_win()

            local shown = Chooser.show({ "first", "second" }, {
                prompt = "Select:",
            }, function(choice)
                selected_choice = choice
            end)

            assert.is_true(shown)

            local chooser_winid = vim.api.nvim_get_current_win()
            local chooser_bufnr = vim.api.nvim_get_current_buf()
            local normal_map = get_buffer_map(chooser_bufnr, "n", "<CR>")
            local insert_map = get_buffer_map(chooser_bufnr, "i", "<CR>")

            assert.equal(1, normal_map.buffer)
            assert.equal(1, insert_map.buffer)

            vim.api.nvim_win_set_cursor(chooser_winid, { 2, 0 })
            normal_map.callback()
            vim.wait(50, function()
                return selected_choice ~= nil
            end)

            assert.equal("second", selected_choice)
            assert.is_false(vim.api.nvim_win_is_valid(chooser_winid))
            assert.equal(origin_winid, vim.api.nvim_get_current_win())
        end
    )

    it(
        "uses buffer-local j and k mappings to move the chooser selection",
        function()
            local shown = Chooser.show({ "first", "second", "third" }, {
                prompt = "Select:",
            }, function() end)

            assert.is_true(shown)

            local chooser_winid = vim.api.nvim_get_current_win()
            local chooser_bufnr = vim.api.nvim_get_current_buf()
            local down_map = get_buffer_map(chooser_bufnr, "n", "j")
            local up_map = get_buffer_map(chooser_bufnr, "n", "k")
            local arrow_down_map = get_buffer_map(chooser_bufnr, "n", "<Down>")
            local arrow_up_map = get_buffer_map(chooser_bufnr, "n", "<Up>")

            assert.equal(1, down_map.buffer)
            assert.equal(1, up_map.buffer)
            assert.equal(1, arrow_down_map.buffer)
            assert.equal(1, arrow_up_map.buffer)

            assert.equal(1, vim.api.nvim_win_get_cursor(chooser_winid)[1])

            down_map.callback()
            assert.equal(2, vim.api.nvim_win_get_cursor(chooser_winid)[1])

            arrow_down_map.callback()
            assert.equal(3, vim.api.nvim_win_get_cursor(chooser_winid)[1])

            up_map.callback()
            assert.equal(2, vim.api.nvim_win_get_cursor(chooser_winid)[1])

            arrow_up_map.callback()
            assert.equal(1, vim.api.nvim_win_get_cursor(chooser_winid)[1])
        end
    )
end)
