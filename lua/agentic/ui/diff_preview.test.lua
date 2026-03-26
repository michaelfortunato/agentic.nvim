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
        local orig_diff_keymaps

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
            orig_diff_keymaps = vim.deepcopy(Config.keymaps.diff_preview)
            Config.diff_preview.layout = "inline"
        end)

        after_each(function()
            read_stub:revert()
            get_winid_spy:revert()
            notify_spy:revert()
            Config.diff_preview.layout = orig_layout
            Config.keymaps.diff_preview = orig_diff_keymaps
        end)

        it(
            "falls back to an approximate inline preview when diff matching fails",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
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

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = { "nonexistent content that wont match" },
                        new = { "replacement" },
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
                local review_lines = review_extmarks[1]
                    and review_extmarks[1][4].virt_lines
                local drift_line = review_lines and review_lines[2] or nil
                local drift_text = drift_line
                        and table.concat(
                            vim.tbl_map(function(segment)
                                return segment[1]
                            end, drift_line),
                            ""
                        )
                    or ""

                assert.truthy(#diff_extmarks > 0)
                assert.truthy(#review_extmarks > 0)
                assert.truthy(drift_text:find("Context drift", 1, true) ~= nil)
                assert.spy(get_winid_spy).was.called(0)
                assert.spy(notify_spy).was.called(1)

                DiffPreview.clear_diff(file_bufnr)
                vim.api.nvim_buf_delete(file_bufnr, { force = true })
            end
        )

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
                assert.equal(prompt_bufnr, vim.api.nvim_get_current_buf())

                vim.cmd("only")
                vim.api.nvim_buf_delete(prompt_bufnr, { force = true })
                if vim.api.nvim_buf_is_valid(file_bufnr) then
                    vim.api.nvim_buf_delete(file_bufnr, { force = true })
                end
            end
        )

        it(
            "focuses a newly opened review target on the first diff hunk",
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
                assert.equal(review_winid, vim.api.nvim_get_current_win())
                assert.equal(
                    vim.fs.basename(file_path),
                    vim.fs.basename(
                        vim.api.nvim_buf_get_name(
                            vim.api.nvim_win_get_buf(review_winid)
                        )
                    )
                )
                assert.equal(1, vim.api.nvim_win_get_cursor(review_winid)[1])

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
            "focuses an existing review window when the diff is outside its viewport",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)
                local file_lines = {}
                for line = 1, 80 do
                    file_lines[#file_lines + 1] =
                        string.format("local line_%d = %d", line, line)
                end

                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    file_bufnr
                )
                vim.api.nvim_buf_set_name(file_bufnr, file_path)
                vim.api.nvim_buf_set_lines(file_bufnr, 0, -1, false, file_lines)

                local review_winid = vim.api.nvim_get_current_win()
                vim.cmd("vsplit")
                local prompt_winid = vim.api.nvim_get_current_win()
                local prompt_bufnr = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_win_set_buf(prompt_winid, prompt_bufnr)
                vim.api.nvim_set_current_win(review_winid)
                vim.api.nvim_win_set_height(review_winid, 8)
                vim.api.nvim_win_set_cursor(review_winid, { 1, 0 })
                vim.api.nvim_set_current_win(prompt_winid)

                read_stub:invokes(function()
                    return vim.deepcopy(file_lines), nil
                end)

                local new_lines = vim.deepcopy(file_lines)
                new_lines[55] = "local line_55 = 5500"

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = vim.deepcopy(file_lines),
                        new = new_lines,
                    },
                    review_actions = {
                        on_accept = function() end,
                        on_reject = function() end,
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                assert.equal(review_winid, vim.api.nvim_get_current_win())
                assert.equal(56, vim.api.nvim_win_get_cursor(review_winid)[1])
                assert.spy(get_winid_spy).was.called(0)

                DiffPreview.clear_diff(file_bufnr)
                vim.cmd("only")
                vim.api.nvim_buf_delete(prompt_bufnr, { force = true })
                vim.api.nvim_buf_delete(file_bufnr, { force = true })
            end
        )

        it(
            "installs review approval keymaps and restores prior buffer-local mappings",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
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
                    "m",
                    original_rhs,
                    { noremap = true, silent = true }
                )

                local accept_spy = spy_module.new(function() end)
                local reject_spy = spy_module.new(function() end)
                local accept_all_spy = spy_module.new(function() end)
                local reject_all_spy = spy_module.new(function() end)

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
                        on_accept_all = function()
                            accept_all_spy()
                        end,
                        on_reject_all = function()
                            reject_all_spy()
                        end,
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                vim.api.nvim_set_current_buf(file_bufnr)
                local review_marks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    DiffPreview.NS_REVIEW,
                    0,
                    -1,
                    { details = true }
                )
                local diff_marks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    HunkNavigation.NS_DIFF,
                    0,
                    -1,
                    { details = true }
                )

                local accept_map = vim.fn.maparg("m", "n", false, true)
                local reject_map = vim.fn.maparg("n", "n", false, true)
                local accept_all_map = vim.fn.maparg("M", "n", false, true)
                local reject_all_map = vim.fn.maparg("N", "n", false, true)

                local banner_lines = review_marks[1]
                    and review_marks[1][4].virt_lines
                local global_hint = banner_lines and banner_lines[2] or nil
                assert.is_not_nil(global_hint)
                local global_hint_segments = global_hint --[[@as table]]
                local global_text = table.concat(
                    vim.tbl_map(function(segment)
                        return segment[1]
                    end, global_hint_segments),
                    ""
                )
                assert.truthy(global_text:find("M yes-all", 1, true))
                assert.truthy(global_text:find("N no-all", 1, true))

                local footer_text = nil
                for _, mark in ipairs(diff_marks) do
                    local details = mark[4] or {}
                    local virt_lines = details.virt_lines
                    if virt_lines and #virt_lines > 0 then
                        local footer_segments = virt_lines[#virt_lines]
                        local candidate = table.concat(
                            vim.tbl_map(function(segment)
                                return segment[1]
                            end, footer_segments),
                            ""
                        )
                        if candidate:find("m yes", 1, true) then
                            footer_text = candidate
                            break
                        end
                    end
                end

                assert.is_not_nil(footer_text)
                local confirmed_footer_text = footer_text --[[@as string]]
                assert.truthy(confirmed_footer_text:find("m yes", 1, true))
                assert.truthy(confirmed_footer_text:find("n no", 1, true))

                vim.api.nvim_win_set_cursor(
                    vim.api.nvim_get_current_win(),
                    { 2, 0 }
                )
                accept_map.callback()
                reject_map.callback()
                accept_all_map.callback()
                reject_all_map.callback()

                assert.spy(accept_spy).was.called(1)
                assert.spy(reject_spy).was.called(1)
                assert.spy(accept_all_spy).was.called(1)
                assert.spy(reject_all_spy).was.called(1)

                DiffPreview.clear_diff(file_bufnr)

                local restored_map = vim.fn.maparg("m", "n", false, true)
                assert.equal(original_rhs, restored_map.rhs)

                vim.api.nvim_buf_delete(file_bufnr, { force = true })
            end
        )

        it(
            "uses configurable review keymaps from keymaps.diff_preview",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)

                Config.keymaps.diff_preview.accept = "<leader>ya"
                Config.keymaps.diff_preview.reject = "<leader>nn"
                Config.keymaps.diff_preview.accept_all = "<leader>YA"
                Config.keymaps.diff_preview.reject_all = "<leader>NN"

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

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                    review_actions = {
                        on_accept = function() end,
                        on_reject = function() end,
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                local review_marks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    DiffPreview.NS_REVIEW,
                    0,
                    -1,
                    { details = true }
                )
                local diff_marks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    HunkNavigation.NS_DIFF,
                    0,
                    -1,
                    { details = true }
                )

                local accept_map = vim.fn.maparg("<leader>ya", "n", false, true)
                local reject_map = vim.fn.maparg("<leader>nn", "n", false, true)
                local accept_all_map =
                    vim.fn.maparg("<leader>YA", "n", false, true)
                local reject_all_map =
                    vim.fn.maparg("<leader>NN", "n", false, true)

                assert.is_not_nil(accept_map.callback)
                assert.is_not_nil(reject_map.callback)
                assert.is_not_nil(accept_all_map.callback)
                assert.is_not_nil(reject_all_map.callback)

                local banner_lines = review_marks[1]
                    and review_marks[1][4].virt_lines
                local global_hint = banner_lines and banner_lines[2] or nil
                assert.is_not_nil(global_hint)
                local global_text = table.concat(
                    vim.tbl_map(function(segment)
                        return segment[1]
                    end, global_hint --[[@as table]]),
                    ""
                )
                assert.truthy(global_text:find("<leader>YA yes%-all") ~= nil)
                assert.truthy(global_text:find("<leader>NN no%-all") ~= nil)

                local footer_text = nil
                for _, mark in ipairs(diff_marks) do
                    local details = mark[4] or {}
                    local virt_lines = details.virt_lines
                    if virt_lines and #virt_lines > 0 then
                        local footer_segments = virt_lines[#virt_lines]
                        local candidate = table.concat(
                            vim.tbl_map(function(segment)
                                return segment[1]
                            end, footer_segments),
                            ""
                        )
                        if candidate:find("<leader>ya yes", 1, true) then
                            footer_text = candidate
                            break
                        end
                    end
                end

                assert.is_not_nil(footer_text)
                local confirmed_footer_text = footer_text --[[@as string]]
                assert.truthy(
                    confirmed_footer_text:find("<leader>nn no", 1, true)
                )

                DiffPreview.clear_diff(file_bufnr)
                vim.api.nvim_buf_delete(file_bufnr, { force = true })
            end
        )

        it(
            "restores original callback keymaps after review teardown",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)
                local restored_spy = spy_module.new(function() end)

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
                vim.keymap.set("n", "n", function()
                    restored_spy()
                end, {
                    buffer = file_bufnr,
                    desc = "Original reject mapping",
                })

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                    review_actions = {
                        on_accept = function() end,
                        on_reject = function() end,
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                DiffPreview.clear_diff(file_bufnr)

                local restored_map = vim.api.nvim_buf_call(
                    file_bufnr,
                    function()
                        return vim.fn.maparg("n", "n", false, true)
                    end
                )

                assert.is_not_nil(restored_map.callback)
                restored_map.callback()
                assert.spy(restored_spy).was.called(1)

                vim.api.nvim_buf_delete(file_bufnr, { force = true })
            end
        )

        it(
            "renders m/n review hints at the bottom of every inline hunk",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)
                local file_lines = {
                    "local first = 1",
                    "print(first)",
                    "",
                    "local second = 2",
                    "print(second)",
                    "",
                }

                read_stub:invokes(function()
                    return vim.deepcopy(file_lines), nil
                end)

                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    file_bufnr
                )
                vim.api.nvim_buf_set_name(file_bufnr, file_path)
                vim.api.nvim_buf_set_lines(file_bufnr, 0, -1, false, file_lines)

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = vim.deepcopy(file_lines),
                        new = {
                            "local first = 10",
                            "print(first)",
                            "",
                            "local second = 20",
                            "print(second)",
                            "",
                        },
                    },
                    review_actions = {
                        on_accept = function() end,
                        on_reject = function() end,
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                local diff_marks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    HunkNavigation.NS_DIFF,
                    0,
                    -1,
                    { details = true }
                )

                local footer_count = 0
                for _, mark in ipairs(diff_marks) do
                    local details = mark[4] or {}
                    local virt_lines = details.virt_lines
                    if virt_lines and #virt_lines > 0 then
                        local footer_segments = virt_lines[#virt_lines]
                        local footer_text = table.concat(
                            vim.tbl_map(function(segment)
                                return segment[1]
                            end, footer_segments),
                            ""
                        )
                        if footer_text:find("m yes", 1, true) then
                            footer_count = footer_count + 1
                            assert.truthy(footer_text:find("n no", 1, true))
                        end
                    end
                end

                assert.equal(2, footer_count)

                DiffPreview.clear_diff(file_bufnr)
                vim.api.nvim_buf_delete(file_bufnr, { force = true })
            end
        )

        it(
            "applies m and n to the nearest pending hunk instead of the whole diff",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)
                local file_lines = {
                    "local first = 1",
                    "print(first)",
                    "",
                    "local second = 2",
                    "print(second)",
                    "",
                }
                local accept_spy = spy_module.new(function() end)
                local reject_spy = spy_module.new(function() end)

                read_stub:invokes(function()
                    return vim.deepcopy(file_lines), nil
                end)

                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    file_bufnr
                )
                vim.api.nvim_buf_set_name(file_bufnr, file_path)
                vim.api.nvim_buf_set_lines(file_bufnr, 0, -1, false, file_lines)

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = vim.deepcopy(file_lines),
                        new = {
                            "local first = 10",
                            "print(first)",
                            "",
                            "local second = 20",
                            "print(second)",
                            "",
                        },
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

                vim.api.nvim_win_set_cursor(
                    vim.api.nvim_get_current_win(),
                    { 5, 0 }
                )

                local reject_map = vim.fn.maparg("n", "n", false, true)
                reject_map.callback()

                assert.spy(accept_spy).was.called(0)
                assert.spy(reject_spy).was.called(0)

                local diff_marks = vim.api.nvim_buf_get_extmarks(
                    file_bufnr,
                    HunkNavigation.NS_DIFF,
                    0,
                    -1,
                    { details = true }
                )
                local remaining_footer_count = 0
                for _, mark in ipairs(diff_marks) do
                    local details = mark[4] or {}
                    local virt_lines = details.virt_lines
                    if virt_lines and #virt_lines > 0 then
                        local footer_segments = virt_lines[#virt_lines]
                        local footer_text = table.concat(
                            vim.tbl_map(function(segment)
                                return segment[1]
                            end, footer_segments),
                            ""
                        )
                        if footer_text:find("m yes", 1, true) then
                            remaining_footer_count = remaining_footer_count + 1
                        end
                    end
                end

                assert.equal(1, remaining_footer_count)
                assert.equal(2, vim.api.nvim_win_get_cursor(0)[1])

                local accept_map = vim.fn.maparg("m", "n", false, true)
                accept_map.callback()

                assert.spy(accept_spy).was.called(0)
                assert.spy(reject_spy).was.called(1)
                assert.same({
                    "local first = 10",
                    "print(first)",
                    "",
                    "local second = 2",
                    "print(second)",
                    "",
                }, vim.api.nvim_buf_get_lines(
                    file_bufnr,
                    0,
                    -1,
                    false
                ))

                DiffPreview.clear_diff(file_bufnr)
                vim.api.nvim_buf_delete(file_bufnr, { force = true })
                os.remove(file_path)
            end
        )

        it(
            "passes m through to builtin marks when the cursor is not adjacent to a hunk",
            function()
                local file_path = vim.fn.tempname() .. ".lua"
                local file_bufnr = vim.api.nvim_create_buf(true, false)
                local file_lines = {
                    "local first = 1",
                    "print(first)",
                    "",
                    "local second = 2",
                    "print(second)",
                    "",
                }

                read_stub:invokes(function()
                    return vim.deepcopy(file_lines), nil
                end)

                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    file_bufnr
                )
                vim.api.nvim_buf_set_name(file_bufnr, file_path)
                vim.api.nvim_buf_set_lines(file_bufnr, 0, -1, false, file_lines)

                DiffPreview.show_diff({
                    file_path = file_path,
                    diff = {
                        old = vim.deepcopy(file_lines),
                        new = {
                            "local first = 10",
                            "print(first)",
                            "",
                            "local second = 20",
                            "print(second)",
                            "",
                        },
                    },
                    review_actions = {
                        on_accept = function() end,
                        on_reject = function() end,
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                vim.api.nvim_win_set_cursor(
                    vim.api.nvim_get_current_win(),
                    { 6, 0 }
                )
                vim.api.nvim_feedkeys(
                    vim.api.nvim_replace_termcodes("ma", true, false, true),
                    "xt",
                    false
                )

                local mark_pos = vim.fn.getpos("'a")
                assert.equal(6, mark_pos[2])

                DiffPreview.clear_diff(file_bufnr)
                vim.api.nvim_buf_delete(file_bufnr, { force = true })
                os.remove(file_path)
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
