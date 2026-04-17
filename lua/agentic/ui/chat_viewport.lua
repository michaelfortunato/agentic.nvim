local Config = require("agentic.config")

--- @class agentic.ui.ChatViewport.Opts
--- @field tab_page_id integer
--- @field get_chat_winid fun(): integer|nil
--- @field set_unread_context fun(context: string|nil)

--- @class agentic.ui.ChatViewport
--- @field tab_page_id integer
--- @field _get_chat_winid fun(): integer|nil
--- @field _set_unread_context fun(context: string|nil)
--- @field _follow_output boolean
--- @field _has_unread_output boolean
--- @field _saved_view? vim.fn.winsaveview.ret
--- @field _scroll_tracking_augroup integer
--- @field _message_writer? agentic.ui.MessageWriter
--- @field _message_writer_listener_id? integer
local ChatViewport = {}
ChatViewport.__index = ChatViewport

--- @param winid integer|nil
local function scroll_window_to_bottom(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    local last_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_win_set_cursor(winid, { last_line, 0 })
    vim.api.nvim_win_call(winid, function()
        vim.cmd("normal! zb")
    end)
end

--- @param opts agentic.ui.ChatViewport.Opts
--- @return agentic.ui.ChatViewport
function ChatViewport:new(opts)
    local instance = setmetatable({
        tab_page_id = opts.tab_page_id,
        _get_chat_winid = opts.get_chat_winid,
        _set_unread_context = opts.set_unread_context,
        _follow_output = true,
        _has_unread_output = false,
        _saved_view = nil,
        _scroll_tracking_augroup = 0,
        _message_writer = nil,
        _message_writer_listener_id = nil,
    }, self)

    instance:_bind_scroll_tracking()

    return instance
end

function ChatViewport:destroy()
    self:unbind_message_writer()

    if self._scroll_tracking_augroup ~= 0 then
        pcall(vim.api.nvim_del_augroup_by_id, self._scroll_tracking_augroup)
        self._scroll_tracking_augroup = 0
    end
end

function ChatViewport:_refresh_unread_context()
    local context = self._has_unread_output and "New output below" or nil
    self._set_unread_context(context)
end

function ChatViewport:_mark_output_unread()
    if self:should_follow_output() then
        self._has_unread_output = false
    else
        self._has_unread_output = true
    end

    self:_refresh_unread_context()
end

function ChatViewport:_clear_unread_output()
    if not self._has_unread_output then
        self:_refresh_unread_context()
        return
    end

    self._has_unread_output = false
    self:_refresh_unread_context()
end

--- @param message_writer agentic.ui.MessageWriter
function ChatViewport:bind_message_writer(message_writer)
    self:unbind_message_writer()
    self._message_writer = message_writer
    self._message_writer_listener_id = message_writer:add_content_changed_listener(
        function()
            self:_mark_output_unread()
        end
    )
end

function ChatViewport:unbind_message_writer()
    if self._message_writer then
        self._message_writer:remove_content_changed_listener(
            self._message_writer_listener_id
        )
    end

    self._message_writer = nil
    self._message_writer_listener_id = nil
end

--- @return boolean
function ChatViewport:_is_auto_scroll_enabled()
    local threshold = Config.auto_scroll and Config.auto_scroll.threshold
    return threshold ~= nil and threshold > 0
end

--- @param winid integer|nil
--- @return boolean
function ChatViewport:_is_window_near_bottom(winid)
    if not self:_is_auto_scroll_enabled() then
        return false
    end

    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return true
    end

    local threshold = Config.auto_scroll.threshold
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local last_visible_line = vim.api.nvim_win_call(winid, function()
        return vim.fn.line("w$")
    end)

    return total_lines - last_visible_line <= threshold
end

--- @return boolean
function ChatViewport:update_follow_output()
    if not self:_is_auto_scroll_enabled() then
        self._follow_output = false
        self:_clear_unread_output()
        return false
    end

    local winid = self._get_chat_winid()
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return self._follow_output
    end

    self._follow_output = self:_is_window_near_bottom(winid)
    if self._follow_output then
        self:_clear_unread_output()
    else
        self:_refresh_unread_context()
    end

    return self._follow_output
end

function ChatViewport:store_view()
    local winid = self._get_chat_winid()
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    self._saved_view = vim.api.nvim_win_call(winid, function()
        return vim.fn.winsaveview()
    end)
end

function ChatViewport:restore_view()
    local winid = self._get_chat_winid()
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    if self:should_follow_output() then
        self:scroll_to_bottom()
        return
    end

    if self._saved_view then
        vim.api.nvim_win_call(winid, function()
            vim.fn.winrestview(self._saved_view)
        end)
    end

    self:update_follow_output()
end

--- @return boolean
function ChatViewport:should_follow_output()
    if not self:_is_auto_scroll_enabled() then
        return false
    end

    return self._follow_output
end

function ChatViewport:scroll_to_bottom()
    if self:_is_auto_scroll_enabled() then
        self._follow_output = true
    end

    self:_clear_unread_output()
    scroll_window_to_bottom(self._get_chat_winid())
    self:store_view()
end

function ChatViewport:_bind_scroll_tracking()
    self._scroll_tracking_augroup = vim.api.nvim_create_augroup(
        "agentic_chat_scroll_" .. tostring(self.tab_page_id),
        { clear = true }
    )

    vim.api.nvim_create_autocmd("WinScrolled", {
        group = self._scroll_tracking_augroup,
        pattern = "*",
        callback = function(args)
            local chat_winid = self._get_chat_winid()
            if
                not chat_winid
                or not vim.api.nvim_win_is_valid(chat_winid)
                or args.match ~= tostring(chat_winid)
            then
                return
            end

            self:update_follow_output()
            self:store_view()
        end,
    })
end

return ChatViewport
