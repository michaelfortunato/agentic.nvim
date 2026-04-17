local FileSystem = require("agentic.utils.file_system")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.FilePicker
--- @field _files table[]
--- @field _bufnr integer
--- @field _root string
--- @field _resolve_root? fun(): string|nil
--- @field _resolve_cwd? fun(): string|nil
--- @field _on_file_selected? fun(file_path: string)
--- @field _skip_auto_show_once boolean
--- @field _roots_key? string|nil
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
FilePicker.CMD_BFS = {
    "bfs",
    "-name",
    ".git",
    "-prune",
    "-o",
    "-type",
    "f",
    "-print",
}

--- Buffer-local lookup cache.
--- Lifetime is anchored by SessionManager.file_picker; weak values avoid stale
--- entries after the owning session is released.
local instances_by_buffer = setmetatable({}, { __mode = "v" })
local CACHE_REFRESH_MS = 10000
local MAX_COMPLETION_RESULTS = 200
local files_by_root = {}
local executable_by_command = {}
local BLINK_SOURCE_ID = "agentic_files"
local blink_provider_registered = false
local blink_filetype_registered = false

--- @class agentic.ui.FilePicker.Opts
--- @field resolve_root? fun(): string|nil
--- @field resolve_cwd? fun(): string|nil
--- @field on_file_selected? fun(file_path: string)

--- @class agentic.ui.FilePicker.RootCache
--- @field files table[]
--- @field scanning boolean
--- @field updated_at integer
--- @field waiters fun(files: table[])[]

--- @class agentic.ui.FilePicker.BlinkAPI
--- @field show fun(opts: {providers?: string[]}|nil)
--- @field add_source_provider fun(source_id: string, source_config: table)
--- @field add_filetype_source fun(filetype: string, source_id: string)

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

--- @param files table[]
local function sort_files(files)
    table.sort(files, function(left, right)
        local left_priority = left._root_priority or 1
        local right_priority = right._root_priority or 1
        if left_priority ~= right_priority then
            return left_priority < right_priority
        end

        local left_gitignored = left._gitignored_priority or 0
        local right_gitignored = right._gitignored_priority or 0
        if left_gitignored ~= right_gitignored then
            return left_gitignored < right_gitignored
        end

        return left.word < right.word
    end)
end

--- @param item table
--- @param relative_path string
local function add_search_entry(item, relative_path)
    if relative_path == "" then
        return
    end

    local search_entries = item._search_entries or {}
    local relative_path_lc = relative_path:lower()
    for _, entry in ipairs(search_entries) do
        if entry.path_lc == relative_path_lc then
            return
        end
    end

    local basename_lc = relative_path_lc:match("([^/]+)$") or relative_path_lc
    search_entries[#search_entries + 1] = {
        path_lc = relative_path_lc,
        basename_lc = basename_lc,
    }
    item._search_entries = search_entries

    local filter_parts = item._filter_parts or {}
    filter_parts[#filter_parts + 1] = relative_path
    item._filter_parts = filter_parts
    item._filter_text = table.concat(filter_parts, " ")
end

--- @param root string
--- @param abs_path string
--- @return table|nil
local function make_file_item(root, abs_path)
    local relative_path = to_root_relative_path(root, abs_path)
    if relative_path == "" then
        return nil
    end

    local relative_path_lc = relative_path:lower()
    local basename_lc = relative_path_lc:match("([^/]+)$") or relative_path_lc

    --- @type table
    local item = {
        word = "@" .. relative_path,
        menu = "File",
        kind = "@",
        icase = 1,
        _abs_path = abs_path,
        _path_lc = relative_path_lc,
        _basename_lc = basename_lc,
        _search_entries = {},
        _filter_parts = {},
        _filter_text = "",
        _gitignored_priority = 0,
    }

    add_search_entry(item, relative_path)

    return item
end

--- @param roots string[]
--- @return string
local function get_roots_key(roots)
    return table.concat(roots, "\n")
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
        _resolve_cwd = opts.resolve_cwd,
        _on_file_selected = opts.on_file_selected,
        _skip_auto_show_once = false,
        _roots_key = nil,
    }, self)
    instance:_setup_blink_completion(bufnr)
    return instance
end

