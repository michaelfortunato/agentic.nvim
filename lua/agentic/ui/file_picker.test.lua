local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local FilePicker = require("agentic.ui.file_picker")
local BlinkSource = require("agentic.ui.file_picker_blink_source")

--- Computes the differences between two tables
--- @param left table
--- @param right table
--- @return string[] only_in_left Items only in left table
--- @return string[] only_in_right Items only in right table
local function table_diff(left, right)
    local left_set = {}
    for _, v in ipairs(left) do
        left_set[v] = true
    end

    local right_set = {}
    for _, v in ipairs(right) do
        right_set[v] = true
    end

    local only_in_left = {}
    for _, v in ipairs(left) do
        if not right_set[v] then
            table.insert(only_in_left, v)
        end
    end

    local only_in_right = {}
    for _, v in ipairs(right) do
        if not left_set[v] then
            table.insert(only_in_right, v)
        end
    end

    return only_in_left, only_in_right
end

describe("FilePicker:scan_files", function()
    --- @type TestStub|nil
    local system_stub
    local original_cmd_rg
    local original_cmd_fd
    local original_cmd_git
    local original_cmd_bfs
    local original_hidden

    --- @type agentic.ui.FilePicker
    local picker

    before_each(function()
        original_cmd_rg = FilePicker.CMD_RG[1]
        original_cmd_fd = FilePicker.CMD_FD[1]
        original_cmd_git = FilePicker.CMD_GIT[1]
        original_cmd_bfs = FilePicker.CMD_BFS[1]
        original_hidden = Config.file_picker.hidden
        Config.file_picker.hidden = false
        picker = FilePicker:new(vim.api.nvim_create_buf(false, true)) --[[@as agentic.ui.FilePicker]]
    end)

    after_each(function()
        if system_stub then
            system_stub:revert()
            system_stub = nil
        end
        FilePicker.CMD_RG[1] = original_cmd_rg
        FilePicker.CMD_FD[1] = original_cmd_fd
        FilePicker.CMD_GIT[1] = original_cmd_git
        FilePicker.CMD_BFS[1] = original_cmd_bfs
        Config.file_picker.hidden = original_hidden
    end)

    describe("mocked commands", function()
        it("should stop at first successful command", function()
            -- Make all commands available by setting them to executables that exist
            FilePicker.CMD_RG[1] = "echo"
            FilePicker.CMD_FD[1] = "echo"
            FilePicker.CMD_GIT[1] = "echo"
            FilePicker.CMD_BFS[1] = "echo"

            system_stub = spy.stub(vim.fn, "system")
            system_stub:invokes(function(_cmd)
                -- First call returns empty (simulates failure)
                -- Second call returns files (simulates success)
                if system_stub.call_count == 1 then
                    return ""
                else
                    return "file1.lua\nfile2.lua\nfile3.lua\n"
                end
            end)

            local files = picker:scan_files()

            -- Should have called system exactly 2 times (first fails, second succeeds)
            assert.equal(2, system_stub.call_count)
            assert.equal(3, #files)
        end)

        it("filters hidden files when hidden results are disabled", function()
            FilePicker.CMD_RG[1] = "echo"
            FilePicker.CMD_FD[1] = "echo"
            FilePicker.CMD_GIT[1] = "echo"
            FilePicker.CMD_BFS[1] = "echo"

            system_stub = spy.stub(vim.fn, "system")
            system_stub:returns("file1.lua\n.env\nfoo/.secret\n")

            local files = picker:scan_files("/tmp/agentic-file-picker")
            local words = vim.tbl_map(function(file)
                return file.word
            end, files)

            assert.same({ "@file1.lua" }, words)
        end)

        it("renders paths relative to the resolved root", function()
            FilePicker.CMD_RG[1] = "echo"
            FilePicker.CMD_FD[1] = "echo"
            FilePicker.CMD_GIT[1] = "echo"
            FilePicker.CMD_BFS[1] = "echo"

            system_stub = spy.stub(vim.fn, "system")
            system_stub:returns("/tmp/agentic-file-picker/src/main.lua\n")

            local files = picker:scan_files("/tmp/agentic-file-picker")

            assert.equal("@src/main.lua", files[1].word)
        end)
    end)

    describe("real commands", function()
        local original_exclude_patterns

        before_each(function()
            original_exclude_patterns =
                vim.tbl_extend("force", {}, FilePicker.GLOB_EXCLUDE_PATTERNS)
        end)

        after_each(function()
            FilePicker.GLOB_EXCLUDE_PATTERNS = original_exclude_patterns
        end)

        it("should return same files in same order for all commands", function()
            -- Test rg
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            FilePicker.CMD_BFS[1] = "nonexistent_bfs"
            local files_rg = picker:scan_files()

            -- Test fd
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = original_cmd_fd
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            FilePicker.CMD_BFS[1] = "nonexistent_bfs"
            local files_fd = picker:scan_files()

            -- Test git
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = original_cmd_git
            FilePicker.CMD_BFS[1] = "nonexistent_bfs"
            local files_git = picker:scan_files()

            -- All commands should return more than 0 files
            assert.is_true(#files_rg > 0)
            assert.is_true(#files_fd > 0)
            assert.is_true(#files_git > 0)

            -- Extract just the word (filename) for comparison
            local words_rg = vim.tbl_map(function(f)
                return f.word
            end, files_rg)
            local words_fd = vim.tbl_map(function(f)
                return f.word
            end, files_fd)
            local words_git = vim.tbl_map(function(f)
                return f.word
            end, files_git)

            local rg_only, fd_only = table_diff(words_rg, words_fd)
            assert.are.same(rg_only, fd_only)

            local fd_only2, git_only = table_diff(words_fd, words_git)
            assert.are.same(fd_only2, git_only)

            assert.are.equal(#files_rg, #files_fd)
            assert.are.equal(#files_fd, #files_git)
        end)

        it("should use glob fallback when all commands fail", function()
            -- First, get files from rg for comparison
            FilePicker.CMD_RG[1] = original_cmd_rg
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            FilePicker.CMD_BFS[1] = "nonexistent_bfs"
            local files_rg = picker:scan_files()

            -- Disable all commands to force glob fallback
            FilePicker.CMD_RG[1] = "nonexistent_rg"
            FilePicker.CMD_FD[1] = "nonexistent_fd"
            FilePicker.CMD_GIT[1] = "nonexistent_git"
            FilePicker.CMD_BFS[1] = "nonexistent_bfs"

            -- deps is the temp folder where mini.nvim is installed during tests
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "deps/")
            -- lazy_repro is the temp folder where plugins are installed during tests
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "lazy_repro/")
            -- .local is the folder where Neovim is installed during tests in CI
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.local/")
            -- settings.local.json is gitignored but glob fallback doesn't respect .gitignore
            table.insert(
                FilePicker.GLOB_EXCLUDE_PATTERNS,
                "settings%.local%.json"
            )
            -- .opencode/.gitignore ignores specific files (bun.lock, package.json, etc.)
            -- rg/fd/git respect nested .gitignore but glob fallback doesn't
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.opencode/bun")
            table.insert(FilePicker.GLOB_EXCLUDE_PATTERNS, "%.opencode/package")
            table.insert(
                FilePicker.GLOB_EXCLUDE_PATTERNS,
                "%.opencode/%.gitignore"
            )

            local files_glob = picker:scan_files()

            assert.is_true(#files_glob > 0)

            -- Extract just the word (filename) for comparison
            local words_rg = vim.tbl_map(function(f)
                return f.word
            end, files_rg)
            local words_glob = vim.tbl_map(function(f)
                return f.word
            end, files_glob)

            local rg_only, glob_only = table_diff(words_rg, words_glob)
            assert.are.same(rg_only, glob_only)

            assert.are.equal(#words_rg, #words_glob)
        end)
    end)
end)

describe("FilePicker:request_completion_items", function()
    --- @type agentic.ui.FilePicker
    local picker
    --- @type integer
    local bufnr
    --- @type integer
    local original_bufnr

    before_each(function()
        original_bufnr = vim.api.nvim_get_current_buf()
        bufnr = vim.api.nvim_create_buf(false, true)
        picker = FilePicker:new(bufnr) --[[@as agentic.ui.FilePicker]]
        vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
        if original_bufnr and vim.api.nvim_buf_is_valid(original_bufnr) then
            vim.api.nvim_set_current_buf(original_bufnr)
        end

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("returns only matching completion items", function()
        local files = {
            {
                word = "@src/main.lua",
                _path_lc = "src/main.lua",
                _basename_lc = "main.lua",
            },
            {
                word = "@src/other.lua",
                _path_lc = "src/other.lua",
                _basename_lc = "other.lua",
            },
            {
                word = "@tests/main_spec.lua",
                _path_lc = "tests/main_spec.lua",
                _basename_lc = "main_spec.lua",
            },
        }
        picker:_store_files(picker:_resolve_scan_root(), files)

        local matches
        picker:request_completion_items("@main", function(items)
            matches = items
        end)
        local words = vim.tbl_map(function(item)
            return item.word
        end, matches)

        assert.same({ "@src/main.lua", "@tests/main_spec.lua" }, words)
    end)

    it("caps completion results to a bounded set", function()
        local files = {}

        for i = 1, 260 do
            local path = string.format("src/file-%03d.lua", i)
            files[i] = {
                word = "@" .. path,
                _path_lc = path,
                _basename_lc = path:match("([^/]+)$"),
            }
        end

        picker:_store_files(picker:_resolve_scan_root(), files)

        local matches
        picker:request_completion_items("@file", function(items)
            matches = items
        end)

        assert.equal(200, #matches)
        assert.equal("@src/file-001.lua", matches[1].word)
        assert.equal("@src/file-200.lua", matches[#matches].word)
    end)

    it("returns cached source items for blink to fuzzy match", function()
        local files = {
            {
                word = "@src/main.lua",
                _path_lc = "src/main.lua",
                _basename_lc = "main.lua",
            },
            {
                word = "@tests/main_spec.lua",
                _path_lc = "tests/main_spec.lua",
                _basename_lc = "main_spec.lua",
            },
        }

        picker:_store_files(picker:_resolve_scan_root(), files)

        local matches
        picker:request_source_items(function(items)
            matches = items
        end)

        assert.same(files, matches)
    end)
end)

describe("Blink file picker source", function()
    local source = BlinkSource.new({})
    local picker
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        picker = FilePicker:new(bufnr) --[[@as agentic.ui.FilePicker]]
        vim.bo[bufnr].filetype = "AgenticInput"
        picker:_store_files(picker:_resolve_scan_root(), {
            {
                word = "@src/main.lua",
                _path_lc = "src/main.lua",
                _basename_lc = "main.lua",
            },
            {
                word = "@src/other.lua",
                _path_lc = "src/other.lua",
                _basename_lc = "other.lua",
            },
        })
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("returns raw source items for an active @ mention", function()
        local response
        source:get_completions({
            bufnr = bufnr,
            line = "review @main",
            cursor = { 1, 12 },
        }, function(items)
            response = items
        end)

        assert.equal(2, #response.items)
        assert.equal("src/main.lua", response.items[1].label)
        assert.equal("@src/main.lua", response.items[1].textEdit.newText)
        assert.equal(7, response.items[1].textEdit.range.start.character)
    end)

    it("returns no completions outside an @ mention", function()
        local response
        source:get_completions({
            bufnr = bufnr,
            line = "email@example.com",
            cursor = { 1, 17 },
        }, function(items)
            response = items
        end)

        assert.same({}, response.items)
    end)
end)
