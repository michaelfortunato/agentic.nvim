local FileSystem = require("agentic.utils.file_system")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.ui.FilePicker
--- @field _files table[]
--- @field _bufnr integer
--- @field _root string
--- @field _resolve_root? fun(): string|nil
local FilePicker = {}
FilePicker.__index = FilePicker

FilePicker.CMD_RG = {
    "rg",
    "--files",
    "--color",
    "never",
    "--glob",
    "!.git", -- Exclude .git (both directory and file used in worktrees)
}

FilePicker.CMD_FD = {
    "fd",
    "--type",
    "f",
    "--color",
    "never",
    "--exclude",
    ".git", -- Exclude .git (both directory and file used in worktrees)
}

FilePicker.CMD_GIT = { "git", "ls-files", "-co", "--exclude-standard" }

--- Buffer-local storage (weak values for automatic cleanup)
local instances_by_buffer = setmetatable({}, { __mode = "v" })
local CACHE_REFRESH_MS = 10000
local MAX_COMPLETION_RESULTS = 200
local files_by_root = {}
local executable_by_command = {}

--- @class agentic.ui.FilePicker.Opts
--- @field resolve_root? fun(): string|nil

--- @class agentic.ui.FilePicker.RootCache
--- @field files table[]
--- @field scanning boolean
--- @field updated_at integer
--- @field waiters fun(files: table[])[]

--- @return integer
local function now_ms()
    return math.floor(vim.loop.hrtime() / 1e6)
end

--- @param command string
--- @return boolean
local function is_executable(command)
    if executable_by_command[command] == nil then
        executable_by_command[command] = vim.fn.executable(command) == 1
    end

    return executable_by_command[command]
end

--- @param root string
--- @return string
local function normalize_root(root)
    return vim.fs.normalize(FileSystem.to_absolute_path(root))
end

--- @param path string
--- @return boolean
local function has_hidden_segment(path)
    for segment in path:gmatch("[^/]+") do
        if segment:sub(1, 1) == "." and segment ~= "." and segment ~= ".." then
            return true
        end
    end

    return false
end

--- @param root string
--- @param path string
--- @return string
local function to_absolute_path(root, path)
    if path == "" then
        return root
    end

    if vim.startswith(path, root .. "/") or path == root then
        return vim.fs.normalize(path)
    end

    if vim.startswith(path, "/") then
        return vim.fs.normalize(path)
    end

    return vim.fs.normalize(root .. "/" .. path)
end

--- @param root string
--- @param abs_path string
--- @return string
local function to_root_relative_path(root, abs_path)
    local root_prefix = root .. "/"

    if vim.startswith(abs_path, root_prefix) then
        return abs_path:sub(#root_prefix + 1)
    end

    return FileSystem.to_smart_path(abs_path)
end

--- @param bufnr number
--- @param opts agentic.ui.FilePicker.Opts|nil
--- @return agentic.ui.FilePicker|nil
function FilePicker:new(bufnr, opts)
    if not Config.file_picker.enabled then
        return nil
    end

    opts = opts or {}

    --- @type agentic.ui.FilePicker
    local instance = setmetatable({
        _files = {},
        _bufnr = bufnr,
        _root = normalize_root(vim.fn.getcwd()),
        _resolve_root = opts.resolve_root,
    }, self)
    instance:_setup_completion(bufnr)
    return instance
end

--- Completion menu accept sequence
--- Space after <C-y> ensures completion menu closes and user is ready to start a new completion
local COMPLETION_ACCEPT =
    vim.api.nvim_replace_termcodes("<C-y> ", true, true, true)

--- Sets up omnifunc completion and @ trigger detection
--- @param bufnr number
function FilePicker:_setup_completion(bufnr)
    vim.bo[bufnr].omnifunc =
        "v:lua.require'agentic.ui.file_picker'.complete_func"
    vim.bo[bufnr].completeopt = "menu,menuone,noinsert,popup,fuzzy"
    vim.bo[bufnr].iskeyword = vim.bo[bufnr].iskeyword .. ",@"
    instances_by_buffer[bufnr] = self

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.accept_completion,
        bufnr,
        function()
            if vim.fn.pumvisible() == 1 then
                return COMPLETION_ACCEPT
            end

            return ""
        end,
        {
            desc = "Agentic accept completion",
            expr = true,
            replace_keycodes = false,
        }
    )

    local last_at_pos = nil

    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = bufnr,
        callback = function()
            local cursor = vim.api.nvim_win_get_cursor(0)
            local line = vim.api.nvim_get_current_line()
            local before_cursor = line:sub(1, cursor[2])

            -- Match @ at start of line or after whitespace (space/tab)
            local at_match = before_cursor:match("^@[^%s]*$")
                or before_cursor:match("[%s]@[^%s]*$")

            if at_match then
                local at_pos = before_cursor:reverse():find("@")
                local current_pos = cursor[2] - at_pos

                -- Only scan if this is a new @ position
                if current_pos ~= last_at_pos then
                    last_at_pos = current_pos
                    self:_prime_files()
                elseif self._files and #self._files > 0 then
                    self:_trigger_completion_menu()
                end
            else
                last_at_pos = nil
            end
        end,
    })
