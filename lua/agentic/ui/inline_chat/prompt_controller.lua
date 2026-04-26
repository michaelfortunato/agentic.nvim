---@diagnostic disable: invisible
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local KeymapHelp = require("agentic.ui.keymap_help")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local Utils = require("agentic.ui.inline_chat.utils")

local M = {}

local KEYMAP_HELP_KEY = "?"

--- @return integer
local function get_prompt_min_height()
    return math.max(1, Config.inline.prompt_height)
end

--- @param prompt agentic.ui.InlineChat.PromptState
--- @return integer
local function get_prompt_max_height(prompt)
    local min_height = get_prompt_min_height()

    if
        not prompt.source_winid
        or not vim.api.nvim_win_is_valid(prompt.source_winid)
    then
        return min_height
    end

    return math.max(
        min_height,
        vim.api.nvim_win_get_height(prompt.source_winid) - 2
    )
end

--- @param prompt agentic.ui.InlineChat.PromptState
local function refresh_prompt_height(prompt)
    if
        not prompt.prompt_winid
        or not vim.api.nvim_win_is_valid(prompt.prompt_winid)
    then
        return
    end

    local min_height = get_prompt_min_height()
    local max_height = get_prompt_max_height(prompt)
    local text_height = vim.api.nvim_win_text_height(prompt.prompt_winid, {
        max_height = max_height,
    })
    local target_height =
        math.max(min_height, math.min(max_height, text_height.all))

    if vim.api.nvim_win_get_height(prompt.prompt_winid) == target_height then
        return
    end

    vim.api.nvim_win_set_config(prompt.prompt_winid, { height = target_height })
end

--- @param bufnr integer|nil
--- @param winid integer|nil
--- @return integer resolved_bufnr
--- @return integer resolved_winid
local function resolve_source_context(bufnr, winid)
    local current_winid = vim.api.nvim_get_current_win()
    local current_bufnr = vim.api.nvim_get_current_buf()

    local resolved_winid = winid
    if
        resolved_winid == nil
        and bufnr ~= nil
        and vim.api.nvim_buf_is_valid(bufnr)
    then
        local visible_winid = vim.fn.bufwinid(bufnr)
        if visible_winid ~= -1 and vim.api.nvim_win_is_valid(visible_winid) then
            resolved_winid = visible_winid
        end
    end

    if
        resolved_winid == nil or not vim.api.nvim_win_is_valid(resolved_winid)
    then
        resolved_winid = current_winid
    end

    local resolved_bufnr = bufnr
    if
        resolved_bufnr == nil
        or not vim.api.nvim_buf_is_valid(resolved_bufnr)
    then
        resolved_bufnr = vim.api.nvim_win_get_buf(resolved_winid)
    end

    if not vim.api.nvim_buf_is_valid(resolved_bufnr) then
        resolved_bufnr = current_bufnr
    end

    return resolved_bufnr, resolved_winid
end

--- @param self agentic.ui.InlineChat
--- @return boolean
function M.is_prompt_open(self)
    return self._prompt ~= nil
        and vim.api.nvim_win_is_valid(self._prompt.prompt_winid)
end

--- @param prompt agentic.ui.InlineChat.PromptState
--- @param mode string|nil
local function refresh_prompt_footer(prompt, mode)
    if
        not prompt.prompt_winid
        or not vim.api.nvim_win_is_valid(prompt.prompt_winid)
    then
        return
    end

    vim.api.nvim_win_set_config(
        prompt.prompt_winid,
        M._build_prompt_footer_config(mode)
    )
end

--- @private
--- @param mode string|nil
--- @return vim.api.keyset.win_config config
function M._build_prompt_footer_config(mode)
    return {
        footer = M.build_prompt_footer(mode),
        footer_pos = "right",
    }
end

