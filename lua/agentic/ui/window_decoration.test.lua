local assert = require("tests.helpers.assert")
local WindowDecoration = require("agentic.ui.window_decoration")

describe("window_decoration", function()
    after_each(function()
        pcall(vim.cmd, "only")
    end)

    describe("get_headers_state", function()
        it("creates isolated header state per tabpage", function()
            local first_tab = vim.api.nvim_get_current_tabpage()
            local headers = WindowDecoration.get_headers_state(first_tab)
            headers.chat.context = "Mode: Code"
            WindowDecoration.set_headers_state(first_tab, headers)

            vim.cmd("tabnew")
            local second_tab = vim.api.nvim_get_current_tabpage()
            local second_headers =
                WindowDecoration.get_headers_state(second_tab)

            assert.is_nil(second_headers.chat.context)

            vim.cmd("tabclose")
        end)
    end)

    describe("render_header", function()
        it("does not touch statusline or show a winbar", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

            local winid = vim.api.nvim_open_win(bufnr, true, {
                split = "right",
                win = -1,
            })
            vim.api.nvim_set_option_value("statusline", "user-status", {
                win = winid,
            })

            WindowDecoration.render_header(bufnr, "chat", "Mode: Code")

            local ok = vim.wait(200, function()
                return vim.api.nvim_buf_get_name(bufnr) ~= ""
            end)

            assert.is_true(ok)
            assert.equal("", vim.wo[winid].winbar)
            assert.equal("user-status", vim.wo[winid].statusline)
            assert.truthy(
                vim.wo[winid].winhighlight:match(
                    "WinSeparator:AgenticWinSeparator"
                )
            )
            assert.falsy(vim.wo[winid].winhighlight:match("StatusLine:"))
            assert.falsy(vim.wo[winid].winhighlight:match("StatusLineNC:"))
            assert.truthy(vim.api.nvim_buf_get_name(bufnr):match("Agentic Chat"))

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("renders wrapped chat context inside the buffer instead of the winbar", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "body" })

            local winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 32,
                height = 8,
                row = 1,
                col = 1,
            })

            WindowDecoration.render_header(
                bufnr,
                "chat",
                "Approval Preset: Read Only | Model: gpt-5.4 | Reasoning Effort: Xhigh"
            )

            local ok = vim.wait(200, function()
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
                return lines[1] ~= "body"
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)

            assert.is_true(ok)
            assert.equal("", vim.wo[winid].winbar)
            assert.truthy(lines[1]:match("Approval Preset: Read Only"))
            assert.truthy(lines[2]:match("Reasoning Effort: Xhigh"))
            assert.equal("", lines[3])
            assert.equal("body", lines[4])
            assert.truthy(
                vim.api.nvim_buf_get_name(bufnr):match("Agentic Chat") ~= nil
            )
            assert.falsy(vim.api.nvim_buf_get_name(bufnr):match("Approval"))

            WindowDecoration.render_header(
                bufnr,
                "chat",
                "Approval Preset: Default | Model: gpt-5.4"
            )

            vim.wait(200, function()
                lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
                return lines[1] == "Approval Preset: Default | Model: gpt-5.4"
            end)

            lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
            assert.equal("Approval Preset: Default | Model: gpt-5.4", lines[1])
            assert.equal("", lines[2])
            assert.equal("body", lines[3])

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("wraps a single long config segment instead of forcing one mechanical line", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "body" })

            local winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 24,
                height = 8,
                row = 1,
                col = 1,
            })

            WindowDecoration.render_header(
                bufnr,
                "chat",
                "Approval Preset: Read Only Extremely Long Value"
            )

            local ok = vim.wait(200, function()
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
                return lines[1] ~= "body"
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)

            assert.is_true(ok)
            assert.equal("Approval Preset: Read", lines[1])
            assert.equal("Only Extremely Long", lines[2])
            assert.equal("Value", lines[3])
            assert.equal("", lines[4])
            assert.equal("body", lines[5])

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