--- @param line string
--- @param cursor_col integer
--- @return { start_col: integer, query: string }|nil
local function get_active_mention(line, cursor_col)
    local before_cursor = line:sub(1, cursor_col)
    local at_col = before_cursor:match(".*()@[^%s]*$")
    if not at_col then
        return nil
    end

    if at_col > 1 then
        local prefix = before_cursor:sub(at_col - 1, at_col - 1)
        if not prefix:match("%s") then
            return nil
        end
    end

    return {
        start_col = at_col - 1,
        query = before_cursor:sub(at_col),
    }
end

--- @return agentic.ui.FilePicker.BlinkAPI|nil
function FilePicker:_get_blink()
    local ok, blink = pcall(require, "blink.cmp")
    if not ok then
        return nil
    end

    return blink
end

function FilePicker:_ensure_blink_registered()
    local blink = self:_get_blink()
    if not blink then
        return nil
    end

    if not blink_provider_registered then
        local ok_config, blink_config = pcall(require, "blink.cmp.config")
        local already_registered = ok_config
            and blink_config.sources
            and blink_config.sources.providers
            and blink_config.sources.providers[BLINK_SOURCE_ID] ~= nil

        if not already_registered then
            blink.add_source_provider(BLINK_SOURCE_ID, {
                name = "Agentic Files",
                module = "agentic.ui.file_picker_blink_source",
                async = true,
                max_items = MAX_COMPLETION_RESULTS,
            })
        end

        blink_provider_registered = true
    end

    if not blink_filetype_registered then
        blink.add_filetype_source("AgenticInput", BLINK_SOURCE_ID)
        blink_filetype_registered = true
    end

    return blink
end

--- @return boolean
function FilePicker:_is_blink_menu_open()
    local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
    if not ok_menu or not menu or not menu.win or not menu.win.is_open then
        return false
    end

    return menu.win:is_open()
end

--- @param line string
--- @param cursor_col integer
function FilePicker:_show_mention_completion_if_needed(line, cursor_col)
    if self._skip_auto_show_once then
        self._skip_auto_show_once = false
        return
    end

    local mention = get_active_mention(line, cursor_col)
    if not mention or self:_is_blink_menu_open() then
        return
    end

    local blink = self:_get_blink()
    if not blink then
        return
    end

    blink.show({
        providers = { BLINK_SOURCE_ID },
    })
end

function FilePicker:skip_next_auto_show()
    self._skip_auto_show_once = true
    vim.schedule(function()
        if self._skip_auto_show_once then
            self._skip_auto_show_once = false
        end
    end)
end

--- Sets up blink-triggered completion for @ file mentions
--- @param bufnr number
function FilePicker:_setup_blink_completion(bufnr)
    instances_by_buffer[bufnr] = self
    self:_ensure_blink_registered()

    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = bufnr,
        callback = function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end

            local cursor = vim.api.nvim_win_get_cursor(0)
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                cursor[1] - 1,
                cursor[1],
                false
            )[1] or ""

            self:_show_mention_completion_if_needed(line, cursor[2])
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

--- @return string
function FilePicker:_resolve_current_cwd()
    local cwd = self._resolve_cwd and self._resolve_cwd() or vim.fn.getcwd()
    if not cwd or cwd == "" then
        cwd = vim.fn.getcwd()
    end

    return normalize_root(cwd)
end

