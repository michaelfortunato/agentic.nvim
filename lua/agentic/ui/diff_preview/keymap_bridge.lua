local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ReviewState = require("agentic.ui.diff_preview.review_state")

--- Owns review keymap save/restore and review action bindings.
--- @class agentic.ui.DiffPreview.KeymapBridge
local M = {}

local function get_diff_preview_keymaps()
    local configured = Config.keymaps and Config.keymaps.diff_preview or {}
    local defaults = DefaultConfig.keymaps.diff_preview

    return {
        next_hunk = configured.next_hunk or defaults.next_hunk,
        prev_hunk = configured.prev_hunk or defaults.prev_hunk,
        accept = configured.accept or defaults.accept,
        reject = configured.reject or defaults.reject,
        accept_all = configured.accept_all or defaults.accept_all,
        reject_all = configured.reject_all or defaults.reject_all,
    }
end

--- @param action fun()|nil
local function schedule_review_action(action)
    if not action then
        return
    end

    vim.schedule(action)
end

--- @param bufnr integer
--- @param key string
--- @return table|nil
local function save_buffer_keymap(bufnr, key)
    local ok, keymaps = pcall(vim.api.nvim_buf_get_keymap, bufnr, "n")
    if not ok then
        return nil
    end

    for _, map_info in ipairs(keymaps) do
        if map_info and map_info.lhs == key then
            return map_info
        end
    end

    return nil
end

--- @param bufnr integer
function M.restore_review_keymaps(bufnr)
    local state = ReviewState.peek_review_state(bufnr)
    if not state then
        return
    end

    local review_keymaps = get_diff_preview_keymaps()
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.accept)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.reject)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.accept_all)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", review_keymaps.reject_all)

    if state.saved_keymaps then
        for _, saved_map in pairs(state.saved_keymaps) do
            if saved_map and saved_map.lhs then
                local opts = {}
                if saved_map.noremap == 1 then
                    opts.noremap = true
                end
                if saved_map.silent == 1 then
                    opts.silent = true
                end
                if saved_map.expr == 1 then
                    opts.expr = true
                end
                if saved_map.nowait == 1 then
                    opts.nowait = true
                end

                if saved_map.callback then
                    opts.buffer = bufnr
                    pcall(
                        BufHelpers.keymap_set,
                        bufnr,
                        "n",
                        saved_map.lhs,
                        saved_map.callback,
                        opts
                    )
                elseif saved_map.rhs and saved_map.rhs ~= "" then
                    pcall(
                        vim.api.nvim_buf_set_keymap,
                        bufnr,
                        "n",
                        saved_map.lhs,
                        saved_map.rhs,
                        opts
                    )
                end
            end
        end
    end

    ReviewState.clear_review_state(bufnr)
end

--- @param bufnr integer
--- @param review_actions agentic.ui.DiffPreview.ReviewActions|nil
function M.setup_review_keymaps(bufnr, review_actions)
    if not review_actions then
        return
    end

    local review_keymaps = get_diff_preview_keymaps()
    local state = ReviewState.get_review_state(bufnr)
    state.saved_keymaps.accept =
        save_buffer_keymap(bufnr, review_keymaps.accept)
    state.saved_keymaps.reject =
        save_buffer_keymap(bufnr, review_keymaps.reject)
    state.saved_keymaps.accept_all =
        save_buffer_keymap(bufnr, review_keymaps.accept_all)
    state.saved_keymaps.reject_all =
        save_buffer_keymap(bufnr, review_keymaps.reject_all)

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.accept, function()
        if ReviewState.get_review_session(bufnr) then
            ReviewState.resolve_pending_hunk(bufnr, "accept")
            return ""
        end
        schedule_review_action(review_actions.on_accept)
        return ""
    end, {
        desc = "Agentic Review: Accept diff",
        nowait = true,
        expr = true,
    })

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.reject, function()
        if ReviewState.get_review_session(bufnr) then
            ReviewState.resolve_pending_hunk(bufnr, "reject")
            return ""
        end
        schedule_review_action(review_actions.on_reject)
        return ""
    end, {
        desc = "Agentic Review: Reject diff",
        nowait = true,
        expr = true,
    })

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.accept_all, function()
        schedule_review_action(
            review_actions.on_accept_all or review_actions.on_accept
        )
    end, { desc = "Agentic Review: Accept diff", nowait = true })

    BufHelpers.keymap_set(bufnr, "n", review_keymaps.reject_all, function()
        schedule_review_action(
            review_actions.on_reject_all or review_actions.on_reject
        )
    end, { desc = "Agentic Review: Reject diff", nowait = true })
end

return M
