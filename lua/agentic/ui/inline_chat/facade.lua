local PromptController = require("agentic.ui.inline_chat.prompt_controller")
local RuntimeStore = require("agentic.ui.inline_chat.runtime_store")
local Utils = require("agentic.ui.inline_chat.utils")

--- UI Sync Scopes
--- - Tab-local: one InlineChat runtime per widget/session binding
--- - Window-local: source window affinity for prompt focus restore
--- - Buffer-local: thread store in vim.b[bufnr][THREAD_STORE_KEY], range extmarks, overlays

--- @class agentic.ui.InlineChat.OpenSelection
--- @field file_path string
--- @field start_line integer
--- @field end_line integer

--- @class agentic.ui.InlineChat.PromptState
--- @field prompt_bufnr integer
--- @field prompt_winid integer
--- @field conversation_id? string
--- @field close_cancels_conversation boolean
--- @field selection agentic.Selection
--- @field source_bufnr integer
--- @field source_winid integer

--- @class agentic.ui.InlineChat.ActiveRequest
--- @field conversation_id string
--- @field submission_id? integer
--- @field source_bufnr integer
--- @field source_winid integer
--- @field selection agentic.Selection
--- @field prompt string
--- @field config_context? string
--- @field range_extmark_id integer
--- @field thread_turn_index integer
--- @field phase "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed"
--- @field status_text string
--- @field thought_text string
--- @field message_text string
--- @field tool_label? string
--- @field tool_detail? string
--- @field tool_failed boolean
--- @field overlay_hidden boolean
--- @field progress_id? integer|string

--- @class agentic.ui.InlineChat.RequestInput
--- @field conversation_id? string|nil
--- @field submission_id? integer|nil
--- @field prompt string
--- @field selection agentic.Selection
--- @field source_bufnr integer
--- @field source_winid integer
--- @field phase? "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed"
--- @field status_text? string

--- @class agentic.ui.InlineChat.ThreadTurn
--- @field conversation_id? string
--- @field selection agentic.Selection
--- @field prompt string
--- @field config_context? string
--- @field phase "busy"|"thinking"|"generating"|"tool"|"waiting"|"completed"|"failed"
--- @field status_text string
--- @field thought_text string
--- @field message_text string
--- @field tool_label? string
--- @field tool_detail? string
--- @field tool_failed boolean
--- @field overlay_hidden boolean
--- @field created_at integer
--- @field updated_at integer

--- @class agentic.ui.InlineChat.ThreadState
--- @field extmark_id integer
--- @field source_bufnr integer
--- @field selection agentic.Selection
--- @field turns agentic.ui.InlineChat.ThreadTurn[]
--- @field updated_at integer

--- @alias agentic.ui.InlineChat.ThreadStore table<string, agentic.ui.InlineChat.ThreadState>

--- @class agentic.ui.InlineChat.ThreadRuntime
--- @field source_bufnr integer
--- @field source_winid integer
--- @field range_extmark_id integer
--- @field overlay_extmark_id? integer
--- @field close_timer? uv.uv_timer_t
--- @field sparkle_timer? uv.uv_timer_t
--- @field sparkle_frame? integer

--- @class agentic.ui.InlineChat.NewOpts
--- @field tab_page_id integer
--- @field instance_id? integer
--- @field on_submit fun(request: {conversation_id?: string|nil, prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}): boolean
--- @field on_conversation_exit? fun(conversation_id: string): nil
--- @field on_change_mode? fun(): nil
--- @field on_change_model? fun(): nil
--- @field on_change_thought_level? fun(): nil
--- @field on_change_approval_preset? fun(): nil
--- @field get_config_context? fun(): string|nil

--- @class agentic.ui.InlineChat
--- @field tab_page_id integer
--- @field instance_id? integer
--- @field _on_submit fun(request: {conversation_id?: string|nil, prompt: string, selection: agentic.Selection, source_bufnr: integer, source_winid: integer}): boolean
--- @field _on_conversation_exit fun(conversation_id: string): nil
--- @field _on_change_mode fun(): nil
--- @field _on_change_model fun(): nil
--- @field _on_change_thought_level fun(): nil
--- @field _on_change_approval_preset fun(): nil
--- @field _get_config_context fun(): string|nil
--- @field _prompt? agentic.ui.InlineChat.PromptState
--- @field _active_request? agentic.ui.InlineChat.ActiveRequest
--- @field _active_requests table<string, agentic.ui.InlineChat.ActiveRequest>
--- @field _queued_requests table<integer, agentic.ui.InlineChat.ActiveRequest>
--- @field _thread_runtimes table<string, agentic.ui.InlineChat.ThreadRuntime>
local InlineChat = {}
InlineChat.__index = InlineChat
InlineChat.NS_INLINE = vim.api.nvim_create_namespace("agentic_inline_chat")
InlineChat.NS_INLINE_THREADS =
    vim.api.nvim_create_namespace("agentic_inline_chat_threads")
InlineChat.THREAD_STORE_KEY = "_agentic_inline_threads"

