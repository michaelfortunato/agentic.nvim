--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentModes = require("agentic.acp.agent_modes")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionEvents = require("agentic.session.session_events")
local SessionState = require("agentic.session.session_state")
local SessionManager = require("agentic.session_manager")

--- @param mode_id string
--- @return agentic.acp.CurrentModeUpdate
local function mode_update(mode_id)
    return { sessionUpdate = "current_mode_update", currentModeId = mode_id }
end

describe("agentic.SessionManager", function()
    describe("_on_session_update: current_mode_update", function()
        --- @type TestStub
        local notify_stub
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local legacy_modes = AgentModes:new()
            legacy_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "code", name = "Code", description = "Coding" },
                },
                currentModeId = "plan",
            })

            session = {
                config_options = {
                    legacy_agent_modes = legacy_modes,
                    get_header_context = function()
                        local current_mode =
                            legacy_modes:get_mode(legacy_modes.current_mode_id)
                        return current_mode and ("Mode: " .. current_mode.name)
                            or nil
                    end,
                },
                chat_history = { title = "" },
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                _render_window_headers = SessionManager._render_window_headers,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("updates state, re-renders header, notifies user", function()
            session:_on_session_update(mode_update("code"))

            assert.equal(
                "code",
                session.config_options.legacy_agent_modes.current_mode_id
            )

            assert.spy(render_header_spy).was.called(2)
            assert.equal("chat", render_header_spy.calls[1][2])
            assert.equal("Mode: Code", render_header_spy.calls[1][3])
            assert.equal("input", render_header_spy.calls[2][2])
            assert.equal("", render_header_spy.calls[2][3])

            assert.spy(notify_stub).was.called(1)
            assert.equal("Mode changed to: code", notify_stub.calls[1][1])
            assert.equal(vim.log.levels.INFO, notify_stub.calls[1][2])
        end)

        it("rejects invalid mode and keeps current state", function()
            session:_on_session_update(mode_update("nonexistent"))

            assert.equal(
                "plan",
                session.config_options.legacy_agent_modes.current_mode_id
            )
            assert.spy(render_header_spy).was.called(0)

            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("_on_session_update: config_option_update", function()
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            keymap_stub:revert()

            session = {
                config_options = config_opts,
                chat_history = { title = "" },
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                _render_window_headers = SessionManager._render_window_headers,
                _handle_new_config_options = SessionManager._handle_new_config_options,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("sets config options and updates header on mode", function()
            --- @type agentic.acp.ConfigOptionsUpdate
            local update = {
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "plan",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            {
                                value = "plan",
                                name = "Plan",
                                description = "",
                            },
                        },
                    },
                },
            }

            session:_on_session_update(update)

            assert.is_not_nil(session.config_options.mode)
            assert.equal("plan", session.config_options.mode.currentValue)
            assert.spy(render_header_spy).was.called(2)
            assert.equal("chat", render_header_spy.calls[1][2])
            assert.equal("Mode: Plan", render_header_spy.calls[1][3])
            assert.equal("input", render_header_spy.calls[2][2])
            assert.equal("", render_header_spy.calls[2][3])
        end)

        it("preserves provider config ordering in the prompt header", function()
            --- @type agentic.acp.ConfigOptionsUpdate
            local update = {
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        id = "thought-1",
                        category = "thought_level",
                        currentValue = "deep",
                        description = "Thought Level",
                        name = "Thought Level",
                        options = {
                            { value = "deep", name = "Deep", description = "" },
                        },
                    },
                    {
                        id = "model-1",
                        category = "model",
                        currentValue = "gpt-5.4",
                        description = "Model",
                        name = "Model",
                        options = {
                            {
                                value = "gpt-5.4",
                                name = "GPT-5.4",
                                description = "",
                            },
                        },
                    },
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "code",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            { value = "code", name = "Code", description = "" },
                        },
                    },
                },
            }

            session:_on_session_update(update)

            assert.equal(
                "Thought Level: Deep | Model: GPT-5.4 | Mode: Code",
                render_header_spy.calls[1][3]
            )
        end)
    end)

    describe("_on_session_update: session_info_update", function()
        --- @type agentic.SessionManager
        local session

        before_each(function()
            local session_state = SessionState:new()
            session_state:dispatch(SessionEvents.set_session_title("Old title"))
            session = {
                session_state = session_state,
                chat_history = session_state:get_history(),
                config_options = {
                    get_header_context = function()
                        return "Mode: Code"
                    end,
                },
                widget = {
                    render_header = function() end,
                },
                _on_session_update = SessionManager._on_session_update,
                _render_window_headers = SessionManager._render_window_headers,
            } --[[@as agentic.SessionManager]]
        end)

        it(
            "updates the stored chat title when the agent sends session info",
            function()
                session:_on_session_update({
                    sessionUpdate = "session_info_update",
                    title = "New session title",
                })

                assert.equal("New session title", session.chat_history.title)
            end
        )
    end)

    describe("_handle_mode_change", function()
        --- @type TestStub
        local notify_stub
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr
        --- @type TestSpy
        local set_config_option_spy

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")
            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )
            keymap_stub:revert()

            config_opts:set_options({
                {
                    id = "mode-1",
                    category = "mode",
                    currentValue = "plan",
                    description = "Mode",
                    name = "Mode",
                    options = {
                        { value = "plan", name = "Plan", description = "" },
                        { value = "code", name = "Code", description = "" },
                    },
                },
            })

            set_config_option_spy = spy.new(
                function(_agent, _session_id, _config_id, _value, callback)
                    callback({
                        configOptions = {
                            {
                                id = "mode-1",
                                category = "mode",
                                currentValue = "code",
                                description = "Mode",
                                name = "Mode",
                                options = {
                                    {
                                        value = "plan",
                                        name = "Plan",
                                        description = "",
                                    },
                                    {
                                        value = "code",
                                        name = "Code",
                                        description = "",
                                    },
                                },
                            },
                        },
                    }, nil)
                end
            )

            session = {
                session_id = "sess-1",
                agent = {
                    set_config_option = set_config_option_spy,
                },
                config_options = config_opts,
                chat_history = { title = "" },
                widget = {
                    render_header = spy.new(function() end),
                    buf_nrs = { chat = test_bufnr },
                },
                _handle_mode_change = SessionManager._handle_mode_change,
                _handle_new_config_options = SessionManager._handle_new_config_options,
                _render_window_headers = SessionManager._render_window_headers,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("uses the provider-advertised config option id", function()
            session:_handle_mode_change("code", false)

            assert.equal("sess-1", set_config_option_spy.calls[1][2])
            assert.equal("mode-1", set_config_option_spy.calls[1][3])
            assert.equal("code", set_config_option_spy.calls[1][4])
        end)
    end)

    describe("_handle_config_option_change", function()
        --- @type TestStub
        local notify_stub
        --- @type agentic.SessionManager
        local session
        --- @type TestSpy
        local set_config_option_spy

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local config_opts = AgentConfigOptions:new(
                {},
                function() end,
                function() end,
                function() end
            )

            config_opts:set_options({
                {
                    id = "thought-1",
                    category = "thought_level",
                    currentValue = "normal",
                    description = "Thought Level",
                    name = "Thought Level",
                    options = {
                        { value = "normal", name = "Normal", description = "" },
                        { value = "deep", name = "Deep", description = "" },
                    },
                },
            })

            set_config_option_spy = spy.new(
                function(_agent, _session_id, _config_id, _value, callback)
                    callback({
                        configOptions = {
                            {
                                id = "thought-1",
                                category = "thought_level",
                                currentValue = "deep",
                                description = "Thought Level",
                                name = "Thought Level",
                                options = {
                                    {
                                        value = "normal",
                                        name = "Normal",
                                        description = "",
                                    },
                                    {
                                        value = "deep",
                                        name = "Deep",
                                        description = "",
                                    },
                                },
                            },
                        },
                    }, nil)
                end
            )

            session = {
                session_id = "sess-2",
                agent = {
                    set_config_option = set_config_option_spy,
                },
                config_options = config_opts,
                chat_history = { title = "" },
                widget = {
                    render_header = function() end,
                },
                _handle_config_option_change = SessionManager._handle_config_option_change,
                _handle_new_config_options = SessionManager._handle_new_config_options,
                _render_window_headers = SessionManager._render_window_headers,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            notify_stub:revert()
        end)

        it(
            "routes generic config options through session/set_config_option",
            function()
                session:_handle_config_option_change("thought-1", "deep")

                assert.equal("sess-2", set_config_option_spy.calls[1][2])
                assert.equal("thought-1", set_config_option_spy.calls[1][3])
                assert.equal("deep", set_config_option_spy.calls[1][4])
                assert.spy(notify_stub).was.called(1)
                assert.equal(
                    "Thought Level changed to: Deep",
                    notify_stub.calls[1][1]
                )
            end
        )

        it(
            "notes that live config changes do not interrupt generation",
            function()
                session.is_generating = true

                session:_handle_config_option_change("thought-1", "deep")

                assert.equal(
                    "Thought Level changed to: Deep. Applies without interrupting the current response.",
                    notify_stub.calls[1][1]
                )
            end
        )

        it("keeps provider config option labels unchanged in notifications", function()
            session.agent.set_config_option =
                function(_agent, _session_id, _config_id, _value, callback)
                    callback({}, nil)
                end

            session.config_options:set_options({
                {
                    id = "approval-1",
                    category = "unknown",
                    currentValue = "read_only",
                    description = "Approval Preset",
                    name = "Approval Preset",
                    options = {
                        {
                            value = "read_only",
                            name = "Read Only",
                            description = "",
                        },
                        {
                            value = "default",
                            name = "Default",
                            description = "",
                        },
                    },
                },
            })

            session:_handle_config_option_change("approval-1", "default")

            assert.equal(
                "Approval Preset changed to: Default",
                notify_stub.calls[1][1]
            )
        end)
    end)

    describe("queued submissions", function()
        --- @type TestStub
        local notify_stub
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            test_bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("queues follow-up prompts submitted while generating", function()
            local session_state = SessionState:new()
            local send_prompt_spy = spy.new(function() end)

            local session = {
                session_id = "sess-queue-1",
                is_generating = true,
                _queued_submissions = {},
                _next_queue_id = 0,
                session_state = session_state,
                chat_history = session_state:get_history(),
                agent = {
                    provider_config = { name = "Codex" },
                    send_prompt = send_prompt_spy,
                },
                todo_list = { close_if_all_completed = function() end },
                code_selection = {
                    is_empty = function()
                        return true
                    end,
                },
                file_list = {
                    is_empty = function()
                        return true
                    end,
                },
                diagnostics_list = {
                    is_empty = function()
                        return true
                    end,
                },
                config_options = {
                    get_header_context = function()
                        return nil
                    end,
                },
                widget = {
                    render_header = function() end,
                    win_nrs = {},
                    buf_nrs = {
                        chat = test_bufnr,
                        input = test_bufnr,
                        queue = test_bufnr,
                    },
                },
                _is_first_message = false,
                _render_window_headers = SessionManager._render_window_headers,
                _sync_queue_panel = function() end,
                _enqueue_submission = SessionManager._enqueue_submission,
                _handle_input_submit = SessionManager._handle_input_submit,
            } --[[@as agentic.SessionManager]]

            session:_handle_input_submit("follow up")

            assert.spy(send_prompt_spy).was.called(0)
            assert.equal(1, #session._queued_submissions)
            assert.equal("follow up", session._queued_submissions[1].input_text)
            assert.equal(
                "Queued follow-up. It will be sent when the agent is ready.",
                notify_stub.calls[1][1]
            )
        end)

        it(
            "drains the next queued submission when the agent becomes ready",
            function()
                local dispatch_spy = spy.new(function() end)
                local queued_submission = {
                    id = 1,
                    input_text = "queued prompt",
                    prompt = {
                        { type = "text", text = "queued prompt" },
                    },
                    message_lines = { "queued prompt" },
                    user_msg = {
                        type = "user",
                        text = "queued prompt",
                        timestamp = 1,
                        provider_name = "Codex",
                    },
                }

                local session = {
                    is_generating = false,
                    _queued_submissions = { queued_submission },
                    _interrupt_submission = nil,
                    _sync_queue_panel = function() end,
                    _dispatch_submission = dispatch_spy,
                    _pop_next_queued_submission = SessionManager._pop_next_queued_submission,
                    _drain_queued_submissions = SessionManager._drain_queued_submissions,
                } --[[@as agentic.SessionManager]]

                session:_drain_queued_submissions()

                assert.equal(0, #session._queued_submissions)
                assert.spy(dispatch_spy).was.called(1)
                assert.equal(queued_submission, dispatch_spy.calls[1][2])
            end
        )

        it("formats /review prompts as review requests in the transcript", function()
            local session_state = SessionState:new()
            local dispatch_spy = spy.new(function() end)

            local session = {
                session_id = "sess-review-1",
                is_generating = false,
                _queued_submissions = {},
                _next_queue_id = 0,
                session_state = session_state,
                chat_history = session_state:get_history(),
                agent = {
                    provider_config = { name = "Codex" },
                },
                todo_list = { close_if_all_completed = function() end },
                code_selection = {
                    is_empty = function()
                        return true
                    end,
                },
                file_list = {
                    is_empty = function()
                        return true
                    end,
                },
                diagnostics_list = {
                    is_empty = function()
                        return true
                    end,
                },
                config_options = {
                    get_header_context = function()
                        return nil
                    end,
                },
                widget = {
                    render_header = function() end,
                    win_nrs = {},
                    buf_nrs = {
                        chat = test_bufnr,
                        input = test_bufnr,
                        queue = test_bufnr,
                    },
                },
                _is_first_message = false,
                _dispatch_submission = dispatch_spy,
                _render_window_headers = function() end,
                _handle_input_submit = SessionManager._handle_input_submit,
            } --[[@as agentic.SessionManager]]

            session:_handle_input_submit("/review focus on chat_history.lua")

            assert.spy(dispatch_spy).was.called(1)

            local submission = dispatch_spy.calls[1][2]
            assert.truthy(vim.startswith(submission.message_lines[1], "Review · "))
            assert.equal("focus on chat_history.lua", submission.message_lines[2])
            assert.equal(2, #submission.message_lines)
        end)

        it("resizes the queue panel when queued count changes while visible", function()
            local resize_spy = spy.new(function()
                return true
            end)
            local set_items_spy = spy.new(function() end)
            local render_header_spy = spy.new(function() end)
            local refresh_layout_spy = spy.new(function() end)

            local session = {
                _queued_submissions = {
                    { id = 1, input_text = "first" },
                    { id = 2, input_text = "second" },
                },
                queue_list = {
                    set_items = set_items_spy,
                },
                widget = {
                    win_nrs = {},
                    is_open = function()
                        return true
                    end,
                    render_header = render_header_spy,
                    resize_optional_window = resize_spy,
                    refresh_layout = refresh_layout_spy,
                },
                _render_window_headers = function() end,
                _sync_queue_panel = SessionManager._sync_queue_panel,
            } --[[@as agentic.SessionManager]]

            session:_sync_queue_panel(true)

            assert.spy(set_items_spy).was.called(1)
            assert.equal("queue", render_header_spy.calls[1][2])
            assert.equal("2", render_header_spy.calls[1][3])
            assert.spy(resize_spy).was.called(1)
            assert.equal("queue", resize_spy.calls[1][2])
            assert.equal(
                Config.windows.queue.max_height,
                resize_spy.calls[1][3]
            )
            assert.spy(refresh_layout_spy).was.called(0)
        end)

        it("rebuilds layout if direct queue resize does not take", function()
            local resize_spy = spy.new(function()
                return false
            end)
            local refresh_layout_spy = spy.new(function() end)

            local session = {
                _queued_submissions = {
                    { id = 1, input_text = "first" },
                    { id = 2, input_text = "second" },
                    { id = 3, input_text = "third" },
                },
                queue_list = {
                    set_items = function() end,
                },
                widget = {
                    win_nrs = {},
                    is_open = function()
                        return true
                    end,
                    render_header = function() end,
                    resize_optional_window = resize_spy,
                    refresh_layout = refresh_layout_spy,
                },
                _render_window_headers = function() end,
                _sync_queue_panel = SessionManager._sync_queue_panel,
            } --[[@as agentic.SessionManager]]

            session:_sync_queue_panel(true)

            assert.spy(resize_spy).was.called(1)
            assert.spy(refresh_layout_spy).was.called(1)
        end)
    end)

    describe("_generate_welcome_header", function()
        it(
            "returns header with provider name, session id, and timestamp",
            function()
                local header = SessionManager._generate_welcome_header(
                    "Claude ACP",
                    "abc123"
                )

                assert.truthy(header:match("^Agentic · Claude ACP\n"))
                assert.truthy(header:match("\nSession · abc123\n"))
                assert.truthy(header:match("\nStarted · %d%d%d%d%-%d%d%-%d%d"))
            end
        )

        it("uses 'unknown' when session_id is nil", function()
            local header =
                SessionManager._generate_welcome_header("Claude ACP", nil)

            assert.truthy(header:match("^Agentic · Claude ACP\n"))
            assert.truthy(header:match("\nSession · unknown\n"))
        end)

        it("includes version when provided", function()
            local header = SessionManager._generate_welcome_header(
                "Claude ACP",
                "abc123",
                "1.2.3"
            )

            assert.truthy(header:match("^Agentic · Claude ACP v1%.2%.3\n"))
            assert.truthy(header:match("\nSession · abc123\n"))
        end)

        it("omits version when nil", function()
            local header = SessionManager._generate_welcome_header(
                "Claude ACP",
                "abc123",
                nil
            )

            assert.truthy(header:match("^Agentic · Claude ACP\n"))
            assert.is_nil(header:match(" v"))
        end)
    end)

    describe("_handle_permission_request", function()
        it(
            "marks review state, queues approval, and shows waiting activity",
            function()
                local session_state = SessionState:new()
                local start_spy = spy.new(function() end)
                local add_request_spy = spy.new(function() end)
                local observed_queue_length = nil

                session_state:dispatch(SessionEvents.upsert_tool_call({
                    tool_call_id = "tc-perm-1",
                    kind = "edit",
                    status = "pending",
                    file_path = "/tmp/demo.lua",
                    diff = { old = { "a" }, new = { "b" } },
                }))

                local session = {
                    session_state = session_state,
                    is_generating = true,
                    status_animation = { start = start_spy },
                    permission_manager = {
                        add_request = function(_self, request, callback)
                            session_state:dispatch(
                                SessionEvents.enqueue_permission(
                                    request,
                                    callback
                                )
                            )
                            session_state:dispatch(
                                SessionEvents.show_next_permission()
                            )
                            observed_queue_length =
                                #session_state:get_state().permissions.queue
                            add_request_spy(request, callback)
                        end,
                    },
                    _set_chat_activity = SessionManager._set_chat_activity,
                    _clear_chat_activity = SessionManager._clear_chat_activity,
                    _get_active_tool_activity = SessionManager._get_active_tool_activity,
                    _refresh_chat_activity = SessionManager._refresh_chat_activity,
                    _handle_permission_request = SessionManager._handle_permission_request,
                } --[[@as agentic.SessionManager]]

                session:_handle_permission_request({
                    toolCall = { toolCallId = "tc-perm-1" },
                    options = {
                        {
                            optionId = "allow-once",
                            name = "Allow once",
                            kind = "allow_once",
                        },
                    },
                }, function() end)

                assert.equal(0, observed_queue_length)
                assert.spy(start_spy).was.called_with(
                    session.status_animation,
                    "waiting"
                )
                assert.spy(add_request_spy).was.called(1)

                local state = session_state:get_state()
                assert.equal(
                    "requested",
                    state.tools.by_id["tc-perm-1"].permission_state
                )
                assert.equal("tc-perm-1", state.review.active_tool_call_id)
            end
        )
    end)

    describe("chat activity state", function()
        it("switches between thinking and working as chunks arrive", function()
            local start_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local session = {
                agent = { provider_config = { name = "Codex ACP" } },
                is_generating = true,
                session_state = SessionState:new(),
                status_animation = { start = start_spy },
                message_writer = { write_message_chunk = write_chunk_spy },
                _set_chat_activity = SessionManager._set_chat_activity,
                _clear_chat_activity = SessionManager._clear_chat_activity,
                _get_active_tool_activity = SessionManager._get_active_tool_activity,
                _refresh_chat_activity = SessionManager._refresh_chat_activity,
                _on_session_update = SessionManager._on_session_update,
            } --[[@as agentic.SessionManager]]

            session:_on_session_update({
                sessionUpdate = "agent_thought_chunk",
                content = { text = "thinking..." },
            })

            assert.equal("thinking", session._agent_phase)
            assert.spy(start_spy).was.called_with(
                session.status_animation,
                "thinking"
            )

            session:_on_session_update({
                sessionUpdate = "agent_message_chunk",
                content = { text = "working..." },
            })

            assert.equal("generating", session._agent_phase)
            assert.spy(start_spy).was.called_with(
                session.status_animation,
                "generating"
            )
        end)

        it("shows tool activity while a read tool is in progress", function()
            local start_spy = spy.new(function() end)
            local session = {
                is_generating = true,
                _agent_phase = "thinking",
                session_state = SessionState:new(),
                status_animation = { start = start_spy, stop = function() end },
                permission_manager = {
                    remove_request_by_tool_call_id = spy.new(function() end),
                },
                message_writer = {
                    tool_call_blocks = {},
                    update_tool_call_block = spy.new(function() end),
                    write_tool_call_block = spy.new(function() end),
                },
                _set_chat_activity = SessionManager._set_chat_activity,
                _clear_chat_activity = SessionManager._clear_chat_activity,
                _get_active_tool_activity = SessionManager._get_active_tool_activity,
                _refresh_chat_activity = SessionManager._refresh_chat_activity,
                _on_tool_call = SessionManager._on_tool_call,
                _on_tool_call_update = SessionManager._on_tool_call_update,
            } --[[@as agentic.SessionManager]]

            session:_on_tool_call({
                tool_call_id = "tc-read",
                kind = "read",
                status = "in_progress",
            })

            assert.spy(start_spy).was.called_with(
                session.status_animation,
                "searching"
            )

            session:_on_tool_call_update({
                tool_call_id = "tc-read",
                kind = "read",
                status = "completed",
            })

            assert.spy(start_spy).was.called_with(
                session.status_animation,
                "thinking"
            )
        end)
    end)

    describe("switch_provider", function()
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local schedule_stub
        local original_provider

        before_each(function()
            original_provider = Config.provider
            notify_stub = spy.stub(Logger, "notify")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.provider = original_provider
            schedule_stub:revert()
            notify_stub:revert()
            if get_instance_stub then
                get_instance_stub:revert()
                get_instance_stub = nil
            end
        end)

        it("blocks when is_generating is true", function()
            local session = {
                is_generating = true,
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            assert.spy(notify_stub).was.called(1)
            local msg = notify_stub.calls[1][1]
            assert.truthy(msg:match("[Gg]enerating"))
        end)

        it(
            "soft cancels old session without clearing widget/history",
            function()
                local cancel_spy = spy.new(function() end)
                local permission_clear_spy = spy.new(function() end)
                local status_stop_spy = spy.new(function() end)
                local todo_clear_spy = spy.new(function() end)
                local widget_clear_spy = spy.new(function() end)
                local file_list_clear_spy = spy.new(function() end)
                local code_selection_clear_spy = spy.new(function() end)

                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local new_session_spy = spy.new(function() end)

                local original_messages = { { type = "user", text = "hello" } }
                local mock_chat_history = {
                    messages = original_messages,
                    session_id = "old-session",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = cancel_spy,
                        provider_config = { name = "Old Provider" },
                    },
                    permission_manager = { clear = permission_clear_spy },
                    status_animation = { stop = status_stop_spy },
                    todo_list = { clear = todo_clear_spy },
                    widget = { clear = widget_clear_spy },
                    file_list = { clear = file_list_clear_spy },
                    code_selection = { clear = code_selection_clear_spy },
                    chat_history = mock_chat_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                assert.spy(cancel_spy).was.called(1)
                assert.is_nil(session.session_id)
                assert.spy(permission_clear_spy).was.called(1)
                assert.spy(status_stop_spy).was.called(1)
                assert.spy(todo_clear_spy).was.called(1)

                assert.spy(widget_clear_spy).was.called(0)
                assert.spy(file_list_clear_spy).was.called(0)
                assert.spy(code_selection_clear_spy).was.called(0)

                assert.equal(mock_new_agent, session.agent)

                assert.spy(new_session_spy).was.called(1)
                local opts = new_session_spy.calls[1][2]
                assert.is_true(opts.restore_mode)
                assert.equal("function", type(opts.on_created))
            end
        )

        it(
            "schedules history resend and sets _is_first_message in on_created",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                local original_messages = { { type = "user", text = "hello" } }
                local saved_history = {
                    messages = original_messages,
                    session_id = "old",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    status_animation = { stop = function() end },
                    todo_list = { clear = function() end },
                    session_state = SessionState:new({
                        chat_history = saved_history,
                    }),
                    chat_history = saved_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                assert.is_not_nil(captured_on_created)

                local new_timestamp = os.time()
                session.chat_history = {
                    messages = {},
                    session_id = "new",
                    timestamp = new_timestamp,
                }
                captured_on_created()

                assert.same(original_messages, session.chat_history.messages)
                assert.equal("new", session.chat_history.session_id)
                assert.equal(new_timestamp, session.chat_history.timestamp)
                assert.same(original_messages, session._history_to_send)
                assert.is_true(session._is_first_message)
            end
        )

        it("no-ops soft cancel when session_id is nil", function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local mock_agent = {
                provider_config = { name = "Provider" },
                cancel_session = spy.new(function() end),
                create_session = spy.new(function() end),
            }
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(_provider, on_ready)
                on_ready(mock_agent)
                return mock_agent
            end)

            Config.provider = "some-provider"

            local session = {
                is_generating = false,
                session_id = nil,

                agent = mock_agent,
                permission_manager = { clear = spy.new(function() end) },
                status_animation = { stop = spy.new(function() end) },
                todo_list = { clear = spy.new(function() end) },
                chat_history = { messages = {} },
                _is_first_message = false,
                _history_to_send = nil,
                new_session = spy.new(function() end),
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            assert.spy(mock_agent.cancel_session).was.called(0)
            assert.spy(session.permission_manager.clear).was.called(1)
            assert.spy(session.status_animation.stop).was.called(1)
            assert.spy(session.todo_list.clear).was.called(1)
            assert.spy(session.new_session).was.called(1)
        end)
    end)

    describe("FileChangedShell autocommand", function()
        local Child = require("tests.helpers.child")
        local child = Child:new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it("sets fcs_choice to reload when FileChangedShell fires", function()
            child.v.fcs_choice = ""
            child.api.nvim_exec_autocmds("FileChangedShell", {
                group = "AgenticCleanup",
                pattern = "*",
            })

            assert.equal("reload", child.v.fcs_choice)
        end)
    end)

    describe("on_tool_call_update: buffer reload", function()
        --- @type TestStub
        local checktime_stub
        --- @type TestStub
        local schedule_stub

        --- @param tool_call_blocks table<string, table>
        --- @return agentic.SessionManager
        local function make_session(tool_call_blocks)
            return {
                session_state = SessionState:new(),
                permission_manager = {
                    remove_request_by_tool_call_id = spy.new(function() end),
                },
                status_animation = {
                    start = spy.new(function() end),
                },
                message_writer = {
                    tool_call_blocks = tool_call_blocks,
                    update_tool_call_block = spy.new(function() end),
                    write_tool_call_block = spy.new(function() end),
                },
            } --[[@as agentic.SessionManager]]
        end

        before_each(function()
            checktime_stub = spy.stub(vim.cmd, "checktime")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            checktime_stub:revert()
            schedule_stub:revert()
        end)

        it("calls checktime for each file-mutating kind", function()
            for _, kind in ipairs({
                "edit",
                "create",
                "write",
                "delete",
                "move",
            }) do
                checktime_stub:reset()
                local tc_id = "tc-" .. kind
                local session = make_session({
                    [tc_id] = { kind = kind, status = "in_progress" },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = tc_id, status = "completed" }
                )

                assert.spy(checktime_stub).was.called(1)
            end
        end)

        it("does not call checktime for failed tool calls", function()
            local session = make_session({
                ["tc-1"] = { kind = "edit", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "failed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime for non-mutating kinds", function()
            local session = make_session({
                ["tc-1"] = { kind = "read", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime when tracker is missing", function()
            local debug_stub = spy.stub(Logger, "debug")
            local session = make_session({})

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-missing", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
            debug_stub:revert()
        end)
    end)
end)
