---@diagnostic disable: missing-fields, undefined-doc-name, undefined-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local SessionState = require("agentic.session.session_state")

describe("agentic.session.SessionLifecycle", function()
    --- @type agentic.session.SessionLifecycle
    local SessionLifecycle
    --- @type TestStub
    local schedule_stub

    local function make_mode_option(current_value, values)
        local select_values = {}
        for _, value in ipairs(values) do
            select_values[#select_values + 1] = {
                value = value,
                name = value,
                description = value,
            }
        end

        return {
            id = "mode",
            category = "mode",
            currentValue = current_value,
            description = "Approval Preset",
            name = "Approval Preset",
            options = select_values,
        }
    end

    local function make_model_option(current_value, values)
        local select_values = {}
        for _, value in ipairs(values) do
            select_values[#select_values + 1] = {
                value = value,
                name = value,
                description = value,
            }
        end

        return {
            id = "model",
            category = "model",
            currentValue = current_value,
            description = "Model",
            name = "Model",
            options = select_values,
        }
    end

    local function make_session_state(config_options)
        return SessionState:new({
            persisted_session = {
                session_id = "persisted-session",
                title = "Persisted session",
                timestamp = 1,
                current_mode_id = nil,
                config_options = config_options or {},
                available_commands = {},
                turns = {},
            },
        })
    end

    before_each(function()
        package.loaded["agentic.session.session_lifecycle"] = nil
        SessionLifecycle = require("agentic.session.session_lifecycle")

        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            fn()
        end)
    end)

    after_each(function()
        schedule_stub:revert()
    end)

    it(
        "restores persisted config options before on_created when recreating a session",
        function()
            local mode_option = make_mode_option("read-only", {
                "read-only",
                "full-access",
            })
            local apply_order = {}
            local on_created_spy = spy.new(function()
                apply_order[#apply_order + 1] = "created"
            end)
            local set_initial_mode_spy = spy.new(function()
                apply_order[#apply_order + 1] = "default-mode"
            end)
            local handle_new_config_options_spy = spy.new(
                function(_self, options)
                    apply_order[#apply_order + 1] = "options:"
                        .. options[1].currentValue
                end
            )
            local set_config_option_spy = spy.new(
                function(_agent, _session_id, config_id, value, callback)
                    apply_order[#apply_order + 1] = config_id .. ":" .. value
                    callback({
                        configOptions = {
                            make_mode_option(value, {
                                "read-only",
                                "full-access",
                            }),
                        },
                    }, nil)
                end
            )

            local session = {
                session_id = nil,
                agent = {
                    provider_config = { default_mode = "read-only" },
                    create_session = function(_self, _handlers, callback)
                        callback({
                            sessionId = "session-1",
                            configOptions = {
                                vim.deepcopy(mode_option),
                            },
                        }, nil)
                    end,
                    set_config_option = set_config_option_spy,
                },
                session_state = make_session_state({
                    make_mode_option("full-access", {
                        "read-only",
                        "full-access",
                    }),
                }),
                config_options = {
                    set_initial_mode = set_initial_mode_spy,
                },
                _handle_new_config_options = function(self, options)
                    handle_new_config_options_spy(self, options)
                end,
            } --[[@as agentic.SessionManager]]

            SessionLifecycle.start(session, {
                restore_mode = true,
                on_created = on_created_spy,
            })

            assert.equal("session-1", session.session_id)
            assert.spy(set_config_option_spy).was.called(1)
            assert.equal("mode", set_config_option_spy.calls[1][3])
            assert.equal("full-access", set_config_option_spy.calls[1][4])
            assert.spy(set_initial_mode_spy).was.called(0)
            assert.spy(on_created_spy).was.called(1)
            assert.same({
                "options:read-only",
                "mode:full-access",
                "options:full-access",
                "created",
            }, apply_order)
        end
    )

    it(
        "falls back to configured default mode when persisted mode is unavailable",
        function()
            local set_initial_mode_spy = spy.new(function() end)
            local set_config_option_spy = spy.new(function() end)
            local on_created_spy = spy.new(function() end)

            local session = {
                session_id = nil,
                agent = {
                    provider_config = { default_mode = "auto" },
                    create_session = function(_self, _handlers, callback)
                        callback({
                            sessionId = "session-2",
                            configOptions = {
                                make_mode_option("read-only", {
                                    "read-only",
                                    "auto",
                                }),
                            },
                        }, nil)
                    end,
                    set_config_option = set_config_option_spy,
                },
                session_state = make_session_state({
                    make_mode_option("full-access", {
                        "read-only",
                        "full-access",
                    }),
                }),
                config_options = {
                    set_initial_mode = set_initial_mode_spy,
                },
                _handle_new_config_options = function() end,
            } --[[@as agentic.SessionManager]]

            SessionLifecycle.start(session, {
                restore_mode = true,
                on_created = on_created_spy,
            })

            assert.spy(set_config_option_spy).was.called(0)
            assert.spy(set_initial_mode_spy).was.called(1)
            assert.equal("auto", set_initial_mode_spy.calls[1][2])
            assert.spy(on_created_spy).was.called(1)
        end
    )

    it(
        "restores non-mode config options without suppressing default mode",
        function()
            local set_initial_mode_spy = spy.new(function() end)
            local set_config_option_spy = spy.new(
                function(_agent, _session_id, _config_id, _value, callback)
                    callback({}, nil)
                end
            )
            local on_created_spy = spy.new(function() end)

            local session = {
                session_id = nil,
                agent = {
                    provider_config = { default_mode = "full-access" },
                    create_session = function(_self, _handlers, callback)
                        callback({
                            sessionId = "session-3",
                            configOptions = {
                                make_mode_option("read-only", {
                                    "read-only",
                                    "full-access",
                                }),
                                make_model_option("gpt-5.4", {
                                    "gpt-5.4",
                                    "gpt-5.5",
                                }),
                            },
                        }, nil)
                    end,
                    set_config_option = set_config_option_spy,
                },
                session_state = make_session_state({
                    make_model_option("gpt-5.5", {
                        "gpt-5.4",
                        "gpt-5.5",
                    }),
                }),
                config_options = {
                    set_initial_mode = set_initial_mode_spy,
                    get_config_option = function()
                        return nil
                    end,
                },
                _handle_new_config_options = function() end,
                _render_window_headers = function() end,
            } --[[@as agentic.SessionManager]]

            SessionLifecycle.start(session, {
                restore_mode = true,
                on_created = on_created_spy,
            })

            assert.spy(set_config_option_spy).was.called(1)
            assert.equal("model", set_config_option_spy.calls[1][3])
            assert.equal("gpt-5.5", set_config_option_spy.calls[1][4])
            assert.spy(set_initial_mode_spy).was.called(1)
            assert.equal("full-access", set_initial_mode_spy.calls[1][2])
            assert.spy(on_created_spy).was.called(1)
        end
    )
end)
