local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local FloatingMessage = require("agentic.ui.floating_message")
local KeymapHelp = require("agentic.ui.keymap_help")

describe("agentic.ui.KeymapHelp", function()
    --- @type integer
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it(
        "renders described buffer-local keymaps grouped by lhs and modes",
        function()
            local show_stub = spy.stub(FloatingMessage, "show")

            vim.keymap.set("n", "?", function() end, {
                buffer = bufnr,
                desc = "Agentic: Show available keymaps",
            })
            vim.keymap.set({ "i", "n" }, "<CR>", function() end, {
                buffer = bufnr,
                desc = "Agentic: Submit prompt",
            })
            vim.keymap.set("v", "d", function() end, {
                buffer = bufnr,
                desc = "Agentic files: remove selected files",
            })

            KeymapHelp.show_for_buffer(bufnr)

            assert.spy(show_stub).was.called(1)

            local opts = show_stub.calls[1][1]
            assert.truthy(vim.tbl_contains(opts.body, "Available keymaps:"))
            assert.truthy(
                vim.tbl_contains(opts.body, "- `?` [n] Show available keymaps")
            )
            assert.truthy(
                vim.tbl_contains(opts.body, "- `<CR>` [n/i] Submit prompt")
            )
            local visual_line = nil
            for _, line in ipairs(opts.body) do
                if
                    line:match(
                        "^%- `d` %[[^%]]+%] files: remove selected files$"
                    )
                then
                    visual_line = line
                    break
                end
            end
            assert.truthy(visual_line)

            show_stub:revert()
        end
    )
end)