end

--- @return boolean
function FilePicker:_include_hidden_files()
    return Config.file_picker.hidden == true
end

--- @return string
function FilePicker:_resolve_scan_root()
    local root = self._resolve_root and self._resolve_root() or vim.fn.getcwd()
    if not root or root == "" then
        root = vim.fn.getcwd()
    end

    return normalize_root(root)
end

--- @param output string
--- @param root string
--- @return table[]
function FilePicker:_build_file_items(output, root)
    local files = {}
    local seen = {}
    local include_hidden = self:_include_hidden_files()

    for line in output:gmatch("[^\n]+") do
        if line ~= "" then
            local abs_path = to_absolute_path(root, vim.trim(line))
            local relative_path = to_root_relative_path(root, abs_path)
            local relative_path_lc = relative_path:lower()

            if relative_path ~= "" then
                if include_hidden or not has_hidden_segment(relative_path) then
                    if not seen[relative_path] then
                        seen[relative_path] = true
                        table.insert(files, {
                            word = "@" .. relative_path,
                            menu = "File",
                            kind = "@",
                            icase = 1,
                            _path_lc = relative_path_lc,
                            _basename_lc = relative_path_lc:match("([^/]+)$")
                                or relative_path_lc,
                        })
                    end
                end
            end
        end
    end

    table.sort(files, function(a, b)
        return a.word < b.word
    end)

    return files
end

--- @param query string
--- @return string
local function normalize_query(query)
    return vim.trim((query or ""):gsub("^@", "")):lower()
end

--- @param query string
--- @return boolean
local function has_component_prefix(path_lc, query)
    return path_lc:find("/" .. query, 1, true) ~= nil
end