--- @param self agentic.ui.InlineChat
--- @param selection agentic.Selection
--- @param opts {conversation_id?: string|nil, close_cancels_conversation?: boolean|nil, source_bufnr?: integer|nil, source_winid?: integer|nil}|nil
--- @return boolean opened
function M.open(self, selection, opts)
    opts = opts or {}
    M.close_prompt(self, true)

    local source_bufnr, source_winid =
        resolve_source_context(opts.source_bufnr, opts.source_winid)

    if vim.api.nvim_get_current_win() ~= source_winid then
        vim.api.nvim_set_current_win(source_winid)
    end

    local normalized_selection =
        Utils.normalize_selection(source_bufnr, selection)
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local prompt_width = math.max(24, Config.inline.prompt_width)
    local win_width = vim.api.nvim_win_get_width(source_winid)
    local width = math.min(prompt_width, math.max(24, win_width - 6))
    local height = get_prompt_min_height()
    local footer_config = M._build_prompt_footer_config(vim.fn.mode())

    vim.bo[prompt_bufnr].buftype = "nofile"
    vim.bo[prompt_bufnr].bufhidden = "wipe"
    vim.bo[prompt_bufnr].buflisted = false
    vim.bo[prompt_bufnr].swapfile = false
    vim.bo[prompt_bufnr].modifiable = true
    vim.bo[prompt_bufnr].filetype = "AgenticInput"
    vim.b[prompt_bufnr]._agentic_session_instance_id = self.instance_id

    vim.api.nvim_buf_set_lines(prompt_bufnr, 0, -1, false, { "" })

    local ok, prompt_winid = pcall(vim.api.nvim_open_win, prompt_bufnr, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " Inline " .. Utils.format_range(normalized_selection) .. " ",
        title_pos = "left",
        footer = footer_config.footer,
        footer_pos = footer_config.footer_pos,
        zindex = 250,
    })

    if not ok then
        Logger.notify(
            "Failed to open inline prompt window.",
            vim.log.levels.ERROR
        )
        pcall(vim.api.nvim_buf_delete, prompt_bufnr, { force = true })
        return false
    end

    vim.wo[prompt_winid].wrap = true
    vim.wo[prompt_winid].linebreak = true
    vim.wo[prompt_winid].winhighlight = "FloatBorder:"
        .. Theme.HL_GROUPS.REVIEW_BANNER_ACCENT

    self._prompt = {
        prompt_bufnr = prompt_bufnr,
        prompt_winid = prompt_winid,
        conversation_id = opts.conversation_id,
        close_cancels_conversation = opts.close_cancels_conversation == true,
        selection = normalized_selection,
        source_bufnr = source_bufnr,
        source_winid = source_winid,
    }

    M.bind_keymaps(self)
    M.bind_autocmds(self)
    refresh_prompt_height(self._prompt)
    vim.cmd("startinsert")
    refresh_prompt_footer(self._prompt, vim.fn.mode())
    return true
end

--- @param self agentic.ui.InlineChat
function M.bind_keymaps(self)
    local prompt = self._prompt
    if not prompt then
        return
    end

    local submit = function()
        self:_submit_prompt()
    end

    BufHelpers.keymap_set(prompt.prompt_bufnr, { "i", "n" }, "<CR>", submit, {
        desc = "Agentic: Submit inline prompt",
    })

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.submit,
        prompt.prompt_bufnr,
        submit,
        { desc = "Agentic: Submit inline prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.close,
        prompt.prompt_bufnr,
        function()
            self:_close_prompt(true)
        end,
        { desc = "Agentic: Close inline prompt" }
    )

    BufHelpers.keymap_set(prompt.prompt_bufnr, "n", "<Esc>", function()
        self:_close_prompt(true)
    end, { desc = "Agentic: Close inline prompt" })

    BufHelpers.multi_keymap_set(KEYMAP_HELP_KEY, prompt.prompt_bufnr, function()
        KeymapHelp.show_for_buffer(prompt.prompt_bufnr)
    end, { desc = "Agentic: Show available keymaps" })

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.change_mode,
        prompt.prompt_bufnr,
        function()
            self._on_change_mode()
        end,
        { desc = "Agentic: Inline mode selector" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.switch_model,
        prompt.prompt_bufnr,
        function()
            self._on_change_model()
        end,
        { desc = "Agentic: Inline model selector" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.switch_thought_level,
        prompt.prompt_bufnr,
        function()
            self._on_change_thought_level()
        end,
        { desc = "Agentic: Inline reasoning selector" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.switch_approval_preset,
        prompt.prompt_bufnr,
        function()
            self._on_change_approval_preset()
        end,
        { desc = "Agentic: Inline approval selector" }
    )
end

--- @param self agentic.ui.InlineChat
function M.bind_autocmds(self)
    local prompt = self._prompt
    if not prompt then
        return
    end

    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = prompt.prompt_bufnr,
        callback = function()
            local current_prompt = self._prompt
            if
                not current_prompt
                or current_prompt.prompt_bufnr ~= prompt.prompt_bufnr
            then
                return
            end

            refresh_prompt_height(current_prompt)
        end,
    })

    vim.api.nvim_create_autocmd("ModeChanged", {
        buffer = prompt.prompt_bufnr,
        callback = function()
            local current_prompt = self._prompt
            if
                not current_prompt
                or current_prompt.prompt_bufnr ~= prompt.prompt_bufnr
            then
                return
            end

            vim.schedule(function()
                local active_prompt = self._prompt
                if
                    not active_prompt
                    or active_prompt.prompt_bufnr ~= prompt.prompt_bufnr
                then
                    return
                end

                refresh_prompt_footer(active_prompt, vim.fn.mode())
            end)
        end,
    })
