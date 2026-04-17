local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local WindowDecoration = require("agentic.ui.window_decoration")

--- Controller for chat widget header state and header-related autocmds.
--- @class agentic.ui.ChatWidget.HeaderController
--- @field widget any
--- @field _augroup? integer
local HeaderController = {}
HeaderController.__index = HeaderController

local KEYMAP_HELP_SUFFIX = "?: keymaps"

--- @param mode string
--- @return string|nil
local function build_input_suffix(mode)
    local parts = { KEYMAP_HELP_SUFFIX }
    local submit_key =
        BufHelpers.find_keymap(Config.keymaps.prompt.submit, mode)

    if submit_key ~= nil then
        parts[#parts + 1] = string.format("%s: submit", submit_key)
    end

    return table.concat(parts, " · ")
end

--- @param widget any
--- @return agentic.ui.ChatWidget.HeaderController
function HeaderController:new(widget)
    return setmetatable({
        widget = widget,
        _augroup = nil,
    }, self)
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @return string|nil
function HeaderController:get_effective_header_context(window_name)
    local overlay = self.widget._header_overlays[window_name]
    local base = self.widget._header_contexts[window_name]

    if overlay and overlay ~= "" then
        if base and base ~= "" then
            return string.format("%s · %s", overlay, base)
        end

        return overlay
    end

    return base
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil
function HeaderController:set_header_overlay(window_name, context)
    self.widget._header_overlays[window_name] = context
    self:render_header(window_name)
end

function HeaderController:refresh_header_keymap_hints()
    if not self.widget.headers then
        return
    end

    self.widget.headers.chat.suffix = KEYMAP_HELP_SUFFIX
    self.widget.headers.input.suffix = build_input_suffix(vim.fn.mode())
end

function HeaderController:bind_events_to_change_headers()
    if self._augroup and self._augroup ~= 0 then
        pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
    end

    self._augroup = vim.api.nvim_create_augroup(
        "agentic_chat_widget_headers_" .. tostring(self.widget.tab_page_id),
        { clear = true }
    )

    local function refresh_header_hints()
        self:refresh_header_keymap_hints()
        self:render_header("chat")
        self:render_header("input")
    end

    refresh_header_hints()

    for _, bufnr in ipairs({
        self.widget.buf_nrs.chat,
        self.widget.buf_nrs.input,
    }) do
        vim.api.nvim_create_autocmd("ModeChanged", {
            group = self._augroup,
            buffer = bufnr,
            callback = function()
                vim.schedule(function()
                    refresh_header_hints()
                end)
            end,
        })
    end
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil
function HeaderController:render_header(window_name, context)
    local bufnr = self.widget.buf_nrs[window_name]
    if not bufnr then
        return
    end

    if context ~= nil then
        self.widget._header_contexts[window_name] = context
    end

    local header = self.widget.headers and self.widget.headers[window_name]
        or nil
    if not header then
        return
    end

    local rendered_header = vim.deepcopy(header)
    rendered_header.context = self:get_effective_header_context(window_name)

    WindowDecoration.render_header(bufnr, window_name, rendered_header, {
        name_suffix = self.widget.instance_id and ("#" .. tostring(
            self.widget.instance_id
        )) or nil,
    })
end

function HeaderController:destroy()
    if self._augroup and self._augroup ~= 0 then
        pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
    end

    self._augroup = nil
end

return HeaderController
