local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local States = require("agentic.states")

describe("agentic.acp.SlashCommands", function()
    local SlashCommands
    local BlinkSource

    --- @type integer
    local bufnr
    local original_slash_trigger
    local original_loaded = {}
    local blink_show_spy
    local blink_add_source_provider_spy
    local blink_add_filetype_source_spy

    local function install_blink_mock()
        for _, module_name in ipairs({
            "blink.cmp",
            "blink.cmp.config",
            "blink.cmp.completion.windows.menu",
            "agentic.acp.slash_commands",
            "agentic.acp.slash_commands_blink_source",
        }) do
            original_loaded[module_name] = package.loaded[module_name]
            package.loaded[module_name] = nil
        end

        blink_show_spy = spy.new(function() end)
        blink_add_source_provider_spy = spy.new(function() end)
        blink_add_filetype_source_spy = spy.new(function() end)

        package.loaded["blink.cmp"] = {
            add_source_provider = blink_add_source_provider_spy,
            add_filetype_source = blink_add_filetype_source_spy,
            show = blink_show_spy,
        }
        package.loaded["blink.cmp.config"] = {
            sources = {
                providers = {},
            },
        }
        package.loaded["blink.cmp.completion.windows.menu"] = {
            win = {
                is_open = function()
                    return false
                end,
            },
        }
    end

    local function restore_loaded_modules()
        for module_name, loaded in pairs(original_loaded) do
            package.loaded[module_name] = loaded
        end
        original_loaded = {}
    end

    before_each(function()
        original_slash_trigger = Config.completion.slash_trigger
        Config.completion.slash_trigger = "/"
        install_blink_mock()
        SlashCommands = require("agentic.acp.slash_commands")
        BlinkSource = require("agentic.acp.slash_commands_blink_source")
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        SlashCommands.setup_completion(bufnr)
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        Config.completion.slash_trigger = original_slash_trigger
        restore_loaded_modules()
    end)

    describe("setCommands", function()
        it(
            "sets commands from ACP provider and automatically adds /new",
            function()
                --- @type agentic.acp.AvailableCommand[]
                local commands_mock = {
                    { name = "plan", description = "Create a plan" },
                    { name = "review", description = "Review code" },
                }

                SlashCommands.setCommands(bufnr, commands_mock)

                local commands = States.getSlashCommands()

                -- Verify total count includes /new
                assert.equal(3, #commands)

                -- Verify provided commands are set correctly
                assert.equal("plan", commands[1].word)
                assert.equal("Create a plan", commands[1].menu)
                assert.equal("Create a plan", commands[1].info)
                assert.equal("review", commands[2].word)
                assert.equal("Review code", commands[2].menu)
                assert.equal("Review code", commands[2].info)

                -- Verify /new was automatically added at the end
                assert.equal("new", commands[3].word)
                assert.equal("Start a new session", commands[3].menu)
                assert.equal("Start a new session", commands[3].info)
            end
        )

        it("does not duplicate /new command if already provided", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "new", description = "Custom new description" },
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()

            assert.equal(2, #commands)

            local new_count = 0
            for _, cmd in ipairs(commands) do
                if cmd.word == "new" then
                    new_count = new_count + 1
                    assert.equal("Custom new description", cmd.menu)
                    assert.equal("Custom new description", cmd.info)
                end
            end
            assert.equal(1, new_count)
        end)

        it("merges local commands without duplicating ACP commands", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
                { name = "model", description = "ACP model command" },
            }

            --- @type agentic.acp.AvailableCommand[]
            local local_commands = {
                { name = "model", description = "Local duplicate" },
                { name = "skills", description = "Local skills command" },
            }

            SlashCommands.setCommands(bufnr, commands_mock, {
                local_commands = local_commands,
            })

            local commands = States.getSlashCommands()

            assert.equal(4, #commands)
            assert.equal("plan", commands[1].word)
            assert.equal("model", commands[2].word)
            assert.equal("ACP model command", commands[2].menu)
            assert.equal("skills", commands[3].word)
            assert.equal("Start a new session", commands[4].menu)
        end)

        it("filters out commands with spaces in name", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "valid", description = "Valid command" },
                { name = "has space", description = "Invalid command" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()

            assert.equal(2, #commands) -- valid + /new
            for _, cmd in ipairs(commands) do
                assert.is_false(cmd.word:match("%s") ~= nil)
            end
        end)

        it("filters out clear command", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
                { name = "clear", description = "Clear session" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            assert.equal(2, #commands) -- plan + /new
            for _, cmd in ipairs(commands) do
                assert.is_not.equal("clear", cmd.word)
            end
        end)

        it("skips commands with missing name or description", function()
            --- @type table[]
            local commands_mock = {
                { name = "valid", description = "Valid command" },
                { name = "no-desc" }, -- Missing description
                { description = "No name" }, -- Missing name
            }

            ---@diagnostic disable-next-line: param-type-mismatch
            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            assert.equal(2, #commands) -- valid + /new
        end)

        it("sets case-insensitive completion", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            for _, cmd in ipairs(commands) do
                assert.equal(1, cmd.icase)
            end
        end)
    end)

    describe("completion setup", function()
        it("registers the blink source for AgenticInput buffers", function()
            assert.spy(blink_add_source_provider_spy).was.called(1)
            assert.equal(
                "agentic_slash_commands",
                blink_add_source_provider_spy.calls[1][1]
            )
            assert.spy(blink_add_filetype_source_spy).was.called(1)
            assert.equal(
                "AgenticInput",
                blink_add_filetype_source_spy.calls[1][1]
            )
            assert.equal(
                "agentic_slash_commands",
                blink_add_filetype_source_spy.calls[1][2]
            )
        end)

        it("does not overwrite native completeopt", function()
            local test_bufnr = vim.api.nvim_create_buf(false, true)
            vim.bo[test_bufnr].completeopt = "menu"

            SlashCommands.setup_completion(test_bufnr)

            assert.equal("menu", vim.bo[test_bufnr].completeopt)

            if vim.api.nvim_buf_is_valid(test_bufnr) then
                vim.api.nvim_buf_delete(test_bufnr, { force = true })
            end
        end)

        it("does not install a completefunc", function()
            local completefunc = vim.bo[bufnr].completefunc
            assert.equal("", completefunc)
        end)
    end)

    describe("trigger_completion", function()
        it("starts blink completion after the slash", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
                { name = "review", description = "Review code" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/pl" })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })

            assert.is_true(SlashCommands.trigger_completion(bufnr))
            assert.equal(1, blink_show_spy.call_count)
            assert.equal(
                "agentic_slash_commands",
                blink_show_spy.calls[1][1].providers[1]
            )
        end)

        it("shows blink completion for an empty slash prefix", function()
            SlashCommands.setCommands(bufnr, {
                { name = "plan", description = "Create a plan" },
                { name = "review", description = "Review code" },
            })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            assert.is_true(SlashCommands.trigger_completion(bufnr))
            assert.equal(1, blink_show_spy.call_count)
        end)

        it("does not complete non-command text", function()
            SlashCommands.setCommands(bufnr, {
                { name = "plan", description = "Create a plan" },
            })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "some /p" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            assert.is_false(SlashCommands.trigger_completion(bufnr))
            assert.equal(0, blink_show_spy.call_count)
        end)
    end)

    describe("TextChangedI autocommand", function()
        it(
            "triggers blink completion when typing / at start of line",
            function()
                --- @type agentic.acp.AvailableCommand[]
                local commands_mock = {
                    { name = "plan", description = "Create a plan" },
                }

                SlashCommands.setCommands(bufnr, commands_mock)

                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/p" })
                vim.api.nvim_win_set_cursor(0, { 1, 2 })

                vim.cmd("startinsert")
                vim.cmd("doautocmd TextChangedI")

                assert.equal(1, blink_show_spy.call_count)
                assert.equal(
                    "agentic_slash_commands",
                    blink_show_spy.calls[1][1].providers[1]
                )
            end
        )

        it("does not trigger completion when commands list is empty", function()
            vim.cmd("startinsert")

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/p" })
            vim.api.nvim_win_set_cursor(0, { 1, 2 })

            vim.cmd("doautocmd TextChangedI")

            assert.equal(0, blink_show_spy.call_count)
        end)

        it("does not trigger completion when not at start of line", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands)

            vim.cmd("startinsert")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "some /p" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            vim.cmd("doautocmd TextChangedI")

            assert.equal(0, blink_show_spy.call_count)
        end)

        it("does not trigger completion when line contains space", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands = {
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands)

            vim.cmd("startinsert")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/p " })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })

            vim.cmd("doautocmd TextChangedI")

            assert.equal(0, blink_show_spy.call_count)
        end)

        it(
            "does not trigger completion when slash command has prior text",
            function()
                --- @type agentic.acp.AvailableCommand[]
                local commands = {
                    { name = "plan", description = "Create a plan" },
                }

                SlashCommands.setCommands(bufnr, commands)

                vim.cmd("startinsert")
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "line1", "/p" }
                )
                vim.api.nvim_win_set_cursor(0, { 2, 2 })

                vim.cmd("doautocmd TextChangedI")

                assert.equal(0, blink_show_spy.call_count)
            end
        )
    end)

    describe("blink source", function()
        it("returns command items for blink to fuzzy match", function()
            SlashCommands.setCommands(bufnr, {
                { name = "plan", description = "Create a plan" },
                { name = "review", description = "Review code" },
            })

            local response
            BlinkSource.new({}):get_completions({
                bufnr = bufnr,
                line = "/pl",
                cursor = { 1, 3 },
            }, function(items)
                response = items
            end)

            assert.equal(3, #response.items)
            assert.equal("plan", response.items[1].label)
            assert.equal("/plan", response.items[1].textEdit.newText)
            assert.equal(0, response.items[1].textEdit.range.start.character)
            assert.equal(3, response.items[1].textEdit.range["end"].character)
        end)

        it("honors a custom slash trigger", function()
            Config.completion.slash_trigger = ";"

            SlashCommands.setCommands(bufnr, {
                { name = "plan", description = "Create a plan" },
            })

            local source = BlinkSource.new({})
            local response
            source:get_completions({
                bufnr = bufnr,
                line = ";pl",
                cursor = { 1, 3 },
            }, function(items)
                response = items
            end)

            assert.same({ ";" }, source:get_trigger_characters())
            assert.equal(";plan", response.items[1].textEdit.newText)
            assert.equal("plan", SlashCommands.get_input_command_name(";plan"))
            assert.equal("/plan", SlashCommands.normalize_input(bufnr, ";plan"))
        end)
    end)

    describe("instance management", function()
        it("allows independent commands per buffer instance", function()
            local bufnr2 = vim.api.nvim_create_buf(false, true)
            SlashCommands.setup_completion(bufnr2)

            --- @type agentic.acp.AvailableCommand[]
            local commands1 = {
                { name = "plan", description = "Create a plan" },
            }

            --- @type agentic.acp.AvailableCommand[]
            local commands2 = {
                { name = "review", description = "Review code" },
            }

            SlashCommands.setCommands(bufnr, commands1)
            SlashCommands.setCommands(bufnr2, commands2)

            local commands_buf1 = States.getSlashCommands()
            vim.api.nvim_set_current_buf(bufnr2)
            local commands_buf2 = States.getSlashCommands()

            assert.equal(2, #commands_buf1) -- plan + /new
            assert.equal(2, #commands_buf2) -- review + /new
            assert.equal("plan", commands_buf1[1].word)
            assert.equal("review", commands_buf2[1].word)

            if vim.api.nvim_buf_is_valid(bufnr2) then
                vim.api.nvim_buf_delete(bufnr2, { force = true })
            end
        end)
    end)
end)
