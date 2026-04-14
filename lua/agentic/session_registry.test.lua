---@diagnostic disable: assign-type-mismatch, need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.SessionRegistry", function()
    --- @type agentic.SessionRegistry
    local SessionRegistry

    local acp_health_mock
    local config_mock
    local default_config_mock
    local logger_stub
    local session_manager_mock
    local original_loaded

    --- @type integer[]
    local created_bufnrs

    --- @param opts {instance_id?: integer|nil, tab_page_id?: integer|nil}|nil
    --- @return table
    local function create_mock_session(opts)
        opts = opts or {}

        local widget_bufnr = vim.api.nvim_create_buf(false, true)
        created_bufnrs[#created_bufnrs + 1] = widget_bufnr

        local session = {
            instance_id = opts.instance_id,
            session_id = nil,
            session_state = {
                get_state = function()
                    return {
                        session = {
                            title = "",
                        },
                    }
                end,
            },
            widget = {
                tab_page_id = opts.tab_page_id
                    or vim.api.nvim_get_current_tabpage(),
                buf_nrs = {
                    chat = widget_bufnr,
                },
            },
            destroy = spy.new(function() end),
        }

        session.widget.owns_buffer = function(_, bufnr)
            return bufnr == widget_bufnr
        end

        return session
    end

    before_each(function()
        created_bufnrs = {}

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

        logger_stub = {
            debug = function() end,
            notify = function() end,
        }

        session_manager_mock = {
            new = function(_, opts)
                return create_mock_session(opts)
            end,
        }

        original_loaded = {
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

        for _, bufnr in ipairs(created_bufnrs) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end

        for key, value in pairs(original_loaded) do
            package.loaded[key] = value
        end
    end)

    describe("get_or_create_session", function()
        it(
            "creates a new session when none is resolved from context",
            function()
                local session = SessionRegistry.get_or_create_session()

                assert.is_not_nil(session)
                assert.equal(
                    session,
                    SessionRegistry.sessions[session.instance_id]
                )
            end
        )

        it(
            "returns the active editor-window session without creating another",
            function()
                local first = SessionRegistry.new_session()
                local second = SessionRegistry.new_session()

                SessionRegistry.set_active_session(
                    second,
                    vim.api.nvim_get_current_win()
                )

                local resolved = SessionRegistry.get_or_create_session()

                assert.equal(second, resolved)
                assert.are_not.equal(first, second)
                assert.equal(2, #SessionRegistry.get_sessions())
            end
        )

        it("prefers the session under the current widget buffer", function()
            local first = SessionRegistry.new_session()
            local second = SessionRegistry.new_session()

            vim.api.nvim_set_current_buf(first.widget.buf_nrs.chat)

            local resolved = SessionRegistry.get_or_create_session()

            assert.equal(first, resolved)
            assert.are_not.equal(first, second)
        end)

        it("returns nil when provider is not configured", function()
            acp_health_mock.check_configured_provider = function()
                return false
            end

            assert.is_nil(SessionRegistry.get_or_create_session())
        end)
    end)

    describe("get_current_session", function()
        it("returns nil when no session is resolved from context", function()
            assert.is_nil(SessionRegistry.get_current_session())
        end)

        it("supports the legacy numeric first argument", function()
            local session = SessionRegistry.new_session()
            SessionRegistry.set_active_session(
                session,
                vim.api.nvim_get_current_win()
            )

            local resolved = SessionRegistry.get_current_session(1)

            assert.equal(session, resolved)
        end)
    end)

    describe("session lists", function()
        it("returns all sessions sorted by instance id", function()
            local first = SessionRegistry.new_session()
            local second = SessionRegistry.new_session()

            local sessions = SessionRegistry.get_sessions()

            assert.equal(2, #sessions)
            assert.equal(first, sessions[1])
            assert.equal(second, sessions[2])
        end)

        it("filters widget sessions by tab page", function()
            local first = SessionRegistry.new_session()
            local second = SessionRegistry.new_session()
            second.widget.tab_page_id = first.widget.tab_page_id + 1

            local sessions =
                SessionRegistry.get_widget_sessions(first.widget.tab_page_id)

            assert.equal(1, #sessions)
            assert.equal(first, sessions[1])
        end)
    end)

    describe("find_session_by_buf", function()
        it("returns the owning session for a widget buffer", function()
            local session = SessionRegistry.new_session()

            assert.equal(
                session,
                SessionRegistry.find_session_by_buf(session.widget.buf_nrs.chat)
            )
        end)

        it("returns nil for unrelated buffers", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            created_bufnrs[#created_bufnrs + 1] = bufnr

            assert.is_nil(SessionRegistry.find_session_by_buf(bufnr))
        end)
    end)

    describe("destroy_session", function()
        it(
            "removes the session from the registry and clears active-window state",
            function()
                local session = SessionRegistry.new_session()
                SessionRegistry.set_active_session(
                    session,
                    vim.api.nvim_get_current_win()
                )

                SessionRegistry.destroy_session(session)

                local destroy_spy = session.destroy --[[@as TestSpy]]
                assert.spy(destroy_spy).was.called(1)
                assert.is_nil(SessionRegistry.sessions[session.instance_id])
                assert.is_nil(SessionRegistry.get_current_session())
            end
        )
    end)

    describe("destroy_widget_sessions_for_tab", function()
        it("destroys sessions whose widgets live in the closed tab", function()
            local first = SessionRegistry.new_session()
            local second = SessionRegistry.new_session()
            local third = SessionRegistry.new_session()

            first.widget.tab_page_id = 1
            second.widget.tab_page_id = 1
            third.widget.tab_page_id = 2

            SessionRegistry.destroy_widget_sessions_for_tab(1)

            assert.is_nil(SessionRegistry.sessions[first.instance_id])
            assert.is_nil(SessionRegistry.sessions[second.instance_id])
            assert.is_not_nil(SessionRegistry.sessions[third.instance_id])
        end)
    end)

    describe("sessions weak table", function()
        it("uses weak value metatable", function()
            local metatable = getmetatable(SessionRegistry.sessions)

            assert.is_not_nil(metatable)
            assert.equal("v", metatable.__mode)
        end)
    end)
end)
