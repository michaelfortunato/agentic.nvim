--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch, redundant-parameter, unused-local
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local PromptBuilder = require("agentic.session.prompt_builder")
local SessionEvents = require("agentic.session.session_events")
local SessionState = require("agentic.session.session_state")
local SubmissionQueue = require("agentic.session.submission_queue")
local SessionManager = require("agentic.session_manager")

describe("agentic.SessionManager", function()
    --- @param session_state agentic.session.SessionState
    --- @param text string|nil
    local function seed_request(session_state, text)
        text = text or "test request"
        session_state:dispatch(SessionEvents.append_interaction_request({
            kind = "user",
            text = text,
            timestamp = 1,
            content = {
                { type = "text", text = text },
            },
        }))
    end

    --- @param predicate fun(): boolean
    local function wait_for(predicate)
        assert.is_true(vim.wait(100, predicate))
    end

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
            local session_state = SessionState:new()

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end
            )

            keymap_stub:revert()

            session = {
                session_state = session_state,
                config_options = config_opts,
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

            assert.is_not_nil(session.config_options:get_mode_option())
            assert.equal(
                "plan",
                session.config_options:get_mode_option().currentValue
            )
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

                assert.equal(
                    "New session title",
                    session.session_state:get_state().session.title
                )
            end
        )
    end)

    describe("_on_session_update: current_mode_update", function()
        local session
        local test_bufnr

        before_each(function()
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")
            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
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

            local session_state = SessionState:new()
            session = {
                session_state = session_state,
                config_options = config_opts,
                widget = {
                    render_header = function() end,
                },
                _on_session_update = SessionManager._on_session_update,
                _render_window_headers = SessionManager._render_window_headers,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it(
            "updates the tracked current mode when the agent switches modes",
            function()
                session:_on_session_update({
                    sessionUpdate = "current_mode_update",
                    currentModeId = "code",
                })

                assert.equal(
                    "code",
                    session.session_state:get_state().session.current_mode_id
                )
                assert.equal(
                    "code",
                    session.config_options:get_mode_option().currentValue
                )
            end
        )
    end)

    describe("_on_session_update: usage_update", function()
        it("accepts usage telemetry without warning", function()
            local notify_stub = spy.stub(Logger, "notify")

            local session = {
                session_state = SessionState:new(),
                _on_session_update = SessionManager._on_session_update,
            } --[[@as agentic.SessionManager]]

            --- @type agentic.acp.UsageUpdate
            local update = {
                sessionUpdate = "usage_update",
                used = 2048,
                size = 128000,
                cost = {
                    amount = 0.03,
                    currency = "USD",
                },
            }

            session:_on_session_update(update)

            assert.stub(notify_stub).was.called(0)
            notify_stub:revert()
        end)
    end)

    describe("_setup_prompt_completion", function()
        --- @type integer
        local test_bufnr
        --- @type TestStub
        local file_picker_new_stub
        --- @type TestStub
        local skill_picker_new_stub
        --- @type TestStub
        local setup_completion_stub
        --- @type table
        local mock_picker
        --- @type table
        local mock_skill_picker
        --- @type agentic.SessionManager
        local session

        before_each(function()
            local FilePicker = require("agentic.ui.file_picker")
            local SkillPicker = require("agentic.ui.skill_picker")
            local SlashCommands = require("agentic.acp.slash_commands")

            test_bufnr = vim.api.nvim_create_buf(false, true)
            mock_picker = { _bufnr = test_bufnr }
            mock_skill_picker = { _bufnr = test_bufnr }
            file_picker_new_stub = spy.stub(FilePicker, "new")
            file_picker_new_stub:returns(mock_picker)
            skill_picker_new_stub = spy.stub(SkillPicker, "new")
            skill_picker_new_stub:returns(mock_skill_picker)
            setup_completion_stub = spy.stub(SlashCommands, "setup_completion")

            session = {
                agent = {
                    provider_config = {
                        name = "Codex",
                    },
                },
                widget = {
                    buf_nrs = { input = test_bufnr },
                },
                _get_workspace_root = function()
                    return "/tmp/agentic-workspace"
                end,
                _get_current_cwd = function()
                    return "/tmp/agentic-workspace/packages/app"
                end,
                _setup_prompt_completion = SessionManager._setup_prompt_completion,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            file_picker_new_stub:revert()
            skill_picker_new_stub:revert()
            setup_completion_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("keeps prompt completion helpers on the session", function()
            session:_setup_prompt_completion()

            assert.equal(mock_picker, session.file_picker)
            assert.equal(mock_skill_picker, session.skill_picker)
            assert.equal(test_bufnr, file_picker_new_stub.calls[1][2])
            assert.equal(
                "/tmp/agentic-workspace",
                file_picker_new_stub.calls[1][3].resolve_root()
            )
            assert.equal(
                "/tmp/agentic-workspace/packages/app",
                file_picker_new_stub.calls[1][3].resolve_cwd()
            )
            assert.equal(test_bufnr, skill_picker_new_stub.calls[1][2])
            assert.equal(
                "/tmp/agentic-workspace",
                skill_picker_new_stub.calls[1][3].resolve_workspace_root()
            )
            assert.equal(test_bufnr, setup_completion_stub.calls[1][1])
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
            local config_opts = AgentConfigOptions:new({}, function() end)

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
                session_state = SessionState:new(),
                agent = {
                    set_config_option = set_config_option_spy,
                },
                config_options = config_opts,
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

        it(
            "keeps provider config option labels unchanged in notifications",
            function()
                session.agent.set_config_option = function(
                    _agent,
                    _session_id,
                    _config_id,
                    _value,
                    callback
                )
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
            end
        )
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
                submission_queue = SubmissionQueue:new(),
                session_state = session_state,
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
                _prepare_submission = SessionManager._prepare_submission,
                _render_window_headers = SessionManager._render_window_headers,
                _sync_queue_panel = function() end,
                _sync_inline_queue_states = function() end,
                _enqueue_submission = SessionManager._enqueue_submission,
                _handle_input_submit = SessionManager._handle_input_submit,
            } --[[@as agentic.SessionManager]]

            session:_handle_input_submit("follow up")

            assert.spy(send_prompt_spy).was.called(0)
            assert.equal(1, session.submission_queue:count())
            assert.equal(
                "follow up",
                session.submission_queue:list()[1].input_text
            )
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
                    request = {
                        kind = "user",
                        text = "queued prompt",
                        timestamp = 1,
                        content = {
                            { type = "text", text = "queued prompt" },
                        },
                    },
                }

                local session = {
                    session_id = "sess-queue-drain",
                    is_generating = false,
                    submission_queue = SubmissionQueue:new(),
                    _sync_queue_panel = function() end,
                    _sync_inline_queue_states = function() end,
                    _dispatch_submission = dispatch_spy,
                    _drain_queued_submissions = SessionManager._drain_queued_submissions,
                } --[[@as agentic.SessionManager]]
                session.submission_queue:enqueue(queued_submission)

                session:_drain_queued_submissions()

                assert.equal(0, session.submission_queue:count())
                assert.spy(dispatch_spy).was.called(1)
                assert.equal(queued_submission, dispatch_spy.calls[1][2])
            end
        )

        it(
            "formats /review prompts as review requests in the transcript",
            function()
                local session_state = SessionState:new()
                local dispatch_spy = spy.new(function() end)

                local session = {
                    session_id = "sess-review-1",
                    is_generating = false,
                    submission_queue = SubmissionQueue:new(),
                    session_state = session_state,
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
                    _prepare_submission = SessionManager._prepare_submission,
                    _dispatch_submission = dispatch_spy,
                    _render_window_headers = function() end,
                    _handle_input_submit = SessionManager._handle_input_submit,
                } --[[@as agentic.SessionManager]]

                session:_handle_input_submit(
                    "/review focus on persisted_session.lua"
                )

                assert.spy(dispatch_spy).was.called(1)

                local submission = dispatch_spy.calls[1][2]
                assert.equal(
                    "/review focus on persisted_session.lua",
                    submission.input_text
                )
                assert.equal(
                    "/review focus on persisted_session.lua",
                    submission.request.text
                )
                assert.equal(1, #submission.request.content)
                assert.equal("text", submission.request.content[1].type)
                assert.equal(
                    "/review focus on persisted_session.lua",
                    submission.request.content[1].text
                )
            end
        )

        it(
            "resizes the queue panel when queued count changes while visible",
            function()
                local resize_spy = spy.new(function()
                    return true
                end)
                local set_items_spy = spy.new(function() end)
                local render_header_spy = spy.new(function() end)
                local refresh_layout_spy = spy.new(function() end)

                local session = {
                    submission_queue = SubmissionQueue:new(),
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
                session.submission_queue:enqueue({ input_text = "first" })
                session.submission_queue:enqueue({ input_text = "second" })

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
            end
        )

        it("rebuilds layout if direct queue resize does not take", function()
            local resize_spy = spy.new(function()
                return false
            end)
            local refresh_layout_spy = spy.new(function() end)

            local session = {
                submission_queue = SubmissionQueue:new(),
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
            session.submission_queue:enqueue({ input_text = "first" })
            session.submission_queue:enqueue({ input_text = "second" })
            session.submission_queue:enqueue({ input_text = "third" })

            session:_sync_queue_panel(true)

            assert.spy(resize_spy).was.called(1)
            assert.spy(refresh_layout_spy).was.called(1)
        end)
    end)

    describe("_build_chat_welcome_lines", function()
        it(
            "returns welcome lines with provider name, session id, and timestamp",
            function()
                local session = {
                    agent = {
                        provider_config = { name = "Claude ACP" },
                        agent_info = {},
                    },
                    _build_chat_welcome_lines = SessionManager._build_chat_welcome_lines,
                } --[[@as agentic.SessionManager]]

                local lines = session:_build_chat_welcome_lines({
                    session = {
                        id = "abc123",
                        timestamp = 1711410099,
                    },
                })

                assert.equal("Agentic · Claude ACP", lines[1])
                assert.equal("Session · abc123", lines[2])
                assert.truthy(
                    lines[3]:match("^Started · %d%d%d%d%-%d%d%-%d%d")
                )
            end
        )

        it("returns empty lines when session is missing", function()
            local session = {
                agent = {
                    provider_config = { name = "Claude ACP" },
                    agent_info = {},
                },
                _build_chat_welcome_lines = SessionManager._build_chat_welcome_lines,
            } --[[@as agentic.SessionManager]]

            local lines = session:_build_chat_welcome_lines({
                session = {
                    id = nil,
                    timestamp = 1711410099,
                },
            })

            assert.same({}, lines)
        end)

        it("includes version when provided", function()
            local session = {
                agent = {
                    provider_config = { name = "Claude ACP" },
                    agent_info = { version = "1.2.3" },
                },
                _build_chat_welcome_lines = SessionManager._build_chat_welcome_lines,
            } --[[@as agentic.SessionManager]]

            local lines = session:_build_chat_welcome_lines({
                session = {
                    id = "abc123",
                    timestamp = 1711410099,
                },
            })

            assert.equal("Agentic · Claude ACP v1.2.3", lines[1])
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

                seed_request(session_state, "edit this")
                session_state:dispatch(
                    SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                        tool_call_id = "tc-perm-1",
                        kind = "edit",
                        status = "pending",
                        file_path = "/tmp/demo.lua",
                        diff = { old = { "a" }, new = { "b" } },
                    })
                )

                local session = {
                    agent = { provider_config = { name = "Codex ACP" } },
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
                    sessionId = "sess-perm-1",
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
                assert
                    .spy(start_spy).was
                    .called_with(session.status_animation, "waiting", { detail = nil })
                assert.spy(add_request_spy).was.called(1)

                local state = session_state:get_state()
                assert.equal(
                    "requested",
                    require("agentic.session.session_selectors").get_tool_call(
                        state,
                        "tc-perm-1"
                    ).permission_state
                )
                assert.equal("tc-perm-1", state.review.active_tool_call_id)
            end
        )

        it(
            "derives approval state from the ACP option kind instead of option id",
            function()
                local session_state = SessionState:new()
                local callback_spy = spy.new(function() end)

                seed_request(session_state, "edit this")
                session_state:dispatch(
                    SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                        tool_call_id = "tc-perm-kind-1",
                        kind = "edit",
                        status = "pending",
                        file_path = "/tmp/demo.lua",
                        diff = { old = { "a" }, new = { "b" } },
                    })
                )

                local session = {
                    agent = { provider_config = { name = "Codex ACP" } },
                    session_state = session_state,
                    is_generating = true,
                    status_animation = { start = function() end },
                    permission_manager = {
                        add_request = function(_self, _request, callback)
                            callback("allow-custom")
                        end,
                    },
                    _set_chat_activity = SessionManager._set_chat_activity,
                    _clear_chat_activity = SessionManager._clear_chat_activity,
                    _get_active_tool_activity = SessionManager._get_active_tool_activity,
                    _refresh_chat_activity = SessionManager._refresh_chat_activity,
                    _handle_permission_request = SessionManager._handle_permission_request,
                } --[[@as agentic.SessionManager]]

                session:_handle_permission_request({
                    sessionId = "sess-perm-kind-1",
                    toolCall = { toolCallId = "tc-perm-kind-1" },
                    options = {
                        {
                            optionId = "allow-custom",
                            name = "Allow once",
                            kind = "allow_once",
                        },
                    },
                }, callback_spy --[[@as function]])

                assert.spy(callback_spy).was.called(1)
                assert.equal("allow-custom", callback_spy.calls[1][1])
                assert.equal(
                    "approved",
                    require("agentic.session.session_selectors").get_tool_call(
                        session_state:get_state(),
                        "tc-perm-kind-1"
                    ).permission_state
                )
            end
        )

        it(
            "treats hyphenated option ids as approval outcomes when kind is missing",
            function()
                local session_state = SessionState:new()
                local callback_spy = spy.new(function() end)

                seed_request(session_state, "edit this")
                session_state:dispatch(
                    SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                        tool_call_id = "tc-perm-kind-2",
                        kind = "edit",
                        status = "pending",
                        file_path = "/tmp/demo.lua",
                        diff = { old = { "a" }, new = { "b" } },
                    })
                )

                local session = {
                    agent = { provider_config = { name = "Codex ACP" } },
                    session_state = session_state,
                    is_generating = true,
                    status_animation = { start = function() end },
                    permission_manager = {
                        add_request = function(_self, _request, callback)
                            callback("allow-once")
                        end,
                    },
                    _set_chat_activity = SessionManager._set_chat_activity,
                    _clear_chat_activity = SessionManager._clear_chat_activity,
                    _get_active_tool_activity = SessionManager._get_active_tool_activity,
                    _refresh_chat_activity = SessionManager._refresh_chat_activity,
                    _handle_permission_request = SessionManager._handle_permission_request,
                } --[[@as agentic.SessionManager]]

                session:_handle_permission_request({
                    sessionId = "sess-perm-kind-2",
                    toolCall = { toolCallId = "tc-perm-kind-2" },
                    options = {
                        {
                            optionId = "allow-once",
                            name = "Allow once",
                        },
                    },
                }, callback_spy --[[@as function]])

                assert.spy(callback_spy).was.called(1)
                assert.equal("allow-once", callback_spy.calls[1][1])
                assert.equal(
                    "approved",
                    require("agentic.session.session_selectors").get_tool_call(
                        session_state:get_state(),
                        "tc-perm-kind-2"
                    ).permission_state
                )
            end
        )

        it("clears waiting activity after permission completion", function()
            local session_state = SessionState:new()
            local start_spy = spy.new(function() end)
            local completion_callback = nil

            seed_request(session_state, "edit this")
            session_state:dispatch(
                SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                    tool_call_id = "tc-perm-resume-1",
                    kind = "edit",
                    status = "pending",
                    file_path = "/tmp/demo.lua",
                    diff = { old = { "a" }, new = { "b" } },
                })
            )

            local session = {
                agent = { provider_config = { name = "Codex ACP" } },
                session_state = session_state,
                is_generating = true,
                _agent_phase = "thinking",
                status_animation = {
                    start = start_spy,
                    stop = function() end,
                },
                permission_manager = {
                    add_request = function(_self, request, callback)
                        session_state:dispatch(
                            SessionEvents.enqueue_permission(request, callback)
                        )
                        session_state:dispatch(
                            SessionEvents.show_next_permission()
                        )
                        completion_callback = callback
                    end,
                },
                _set_chat_activity = SessionManager._set_chat_activity,
                _clear_chat_activity = SessionManager._clear_chat_activity,
                _get_active_tool_activity = SessionManager._get_active_tool_activity,
                _refresh_chat_activity = SessionManager._refresh_chat_activity,
                _handle_permission_request = SessionManager._handle_permission_request,
            } --[[@as agentic.SessionManager]]

            session:_handle_permission_request({
                sessionId = "sess-perm-resume-1",
                toolCall = { toolCallId = "tc-perm-resume-1" },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                },
            }, function() end)

            assert
                .spy(start_spy).was
                .called_with(session.status_animation, "waiting", { detail = nil })
            assert.is_not_nil(completion_callback)
            --- @cast completion_callback fun(option_id: string|nil)
            completion_callback("allow-once")
            session_state:dispatch(SessionEvents.complete_current_permission())

            wait_for(function()
                local last_call = start_spy.calls[start_spy.call_count]
                return last_call ~= nil and last_call[2] == "generating"
            end)

            local last_call = start_spy.calls[start_spy.call_count]
            assert.equal("generating", last_call[2])
            assert.same({ detail = "/tmp/demo.lua" }, last_call[3])
            assert.is_nil(session_state:get_state().permissions.current_request)
            assert.is_nil(session_state:get_state().review.active_tool_call_id)
            assert.equal(
                "approved",
                require("agentic.session.session_selectors").get_tool_call(
                    session_state:get_state(),
                    "tc-perm-resume-1"
                ).permission_state
            )
        end)
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
            assert
                .spy(start_spy).was
                .called_with(session.status_animation, "thinking", { detail = nil })

            session:_on_session_update({
                sessionUpdate = "agent_message_chunk",
                content = { text = "working..." },
            })

            assert.equal("generating", session._agent_phase)
            assert
                .spy(start_spy).was
                .called_with(session.status_animation, "generating", { detail = nil })
        end)

        it("shows tool activity while a read tool is in progress", function()
            local start_spy = spy.new(function() end)
            local session_state = SessionState:new()
            seed_request(session_state, "read this")
            local session = {
                agent = { provider_config = { name = "Codex ACP" } },
                is_generating = true,
                _agent_phase = "thinking",
                session_state = session_state,
                status_animation = { start = start_spy, stop = function() end },
                permission_manager = {
                    remove_request_by_tool_call_id = spy.new(function() end),
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
                file_path = "/Users/michaelfortunato/projects/neovim-plugins/agentic.nvim/README.md",
            })

            assert
                .spy(start_spy).was
                .called_with(
                    session.status_animation,
                    "searching",
                    { detail = "README.md" }
                )

            session:_on_tool_call_update({
                tool_call_id = "tc-read",
                kind = "read",
                status = "completed",
            })

            assert
                .spy(start_spy).was
                .called_with(session.status_animation, "thinking", { detail = nil })
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

                local original_turns = {
                    {
                        index = 1,
                        request = {
                            kind = "user",
                            text = "hello",
                            timestamp = 1,
                            content = {
                                { type = "text", text = "hello" },
                            },
                            content_nodes = {},
                        },
                        response = {
                            provider_name = "Codex ACP",
                            nodes = {},
                        },
                        result = nil,
                    },
                }
                local saved_persisted_session = {
                    turns = original_turns,
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
                    session_state = SessionState:new({
                        persisted_session = saved_persisted_session,
                    }),
                    widget = { clear = widget_clear_spy },
                    file_list = { clear = file_list_clear_spy },
                    code_selection = { clear = code_selection_clear_spy },
                    _is_first_message = false,
                    _restored_turns_to_send = nil,
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
            "schedules restored-message resend and sets _is_first_message in on_created",
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

                local original_turns = {
                    {
                        index = 1,
                        request = {
                            kind = "user",
                            text = "hello",
                            timestamp = 1,
                            content = {
                                { type = "text", text = "hello" },
                            },
                            content_nodes = {},
                        },
                        response = {
                            provider_name = "Codex ACP",
                            nodes = {},
                        },
                        result = nil,
                    },
                }
                local InteractionModel =
                    require("agentic.session.interaction_model")
                local expected_turns = InteractionModel.from_persisted_session({
                    turns = original_turns,
                }).turns
                local saved_persisted_session = {
                    turns = original_turns,
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
                        persisted_session = saved_persisted_session,
                    }),
                    _is_first_message = false,
                    _restored_turns_to_send = nil,
                    _render_window_headers = function() end,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                assert.is_not_nil(captured_on_created)

                local new_timestamp = os.time()
                session.session_state:dispatch(SessionEvents.set_session_meta({
                    session_id = "new",
                    timestamp = new_timestamp,
                }))
                captured_on_created()

                local persisted =
                    session.session_state:get_persisted_session_data()
                assert.same(expected_turns, persisted.turns)
                assert.equal("new", persisted.session_id)
                assert.equal(new_timestamp, persisted.timestamp)
                assert.same(expected_turns, session._restored_turns_to_send)
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
                session_state = SessionState:new(),
                _is_first_message = false,
                _restored_turns_to_send = nil,
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
            local session_state = SessionState:new()
            seed_request(session_state, "mutate files")
            for tool_call_id, tool_call in pairs(tool_call_blocks) do
                session_state:dispatch(
                    SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                        tool_call_id = tool_call_id,
                        kind = tool_call.kind,
                        status = tool_call.status,
                        file_path = tool_call.file_path,
                        body = tool_call.body,
                        diff = tool_call.diff,
                        content_items = tool_call.content_items,
                    })
                )
            end

            return {
                agent = { provider_config = { name = "Codex ACP" } },
                session_state = session_state,
                permission_manager = {
                    remove_request_by_tool_call_id = spy.new(function() end),
                },
                status_animation = {
                    start = spy.new(function() end),
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

        it("hides active inline ghost text when a file edit lands", function()
            local handle_tool_call_update_spy = spy.new(function() end)
            local handle_applied_edit_spy = spy.new(function() end)
            local session = make_session({
                ["tc-1"] = { kind = "edit", status = "in_progress" },
            })

            session.inline_chat = {
                is_active = function()
                    return true
                end,
                handle_tool_call_update = handle_tool_call_update_spy,
                handle_applied_edit = handle_applied_edit_spy,
            }

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert.spy(handle_tool_call_update_spy).was.called(1)
            assert.spy(handle_applied_edit_spy).was.called(1)
            assert.spy(checktime_stub).was.called(1)
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

        it(
            "keeps the active review target on non-terminal tool updates",
            function()
                local session = make_session({
                    ["tc-1"] = { kind = "edit", status = "pending" },
                })
                session.session_state:dispatch(
                    SessionEvents.set_review_target("tc-1")
                )

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "in_progress" }
                )

                assert.equal(
                    "tc-1",
                    session.session_state:get_state().review.active_tool_call_id
                )
            end
        )

        it(
            "clears the active review target on terminal tool updates",
            function()
                local session = make_session({
                    ["tc-1"] = { kind = "edit", status = "pending" },
                })
                session.session_state:dispatch(
                    SessionEvents.set_review_target("tc-1")
                )

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = "completed" }
                )

                assert.is_nil(
                    session.session_state:get_state().review.active_tool_call_id
                )
            end
        )

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

    describe("_submit_inline_request", function()
        it("builds inline submissions with explicit selections", function()
            local begin_request_spy = spy.new(function() end)
            local dispatch_spy = spy.new(function() end)

            local session = {
                session_id = "sess-inline-1",
                is_generating = false,
                _session_starting = false,
                _restored_turns_to_send = nil,
                _is_first_message = false,
                session_state = SessionState:new(),
                agent = {
                    provider_config = { name = "Codex" },
                },
                inline_chat = {
                    begin_request = begin_request_spy,
                },
                _render_window_headers = function() end,
                _prepare_submission = SessionManager._prepare_submission,
                _dispatch_submission = dispatch_spy,
                _submit_inline_request = SessionManager._submit_inline_request,
            } --[[@as agentic.SessionManager]]

            local accepted = session:_submit_inline_request({
                prompt = "Refactor the selection",
                selection = {
                    lines = { "local value = 1", "return value" },
                    start_line = 4,
                    end_line = 5,
                    start_col = 7,
                    end_col = 12,
                    file_path = "/tmp/example.lua",
                    file_type = "lua",
                },
                source_bufnr = 10,
                source_winid = 11,
            })

            assert.is_true(accepted)
            assert.spy(begin_request_spy).was.called(0)
            assert.spy(dispatch_spy).was.called(1)

            local submission = dispatch_spy.calls[1][2]
            local prompt_text = {}
            for _, item in ipairs(submission.prompt) do
                if item.type == "text" and item.text then
                    prompt_text[#prompt_text + 1] = item.text
                end
            end
            local combined_prompt = table.concat(prompt_text, "\n")
            assert.equal("Refactor the selection", submission.input_text)
            assert.is_not_nil(submission.inline_request)
            assert.equal("Refactor the selection", submission.prompt[1].text)
            assert.equal(
                PromptBuilder.build_inline_instructions(),
                submission.prompt[2].text
            )
            assert.truthy(combined_prompt:match("<selected_code>"))
            assert.truthy(combined_prompt:match("<col_start>7</col_start>"))
            assert.truthy(combined_prompt:match("<col_end>12</col_end>"))
        end)

        it("queues inline requests while the agent is busy", function()
            local queue_request_spy = spy.new(function() end)
            local dispatch_spy = spy.new(function() end)

            local session = {
                session_id = "sess-inline-2",
                is_generating = true,
                _session_starting = false,
                _restored_turns_to_send = nil,
                _is_first_message = false,
                session_state = SessionState:new(),
                submission_queue = SubmissionQueue:new(),
                agent = {
                    provider_config = { name = "Codex" },
                },
                inline_chat = {
                    queue_request = queue_request_spy,
                    sync_queued_requests = function() end,
                },
                _render_window_headers = function() end,
                _prepare_submission = SessionManager._prepare_submission,
                _dispatch_submission = dispatch_spy,
                _enqueue_submission = SessionManager._enqueue_submission,
                _sync_queue_panel = function() end,
                _sync_inline_queue_states = SessionManager._sync_inline_queue_states,
                _submit_inline_request = SessionManager._submit_inline_request,
            } --[[@as agentic.SessionManager]]

            local accepted = session:_submit_inline_request({
                prompt = "Queue this inline change",
                selection = {
                    lines = { "return value" },
                    start_line = 5,
                    end_line = 5,
                    file_path = "/tmp/example.lua",
                    file_type = "lua",
                },
                source_bufnr = 10,
                source_winid = 11,
            })

            assert.is_true(accepted)
            assert.spy(dispatch_spy).was.called(0)
            assert.equal(1, session.submission_queue:count())
            assert.spy(queue_request_spy).was.called(1)
        end)

        it(
            "dispatches inline requests without depending on the chat session",
            function()
                local dispatch_spy = spy.new(function() end)

                local session = {
                    session_id = nil,
                    is_generating = false,
                    _restored_turns_to_send = nil,
                    _is_first_message = false,
                    agent = {
                        state = "ready",
                        provider_config = { name = "Codex" },
                    },
                    session_state = SessionState:new(),
                    _render_window_headers = function() end,
                    _prepare_submission = SessionManager._prepare_submission,
                    _dispatch_submission = dispatch_spy,
                    _submit_inline_request = SessionManager._submit_inline_request,
                } --[[@as agentic.SessionManager]]

                local accepted = session:_submit_inline_request({
                    prompt = "Refactor the selection",
                    selection = {
                        lines = { "local value = 1" },
                        start_line = 4,
                        end_line = 4,
                        file_path = "/tmp/example.lua",
                        file_type = "lua",
                    },
                    source_bufnr = 10,
                    source_winid = 11,
                })

                assert.is_true(accepted)
                assert.spy(dispatch_spy).was.called(1)

                local submission = dispatch_spy.calls[1][2]
                assert.is_not_nil(submission.inline_request)
                assert.equal("inline", submission.request.surface)
            end
        )
    end)

    describe("open_inline_chat", function()
        it(
            "removes overlapping queued inline requests instead of opening",
            function()
                local remove_spy = spy.new(function() end)
                local notify_stub = spy.stub(Logger, "notify")

                local session = {
                    inline_chat = {
                        find_overlapping_queued_submission = function()
                            return 42
                        end,
                        open = spy.new(function() end),
                    },
                    _remove_queued_submission = remove_spy,
                    open_inline_chat = SessionManager.open_inline_chat,
                } --[[@as agentic.SessionManager]]

                session:open_inline_chat({
                    lines = { "local value = 1" },
                    start_line = 1,
                    end_line = 1,
                    file_path = "/tmp/example.lua",
                    file_type = "lua",
                })

                assert.spy(remove_spy).was.called_with(session, 42)
                assert.spy(session.inline_chat.open).was.called(0)
                assert.truthy(
                    notify_stub.calls[1][1]:match("Removed queued inline")
                )

                notify_stub:revert()
            end
        )
    end)

    describe("_handle_input_submit", function()
        it(
            "waits for the first ACP session before sending chat prompts",
            function()
                local dispatch_spy = spy.new(function() end)
                local new_session_spy = spy.new(function(_self, opts)
                    _self._captured_on_created = opts.on_created
                end)

                local session = {
                    session_id = nil,
                    is_generating = false,
                    _session_starting = false,
                    _pending_session_callbacks = {},
                    _restored_turns_to_send = nil,
                    _is_first_message = false,
                    agent = {
                        state = "ready",
                        provider_config = { name = "Codex" },
                    },
                    session_state = SessionState:new(),
                    submission_queue = SubmissionQueue:new(),
                    todo_list = {
                        close_if_all_completed = function() end,
                    },
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
                    widget = {
                        win_nrs = {},
                    },
                    new_session = new_session_spy,
                    _render_window_headers = function() end,
                    _prepare_submission = SessionManager._prepare_submission,
                    _dispatch_submission = dispatch_spy,
                    _drain_queued_submissions = function() end,
                    _drain_pending_session_callbacks = SessionManager._drain_pending_session_callbacks,
                    _ensure_session_started = SessionManager._ensure_session_started,
                    _with_active_session = SessionManager._with_active_session,
                    _handle_input_submit = SessionManager._handle_input_submit,
                } --[[@as agentic.SessionManager]]

                session:_handle_input_submit("hello")

                assert.spy(new_session_spy).was.called(1)
                assert.is_true(new_session_spy.calls[1][2].restore_mode)
                assert.spy(dispatch_spy).was.called(0)

                session.session_id = "sess-chat-queued"
                session._captured_on_created()

                assert.spy(dispatch_spy).was.called(1)
                assert.equal("hello", dispatch_spy.calls[1][2].input_text)
            end
        )

        it(
            "handles local Codex slash commands without starting a session",
            function()
                local new_session_spy = spy.new(function() end)
                local local_command_spy = spy.new(function()
                    return true
                end)

                local session = {
                    session_id = nil,
                    is_generating = false,
                    _session_starting = false,
                    _pending_session_callbacks = {},
                    _restored_turns_to_send = nil,
                    _is_first_message = false,
                    agent = {
                        state = "ready",
                        provider_config = { name = "Codex" },
                    },
                    session_state = SessionState:new(),
                    submission_queue = SubmissionQueue:new(),
                    todo_list = {
                        close_if_all_completed = function() end,
                    },
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
                    widget = {
                        win_nrs = {},
                    },
                    new_session = new_session_spy,
                    _handle_local_slash_command = local_command_spy,
                    _handle_input_submit = SessionManager._handle_input_submit,
                } --[[@as agentic.SessionManager]]

                session:_handle_input_submit("/skills")

                assert.spy(local_command_spy).was.called(1)
                assert.spy(new_session_spy).was.called(0)
            end
        )
    end)

    describe("_dispatch_submission", function()
        it("waits for an active session before sending the prompt", function()
            local send_prompt_spy = spy.new(function() end)
            local with_active_session_spy = spy.new(function(_self, callback)
                _self._queued_dispatch = callback
            end)

            local session = {
                session_id = nil,
                session_state = SessionState:new(),
                agent = {
                    provider_config = { name = "Codex" },
                    send_prompt = send_prompt_spy,
                },
                inline_chat = nil,
                _with_active_session = with_active_session_spy,
                _dispatch_submission = SessionManager._dispatch_submission,
            } --[[@as agentic.SessionManager]]

            session:_dispatch_submission({
                id = 1,
                input_text = "hello",
                prompt = { { type = "text", text = "hello" } },
                request = {
                    kind = "user",
                    text = "hello",
                    timestamp = os.time(),
                    content = { { type = "text", text = "hello" } },
                },
            })

            assert.spy(with_active_session_spy).was.called(1)
            assert.spy(send_prompt_spy).was.called(0)
            assert.equal(
                0,
                #session.session_state:get_state().interaction.turns
            )
        end)

        it("creates a fresh ACP session for each inline submission", function()
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                callback()
            end)

            local created_session_ids = {}
            local send_prompt_spy = spy.new(
                function(_agent, _session_id, _prompt, callback)
                    callback({ stopReason = "end_turn" }, nil)
                end
            )
            local cancel_session_spy = spy.new(function() end)
            local begin_request_spy = spy.new(function() end)
            local complete_spy = spy.new(function() end)
            local save_stub
            local session_state = SessionState:new()

            save_stub = spy.stub(session_state, "save_persisted_session_data")
            save_stub:invokes(function(_self, callback)
                if callback then
                    callback(nil)
                end
            end)

            local session = {
                session_id = nil,
                _inline_session_id = nil,
                is_generating = false,
                _inline_session_starting = false,
                _pending_inline_session_callbacks = {},
                tab_page_id = 3,
                session_state = session_state,
                config_options = { _options = {} },
                agent = {
                    state = "ready",
                    provider_config = { name = "Codex" },
                    create_session = spy.new(
                        function(_agent, _handlers, callback)
                            local session_id = "inline-"
                                .. tostring(#created_session_ids + 1)
                            created_session_ids[#created_session_ids + 1] =
                                session_id
                            callback({ sessionId = session_id }, nil)
                        end
                    ),
                    send_prompt = send_prompt_spy,
                    cancel_session = cancel_session_spy,
                },
                inline_chat = {
                    begin_request = begin_request_spy,
                    complete = complete_spy,
                },
                _render_window_headers = function() end,
                _refresh_chat_activity = function() end,
                _dispatch_submission = SessionManager._dispatch_submission,
                _drain_pending_inline_session_callbacks = SessionManager._drain_pending_inline_session_callbacks,
                _ensure_inline_session_started = SessionManager._ensure_inline_session_started,
                _with_active_inline_session = SessionManager._with_active_inline_session,
                _start_inline_session = SessionManager._start_inline_session,
                _cancel_inline_session = SessionManager._cancel_inline_session,
                _drain_queued_submissions = function() end,
            } --[[@as agentic.SessionManager]]

            --- @param prompt string
            --- @return agentic.SessionManager.QueuedSubmission
            local function make_inline_submission(prompt)
                --- @type agentic.SessionManager.QueuedSubmission
                local submission = {
                    id = 1,
                    input_text = prompt,
                    prompt = { { type = "text", text = prompt } },
                    request = {
                        kind = "user",
                        surface = "inline",
                        text = prompt,
                        timestamp = os.time(),
                        content = { { type = "text", text = prompt } },
                    },
                    inline_request = {
                        prompt = prompt,
                        selection = {
                            lines = { "local value = 1" },
                            start_line = 1,
                            end_line = 1,
                            file_path = "/tmp/example.lua",
                            file_type = "lua",
                        },
                        source_bufnr = 10,
                        source_winid = 11,
                    },
                }

                return submission
            end

            session:_dispatch_submission(
                make_inline_submission("Inline request one")
            )
            session:_dispatch_submission(
                make_inline_submission("Inline request two")
            )

            assert.same({ "inline-1", "inline-2" }, created_session_ids)
            assert.equal(2, send_prompt_spy.call_count)
            assert.equal("inline-1", send_prompt_spy.calls[1][2])
            assert.equal("inline-2", send_prompt_spy.calls[2][2])
            assert.spy(cancel_session_spy).was.called(2)
            assert.equal("inline-1", cancel_session_spy.calls[1][2])
            assert.equal("inline-2", cancel_session_spy.calls[2][2])
            assert.spy(begin_request_spy).was.called(2)
            assert.spy(complete_spy).was.called(2)
            assert.is_nil(session._inline_session_id)
            assert.is_nil(session.session_id)

            save_stub:revert()
            schedule_stub:revert()
        end)
    end)
end)
