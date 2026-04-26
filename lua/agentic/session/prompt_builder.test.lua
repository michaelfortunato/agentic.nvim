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
            start_col = 7,
            end_col = 12,
            file_path = "/tmp/example.lua",
            file_type = "lua",
        }

        local submission = PromptBuilder.build_submission({
            input_text = "Refactor this selection",
            provider_name = "Codex",
            include_system_info = false,
            selections = { selection },
            inline_instructions = PromptBuilder.build_inline_instructions(),
            surface = "inline",
        })

        assert.equal("Refactor this selection", submission.prompt[1].text)
        assert.equal("inline", submission.request.surface)
        assert.equal(
            PromptBuilder.build_inline_instructions(),
            submission.prompt[2].text
        )
        assert.truthy(
            submission.prompt[2].text:match(
                "answer by adding a language%-appropriate inline or block comment"
            )
        )
        assert.truthy(submission.prompt[3].text:match("IMPORTANT: Focus"))
        assert.truthy(submission.prompt[4].text:match("<selected_code>"))
        assert.truthy(submission.prompt[4].text:match("/tmp/example.lua"))
        assert.truthy(
            submission.prompt[4].text:match("Line 10: local value = 1")
        )
        assert.truthy(submission.prompt[4].text:match("Line 11: return value"))
        assert.truthy(
            submission.prompt[4].text:match("<col_start>7</col_start>")
        )
        assert.truthy(submission.prompt[4].text:match("<col_end>12</col_end>"))
    end)

    it("adds full file context as ACP resource links when requested", function()
        local file_path = vim.fn.tempname() .. ".lua"
        vim.fn.writefile({
            "local value = 1",
            "return value",
            "print(value)",
        }, file_path)

        local selection = {
            lines = {
                "return value",
            },
            start_line = 2,
            end_line = 2,
            file_path = file_path,
            file_type = "lua",
        }

        local submission = PromptBuilder.build_submission({
            input_text = "Refactor this selection",
            provider_name = "Codex",
            include_system_info = false,
            selections = { selection },
            inline_instructions = PromptBuilder.build_inline_instructions(),
            include_full_files = true,
            surface = "inline",
        })

        local combined_prompt = {}
        for _, item in ipairs(submission.prompt) do
            if item.type == "text" and item.text then
                combined_prompt[#combined_prompt + 1] = item.text
            end
        end
        local text = table.concat(combined_prompt, "\n")

        assert.truthy(text:match("ACP file resources"))
        assert.is_nil(text:match("Line 1: local value = 1"))
        assert.equal("resource_link", submission.prompt[6].type)
        assert.equal("file://" .. file_path, submission.prompt[6].uri)
        assert.equal(vim.fs.basename(file_path), submission.prompt[6].name)

        vim.fn.delete(file_path)
    end)

    it("embeds bounded unsaved file context for inline submissions", function()
        local bufnr = vim.api.nvim_create_buf(false, false)
        local file_path = vim.fn.tempname() .. ".lua"
        local lines = {}
        for i = 1, 405 do
            lines[#lines + 1] = "line " .. i
        end

        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = true

        local selection = {
            lines = {
                "line 200",
            },
            start_line = 200,
            end_line = 200,
            file_path = file_path,
            file_type = "lua",
        }

        local submission = PromptBuilder.build_submission({
            input_text = "Refactor this selection",
            provider_name = "Codex",
            include_system_info = false,
            selections = { selection },
            inline_instructions = PromptBuilder.build_inline_instructions(),
            include_full_files = true,
            surface = "inline",
        })

        assert.equal("resource_link", submission.prompt[6].type)
        assert.equal("resource", submission.prompt[7].type)
        assert.equal("file://" .. file_path, submission.prompt[7].resource.uri)
        assert.truthy(
            submission.prompt[7].resource.text:match("Unsaved buffer contents")
        )
        assert.truthy(submission.prompt[7].resource.text:match("Line 400"))
        assert.is_nil(submission.prompt[7].resource.text:match("Line 401"))
        assert.truthy(submission.prompt[7].resource.text:match("truncated"))

        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("embeds bounded fallback file context when requested", function()
        local file_path = vim.fn.tempname() .. ".lua"
        vim.fn.writefile({
            "local value = 1",
            "return value",
        }, file_path)

        local selection = {
            lines = {
                "return value",
            },
            start_line = 2,
            end_line = 2,
            file_path = file_path,
            file_type = "lua",
        }

        local submission = PromptBuilder.build_submission({
            input_text = "Refactor this selection",
            provider_name = "Codex",
            include_system_info = false,
            selections = { selection },
            inline_instructions = PromptBuilder.build_inline_instructions(),
            include_full_files = true,
            embed_full_files = true,
            surface = "inline",
        })

        assert.equal("resource_link", submission.prompt[6].type)
        assert.equal("resource", submission.prompt[7].type)
        assert.truthy(
            submission.prompt[7].resource.text:match(
                "Embedded fallback file context"
            )
        )
        assert.truthy(submission.prompt[7].resource.text:match("Line 2"))

        vim.fn.delete(file_path)
    end)

    it("defaults regular submissions to the chat surface", function()
        local submission = PromptBuilder.build_submission({
            input_text = "Explain this file",
            provider_name = "Codex",
            include_system_info = false,
        })

        assert.equal("chat", submission.request.surface)
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
