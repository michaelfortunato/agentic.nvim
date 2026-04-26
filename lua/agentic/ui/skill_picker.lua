local Chooser = require("agentic.ui.chooser")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.SkillPicker
--- @field _bufnr integer
--- @field _skills agentic.ui.SkillPicker.Item[]
--- @field _resolve_workspace_root_fn? fun(): string|nil
--- @field _resolve_codex_home_fn? fun(): string|nil
--- @field _enabled? fun(): boolean
--- @field _skip_auto_show_once boolean
local SkillPicker = {}
SkillPicker.__index = SkillPicker

local CACHE_REFRESH_MS = 10000
local BLINK_SOURCE_ID = "agentic_skills"
local blink_provider_registered = false
local blink_filetype_registered = false
local skills_by_cache_key = {}

--- @class agentic.ui.SkillPicker.Opts
--- @field resolve_workspace_root? fun(): string|nil
--- @field resolve_codex_home? fun(): string|nil
--- @field enabled? fun(): boolean

--- @class agentic.ui.SkillPicker.CacheEntry
--- @field skills agentic.ui.SkillPicker.Item[]
--- @field updated_at integer

--- @class agentic.ui.SkillPicker.Item
--- @field name string
--- @field description string
--- @field path string
--- @field source string
--- @field word string
--- @field menu string
--- @field kind string
--- @field icase integer
--- @field filter_text string

--- @class agentic.ui.SkillPicker.BlinkAPI
--- @field show fun(opts: {providers?: string[]}|nil)
--- @field add_source_provider fun(source_id: string, source_config: table)
--- @field add_filetype_source fun(filetype: string, source_id: string)

local instances_by_buffer = setmetatable({}, { __mode = "v" })

--- @return integer
local function now_ms()
    return math.floor(vim.loop.hrtime() / 1e6)
end

--- @param path string|nil
--- @return string|nil
local function normalize_optional_path(path)
    if not path or path == "" then
        return nil
    end

    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

--- @param path string
--- @return string[]
local function read_file_lines(path)
    local ok, lines = pcall(vim.fn.readfile, path, "", 24)
    if not ok or type(lines) ~= "table" then
        return {}
    end

    return lines
end

--- @param lines string[]
--- @return string
local function parse_skill_description(lines)
    local description = nil
    local capture_block = false

    for _, raw_line in ipairs(lines) do
        local line = raw_line:gsub("\r", "")
        local inline_description = line:match("^description:%s*(.+)%s*$")
        if inline_description and inline_description ~= "" then
            return vim.trim(inline_description)
        end

        if line:match("^description:%s*$") then
            capture_block = true
        elseif capture_block then
            if line:match("^%s%s+.+") then
                description = vim.trim((description or "") .. " " .. line)
            elseif line:match("^%-%-%-%s*$") then
                break
            else
                capture_block = false
            end
        end
    end

    if description and description ~= "" then
        return description
    end

    for _, raw_line in ipairs(lines) do
        local line = vim.trim(raw_line:gsub("\r", ""))
        if
            line ~= ""
            and not vim.startswith(line, "#")
            and line ~= "---"
            and not line:match("^[%w_%-]+:%s*$")
        then
            return line
        end
    end

    return ""
end

--- @param path string
--- @return string
local function get_skill_dir_name(path)
    return vim.fs.basename(vim.fs.dirname(path))
end

--- @param path string
--- @param source string
--- @param skill_name string
--- @return agentic.ui.SkillPicker.Item
local function build_skill_item(path, source, skill_name)
    local description = parse_skill_description(read_file_lines(path))

    --- @type agentic.ui.SkillPicker.Item
    local item = {
        name = skill_name,
        description = description,
        path = path,
        source = source,
        word = "$" .. skill_name,
        menu = source,
        kind = "$",
        icase = 1,
        filter_text = skill_name,
    }

    return item
end