end

--- @param self agentic.ui.InlineChat
function M.submit_prompt(self)
    local prompt = self._prompt
    if not prompt or not vim.api.nvim_buf_is_valid(prompt.prompt_bufnr) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(prompt.prompt_bufnr, 0, -1, false)
    local text = Utils.sanitize_text(table.concat(lines, "\n"))
    if text == "" then
        Logger.notify("Inline prompt is empty.", vim.log.levels.INFO)
        return
    end

    local accepted = self._on_submit({
        conversation_id = prompt.conversation_id,
        prompt = text,
        selection = vim.deepcopy(prompt.selection),
        source_bufnr = prompt.source_bufnr,
        source_winid = prompt.source_winid,
    })

    if accepted then
        if vim.fn.mode():sub(1, 1) == "i" then
            vim.cmd.stopinsert()
        end
        M.close_prompt(self, true, { submitted = true })
    end
end

--- @param self agentic.ui.InlineChat
--- @param restore_focus boolean
--- @param opts {submitted?: boolean|nil}|nil
function M.close_prompt(self, restore_focus, opts)
    opts = opts or {}
    local prompt = self._prompt
    if not prompt then
        return
    end

    self._prompt = nil

    if
        prompt.prompt_winid and vim.api.nvim_win_is_valid(prompt.prompt_winid)
    then
        pcall(vim.api.nvim_win_close, prompt.prompt_winid, true)
    elseif vim.api.nvim_buf_is_valid(prompt.prompt_bufnr) then
        pcall(vim.api.nvim_buf_delete, prompt.prompt_bufnr, { force = true })
    end

    if
        restore_focus
        and prompt.source_winid
        and vim.api.nvim_win_is_valid(prompt.source_winid)
    then
        vim.api.nvim_set_current_win(prompt.source_winid)
    end

    if
        not opts.submitted
        and prompt.close_cancels_conversation
        and prompt.conversation_id
        and prompt.conversation_id ~= ""
    then
        self._on_conversation_exit(prompt.conversation_id)
    end
end

--- @param mode string|nil
--- @return string
function M.build_prompt_footer(mode)
    local parts = {}
    local current_mode = type(mode) == "string" and mode:sub(1, 1)
        or vim.fn.mode():sub(1, 1)
    local submit_key =
        BufHelpers.find_keymap(Config.keymaps.prompt.submit, current_mode)

    if submit_key == nil and current_mode == "i" then
        submit_key = "<CR>"
    end

    if submit_key then
        parts[#parts + 1] = submit_key .. " submit"
    end

    if current_mode == "n" then
        parts[#parts + 1] = "? keymaps"
    end

    return table.concat(parts, "  ")
end

return M
