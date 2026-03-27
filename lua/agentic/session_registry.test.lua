---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field, duplicate-set-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.SessionRegistry", function()
    --- @type agentic.SessionRegistry
    local SessionRegistry

    --- @type table
    local session_manager_mock
    --- @type table
    local acp_health_mock
    --- @type table
    local logger_stub
    --- @type table
    local config_mock
    --- @type table
    local default_config_mock

    --- @type integer[]
    local created_bufnrs

    --- @type TestStub|nil
    local ui_select_stub

    --- @param tab_page_id integer
    --- @param opts {instance_id?: integer|nil}|nil
    --- @return table
    local function create_mock_session(tab_page_id, opts)
        opts = opts or {}

        local widget_bufnr = vim.api.nvim_create_buf(false, true)
        created_bufnrs[#created_bufnrs + 1] = widget_bufnr

        local session = {
            tab_page_id = tab_page_id,
            instance_id = opts.instance_id,
            widget_bufnr = widget_bufnr,
            widget = {},
            destroy = function() end,
            is_mock = true,
        }

        session.widget.owns_buffer = function(_, bufnr)
            return bufnr == widget_bufnr
        end

        return session
    end

    session_manager_mock = {
        new = function(_, tab_page_id, opts)
            return create_mock_session(tab_page_id, opts)
        end,
    }

    acp_health_mock = {
        check_configured_provider = function()
            return true
        end,
        get_default_provider_names = function()
            return {}
        end,
        is_command_available = function()
            return false
        end,
    }

    logger_stub = {
        debug = function() end,
        notify = function() end,
    }

    config_mock = {
        provider = "claude-acp",
        acp_providers = {
            ["claude-acp"] = { command = "claude-code-acp" },
            ["gemini-acp"] = { command = "gemini" },
        },
    }

    default_config_mock = {
        provider = "claude-acp",
    }

    local original_loaded = {
        ["agentic.config"] = package.loaded["agentic.config"],
        ["agentic.config_default"] = package.loaded["agentic.config_default"],
        ["agentic.acp.acp_health"] = package.loaded["agentic.acp.acp_health"],
        ["agentic.utils.logger"] = package.loaded["agentic.utils.logger"],
        ["agentic.session_manager"] = package.loaded["agentic.session_manager"],
        ["agentic.session_registry"] = package.loaded["agentic.session_registry"],
    }

    package.loaded["agentic.config"] = config_mock
    package.loaded["agentic.config_default"] = default_config_mock
    package.loaded["agentic.acp.acp_health"] = acp_health_mock
    package.loaded["agentic.utils.logger"] = logger_stub
    package.loaded["agentic.session_manager"] = session_manager_mock
    package.loaded["agentic.session_registry"] = nil

    SessionRegistry = require("agentic.session_registry")

    for key, value in pairs(original_loaded) do
        package.loaded[key] = value
    end

    before_each(function()
        created_bufnrs = {}
        package.loaded["agentic.session_manager"] = session_manager_mock

        acp_health_mock.check_configured_provider = function()
            return true
        end
        acp_health_mock.get_default_provider_names = function()
            return {}
        end
        acp_health_mock.is_command_available = function()
            return false
        end

        config_mock.provider = "claude-acp"
        config_mock.acp_providers = {
            ["claude-acp"] = { command = "claude-code-acp" },
            ["gemini-acp"] = { command = "gemini" },
        }
        default_config_mock.provider = "claude-acp"

        session_manager_mock.new = function(_, tab_page_id, opts)
            return create_mock_session(tab_page_id, opts)
        end
    end)

    after_each(function()
        if SessionRegistry and SessionRegistry.sessions then
            for key in pairs(SessionRegistry.sessions) do
                SessionRegistry.sessions[key] = nil
            end
        end

        local active_sessions = SessionRegistry
                and rawget(SessionRegistry, "_window_active_sessions")
            or nil
        if active_sessions then
            for key in pairs(active_sessions) do
                active_sessions[key] = nil
            end
        end

        if SessionRegistry then
            rawset(SessionRegistry, "_next_instance_id", 0)
        end

        for _, bufnr in ipairs(created_bufnrs or {}) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end

        package.loaded["agentic.session_manager"] =
            original_loaded["agentic.session_manager"]
        package.loaded["agentic.config"] = original_loaded["agentic.config"]
        package.loaded["agentic.config_default"] =
            original_loaded["agentic.config_default"]
        package.loaded["agentic.acp.acp_health"] =
            original_loaded["agentic.acp.acp_health"]
        package.loaded["agentic.utils.logger"] =
            original_loaded["agentic.utils.logger"]

        if ui_select_stub then
            ui_select_stub:revert()
            ui_select_stub = nil
        end
    end)

    describe("get_session_for_tab_page", function()
        it("creates a new session when none exists for the tabpage", function()
            local tab_id = 1
            local session = SessionRegistry.get_session_for_tab_page(tab_id)

            assert.is_not_nil(session)
            assert.is_true(session.is_mock)
            assert.equal(tab_id, session.tab_page_id)
            assert.equal(session, SessionRegistry.sessions[session.instance_id])
        end)

        it(
            "returns the session associated with the current editor window",
            function()
                local tab_id = 1
                local first = SessionRegistry.new_session(tab_id)
                local second = SessionRegistry.new_session(tab_id)
                SessionRegistry.set_active_session(
                    second,
                    vim.api.nvim_get_current_win()
                )

                local resolved =
                    SessionRegistry.get_session_for_tab_page(tab_id)

                assert.equal(second, resolved)
                assert.are_not.equal(first, second)
            end
        )

        it("prefers the session under the current cursor buffer", function()
            local tab_id = vim.api.nvim_get_current_tabpage()
            local first = SessionRegistry.new_session(tab_id)
            local second = SessionRegistry.new_session(tab_id)

            vim.api.nvim_set_current_buf(first.widget_bufnr)

            local resolved = SessionRegistry.get_session_for_tab_page(tab_id)

            assert.equal(first, resolved)
            assert.are_not.equal(first, second)
        end)

        it("uses current tabpage when tab_page_id is nil", function()
            local current_tab_id = vim.api.nvim_get_current_tabpage()
            local session = SessionRegistry.get_session_for_tab_page(nil)

            assert.is_not_nil(session)
            assert.equal(current_tab_id, session.tab_page_id)
        end)

        it("calls callback with the resolved session", function()
            local tab_id = 1
            local callback_called = false
            local callback_session = nil

            SessionRegistry.get_session_for_tab_page(tab_id, function(session)
                callback_called = true
                callback_session = session
            end)

            assert.is_true(callback_called)
            assert.is_not_nil(callback_session)
            assert.equal(tab_id, callback_session.tab_page_id)
        end)

        it(
            "returns nil and does not call callback when provider is not configured",
            function()
                acp_health_mock.check_configured_provider = function()
                    return false
                end

                local callback_called = false

                local session = SessionRegistry.get_session_for_tab_page(
                    1,
                    function()
                        callback_called = true
                    end
                )

                assert.is_nil(session)
                assert.is_false(callback_called)
            end
        )
    end)

    describe("get_current_session", function()
        it("returns nil when the tabpage has no sessions", function()
            assert.is_nil(SessionRegistry.get_current_session(1))
        end)

        it(
            "returns the editor-window session without creating a new one",
            function()
                local tab_id = 1
                local session = SessionRegistry.new_session(tab_id)
                SessionRegistry.set_active_session(
                    session,
                    vim.api.nvim_get_current_win()
                )

                local resolved = SessionRegistry.get_current_session(tab_id)

                assert.equal(session, resolved)
                assert.equal(1, #SessionRegistry.get_tab_sessions(tab_id))
            end
        )
    end)

    describe("new_session", function()
        it("creates an additional session in the same tab", function()
            local tab_id = 1
            local first = SessionRegistry.new_session(tab_id)
            local second = SessionRegistry.new_session(tab_id)

            local sessions = SessionRegistry.get_tab_sessions(tab_id)

            assert.are_not.equal(first, second)
            assert.equal(2, #sessions)
            assert.equal(first, sessions[1])
            assert.equal(second, sessions[2])
        end)
    end)

    describe("find_session_by_buf", function()
        it("returns the owning session for a widget buffer", function()
            local session = SessionRegistry.new_session(1)

            local resolved =
                SessionRegistry.find_session_by_buf(session.widget_bufnr)

            assert.equal(session, resolved)
        end)

        it("returns nil for unrelated buffers", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            created_bufnrs[#created_bufnrs + 1] = bufnr

            assert.is_nil(SessionRegistry.find_session_by_buf(bufnr))
        end)
    end)

    describe("destroy_session", function()
        it(
            "destroys the specified session and removes it from the registry",
            function()
                local session = create_mock_session(1, { instance_id = 7 })
                local destroy_spy = spy.new(function() end)
                session.destroy = destroy_spy
                SessionRegistry.sessions[7] = session --[[@as agentic.SessionManager]]
                SessionRegistry.set_active_session(
                    session --[[@as agentic.SessionManager]],
                    vim.api.nvim_get_current_win()
                )

                SessionRegistry.destroy_session(
                    session --[[@as agentic.SessionManager]]
                )

                assert.spy(destroy_spy).was.called(1)
                assert.is_nil(SessionRegistry.sessions[7])
            end
        )

        it(
            "clears the active editor-window association for the destroyed session",
            function()
                local second = SessionRegistry.new_session(1)
                SessionRegistry.set_active_session(
                    second,
                    vim.api.nvim_get_current_win()
                )

                SessionRegistry.destroy_session(second)

                assert.is_nil(SessionRegistry.get_current_session(1))
            end
        )

        it("does nothing when no session matches the target", function()
            SessionRegistry.destroy_session(999)

            assert.equal(0, #SessionRegistry.get_tab_sessions(1))
        end)
    end)

    describe("destroy_sessions_for_tab", function()
        it("destroys all sessions in the given tab only", function()
            local tab1_first = SessionRegistry.new_session(1)
            local tab1_second = SessionRegistry.new_session(1)
            local tab2_session = SessionRegistry.new_session(2)

            SessionRegistry.destroy_sessions_for_tab(1)

            assert.is_nil(SessionRegistry.sessions[tab1_first.instance_id])
            assert.is_nil(SessionRegistry.sessions[tab1_second.instance_id])
            assert.is_not_nil(
                SessionRegistry.sessions[tab2_session.instance_id]
            )
        end)
    end)

    describe("sessions weak table", function()
        it("uses weak value metatable", function()
            local metatable = getmetatable(SessionRegistry.sessions)

            assert.is_not_nil(metatable)
            assert.equal("v", metatable.__mode)
        end)
    end)

    describe("select_provider", function()
        --- @type table[]|nil
        local captured_items
        --- @type table|nil
        local captured_opts
        --- @type function|nil
        local captured_on_choice

        before_each(function()
            captured_items = nil
            captured_opts = nil
            captured_on_choice = nil

            ui_select_stub = spy.stub(vim.ui, "select")
            ui_select_stub:invokes(function(items, opts, on_choice)
                captured_items = items
                captured_opts = opts
                captured_on_choice = on_choice
            end)
        end)

        it("sorts installed providers before not-installed", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-acp", "gemini-acp" }
            end
            acp_health_mock.is_command_available = function(cmd)
                return cmd == "gemini"
            end

            SessionRegistry.select_provider(function() end)

            assert.is_not_nil(captured_items)
            assert.equal(2, #captured_items)
            assert.equal("gemini-acp", captured_items[1].name)
            assert.is_true(captured_items[1].installed)
            assert.equal("claude-acp", captured_items[2].name)
            assert.is_false(captured_items[2].installed)
        end)

        it("marks providers without config as not-installed", function()
            acp_health_mock.get_default_provider_names = function()
                return { "unknown-acp" }
            end

            SessionRegistry.select_provider(function() end)

            assert.equal(1, #captured_items)
            assert.equal("unknown-acp", captured_items[1].name)
            assert.is_false(captured_items[1].installed)
        end)

        it("calls on_selected with the provider name on selection", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-acp" }
            end

            local selected = nil
            SessionRegistry.select_provider(function(provider_name)
                selected = provider_name
            end)

            captured_on_choice(captured_items[1])

            assert.equal("claude-acp", selected)
            assert.equal(
                "Select an ACP provider for the new session:",
                captured_opts.prompt
            )
        end)
    end)
end)