--- @param config_path string
--- @return {name: string, source: string}[]
local function get_enabled_plugin_specs(config_path)
    if vim.fn.filereadable(config_path) ~= 1 then
        return {}
    end

    local ok, lines = pcall(vim.fn.readfile, config_path)
    if not ok or type(lines) ~= "table" then
        return {}
    end
    local specs = {}
    local current = nil

    for _, raw_line in ipairs(lines) do
        local line = vim.trim(raw_line)
        local name, source = line:match('^%[plugins%."([^"@]+)@([^"]+)"%]%s*$')
        if name and source then
            current = { name = name, source = source, enabled = false }
            specs[#specs + 1] = current
        elseif line:match("^%[") then
            current = nil
        elseif current then
            local enabled = line:match("^enabled%s*=%s*(%a+)%s*$")
            if enabled ~= nil then
                current.enabled = enabled == "true"
            end
        end
    end

    local enabled_specs = {}
    for _, spec in ipairs(specs) do
        if spec.enabled then
            enabled_specs[#enabled_specs + 1] = {
                name = spec.name,
                source = spec.source,
            }
        end
    end

    return enabled_specs
end

--- @param root string|nil
--- @param pattern string
--- @return string[]
local function glob_files(root, pattern)
    if not root then
        return {}
    end

    local matches = vim.fn.globpath(root, pattern, false, true)
    local normalized = {}

    for _, path in ipairs(matches) do
        normalized[#normalized + 1] = vim.fs.normalize(path)
    end

    return normalized
end

--- @param codex_home string|nil
--- @return agentic.ui.SkillPicker.Item[]
local function discover_global_skills(codex_home)
    if not codex_home then
        return {}
    end

    local items = {}

    for _, path in ipairs(glob_files(codex_home, "skills/*/SKILL.md")) do
        items[#items + 1] =
            build_skill_item(path, "User Skill", get_skill_dir_name(path))
    end

    for _, path in ipairs(glob_files(codex_home, "skills/.system/*/SKILL.md")) do
        items[#items + 1] =
            build_skill_item(path, "System Skill", get_skill_dir_name(path))
    end

    return items
end

--- @param workspace_root string|nil
--- @return agentic.ui.SkillPicker.Item[]
local function discover_project_skills(workspace_root)
    if not workspace_root then
        return {}
    end

    local items = {}
    local pattern = ".agents/skills/*/SKILL.md"

    for _, path in ipairs(glob_files(workspace_root, pattern)) do
        items[#items + 1] =
            build_skill_item(path, "Project Skill", get_skill_dir_name(path))
    end

    return items
end

--- @param codex_home string|nil
--- @return agentic.ui.SkillPicker.Item[]
local function discover_plugin_skills(codex_home)
    if not codex_home then
        return {}
    end

    local config_path = vim.fs.joinpath(codex_home, "config.toml")
    local enabled_plugins = get_enabled_plugin_specs(config_path)
    local items = {}

    for _, plugin in ipairs(enabled_plugins) do
        local cache_root = vim.fs.joinpath(
            codex_home,
            "plugins",
            "cache",
            plugin.source,
            plugin.name
        )
        for _, path in ipairs(glob_files(cache_root, "*/skills/*/SKILL.md")) do
            local skill_name = plugin.name .. ":" .. get_skill_dir_name(path)
            items[#items + 1] =
                build_skill_item(path, "Plugin Skill", skill_name)
        end
    end

    return items
end

--- @param skills agentic.ui.SkillPicker.Item[]
--- @return agentic.ui.SkillPicker.Item[]
local function dedupe_and_sort(skills)
    local deduped = {}
    local seen = {}

    for _, skill in ipairs(skills) do
        if not seen[skill.name] then
            seen[skill.name] = true
            deduped[#deduped + 1] = skill
        end
    end

    table.sort(deduped, function(left, right)
        return left.name:lower() < right.name:lower()
    end)

    return deduped
end

--- @param line string
--- @param cursor_col integer
--- @return { start_col: integer, query: string }|nil
local function get_active_skill_mention(line, cursor_col)
    local before_cursor = line:sub(1, cursor_col)
    local dollar_col = before_cursor:match(".*()%$[^%s]*$")
    if not dollar_col then
        return nil
    end

    if dollar_col > 1 then
        local prefix = before_cursor:sub(dollar_col - 1, dollar_col - 1)
        if not prefix:match("%s") then
            return nil
        end
    end

    return {
        start_col = dollar_col - 1,
        query = before_cursor:sub(dollar_col),
    }
end

--- @param bufnr integer
--- @param opts agentic.ui.SkillPicker.Opts|nil
--- @return agentic.ui.SkillPicker
function SkillPicker:new(bufnr, opts)
    opts = opts or {}

    --- @type agentic.ui.SkillPicker
    local instance = setmetatable({
        _bufnr = bufnr,
        _skills = {},
        _resolve_workspace_root_fn = opts.resolve_workspace_root or function()
            return nil
        end,
        _resolve_codex_home_fn = opts.resolve_codex_home or function()
            return os.getenv("CODEX_HOME") or vim.fn.expand("~/.codex")
        end,
        _enabled = opts.enabled or function()
            return true
        end,
        _skip_auto_show_once = false,
    }, self)

    instances_by_buffer[bufnr] = instance
    instance:_setup_blink_completion(bufnr)

    return instance
end

--- @return boolean
function SkillPicker:is_enabled()
    return self._enabled == nil or self._enabled()
end

--- @return agentic.ui.SkillPicker.BlinkAPI|nil
function SkillPicker:_get_blink()
    local ok, blink = pcall(require, "blink.cmp")
    if not ok then
        return nil
    end

    return blink
end

function SkillPicker:_ensure_blink_registered()
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
                name = "Agentic Skills",
                module = "agentic.ui.skill_picker_blink_source",
                async = false,
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
function SkillPicker:_is_blink_menu_open()
    local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
    if not ok_menu or not menu or not menu.win or not menu.win.is_open then
        return false
    end

    return menu.win:is_open()
end

--- @return string
function SkillPicker:_get_cache_key()
    local workspace_root = normalize_optional_path(
        self._resolve_workspace_root_fn and self._resolve_workspace_root_fn()
            or nil
    ) or ""
    local codex_home = normalize_optional_path(
        self._resolve_codex_home_fn and self._resolve_codex_home_fn() or nil
    ) or ""

    return table.concat({ workspace_root, codex_home }, "::")
end

--- @return agentic.ui.SkillPicker.Item[]
function SkillPicker:_load_skills()
    local cache_key = self:_get_cache_key()
    local cached = skills_by_cache_key[cache_key]

    if cached and (now_ms() - cached.updated_at) <= CACHE_REFRESH_MS then
        self._skills = cached.skills
        return cached.skills
    end

    local workspace_root = normalize_optional_path(
        self._resolve_workspace_root_fn and self._resolve_workspace_root_fn()
            or nil
    )
    local codex_home = normalize_optional_path(
        self._resolve_codex_home_fn and self._resolve_codex_home_fn() or nil
    )

    local skills = dedupe_and_sort(
        vim.list_extend(
            vim.list_extend(
                discover_project_skills(workspace_root),
                discover_global_skills(codex_home)
            ),
            discover_plugin_skills(codex_home)
        )
    )

    skills_by_cache_key[cache_key] = {
        skills = skills,
        updated_at = now_ms(),
    }
    self._skills = skills

    return skills
end

--- @return boolean
function SkillPicker:has_skills()
    if not self:is_enabled() then
        return false
    end

    return #self:_load_skills() > 0
end

--- @param callback fun(items: agentic.ui.SkillPicker.Item[])
function SkillPicker:request_source_items(callback)
    if not self:is_enabled() then
        callback({})
        return
    end

    callback(self:_load_skills())
end

--- @param on_choice fun(choice: agentic.ui.SkillPicker.Item|nil)|nil
--- @return boolean shown
function SkillPicker:show_selector(on_choice)
    if not self:is_enabled() then
        return false
    end

    local skills = self:_load_skills()
    if #skills == 0 then
        Logger.notify(
            "No Codex skills are available for this workspace.",
            vim.log.levels.INFO,
            { title = "Agentic Skills" }
        )
        return false
    end

    return Chooser.show(skills, {
        prompt = "Available Codex skills:",
        format_item = function(item)
            --- @cast item agentic.ui.SkillPicker.Item
            local description = item.description
            if description == "" then
                description = item.source
            else
                description = item.source .. ": " .. description
            end

            return Chooser.format_named_item(item.name, description, false)
        end,
        max_height = math.min(#skills, 12),
    }, on_choice or function() end)
end

--- @param line string
--- @param cursor_col integer
function SkillPicker:_show_completion_if_needed(line, cursor_col)
    if self._skip_auto_show_once then
        self._skip_auto_show_once = false
        return
    end

    if not self:is_enabled() or self:_is_blink_menu_open() then
        return
    end

    local mention = get_active_skill_mention(line, cursor_col)
    if not mention then
        return
    end

    local blink = self:_ensure_blink_registered()
    if not blink then
        return
    end

    blink.show({
        providers = { BLINK_SOURCE_ID },
    })
end

function SkillPicker:skip_next_auto_show()
    self._skip_auto_show_once = true
    vim.schedule(function()
        if self._skip_auto_show_once then
            self._skip_auto_show_once = false
        end
    end)
end

--- @param bufnr integer
function SkillPicker:_setup_blink_completion(bufnr)
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

            self:_show_completion_if_needed(line, cursor[2])
        end,
    })
end

--- @param bufnr integer
--- @return agentic.ui.SkillPicker|nil
function SkillPicker.get_instance(bufnr)
    return instances_by_buffer[bufnr]
end

SkillPicker.get_active_skill_mention = get_active_skill_mention

return SkillPicker
