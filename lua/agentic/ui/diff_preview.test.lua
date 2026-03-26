local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")
local DiffPreview = require("agentic.ui.diff_preview")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local Logger = require("agentic.utils.logger")

describe("diff_preview", function()
    describe("show_diff", function()
        local read_stub
        local get_winid_spy
        local notify_spy
        local orig_layout

        before_each(function()
            read_stub = spy_module.stub(FileSystem, "read_from_buffer_or_disk")
            read_stub:invokes(function()
                return { "local x = 1", "print(x)", "" }, nil
            end)
            vim.wo.winfixbuf = false
            get_winid_spy = spy_module.new(function()
                return vim.api.nvim_get_current_win()
            end)
            notify_spy = spy_module.on(Logger, "notify")
            orig_layout = Config.diff_preview.layout
            Config.diff_preview.layout = "inline"
        end)

        after_each(function()
            read_stub:revert()
            get_winid_spy:revert()
            notify_spy:revert()
            Config.diff_preview.layout = orig_layout
        end)

        it("should not open a window when diff matching fails", function()
            DiffPreview.show_diff({
                file_path = "/tmp/test_diff_preview_nomatch.lua",
                diff = {
                    old = { "nonexistent content that wont match" },
                    new = { "replacement" },
                },
                get_winid = get_winid_spy --[[@as function]],
            })

            assert.spy(get_winid_spy).was.called(0)
        end)

        it(
            "silently skips diff when both old and new are empty (new file Write tool)",
            function()
                -- Simulate new file: file doesn't exist
                read_stub:invokes(function()
                    return nil
                end)

                DiffPreview.show_diff({
                    file_path = "/tmp/test_new_file.md",
                    diff = {
                        old = {},
                        new = { "" },
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                -- Should not open a window
                assert.spy(get_winid_spy).was.called(0)
                -- Should not show a warning notification
                assert.spy(notify_spy).was.called(0)
            end
        )

        it(
            "renders inline review in a visible non-current window while typing elsewhere",
            function()
                local file_path = "/tmp/test_diff_preview_visible.lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    file_bufnr
                )
                vim.api.nvim_buf_set_name(file_bufnr, file_path)
                vim.api.nvim_buf_set_lines(file_bufnr, 0, -1, false, {
                    "local x = 1",
                    "print(x)",
                    "",
                })

                vim.cmd("vsplit")
                local prompt_bufnr = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    prompt_bufnr
                )

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                local diff_extmarks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    HunkNavigation.NS_DIFF,
                    0,
                    -1,
                    { details = true }
                )
                local review_extmarks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    DiffPreview.NS_REVIEW,
                    0,
                    -1,
                    { details = true }
                )

                assert.truthy(#diff_extmarks > 0)
                assert.truthy(#review_extmarks > 0)
                assert.spy(get_winid_spy).was.called(0)

                vim.cmd("only")
                vim.api.nvim_buf_delete(prompt_bufnr, { force = true })
                if vim.api.nvim_buf_is_valid(file_bufnr) then
                    vim.api.nvim_buf_delete(file_bufnr, { force = true })
                end
            end
        )

        it(
            "opens a hidden review target without stealing prompt focus",
            function()
                local file_path = "/tmp/test_diff_preview_hidden.lua"
                local prompt_winid = vim.api.nvim_get_current_win()

                vim.cmd("vsplit")
                local review_winid = vim.api.nvim_get_current_win()
                vim.api.nvim_set_current_win(prompt_winid)

                local open_target_spy = spy_module.new(function(bufnr)
                    vim.api.nvim_win_set_buf(review_winid, bufnr)
                    return review_winid
                end)

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                    get_winid = open_target_spy --[[@as function]],
                })

                assert.spy(open_target_spy).was.called(1)
                assert.equal(prompt_winid, vim.api.nvim_get_current_win())

                local hidden_bufnr = vim.fn.bufnr(file_path)
                if
                    hidden_bufnr ~= -1
                    and vim.api.nvim_buf_is_valid(hidden_bufnr)
                then
                    local review_extmarks = vim.api.nvim_buf_get_extmarks(
                        hidden_bufnr,
                        DiffPreview.NS_REVIEW,
                        0,
                        -1,
                        { details = true }
                    )
                    assert.truthy(#review_extmarks > 0)
                    vim.api.nvim_buf_delete(hidden_bufnr, { force = true })
                end

                vim.cmd("only")
            end
        )

        it(
            "installs review approval keymaps and restores prior buffer-local mappings",
            function()
                local file_path = "/tmp/test_diff_preview_review_keys.lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    file_bufnr
                )
                vim.api.nvim_buf_set_name(file_bufnr, file_path)
                vim.api.nvim_buf_set_lines(file_bufnr, 0, -1, false, {
                    "local x = 1",
                    "print(x)",
                    "",
                })

                local original_rhs =
                    "<Cmd>let g:agentic_diff_preview_restored = 1<CR>"
                vim.api.nvim_buf_set_keymap(
                    file_bufnr,
                    "n",
                    "j",
                    original_rhs,
                    { noremap = true, silent = true }
                )

                local accept_spy = spy_module.new(function() end)
                local reject_spy = spy_module.new(function() end)

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                    review_actions = {
                        on_accept = function()
                            accept_spy()
                        end,
                        on_reject = function()
                            reject_spy()
                        end,
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                vim.api.nvim_set_current_buf(file_bufnr)

                local accept_map = vim.fn.maparg("j", "n", false, true)
                local reject_map = vim.fn.maparg("k", "n", false, true)
                local accept_all_map = vim.fn.maparg("J", "n", false, true)
                local reject_all_map = vim.fn.maparg("K", "n", false, true)

                accept_map.callback()
                reject_map.callback()
                accept_all_map.callback()
                reject_all_map.callback()

                assert.spy(accept_spy).was.called(2)
                assert.spy(reject_spy).was.called(2)

                DiffPreview.clear_diff(file_bufnr)

                local restored_map = vim.fn.maparg("j", "n", false, true)
                assert.equal(original_rhs, restored_map.rhs)

                vim.api.nvim_buf_delete(file_bufnr, { force = true })
            end
        )
    end)

    describe("clear_diff", function()
        it("clears the diff without any error", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            assert.has_no_errors(function()
                DiffPreview.clear_diff(bufnr)
            end)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it(
            "switches to alternate buffer when clearing unsaved named buffer",
            function()
                vim.wo.winfixbuf = false
                vim.cmd("edit tests/init.lua")
                local init_bufnr = vim.api.nvim_get_current_buf()

                vim.cmd("enew")
                local new_bufnr = vim.api.nvim_get_current_buf()

                local current_bufnr = vim.api.nvim_get_current_buf()
                assert.equal(current_bufnr, new_bufnr)

                vim.cmd("file tests/my_new_test.lua")

                DiffPreview.clear_diff(new_bufnr, true)

                current_bufnr = vim.api.nvim_get_current_buf()
                assert.equal(current_bufnr, init_bufnr)

                if vim.api.nvim_buf_is_valid(new_bufnr) then
                    vim.api.nvim_buf_delete(new_bufnr, { force = true })
                end
                if vim.api.nvim_buf_is_valid(init_bufnr) then
                    vim.api.nvim_buf_delete(init_bufnr, { force = true })
                end
            end
        )

        describe("set and revert modifiable buffer option", function()
            it("restores modifiable state after clearing diff", function()
                local bufnr = vim.api.nvim_create_buf(false, true)
                vim.bo[bufnr].modifiable = true

                -- Simulate what show_diff does: save state and set read-only
                vim.b[bufnr]._agentic_prev_modifiable = true
                vim.bo[bufnr].modifiable = false

                assert.is_false(vim.bo[bufnr].modifiable)

                DiffPreview.clear_diff(bufnr)

                assert.is_true(vim.bo[bufnr].modifiable)
                assert.is_nil(vim.b[bufnr]._agentic_prev_modifiable)

                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)

            it(
                "preserves non-modifiable state if buffer was already read-only",
                function()
                    local bufnr = vim.api.nvim_create_buf(false, true)
                    vim.bo[bufnr].modifiable = false

                    -- Simulate show_diff on already non-modifiable buffer
                    vim.b[bufnr]._agentic_prev_modifiable = false
                    vim.bo[bufnr].modifiable = false

                    DiffPreview.clear_diff(bufnr)

                    assert.is_false(vim.bo[bufnr].modifiable)
                    assert.is_nil(vim.b[bufnr]._agentic_prev_modifiable)

                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            )
        end)
    end)
end)
