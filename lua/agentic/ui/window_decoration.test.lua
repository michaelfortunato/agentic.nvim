local assert = require("tests.helpers.assert")
local WindowDecoration = require("agentic.ui.window_decoration")

describe("window_decoration", function()
    after_each(function()
        pcall(function()
            vim.cmd("only")
        end)
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
        it("does not touch statusline and renders a winbar", function()
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
            assert.truthy(vim.wo[winid].winbar:match("Agentic Chat"))
            assert.is_falsy(vim.wo[winid].winbar:match("Mode: Code"))
            assert.equal("user-status", vim.wo[winid].statusline)
            assert.truthy(
                vim.wo[winid].winhighlight:match(
                    "WinSeparator:AgenticWinSeparator"
                )
            )
            assert.truthy(
                vim.wo[winid].winhighlight:match("WinBar:AgenticStatusLine")
            )
            assert.truthy(
                vim.wo[winid].winhighlight:match("WinBarNC:AgenticStatusLine")
            )
            assert.is_falsy(vim.wo[winid].winhighlight:match("StatusLine:"))
            assert.is_falsy(vim.wo[winid].winhighlight:match("StatusLineNC:"))
            assert.truthy(
                vim.api.nvim_buf_get_name(bufnr):match("Agentic Chat")
            )

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it(
            "renders wrapped chat context inside the buffer and keeps the title in the winbar",
            function()
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
                assert.truthy(vim.wo[winid].winbar:match("Agentic Chat"))
                assert.is_falsy(
                    vim.wo[winid].winbar:match("Approval Preset: Read Only")
                )
                assert.truthy(lines[1]:match("Approval Preset: Read Only"))
                assert.truthy(lines[2]:match("Reasoning Effort: Xhigh"))
                assert.equal("", lines[3])
                assert.equal("body", lines[4])
                assert.truthy(
                    vim.api.nvim_buf_get_name(bufnr):match("Agentic Chat")
                        ~= nil
                )
                assert.is_falsy(
                    vim.api.nvim_buf_get_name(bufnr):match("Approval")
                )

                WindowDecoration.render_header(
                    bufnr,
                    "chat",
                    "Approval Preset: Default | Model: gpt-5.4"
                )

                vim.wait(200, function()
                    lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
                    return lines[1]
                        == "Approval Preset: Default | Model: gpt-5.4"
                end)

                lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
                assert.equal(
                    "Approval Preset: Default | Model: gpt-5.4",
                    lines[1]
                )
                assert.equal("", lines[2])
                assert.equal("body", lines[3])

                vim.api.nvim_win_close(winid, true)
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )

        it("renders non-chat context and suffix inside the winbar", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "queued item" })

            local winid = vim.api.nvim_open_win(bufnr, true, {
                split = "right",
                win = -1,
            })

            WindowDecoration.render_header(bufnr, "queue", "3 pending")

            local ok = vim.wait(200, function()
                return vim.wo[winid].winbar ~= ""
            end)

            assert.is_true(ok)
            assert.truthy(vim.wo[winid].winbar:match("Agentic Queue"))
            assert.truthy(vim.wo[winid].winbar:match("3 pending"))
            assert.truthy(vim.wo[winid].winbar:match("%?: keymaps"))
            assert.is_falsy(vim.wo[winid].winbar:match("send now"))

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it(
            "wraps a single long config segment instead of forcing one mechanical line",
            function()
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
                assert.truthy(vim.wo[winid].winbar:match("Agentic Chat"))
                assert.equal("Approval Preset: Read", lines[1])
                assert.equal("Only Extremely Long", lines[2])
                assert.equal("Value", lines[3])
                assert.equal("", lines[4])
                assert.equal("body", lines[5])

                vim.api.nvim_win_close(winid, true)
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )
    end)
end)