--- @param opts agentic.ui.InlineChat.NewOpts
--- @return agentic.ui.InlineChat
function InlineChat:new(opts)
    local instance = setmetatable({
        tab_page_id = opts.tab_page_id,
        instance_id = opts.instance_id,
        _on_submit = opts.on_submit,
        _on_conversation_exit = opts.on_conversation_exit or function() end,
        _on_change_mode = opts.on_change_mode or function() end,
        _on_change_model = opts.on_change_model or function() end,
        _on_change_thought_level = opts.on_change_thought_level
            or function() end,
        _on_change_approval_preset = opts.on_change_approval_preset
            or function() end,
        _get_config_context = opts.get_config_context or function()
            return nil
        end,
        _prompt = nil,
        _active_request = nil,
        _active_requests = {},
        _queued_requests = {},
        _thread_runtimes = {},
    }, self)

    return instance
end

--- @return boolean
function InlineChat:is_active()
    for _, request in pairs(self._active_requests or {}) do
        if not Utils.is_terminal_phase(request.phase) then
            return true
        end
    end

    return false
end

--- @return boolean
function InlineChat:is_prompt_open()
    return PromptController.is_prompt_open(self)
end

--- @param selection agentic.Selection
--- @param opts {conversation_id?: string|nil, close_cancels_conversation?: boolean|nil, source_bufnr?: integer|nil, source_winid?: integer|nil}|nil
--- @return boolean opened
function InlineChat:open(selection, opts)
    return PromptController.open(self, selection, opts)
end

--- @param request agentic.ui.InlineChat.RequestInput
function InlineChat:queue_request(request)
    RuntimeStore.queue_request(self, request)
end

--- @param queue_items agentic.SessionManager.QueuedSubmission[]
--- @param opts {waiting_for_session?: boolean|nil, interrupt_submission?: agentic.SessionManager.QueuedSubmission|nil}|nil
function InlineChat:sync_queued_requests(queue_items, opts)
    RuntimeStore.sync_queued_requests(self, queue_items, opts)
end

--- @param source_bufnr integer
--- @param selection agentic.Selection
--- @return integer|nil
function InlineChat:find_overlapping_queued_submission(source_bufnr, selection)
    return RuntimeStore.find_overlapping_queued_submission(
        self,
        source_bufnr,
        selection
    )
end

--- @param submission_id integer
--- @return boolean
function InlineChat:remove_queued_submission(submission_id)
    return RuntimeStore.remove_queued_submission(self, submission_id)
end

--- @param request agentic.ui.InlineChat.RequestInput
function InlineChat:begin_request(request)
    RuntimeStore.begin_request(self, request)
end

function InlineChat:refresh()
    RuntimeStore.refresh(self)
end

--- @param update agentic.acp.SessionUpdateMessage
--- @param opts {conversation_id?: string|nil}|nil
function InlineChat:handle_session_update(update, opts)
    RuntimeStore.handle_session_update(self, update, opts)
end

--- @param tool_call table
--- @param opts {conversation_id?: string|nil}|nil
function InlineChat:handle_tool_call(tool_call, opts)
    RuntimeStore.handle_tool_call(self, tool_call, opts)
end

--- @param tool_call table
--- @param opts {conversation_id?: string|nil}|nil
function InlineChat:handle_tool_call_update(tool_call, opts)
    RuntimeStore.handle_tool_call_update(self, tool_call, opts)
end

--- @param opts {conversation_id?: string|nil}|nil
function InlineChat:handle_permission_request(opts)
    RuntimeStore.handle_permission_request(self, opts)
end

--- @param opts {conversation_id?: string|nil, option_id?: string|nil, options?: agentic.acp.PermissionOption[]|nil}
function InlineChat:handle_permission_resolution(opts)
    RuntimeStore.handle_permission_resolution(self, opts)
end

--- @param opts {conversation_id?: string|nil}|nil
function InlineChat:handle_applied_edit(opts)
    RuntimeStore.handle_applied_edit(self, opts)
end

--- @param response agentic.acp.PromptResponse|nil
--- @param err table|nil
--- @param opts {conversation_id?: string|nil}|nil
function InlineChat:complete(response, err, opts)
    RuntimeStore.complete(self, response, err, opts)
end

function InlineChat:clear()
    RuntimeStore.clear(self)
end

--- @param bufnr integer
function InlineChat:clear_buffer(bufnr)
    RuntimeStore.clear_buffer(self, bufnr)
end

--- @return boolean
function InlineChat:has_pending_or_active_requests()
    return RuntimeStore.has_pending_or_active_requests(self)
end

function InlineChat:destroy()
    RuntimeStore.destroy(self)
end

--- @return string
function InlineChat:_build_prompt_footer()
    return PromptController.build_prompt_footer()
end

--- @param restore_focus boolean
function InlineChat:_close_prompt(restore_focus)
    PromptController.close_prompt(self, restore_focus)
end

function InlineChat:_submit_prompt()
    PromptController.submit_prompt(self)
end

return InlineChat
