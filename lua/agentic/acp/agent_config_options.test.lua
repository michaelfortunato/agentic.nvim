local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentConfigOptions", function()
    --- @type agentic.acp.AgentConfigOptions
    local AgentConfigOptions

    --- @type agentic.acp.AgentConfigOptions
    local config_options

    --- @type TestStub
    local multi_keymap_stub

    --- @type agentic.acp.ConfigOption
    local mode_option = {
        id = "mode-1",
        category = "mode",
        currentValue = "normal",
        description = "Agent mode",
        name = "Mode",
        options = {
            {
                value = "normal",
                name = "Normal",
                description = "Standard mode",
            },
            {
                value = "plan",
                name = "Plan",
                description = "Planning mode",
            },
            { value = "code", name = "Code", description = "Coding mode" },
        },
    }

    --- @type agentic.acp.ConfigOption
    local model_option = {
        id = "model-1",
        category = "model",
        currentValue = "claude-sonnet",
        description = "Model selection",
        name = "Model",
        options = {
            {
                value = "claude-sonnet",
                name = "Sonnet",
                description = "Fast model",
            },
        },
    }

    --- @type agentic.acp.ConfigOption
    local thought_option = {
        id = "thought-1",
        category = "thought_level",
        currentValue = "normal",
        description = "Thinking depth",
        name = "Thought Level",
        options = {
            { value = "normal", name = "Normal", description = "Standard" },
        },
    }

    --- @type agentic.acp.ConfigOption
    local approval_option = {
        id = "approval-1",
        currentValue = "read-only",
        description = "Approval Preset",
        name = "Approval Preset",
        options = {
            {
                value = "read-only",
                name = "Read Only",
                description = "No write access",
            },
            {
                value = "default",
                name = "Default",
                description = "Standard access",
            },
        },
    }

    --- @type integer
    local test_bufnr

    before_each(function()
        local BufHelpers = require("agentic.utils.buf_helpers")
        multi_keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

        AgentConfigOptions = require("agentic.acp.agent_config_options")
        test_bufnr = vim.api.nvim_create_buf(false, true)
        config_options = AgentConfigOptions:new(
            { chat = test_bufnr },
            function() end,
            function() end
        )
    end)

    after_each(function()
        multi_keymap_stub:revert()
        vim.api.nvim_buf_delete(test_bufnr, { force = true })
    end)

    describe("constructor", function()
        it(
            "registers keymaps for config, model, reasoning effort, and approval preset on all buffers",
            function()
                assert.stub(multi_keymap_stub).was.called(4)

                local mode_call = multi_keymap_stub.calls[1]
                assert.equal("function", type(mode_call[3]))

                local model_call = multi_keymap_stub.calls[2]
                assert.equal("function", type(model_call[3]))

                local thought_call = multi_keymap_stub.calls[3]
                assert.equal("function", type(thought_call[3]))

                local approval_call = multi_keymap_stub.calls[4]
                assert.equal("function", type(approval_call[3]))
                assert.equal("<localLeader>p", approval_call[1])
            end
        )
    end)

    describe("set_options", function()
        it("assigns all known categories from a single call", function()
            config_options:set_options({
                mode_option,
                model_option,
                thought_option,
                approval_option,
            })

            assert.equal("mode-1", config_options.mode.id)
            assert.equal("model-1", config_options.model.id)
            assert.equal("thought-1", config_options.thought_level.id)
            assert.equal("approval-1", config_options.approval_preset.id)
        end)

        it("detects approval preset options by approval-like labels", function()
            --- @type agentic.acp.ConfigOption
            local aliased_approval = vim.tbl_extend("force", approval_option, {
                category = "sandbox_mode",
                name = "Approval Mode",
                description = "Approval access level",
            }) --[[@as agentic.acp.ConfigOption]]

            config_options:set_options({ aliased_approval })

            assert.equal("approval-1", config_options.approval_preset.id)
        end)

        it("does nothing when configOptions is nil", function()
            config_options:set_options(nil)

            assert.is_nil(config_options.mode)
            assert.is_nil(config_options.model)
            assert.is_nil(config_options.thought_level)
            assert.is_nil(config_options.approval_preset)
        end)

        it("ignores unknown categories", function()
            --- @type agentic.acp.ConfigOption
            local unknown = vim.tbl_extend("force", mode_option, {
                category = "unknown_cat",
            }) --[[@as agentic.acp.ConfigOption]]

            config_options:set_options({ unknown })

            assert.is_nil(config_options.mode)
        end)
    end)

    describe("get_mode", function()
        it("returns matching option by value", function()
            config_options:set_options({ mode_option })

            local result = config_options:get_mode("plan")

            assert.is_not_nil(result)
            if result then
                assert.equal("Plan", result.name)
            end
        end)

        it(
            "returns nil when mode is unset, empty, or value not found",
            function()
                assert.is_nil(config_options:get_mode("normal"))

                local empty_mode = vim.tbl_extend("force", mode_option, {
                    options = {},
                }) --[[@as agentic.acp.ConfigOption]]
                config_options:set_options({ empty_mode })
                assert.is_nil(config_options:get_mode("normal"))

                config_options:set_options({ mode_option })
                assert.is_nil(config_options:get_mode("nonexistent"))
            end
        )
    end)

    describe("get_model", function()
        it("returns matching model option by value", function()
            config_options:set_options({ model_option })

            local result = config_options:get_model("claude-sonnet")

            assert.is_not_nil(result)
            if result then
                assert.equal("Sonnet", result.name)
            end
        end)

        it("returns nil when model is unset or value not found", function()
            assert.is_nil(config_options:get_model("claude-sonnet"))

            config_options:set_options({ model_option })
            assert.is_nil(config_options:get_model("nonexistent"))
        end)
    end)

    describe("get_mode_name", function()
        it("returns name from config option mode", function()
            config_options:set_options({ mode_option })

            assert.equal("Plan", config_options:get_mode_name("plan"))
        end)

        it("returns name from legacy mode", function()
            config_options.legacy_agent_modes:set_modes({
                availableModes = {
                    {
                        id = "legacy-mode",
                        name = "Legacy",
                        description = "Legacy mode",
                    },
                },
                currentModeId = "legacy-mode",
            })

            assert.equal("Legacy", config_options:get_mode_name("legacy-mode"))
        end)

        it("returns nil when mode not found in either source", function()
            config_options:set_options({ mode_option })

            assert.is_nil(config_options:get_mode_name("nonexistent"))
        end)
    end)

    describe("set_initial_mode", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            config_options:set_options({ mode_option })
            local Logger = require("agentic.utils.logger")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        it(
            "calls handler when target differs from current config mode",
            function()
                local handler = spy.new(function() end)

                config_options:set_initial_mode(
                    "plan",
                    handler --[[@as fun(mode: string, is_legacy: boolean|nil): any]]
                )

                assert.spy(handler).was.called(1)
                local args = handler.calls[1]
                assert.equal("plan", args[1])
                assert.is_false(args[2])
            end
        )

        it("calls handler with is_legacy=true for legacy modes", function()
            config_options.legacy_agent_modes:set_modes({
                availableModes = {
                    {
                        id = "legacy-plan",
                        name = "Legacy Plan",
                        description = "",
                    },
                },
                currentModeId = "legacy-normal",
            })

            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                "legacy-plan",
                handler --[[@as fun(mode: string, is_legacy: boolean|nil): any]]
            )

            assert.spy(handler).was.called(1)
            local args = handler.calls[1]
            assert.equal("legacy-plan", args[1])
            assert.is_true(args[2])
        end)

        it("skips handler when target matches currentValue", function()
            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                "normal",
                handler --[[@as fun(mode: string, is_legacy: boolean|nil): any]]
            )

            assert.spy(handler).was.called(0)
        end)

        it("warns when target is not in any mode source", function()
            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                "nonexistent",
                handler --[[@as fun(mode: string, is_legacy: boolean|nil): any]]
            )

            assert.spy(handler).was.called(0)
            assert.stub(notify_stub).was.called(1)
            assert.is_true(
                string.find(notify_stub.calls[1][1], "nonexistent") ~= nil
            )
        end)

        it("does nothing when target is nil or empty", function()
            local handler = spy.new(function() end)

            config_options:set_initial_mode(
                nil,
                handler --[[@as fun(mode: string, is_legacy: boolean|nil): any]]
            )
            config_options:set_initial_mode(
                "",
                handler --[[@as fun(mode: string, is_legacy: boolean|nil): any]]
            )

            assert.spy(handler).was.called(0)
            assert.stub(notify_stub).was.called(0)
        end)

        it(
            "does not crash when no config options and no legacy modes exist",
            function()
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end
                )
                local handler = spy.new(function() end)

                assert.has_no_errors(function()
                    fresh:set_initial_mode(
                        "nonexistent",
                        handler --[[@as fun(mode: string, is_legacy: boolean|nil): any]]
                    )
                end)

                assert.spy(handler).was.called(0)
                assert.stub(notify_stub).was.called(1)
                assert.is_true(
                    string.find(notify_stub.calls[1][1], "unknown") ~= nil
                )
            end
        )
    end)

    describe("show_mode_selector", function()
        --- @type TestStub
        local select_stub

        before_each(function()
            config_options:set_options({ mode_option })
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it(
            "returns true and opens vim.ui.select when config modes exist",
            function()
                local shown = config_options:show_mode_selector(function() end)

                assert.is_true(shown)
                assert.stub(select_stub).was.called(1)
            end
        )

        it(
            "calls handler with value and is_legacy=false on config-option selection",
            function()
                local handler = spy.new(function() end)
                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                config_options:show_mode_selector(
                    handler --[[@as fun(mode: string, is_legacy: boolean): any]]
                )

                assert.spy(handler).was.called_with("plan", false)
            end
        )

        it("does not call handler on current value or cancel", function()
            local handler = spy.new(function() end)

            select_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[1])
            end)
            config_options:show_mode_selector(
                handler --[[@as fun(mode: string, is_config_option: boolean): any]]
            )

            select_stub:invokes(function(_items, _opts, on_choice)
                on_choice(nil)
            end)
            config_options:show_mode_selector(
                handler --[[@as fun(mode: string, is_config_option: boolean): any]]
            )

            assert.spy(handler).was.called(0)
        end)

        it(
            "falls back to legacy modes and wraps callback with is_legacy=true",
            function()
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end
                )
                fresh.legacy_agent_modes:set_modes({
                    availableModes = {
                        {
                            id = "legacy",
                            name = "Legacy",
                            description = "Legacy mode",
                        },
                        {
                            id = "legacy-2",
                            name = "Legacy 2",
                            description = "Another",
                        },
                    },
                    currentModeId = "legacy",
                })

                local handler = spy.new(function() end)
                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                local shown = fresh:show_mode_selector(
                    handler --[[@as fun(mode: string, is_config_option: boolean): any]]
                )

                assert.is_true(shown)
                assert.stub(select_stub).was.called(1)
                assert.spy(handler).was.called_with("legacy-2", true)
            end
        )

        it("returns false and notifies when no modes exist at all", function()
            local Logger = require("agentic.utils.logger")
            local notify_stub = spy.stub(Logger, "notify")

            local fresh = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )
            local handler = function() end

            assert.is_false(fresh:show_mode_selector(handler))
            assert.stub(select_stub).was.called(0)
            assert.stub(notify_stub).was.called(1)
            assert.truthy(
                string.find(notify_stub.calls[1][1], "mode switching")
            )
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])

            notify_stub:revert()
        end)
    end)

    describe("show_model_selector", function()
        --- @type TestStub
        local select_stub

        before_each(function()
            config_options:set_options({ model_option })
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it("opens vim.ui.select with model options", function()
            local shown = config_options:show_model_selector(function() end)

            assert.is_true(shown)
            assert.stub(select_stub).was.called(1)
        end)

        it(
            "calls handler with selected model value and is_legacy=false",
            function()
                local handler = spy.new(function() end)
                --- Add a second model so selection differs from current
                local multi_model = vim.tbl_extend("force", model_option, {
                    options = {
                        {
                            value = "claude-sonnet",
                            name = "Sonnet",
                            description = "Fast",
                        },
                        {
                            value = "claude-opus",
                            name = "Opus",
                            description = "Smart",
                        },
                    },
                }) --[[@as agentic.acp.ConfigOption]]
                config_options:set_options({ multi_model })

                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                config_options:show_model_selector(
                    handler --[[@as fun(model: string, is_legacy: boolean): any]]
                )

                assert.spy(handler).was.called_with("claude-opus", false)
            end
        )

        it(
            "falls back to legacy models and wraps callback with is_legacy=true",
            function()
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end
                )
                fresh.legacy_agent_models:set_models({
                    availableModels = {
                        {
                            modelId = "default",
                            name = "Default",
                            description = "Default model",
                        },
                        {
                            modelId = "opus",
                            name = "Opus",
                            description = "Most capable",
                        },
                    },
                    currentModelId = "default",
                })

                local handler = spy.new(function() end)
                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                local shown = fresh:show_model_selector(
                    handler --[[@as fun(model: string, is_legacy: boolean): any]]
                )

                assert.is_true(shown)
                assert.stub(select_stub).was.called(1)
                assert.spy(handler).was.called_with("opus", true)
            end
        )

        it("returns false and notifies when no model options exist", function()
            local Logger = require("agentic.utils.logger")
            local notify_stub = spy.stub(Logger, "notify")

            local fresh = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            assert.is_false(fresh:show_model_selector(function() end))
            assert.stub(select_stub).was.called(0)
            assert.stub(notify_stub).was.called(1)
            assert.truthy(
                string.find(notify_stub.calls[1][1], "model switching")
            )
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])

            notify_stub:revert()
        end)
    end)

    describe("show_thought_level_selector", function()
        --- @type TestStub
        local select_stub

        before_each(function()
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it(
            "routes the selected reasoning effort through set_config_option",
            function()
                local generic_change = spy.new(function() end)
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end,
                    generic_change --[[@as fun(config_id: string, value: string)]]
                )
                local multi_thought = vim.tbl_extend("force", thought_option, {
                    options = {
                        {
                            value = "normal",
                            name = "Normal",
                            description = "Standard",
                        },
                        {
                            value = "deep",
                            name = "Deep",
                            description = "Extended",
                        },
                    },
                }) --[[@as agentic.acp.ConfigOption]]

                fresh:set_options({ multi_thought })

                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                assert.is_true(fresh:show_thought_level_selector())
                assert.spy(generic_change).was.called_with("thought-1", "deep")
            end
        )

        it(
            "returns false and notifies when reasoning effort is unavailable",
            function()
                local Logger = require("agentic.utils.logger")
                local notify_stub = spy.stub(Logger, "notify")
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end
                )

                assert.is_false(fresh:show_thought_level_selector())
                assert.stub(select_stub).was.called(0)
                assert.stub(notify_stub).was.called(1)
                assert.truthy(
                    string.find(
                        notify_stub.calls[1][1],
                        "reasoning effort switching"
                    )
                )

                notify_stub:revert()
            end
        )
    end)

    describe("show_approval_preset_selector", function()
        --- @type TestStub
        local select_stub

        before_each(function()
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it(
            "routes the selected approval preset through set_config_option",
            function()
                local generic_change = spy.new(function() end)
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end,
                    generic_change --[[@as fun(config_id: string, value: string)]]
                )

                fresh:set_options({ approval_option })

                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                assert.is_true(fresh:show_approval_preset_selector())
                assert.spy(generic_change).was.called_with("approval-1", "default")
            end
        )

        it(
            "falls back to matching provider options even if approval_preset was not assigned yet",
            function()
                local generic_change = spy.new(function() end)
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end,
                    generic_change --[[@as fun(config_id: string, value: string)]]
                )

                local aliased_approval = vim.tbl_extend("force", approval_option, {
                    category = "sandbox_mode",
                    name = "Approval Mode",
                    description = "Approval access level",
                }) --[[@as agentic.acp.ConfigOption]]

                fresh._options = { aliased_approval }
                fresh._options_by_id = {
                    [aliased_approval.id] = aliased_approval,
                }

                select_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                assert.is_true(fresh:show_approval_preset_selector())
                assert.spy(generic_change).was.called_with("approval-1", "default")
            end
        )

        it(
            "returns false and notifies when approval preset is unavailable",
            function()
                local Logger = require("agentic.utils.logger")
                local notify_stub = spy.stub(Logger, "notify")
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end
                )

                assert.is_false(fresh:show_approval_preset_selector())
                assert.stub(select_stub).was.called(0)
                assert.stub(notify_stub).was.called(1)
                assert.truthy(
                    string.find(
                        notify_stub.calls[1][1],
                        "approval preset switching"
                    )
                )

                notify_stub:revert()
            end
        )
    end)

    describe("set_legacy_models", function()
        it("stores legacy models info", function()
            config_options:set_legacy_models({
                availableModels = {
                    {
                        modelId = "opus",
                        name = "Opus",
                        description = "Most capable",
                    },
                },
                currentModelId = "opus",
            })

            local model = config_options.legacy_agent_models:get_model("opus")
            assert.is_not_nil(model)
            assert.equal(
                "opus",
                config_options.legacy_agent_models.current_model_id
            )
        end)
    end)

    describe("clear", function()
        it("resets all fields, legacy modes, and legacy models", function()
            config_options:set_options({
                mode_option,
                model_option,
                thought_option,
                approval_option,
            })
            config_options.legacy_agent_modes:set_modes({
                availableModes = {
                    { id = "legacy", name = "Legacy", description = "" },
                },
                currentModeId = "legacy",
            })
            config_options.legacy_agent_models:set_models({
                availableModels = {
                    {
                        modelId = "opus",
                        name = "Opus",
                        description = "Most capable",
                    },
                },
                currentModelId = "opus",
            })

            config_options:clear()

            assert.is_nil(config_options.mode)
            assert.is_nil(config_options.model)
            assert.is_nil(config_options.thought_level)
            assert.is_nil(config_options.approval_preset)
            assert.is_nil(config_options.legacy_agent_modes:get_mode("legacy"))
            assert.is_nil(config_options.legacy_agent_modes.current_mode_id)
            assert.is_nil(config_options.legacy_agent_models:get_model("opus"))
            assert.is_nil(config_options.legacy_agent_models.current_model_id)
        end)
    end)
end)
