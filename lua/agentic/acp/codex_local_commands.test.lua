---@diagnostic disable: missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local SessionEvents = require("agentic.session.session_events")
local SessionState = require("agentic.session.session_state")

describe("agentic.acp.CodexLocalCommands", function()
    --- @type agentic.acp.CodexLocalCommands
    local CodexLocalCommands

    before_each(function()
        package.loaded["agentic.acp.codex_local_commands"] = nil
        CodexLocalCommands = require("agentic.acp.codex_local_commands")
    end)

    --- @param opts table|nil
    --- @return agentic.SessionManager
    local function make_session(opts)
        opts = opts or {}
        local session_state = SessionState:new()
        if opts.available_commands then
            session_state:dispatch(
                SessionEvents.set_available_commands(opts.available_commands)
            )
        end

        return {
            agent = {
                provider_config = opts.provider_config or {
                    name = "Codex",
                },
            },
            session_state = session_state,
            config_options = opts.config_options,
            skill_picker = opts.skill_picker,
            widget = opts.widget,
        } --[[@as agentic.SessionManager]]
    end

    it("returns no local commands for non-Codex sessions", function()
        local session = make_session({
            provider_config = {
                name = "Claude",
            },
        })

        assert.same({}, CodexLocalCommands.get_available_commands(session))
    end)

    it("exposes only the locally supported Codex shortcuts", function()
        local session = make_session({
            config_options = {
                get_approval_preset_option = function()
                    return { id = "approval" }
                end,
                get_model_option = function()
                    return { id = "model" }
                end,
                get_thought_level_option = function()
                    return nil
                end,
            },
            skill_picker = {
                has_skills = function()
                    return true
                end,
            },
        })

        local commands = CodexLocalCommands.get_available_commands(session)
        local names = vim.tbl_map(function(command)
            return command.name
        end, commands)

        assert.same({ "permissions", "model", "skills" }, names)
    end)

    it("does not shadow commands already advertised by the agent", function()
        local session = make_session({
            available_commands = {
                {
                    name = "permissions",
                    description = "Native permissions command",
                },
            },
            config_options = {
                get_approval_preset_option = function()
                    return { id = "approval" }
                end,
                get_model_option = function()
                    return { id = "model" }
                end,
                get_thought_level_option = function()
                    return nil
                end,
            },
        })

        local commands = CodexLocalCommands.get_available_commands(session)
        local names = vim.tbl_map(function(command)
            return command.name
        end, commands)

        assert.same({ "model" }, names)
    end)

    it("routes /permissions to the approval preset selector", function()
        local approval_spy = spy.new(function() end)
        local session = make_session({
            config_options = {
                get_approval_preset_option = function()
                    return { id = "approval" }
                end,
                show_approval_preset_selector = approval_spy,
            },
        })

        assert.is_true(CodexLocalCommands.handle_input(session, "/permissions"))
        assert.spy(approval_spy).was.called(1)
    end)

    it(
        "routes /model to the combined config selector when available",
        function()
            local config_spy = spy.new(function()
                return true
            end)
            local session = make_session({
                config_options = {
                    get_model_option = function()
                        return { id = "model" }
                    end,
                    get_thought_level_option = function()
                        return { id = "thought_level" }
                    end,
                    show_config_selector = config_spy,
                },
            })

            assert.is_true(CodexLocalCommands.handle_input(session, "/model"))
            assert.spy(config_spy).was.called(1)
        end
    )

    it("opens the skill list and inserts the chosen skill mention", function()
        local set_input_text_spy = spy.new(function() end)
        local focus_input_spy = spy.new(function() end)
        local captured_callback = nil
        local show_selector_spy = spy.new(function(_self, callback)
            captured_callback = callback
            return true
        end)

        local session = make_session({
            skill_picker = {
                has_skills = function()
                    return true
                end,
                show_selector = show_selector_spy,
            },
            widget = {
                set_input_text = set_input_text_spy,
                focus_input = focus_input_spy,
            },
        })

        assert.is_true(CodexLocalCommands.handle_input(session, "/skills"))
        assert.spy(show_selector_spy).was.called(1)
        assert.is_not_nil(captured_callback)

        local on_choice = captured_callback --[[@as fun(choice: table)]]
        on_choice({
            name = "openai-docs",
        })

        assert
            .spy(set_input_text_spy).was
            .called_with(session.widget, "$openai-docs ")
        assert.spy(focus_input_spy).was.called_with(session.widget)
    end)
end)