--- @param query string
--- @return table[]
function FilePicker:_filter_completion_items(query)
    local normalized_query = normalize_query(query)
    if normalized_query == "" then
        return vim.list_slice(
            self._files,
            1,
            math.min(#self._files, MAX_COMPLETION_RESULTS)
        )
    end

    local buckets = {
        {}, -- basename exact
        {}, -- basename prefix
        {}, -- path component prefix
        {}, -- basename substring
        {}, -- path substring
    }

    for _, item in ipairs(self._files) do
        local path_lc = item._path_lc or item.word:sub(2):lower()
        local basename_lc = item._basename_lc
            or (path_lc:match("([^/]+)$") or path_lc)

        local bucket_index = nil
        if basename_lc == normalized_query then
            bucket_index = 1
        elseif vim.startswith(basename_lc, normalized_query) then
            bucket_index = 2
        elseif has_component_prefix(path_lc, normalized_query) then
            bucket_index = 3
        elseif basename_lc:find(normalized_query, 1, true) then
            bucket_index = 4
        elseif path_lc:find(normalized_query, 1, true) then
            bucket_index = 5
        end

        if bucket_index then
            local bucket = buckets[bucket_index]
            if #bucket < MAX_COMPLETION_RESULTS then
                bucket[#bucket + 1] = item
            end
        end
    end

    local matches = {}
    for _, bucket in ipairs(buckets) do
        for _, item in ipairs(bucket) do
            matches[#matches + 1] = item
            if #matches >= MAX_COMPLETION_RESULTS then
                return matches
            end
        end
    end

    return matches
end

--- @param root string
--- @param files table[]
function FilePicker:_store_files(root, files)
    files_by_root[root] = {
        files = files,
        scanning = false,
        updated_at = now_ms(),
        waiters = {},
    }
    self._root = root
    self._files = files
end

--- @param root string
--- @return agentic.ui.FilePicker.RootCache|nil
function FilePicker:_get_cached_files(root)
    local cache = files_by_root[root]
    if not cache or not cache.files then
        return nil
    end

    return cache
end

--- @param root string
--- @return boolean
function FilePicker:_cache_is_fresh(root)
    local cache = self:_get_cached_files(root)
    if not cache then
        return false
    end

    return (now_ms() - cache.updated_at) <= CACHE_REFRESH_MS
end

function FilePicker:_trigger_completion_menu()
    vim.opt_local.pumwidth = math.floor(vim.o.columns * 0.45)

    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true),
        "n",
        false
    )
end

--- @return boolean
function FilePicker:_should_trigger_completion()
    if vim.api.nvim_get_current_buf() ~= self._bufnr then
        return false
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local before_cursor = line:sub(1, cursor[2])

    return before_cursor:match("^@[^%s]*$") ~= nil
        or before_cursor:match("[%s]@[^%s]*$") ~= nil
end

function FilePicker:_prime_files()
    local root = self:_resolve_scan_root()
    local cache = self:_get_cached_files(root)

    self._root = root

    if cache then
        self._files = cache.files
        if #cache.files > 0 then
            self:_trigger_completion_menu()
        end

        if self:_cache_is_fresh(root) or cache.scanning then
            return
        end
    end

    self:_scan_files_async(root, function(files)
        if not vim.api.nvim_buf_is_valid(self._bufnr) or self._root ~= root then
            return
        end

        self._files = files

        if #files > 0 and self:_should_trigger_completion() then
            self:_trigger_completion_menu()
        end
    end)
end

--- @param commands table[]
--- @param index integer
--- @param root string
--- @param callback fun(files: table[])
function FilePicker:_run_scan_commands_async(commands, index, root, callback)
    if index > #commands then
        callback(self:_scan_files_glob(root))
        return
    end

    local cmd_parts = commands[index]
    Logger.debug("[FilePicker] Async command:", vim.inspect(cmd_parts))

    if vim.system then
        vim.system(cmd_parts, { text = true }, function(result)
            vim.schedule(function()
                if result.code == 0 and result.stdout ~= "" then
                    callback(self:_build_file_items(result.stdout, root))
                    return
                end

                self:_run_scan_commands_async(
                    commands,
                    index + 1,
                    root,
                    callback
                )
            end)
        end)
        return
    end

    local output = vim.fn.system(cmd_parts)
    if vim.v.shell_error == 0 and output ~= "" then
        callback(self:_build_file_items(output, root))
        return
    end

    self:_run_scan_commands_async(commands, index + 1, root, callback)
end

--- @param root string
--- @param callback fun(files: table[])
function FilePicker:_scan_files_async(root, callback)
    local cache = files_by_root[root]
    if cache and cache.scanning then
        table.insert(cache.waiters, callback)
        return
    end

    cache = cache
        or {
            files = {},
            scanning = false,
            updated_at = 0,
            waiters = {},
        }
    cache.scanning = true
    table.insert(cache.waiters, callback)
    files_by_root[root] = cache

    local commands = self:_build_scan_commands(root)
    self:_run_scan_commands_async(commands, 1, root, function(files)
        local current_cache = files_by_root[root] or cache
        current_cache.files = files
        current_cache.scanning = false
        current_cache.updated_at = now_ms()

        local waiters = current_cache.waiters
        current_cache.waiters = {}
        files_by_root[root] = current_cache

        for _, waiter in ipairs(waiters) do
            waiter(files)
        end
    end)
end

--- @param root string|nil
function FilePicker:scan_files(root)
    root = normalize_root(root or self:_resolve_scan_root())
    local commands = self:_build_scan_commands(root)

    -- Try each command until one succeeds
    for _, cmd_parts in ipairs(commands) do
        Logger.debug("[FilePicker] Trying command:", vim.inspect(cmd_parts))
        local start_time = vim.loop.hrtime()

        local output = vim.fn.system(cmd_parts)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6

        Logger.debug(
            string.format(
                "[FilePicker] Command completed in %.2fms, exit_code: %d",
                elapsed,
                vim.v.shell_error
            )
        )

        if vim.v.shell_error == 0 and output ~= "" then
            local files = self:_build_file_items(output, root)
            self:_store_files(root, files)
            return files
        end
    end

    -- Fallback to glob if all commands failed
    local files = self:_scan_files_glob(root)
    self:_store_files(root, files)
    return files
end

--- Builds list of all available scan commands to try in order
--- All commands run against the resolved project root
--- @param root string
--- @return table[] commands List of command arrays to try
function FilePicker:_build_scan_commands(root)
    local commands = {}
    local include_hidden = self:_include_hidden_files()

    if is_executable(FilePicker.CMD_RG[1]) then
        local cmd = vim.list_extend({}, FilePicker.CMD_RG)
        if include_hidden then
            table.insert(cmd, "--hidden")
        end
        table.insert(cmd, root)
        table.insert(commands, cmd)
    end

    if is_executable(FilePicker.CMD_FD[1]) then
        local cmd = vim.list_extend({}, FilePicker.CMD_FD)
        if include_hidden then
            table.insert(cmd, "--hidden")
        end
        table.insert(cmd, ".")
        table.insert(cmd, root)
        table.insert(commands, cmd)
    end

    if is_executable(FilePicker.CMD_GIT[1]) then
        local git_marker = vim.uv.fs_stat(root .. "/.git")
        if git_marker then
            table.insert(commands, {
                "git",
                "-C",
                root,
                unpack(FilePicker.CMD_GIT, 2),
            })
        end
    end

    return commands
end

--- used exclusively with glob fallback to exclude common unwanted files
FilePicker.GLOB_EXCLUDE_PATTERNS = {
    "^%.$",
    "^%.%.$",
    "%.git/",
    "^%.git$", -- Exclude .git (both directory and file used in worktrees)
    "%.DS_Store$",
    "node_modules/",
    "%.pyc$",
    "%.swp$",
    "__pycache__/",
    "dist/",
    "build/",
    "vendor/",
    "%.next/",
    -- Java/JVM
    "target/",
    "%.gradle/",
    "%.m2/",
    -- Ruby
    "%.bundle/",
    -- Build/Cache
    "%.cache/",
    "%.turbo/",
    "/out/", -- Build output directory (anchored to avoid matching "layout/")
    -- Coverage
    "coverage/",
    "%.nyc_output/",
    -- Package managers
    "%.npm/",
    "%.yarn/",
    "%.pnpm%-store/",
    "bower_components/",
}

--- Checks if path should be excluded from the file list
--- Necessary when using glob fallback, since it can't exclude files
--- @param path string
--- @return boolean
function FilePicker:_should_exclude(path)
    for _, pattern in ipairs(FilePicker.GLOB_EXCLUDE_PATTERNS) do
        if path:match(pattern) then
            return true
        end
    end

    return false
end

--- @param root string
--- @return table[]
function FilePicker:_scan_files_glob(root)
    Logger.debug("[FilePicker] All commands failed, using glob fallback")
    local files = {}
    local seen = {}
    local include_hidden = self:_include_hidden_files()
    local glob_files = vim.fn.globpath(root, "**/*", false, true)

    if include_hidden then
        vim.list_extend(glob_files, vim.fn.globpath(root, "**/.*", false, true))
        vim.list_extend(
            glob_files,
            vim.fn.globpath(root, "**/.*/**/*", false, true)
        )
    end

    Logger.debug("[FilePicker] Glob returned", #glob_files, "paths")

    for _, path in ipairs(glob_files) do
        if vim.fn.isdirectory(path) == 0 then
            local relative_path =
                to_root_relative_path(root, vim.fs.normalize(path))
            if not self:_should_exclude(relative_path) then
                if include_hidden or not has_hidden_segment(relative_path) then
                    if not seen[relative_path] then
                        seen[relative_path] = true
                        table.insert(files, {
                            word = "@" .. relative_path,
                            menu = "File",
                            kind = "@",
                            icase = 1,
                        })
                    end
                end
            end
        end
    end

    table.sort(files, function(a, b)
        return a.word < b.word
    end)

    return files
end

--- Omnifunc completion function (called by Neovim)
--- @param findstart number 1 for finding start position, 0 for returning matches
--- @param _base string The text to complete
--- @return number|table
function FilePicker.complete_func(findstart, _base)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local before_cursor = line:sub(1, cursor[2])

        local at_pos = before_cursor:reverse():find("@")
        if at_pos then
            local start_col = cursor[2] - at_pos
            return start_col
        end
        -- Return -3: Cancel silently and leave completion mode (see :h complete-functions)
        return -3
    else
        local bufnr = vim.api.nvim_get_current_buf()
        local instance = instances_by_buffer[bufnr]
        if not instance then
            Logger.debug("[FilePicker] No instance found for buffer:", bufnr)
            return {}
        end

        return instance:_filter_completion_items(_base)
    end
end

return FilePicker