--- @return string[]
function FilePicker:_resolve_search_roots()
    local roots = {}
    local seen = {}

    for _, root in ipairs({
        self:_resolve_scan_root(),
        self:_resolve_current_cwd(),
    }) do
        if root and root ~= "" and not seen[root] then
            seen[root] = true
            roots[#roots + 1] = root
        end
    end

    return roots
end

--- @param path string
--- @return string
function FilePicker:resolve_path(path)
    local fallback = nil

    for _, root in ipairs(self:_resolve_search_roots()) do
        local abs_path = to_absolute_path(root, path)
        fallback = fallback or abs_path

        local stat = vim.uv.fs_stat(abs_path)
        if stat then
            return abs_path
        end
    end

    return fallback or to_absolute_path(self:_resolve_scan_root(), path)
end

--- @param input_text string
--- @return string[] file_paths
function FilePicker:resolve_mentioned_file_paths(input_text)
    local file_paths = {}
    local seen = {}

    for path in (" " .. input_text):gmatch("%s@([^%s]+)") do
        local abs_path = self:resolve_path(path)
        local stat = vim.uv.fs_stat(abs_path)

        if stat and stat.type == "file" and not seen[abs_path] then
            seen[abs_path] = true
            file_paths[#file_paths + 1] = abs_path
        end
    end

    return file_paths
end

--- @param path string
function FilePicker:handle_file_selected(path)
    if not self._on_file_selected then
        return
    end

    local abs_path = self:resolve_path(path)
    local stat = vim.uv.fs_stat(abs_path)
    if not stat or stat.type ~= "file" then
        return
    end

    self._on_file_selected(abs_path)
end

--- @param output string
--- @param root string
--- @param ensure_exists? boolean
--- @return table[]
function FilePicker:_build_file_items(output, root, ensure_exists)
    local files = {}
    local seen = {}
    local include_hidden = self:_include_hidden_files()

    for line in output:gmatch("[^\n]+") do
        if line ~= "" then
            local abs_path = to_absolute_path(root, vim.trim(line))
            if not ensure_exists or vim.uv.fs_stat(abs_path) then
                local relative_path = to_root_relative_path(root, abs_path)

                if relative_path ~= "" then
                    if
                        include_hidden or not has_hidden_segment(relative_path)
                    then
                        if not seen[relative_path] then
                            seen[relative_path] = true
                            local item = make_file_item(root, abs_path)
                            if item then
                                table.insert(files, item)
                            end
                        end
                    end
                end
            end
        end
    end

    sort_files(files)

    return files
end

--- @param cmd_parts table
--- @return boolean
local function command_needs_existing_file_filter(cmd_parts)
    return cmd_parts[1] == "git"
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
        local bucket_index = nil
        local search_entries = item._search_entries
            or {
                {
                    path_lc = item._path_lc or item.word:sub(2):lower(),
                    basename_lc = item._basename_lc,
                },
            }

        for _, entry in ipairs(search_entries) do
            local path_lc = entry.path_lc
            local basename_lc = entry.basename_lc
                or (path_lc:match("([^/]+)$") or path_lc)

            if basename_lc == normalized_query then
                bucket_index = bucket_index and math.min(bucket_index, 1) or 1
            elseif vim.startswith(basename_lc, normalized_query) then
                bucket_index = bucket_index and math.min(bucket_index, 2) or 2
            elseif has_component_prefix(path_lc, normalized_query) then
                bucket_index = bucket_index and math.min(bucket_index, 3) or 3
            elseif basename_lc:find(normalized_query, 1, true) then
                bucket_index = bucket_index and math.min(bucket_index, 4) or 4
            elseif path_lc:find(normalized_query, 1, true) then
                bucket_index = bucket_index and math.min(bucket_index, 5) or 5
            end
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

--- @param roots string[]
--- @return table[]
function FilePicker:_merge_cached_files_for_roots(roots)
    local merged = {}
    local items_by_abs_path = {}

    for root_index, root in ipairs(roots) do
        local cache = self:_get_cached_files(root)
        if cache then
            for _, cached_item in ipairs(cache.files) do
                local abs_path = cached_item._abs_path
                if abs_path then
                    local item = items_by_abs_path[abs_path]
                    if not item then
                        item = make_file_item(root, abs_path)
                        if item then
                            item._root_priority = root_index
                            item._gitignored_priority = cached_item._gitignored_priority
                                or 0
                            items_by_abs_path[abs_path] = item
                            merged[#merged + 1] = item
                        end
                    elseif root_index < (item._root_priority or math.huge) then
                        local relative_path =
                            to_root_relative_path(root, abs_path)
                        item.word = "@" .. relative_path
                        item._path_lc = relative_path:lower()
                        item._basename_lc = item._path_lc:match("([^/]+)$")
                            or item._path_lc
                        item._root_priority = root_index
                    end

                    if item then
                        item._gitignored_priority = math.min(
                            item._gitignored_priority or 0,
                            cached_item._gitignored_priority or 0
                        )
                        add_search_entry(
                            item,
                            to_root_relative_path(root, abs_path)
                        )
                    end
                end
            end
        end
    end

    sort_files(merged)

    return merged
end

--- @param roots string[]
--- @return table[]
function FilePicker:_refresh_files_for_roots(roots)
    self._root = roots[1] or self:_resolve_scan_root()
    self._files = self:_merge_cached_files_for_roots(roots)
    return self._files
end

--- @param roots string[]
--- @param callback fun(items: table[])
--- @param transform fun(items: table[]): table[]
function FilePicker:_request_items_for_roots(roots, callback, transform)
    local request_key = get_roots_key(roots)
    self._roots_key = request_key

    callback(transform(self:_refresh_files_for_roots(roots)))

    for _, root in ipairs(roots) do
        local cache = self:_get_cached_files(root)
        local needs_scan = cache == nil
            or cache.scanning
            or not self:_cache_is_fresh(root)

        if needs_scan then
            self:_scan_files_async(root, function()
                if
                    not vim.api.nvim_buf_is_valid(self._bufnr)
                    or self._roots_key ~= request_key
                then
                    return
                end

                callback(transform(self:_refresh_files_for_roots(roots)))
            end)
        end
    end
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

--- @param query string
--- @param callback fun(items: table[])
function FilePicker:request_completion_items(query, callback)
    local roots = self:_resolve_search_roots()
    self:_request_items_for_roots(roots, callback, function()
        return self:_filter_completion_items(query)
    end)
end

--- Returns the raw cached source items for blink to fuzzy match itself.
--- @param callback fun(items: table[])
function FilePicker:request_source_items(callback)
    local roots = self:_resolve_search_roots()
    self:_request_items_for_roots(roots, callback, function(items)
        return items
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
                    callback(
                        self:_build_file_items(
                            result.stdout,
                            root,
                            command_needs_existing_file_filter(cmd_parts)
                        )
                    )
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
        callback(
            self:_build_file_items(
                output,
                root,
                command_needs_existing_file_filter(cmd_parts)
            )
        )
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
            local files = self:_build_file_items(
                output,
                root,
                command_needs_existing_file_filter(cmd_parts)
            )
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

    local git_marker = vim.uv.fs_stat(root .. "/.git")
    if is_executable(FilePicker.CMD_GIT[1]) and git_marker then
        table.insert(commands, {
            "git",
            "-C",
            root,
            unpack(FilePicker.CMD_GIT, 2),
        })
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

    if is_executable(FilePicker.CMD_RG[1]) then
        local cmd = vim.list_extend({}, FilePicker.CMD_RG)
        if include_hidden then
            table.insert(cmd, "--hidden")
        end
        table.insert(cmd, root)
        table.insert(commands, cmd)
    end

    if is_executable(FilePicker.CMD_BFS[1]) then
        local cmd = { FilePicker.CMD_BFS[1], root }
        vim.list_extend(cmd, vim.list_slice(FilePicker.CMD_BFS, 2))
        table.insert(commands, cmd)
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
--- @param files table[]
--- @return table<string, boolean>
function FilePicker:_get_gitignored_relative_paths(root, files)
    if #files == 0 or not is_executable(FilePicker.CMD_GIT[1]) then
        return {}
    end

    local git_marker = vim.uv.fs_stat(root .. "/.git")
    if not git_marker then
        return {}
    end

    local relative_paths = {}
    for _, item in ipairs(files) do
        relative_paths[#relative_paths + 1] = item.word:sub(2)
    end

    local output = vim.fn.system({
        "git",
        "-C",
        root,
        "check-ignore",
        "--stdin",
    }, table.concat(relative_paths, "\n"))

    if output == "" then
        return {}
    end

    local ignored = {}
    for line in output:gmatch("[^\n]+") do
        local path = vim.trim(line)
        if path ~= "" then
            ignored[path] = true
        end
    end

    return ignored
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
            local normalized_path = vim.fs.normalize(path)
            local relative_path = to_root_relative_path(root, normalized_path)
            if not self:_should_exclude(relative_path) then
                if include_hidden or not has_hidden_segment(relative_path) then
                    if not seen[relative_path] then
                        seen[relative_path] = true
                        local item = make_file_item(root, normalized_path)
                        if item then
                            table.insert(files, item)
                        end
                    end
                end
            end
        end
    end

    local gitignored_paths = self:_get_gitignored_relative_paths(root, files)
    for _, item in ipairs(files) do
        item._gitignored_priority = gitignored_paths[item.word:sub(2)] and 1
            or 0
    end

    sort_files(files)

    return files
end

--- @param bufnr integer
--- @return agentic.ui.FilePicker|nil
function FilePicker.get_instance(bufnr)
    return instances_by_buffer[bufnr]
end

FilePicker.get_active_mention = get_active_mention

return FilePicker
