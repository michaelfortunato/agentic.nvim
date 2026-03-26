local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentConfigOptions = require("agentic.acp.agent_config_options")
local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

describe("config selector", function()
    --- @type TestStub
    local notify_stub
    --- @type TestStub
    local select_stub

    local format_all = function(items, opts)
        return vim.tbl_map(function(item)
            return opts.format_item(item)
        end, items)
    end

    before_each(function()
        notify_stub = spy.stub(Logger, "notify")
        select_stub = spy.stub(vim.ui, "select")
    end)

    after_each(function()
        notify_stub:revert()
        select_stub:revert()
    end)

    describe("AgentConfigOptions (modern provider)", function()
        it("marks default model and updates after selection", function()
            local config = AgentConfigOptions:new(
                {},
                function() end,
                function() end
            )
            ---@diagnostic disable-next-line: missing-fields
            config:set_options({
                ---@diagnostic disable-next-line: missing-fields
                {
                    id = "model-1",
                    category = "model",
                    currentValue = "m2",
                    name = "Model",
                    options = {
                        ---@diagnostic disable-next-line: missing-fields
                        { value = "m1", name = "M1" },
                        ---@diagnostic disable-next-line: missing-fields
                        { value = "m2", name = "M2" },
                    },
                },
            })

            -- Simulate provider update after selection
            local handle_model_change = function(model_id)
                ---@diagnostic disable-next-line: missing-fields
                config:set_options({
                    ---@diagnostic disable-next-line: missing-fields
                    {
                        id = "model-1",
                        category = "model",
                        currentValue = model_id,
                        name = "Model",
                        options = {
                            ---@diagnostic disable-next-line: missing-fields
                            { value = "m1", name = "M1" },
                            ---@diagnostic disable-next-line: missing-fields
                            { value = "m2", name = "M2" },
                        },
                    },
                })
            end

            -- Verify initial state and select m1
            local first_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                first_render = format_all(items, opts)
                on_choice(items[2]) -- select m1
            end)
            config:show_model_selector(handle_model_change)

            assert.same({ "● M2", "  M1" }, first_render)

            -- Re-open to verify it was updated
            local second_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                second_render = format_all(items, opts)
                on_choice(nil)
            end)
            config:show_model_selector(handle_model_change)

            assert.same({ "● M1", "  M2" }, second_render)
        end)

        it("renders approval preset labels exactly as provided", function()
            local config = AgentConfigOptions:new(
                {},
                function() end,
                function() end
            )

            config:set_options({
                {
                    id = "approval-1",
                    category = "unknown",
                    currentValue = "read_only",
                    name = "Approval Preset",
                    options = {
                        { value = "read_only", name = "Read Only" },
                        { value = "default", name = "Default" },
                    },
                },
            })

            local steering_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                steering_render = format_all(items, opts)
                on_choice(nil)
            end)

            config:show_config_selector()

            assert.equal(
                "Approval Preset: Read Only",
                config:get_header_context()
            )
            assert.same({ "  Approval Preset: Read Only" }, steering_render)
        end)
    end)

    describe("AgentModels (legacy provider integration)", function()
        it("marks initial legacy model and updates after success", function()
            -- Setup minimal session that uses the REAL _handle_model_change logic
            ---@type any
            local session = {
                session_id = "s1",
                config_options = AgentConfigOptions:new(
                    {},
                    function() end,
                    function() end
                ),
                chat_history = { title = "" },
                widget = {
                    render_header = function() end,
                },
                agent = {
                    set_model = function(_self, _id, _model, callback)
                        callback({}, nil) -- Success
                    end,
                },
                ---@diagnostic disable-next-line: invisible
                _handle_model_change = SessionManager._handle_model_change,
                _render_window_headers = SessionManager._render_window_headers,
            }

            session.config_options:set_legacy_models({
                availableModels = {
                    { modelId = "m1", name = "M1", description = "D1" },
                    { modelId = "m2", name = "M2", description = "D2" },
                },
                currentModelId = "m2",
            })

            -- Verify initial state
            local first_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                first_render = format_all(items, opts)
                on_choice(nil)
            end)
            session.config_options:show_model_selector(function() end)

            assert.same({ "● M2: D2", "  M1: D1" }, first_render)

            -- Call the REAL _handle_model_change
            ---@diagnostic disable-next-line: invisible
            session:_handle_model_change("m1", true)

            -- Verify the fix: legacy_agent_models state should be updated via SessionManager callback
            assert.equal(
                "m1",
                session.config_options.legacy_agent_models.current_model_id
            )

            -- Verify UI also reflects it when re-opening
            local second_render = {}
            select_stub:invokes(function(items, opts, on_choice)
                second_render = format_all(items, opts)
                on_choice(nil)
            end)

            -- Selection logic triggers model change handler
            session.config_options:show_model_selector(
                function(model_id, is_legacy)
                    ---@diagnostic disable-next-line: invisible
                    session:_handle_model_change(model_id, is_legacy)
                end
            )

            assert.same({ "● M1: D1", "  M2: D2" }, second_render)
        end)

        it(
            "preserves provider config option ordering in the config selector",
            function()
                local generic_change = spy.new(function() end)
                local config = AgentConfigOptions:new(
                    {},
                    function() end,
                    function() end,
                    generic_change --[[@as fun(config_id: string, value: string)]]
                )

                ---@diagnostic disable-next-line: missing-fields
                config:set_options({
                    {
                        id = "thought-1",
                        category = "thought_level",
                        currentValue = "normal",
                        name = "Thought Level",
                        options = {
                            { value = "normal", name = "Normal" },
                            { value = "deep", name = "Deep" },
                        },
                    },
                    {
                        id = "model-1",
                        category = "model",
                        currentValue = "m2",
                        name = "Model",
                        options = {
                            { value = "m1", name = "M1" },
                            { value = "m2", name = "M2" },
                        },
                    },
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "code",
                        name = "Mode",
                        options = {
                            { value = "plan", name = "Plan" },
                            { value = "code", name = "Code" },
                        },
                    },
                })

                local steering_render = {}
                local select_call = 0

                select_stub:invokes(function(items, opts, on_choice)
                    select_call = select_call + 1

                    if select_call == 1 then
                        steering_render = format_all(items, opts)
                        on_choice(items[1])
                        return
                    end

                    on_choice(items[2])
                end)

                config:show_config_selector()

                assert.same({
                    "  Thought Level: Normal",
                    "  Model: M2",
                    "  Mode: Code",
                }, steering_render)
                assert.spy(generic_change).was.called_with("thought-1", "deep")
            end
        )

        it("builds header context in provider order", function()
            local config = AgentConfigOptions:new(
                {},
                function() end,
                function() end
            )

            ---@diagnostic disable-next-line: missing-fields
            config:set_options({
                {
                    id = "thought-1",
                    category = "thought_level",
                    currentValue = "deep",
                    name = "Thought Level",
                    options = {
                        { value = "normal", name = "Normal" },
                        { value = "deep", name = "Deep" },
                    },
                },
                {
                    id = "model-1",
                    category = "model",
                    currentValue = "m2",
                    name = "Model",
                    options = {
                        { value = "m2", name = "M2" },
                    },
                },
                {
                    id = "mode-1",
                    category = "mode",
                    currentValue = "code",
                    name = "Mode",
                    options = {
                        { value = "code", name = "Code" },
                    },
                },
            })

            assert.equal(
                "Thought Level: Deep | Model: M2 | Mode: Code",
                config:get_header_context()
            )
        end)
    end)
end)
