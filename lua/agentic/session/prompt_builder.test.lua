local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local PromptBuilder = require("agentic.session.prompt_builder")

describe("agentic.session.PromptBuilder", function()
    it(
        "adds environment info as embedded context on the first prompt",
        function()
            local submission = PromptBuilder.build_submission({
                input_text = "Summarize the repo state",
                provider_name = "Codex",
                include_system_info = true,
            })

            assert.equal("resource", submission.prompt[2].type)
            assert.equal(
                "agentic://environment_info",
                submission.prompt[2].resource.uri
            )
            assert.truthy(
                submission.prompt[2].resource.text:match("%- Platform: ")
            )
            assert.truthy(
                submission.prompt[2].resource.text:match("%- Project root: ")
            )
        end
    )

    it("builds inline submissions from explicit selections", function()
        local selection = {
            lines = {
                "local value = 1",
                "return value",
            },
            start_line = 10,
            end_line = 11,
            file_path = "/tmp/example.lua",
            file_type = "lua",
        }

        local submission = PromptBuilder.build_submission({
            input_text = "Refactor this selection",
            provider_name = "Codex",
            include_system_info = false,
            selections = { selection },
            inline_instructions = PromptBuilder.build_inline_instructions(),
        })

        assert.equal("Refactor this selection", submission.prompt[1].text)
        assert.equal(
            PromptBuilder.build_inline_instructions(),
            submission.prompt[2].text
        )
        assert.truthy(submission.prompt[3].text:match("IMPORTANT: Focus"))
        assert.truthy(submission.prompt[4].text:match("<selected_code>"))
        assert.truthy(submission.prompt[4].text:match("/tmp/example.lua"))
        assert.truthy(
            submission.prompt[4].text:match("Line 10: local value = 1")
        )
        assert.truthy(submission.prompt[4].text:match("Line 11: return value"))
    end)

    it(
        "keeps regular code selection behavior when explicit selections are absent",
        function()
            local clear_spy = spy.new(function() end)
            local selection = {
                lines = { "print('hello')" },
                start_line = 3,
                end_line = 3,
                file_path = "/tmp/example.lua",
                file_type = "lua",
            }
            local code_selection = {
                is_empty = function()
                    return false
                end,
                get_selections = function()
                    return { selection }
                end,
                clear = clear_spy,
            }
            local typed_code_selection = code_selection
            --- @cast typed_code_selection agentic.ui.CodeSelection

            local submission = PromptBuilder.build_submission({
                input_text = "Explain this",
                provider_name = "Codex",
                include_system_info = false,
                code_selection = typed_code_selection,
            })

            assert.spy(clear_spy).was.called(1)
            assert.truthy(submission.prompt[2].text:match("<selected_code>"))
        end
    )
end)
