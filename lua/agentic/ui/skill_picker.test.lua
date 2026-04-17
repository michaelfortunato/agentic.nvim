local assert = require("tests.helpers.assert")

local SkillPicker = require("agentic.ui.skill_picker")

describe("agentic.ui.SkillPicker", function()
    --- @type integer
    local bufnr
    --- @type string[]
    local temp_dirs

    --- @param path string
    --- @param lines string[]
    local function write_file(path, lines)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(lines, path)
    end

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        temp_dirs = {}
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end

        for _, path in ipairs(temp_dirs) do
            vim.fn.delete(path, "rf")
        end
    end)

    it("discovers project, user, system, and plugin skills", function()
        local base = vim.fs.normalize(vim.fn.tempname())
        local workspace_root = base .. "-workspace"
        local codex_home = base .. "-codex"

        temp_dirs = { workspace_root, codex_home }

        write_file(
            workspace_root .. "/.agents/skills/project-skill/SKILL.md",
            { "description: Project skill", "---" }
        )
        write_file(
            codex_home .. "/skills/local-skill/SKILL.md",
            { "description: Local skill", "---" }
        )
        write_file(
            codex_home .. "/skills/.system/system-skill/SKILL.md",
            { "description: System skill", "---" }
        )
        write_file(codex_home .. "/config.toml", {
            '[plugins."github@openai-curated"]',
            "enabled = true",
        })
        write_file(
            codex_home
                .. "/plugins/cache/openai-curated/github/rev123/skills/gh-fix-ci/SKILL.md",
            { "description: Plugin skill", "---" }
        )

        local picker = SkillPicker:new(bufnr, {
            resolve_workspace_root = function()
                return workspace_root
            end,
            resolve_codex_home = function()
                return codex_home
            end,
        })

        local items
        picker:request_source_items(function(skills)
            items = skills
        end)

        local names = vim.tbl_map(function(item)
            return item.name
        end, items)

        assert.same({
            "github:gh-fix-ci",
            "local-skill",
            "project-skill",
            "system-skill",
        }, names)
        assert.equal("$github:gh-fix-ci", items[1].word)
        assert.equal("Plugin Skill", items[1].source)
    end)

    it("detects active skill mentions only at word boundaries", function()
        local mention = SkillPicker.get_active_skill_mention("use $open", 9)
        assert.is_not_nil(mention)
        if mention == nil then
            return
        end

        assert.equal("$open", mention.query)

        assert.is_nil(SkillPicker.get_active_skill_mention("path$open", 9))
    end)
end)
