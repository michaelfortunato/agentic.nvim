local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentConfigOptions", function()
    local AgentConfigOptions
    local config_options
    local multi_keymap_stub
    local test_bufnr

    local mode_option = {
        id = "mode-1",
        category = "mode",
        currentValue = "normal",
        description = "Agent mode",
        name = "Mode",
        options = {
            { value = "normal", name = "Normal", description = "Standard" },
            { value = "plan", name = "Plan", description = "Planning" },
        },
    }

    local model_option = {
        id = "model-1",
        category = "model",
        currentValue = "gpt-5.4",
        description = "Model selection",
        name = "Model",
        options = {
            { value = "gpt-5.4", name = "GPT-5.4", description = "Fast" },
            { value = "gpt-5.5", name = "GPT-5.5", description = "Newer" },
        },
    }

    local thought_option = {
        id = "thought-1",
        category = "thought_level",
        currentValue = "high",
        description = "Reasoning Effort",
        name = "Reasoning Effort",
        options = {
            { value = "high", name = "High", description = "More work" },
            { value = "xhigh", name = "Xhigh", description = "Max work" },
        },
    }

    local approval_option = {
        id = "approval-1",
        category = "approval_preset",
        currentValue = "read-only",
        description = "Approval access level",
        name = "Approval Preset",
        options = {
            {
                value = "read-only",
                name = "Read Only",
                description = "No writes",
            },
            {
                value = "default",
                name = "Default",
                description = "Standard access",
            },
        },
    }

    local grouped_model_option = {
        id = "model-grouped",
        category = "model",
        currentValue = "gpt-5.5",
        description = "Model selection",
        name = "Model",
        type = "select",
        options = {
            {
                group = "stable",
                name = "Stable",
                options = {
                    {
                        value = "gpt-5.4",
                        name = "GPT-5.4",
                        description = "Fast",
                    },
                },
            },
            {
                group = "preview",
                name = "Preview",
                options = {
                    {
                        value = "gpt-5.5",
                        name = "GPT-5.5",
                        description = "Newer",
                    },
                },
            },
        },
    }

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

    it("registers config keymaps on construction", function()
        assert.stub(multi_keymap_stub).was.called(4)
        assert.equal("<localLeader>p", multi_keymap_stub.calls[4][1])
    end)

    it("assigns known config categories from provider options", function()
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

    it(
        "does not infer approval preset shortcuts from unrelated categories",
        function()
            local aliased = vim.tbl_extend("force", approval_option, {
                category = "sandbox_mode",
                name = "Approval Mode",
                description = "Approval access level",
            })

            config_options:set_options({ aliased })

            assert.is_nil(config_options.approval_preset)
        end
    )

    it("builds header context from provider option order", function()
        config_options:set_options({
            approval_option,
            model_option,
            thought_option,
        })

        assert.equal(
            "Approval Preset: Read Only | Model: GPT-5.4 | Reasoning Effort: High",
            config_options:get_header_context()
        )
    end)

    it("returns mode and model names from config options", function()
        config_options:set_options({ mode_option, model_option })

        assert.equal("Plan", config_options:get_mode_name("plan"))
        assert.equal(
            "GPT-5.5",
            config_options:get_config_value_name("model-1", "gpt-5.5")
        )
    end)

    it("applies current_mode_update to the active mode option", function()
        config_options:set_options({
            vim.tbl_deep_extend("force", {}, mode_option),
        })

        config_options:set_current_mode("plan")

        assert.equal("plan", config_options.mode.currentValue)
    end)

    it("warns when configured default_mode is not available", function()
        local Logger = require("agentic.utils.logger")
        local notify_stub = spy.stub(Logger, "notify")
        local handler = spy.new(function() end)

        config_options:set_options({ mode_option })
        config_options:set_initial_mode("missing-mode", handler)

        assert.spy(handler).was.called(0)
        assert.stub(notify_stub).was.called(1)

        notify_stub:revert()
    end)

    it("switches to a configured default mode when available", function()
        local handler = spy.new(function() end)

        config_options:set_options({ mode_option })
        config_options:set_initial_mode("plan", handler)

        assert.spy(handler).was.called_with("plan")
    end)

    describe("selectors", function()
        local chooser_show_stub

        before_each(function()
            local Chooser = require("agentic.ui.chooser")
            chooser_show_stub = spy.stub(Chooser, "show")
        end)

        after_each(function()
            chooser_show_stub:revert()
        end)

        it("shows model selector and routes selected model value", function()
            local handler = spy.new(function() end)
            config_options:set_options({ model_option })

            chooser_show_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[2])
            end)

            assert.is_true(config_options:show_model_selector(handler))
            assert.spy(handler).was.called_with("gpt-5.5")
        end)

        it("shows mode selector and routes selected mode value", function()
            local handler = spy.new(function() end)
            config_options:set_options({ mode_option })

            chooser_show_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[2])
            end)

            assert.is_true(config_options:show_mode_selector(handler))
            assert.spy(handler).was.called_with("plan")
        end)

        it("flattens grouped select options from the ACP schema", function()
            local handler = spy.new(function() end)
            local fresh = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            fresh:set_options({ grouped_model_option })

            chooser_show_stub:invokes(function(items, _opts, on_choice)
                assert.equal(2, #items)
                on_choice(items[2])
            end)

            assert.is_true(fresh:show_model_selector(handler))
            assert.spy(handler).was.called_with("gpt-5.4")
        end)

        it(
            "shows thought-level selector and writes config option changes",
            function()
                local generic_change = spy.new(function() end)
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end,
                    generic_change
                )

                fresh:set_options({ thought_option })
                chooser_show_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                assert.is_true(fresh:show_thought_level_selector())
                assert.spy(generic_change).was.called_with("thought-1", "xhigh")
            end
        )

        it(
            "shows approval preset selector and writes config option changes",
            function()
                local generic_change = spy.new(function() end)
                local fresh = AgentConfigOptions:new(
                    { chat = test_bufnr },
                    function() end,
                    function() end,
                    generic_change
                )

                fresh:set_options({ approval_option })
                chooser_show_stub:invokes(function(items, _opts, on_choice)
                    on_choice(items[2])
                end)

                assert.is_true(fresh:show_approval_preset_selector())
                assert
                    .spy(generic_change).was
                    .called_with("approval-1", "default")
            end
        )

        it("shows session config selector in provider order", function()
            local generic_change = spy.new(function() end)
            local fresh = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end,
                generic_change
            )
            local render = {}
            local select_call = 0

            fresh:set_options({ thought_option, model_option, approval_option })

            chooser_show_stub:invokes(function(items, opts, on_choice)
                select_call = select_call + 1

                if select_call == 1 then
                    render = vim.tbl_map(opts.format_item, items)
                    on_choice(items[1])
                    return
                end

                on_choice(items[2])
            end)

            assert.is_true(fresh:show_config_selector())
            assert.same({
                "  Reasoning Effort: High",
                "  Model: GPT-5.4",
                "  Approval Preset: Read Only",
            }, render)
            assert.spy(generic_change).was.called_with("thought-1", "xhigh")
        end)
    end)

    it("clear resets provider options", function()
        config_options:set_options({
            mode_option,
            model_option,
            thought_option,
            approval_option,
        })

        config_options:clear()

        assert.is_nil(config_options.mode)
        assert.is_nil(config_options.model)
        assert.is_nil(config_options.thought_level)
        assert.is_nil(config_options.approval_preset)
        assert.same({}, config_options._options)
    end)
end)
