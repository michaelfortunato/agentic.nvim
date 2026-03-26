local assert = require("tests.helpers.assert")

describe("agentic.Theme", function()
    local Theme = require("agentic.theme")

    local tracked_groups = {
        "DiffAdd",
        "DiffDelete",
        "DiagnosticWarn",
        "DiagnosticInfo",
        Theme.HL_GROUPS.DIFF_ADD_WORD,
        Theme.HL_GROUPS.DIFF_DELETE_WORD,
        Theme.HL_GROUPS.STATUS_PENDING,
        Theme.HL_GROUPS.SPINNER_GENERATING,
    }

    local saved_highlights

    local function read_highlight(group)
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, {
            name = group,
            link = false,
        })

        if not ok or vim.tbl_count(hl) == 0 then
            return nil
        end

        return hl
    end

    before_each(function()
        saved_highlights = {}

        for _, group in ipairs(tracked_groups) do
            saved_highlights[group] = read_highlight(group)
        end
    end)

    after_each(function()
        for _, group in ipairs(tracked_groups) do
            vim.api.nvim_set_hl(0, group, saved_highlights[group] or {})
        end
    end)

    it("derives inline diff highlights from the active diff groups", function()
        vim.api.nvim_set_hl(0, "DiffAdd", {
            fg = 0x112233,
            bg = 0xAABBCC,
        })
        vim.api.nvim_set_hl(0, "DiffDelete", {
            fg = 0x445566,
            bg = 0xDDEEFF,
        })

        Theme.setup()

        local add_word =
            vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.DIFF_ADD_WORD, link = false })
        local delete_word =
            vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.DIFF_DELETE_WORD, link = false })

        assert.equal(0x112233, add_word.fg)
        assert.equal(0xAABBCC, add_word.bg)
        assert.is_true(add_word.underline)

        assert.equal(0x445566, delete_word.fg)
        assert.equal(0xDDEEFF, delete_word.bg)
        assert.is_true(delete_word.underline)
    end)

    it("reapplies theme-linked groups when source highlights change", function()
        vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0x111111 })
        vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x222222 })

        Theme.setup()

        local pending =
            vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.STATUS_PENDING, link = false })
        local generating =
            vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.SPINNER_GENERATING, link = false })

        assert.equal(0x111111, pending.fg)
        assert.equal(0x222222, generating.fg)

        vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0x333333 })
        vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x444444 })

        Theme.setup()

        pending =
            vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.STATUS_PENDING, link = false })
        generating =
            vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.SPINNER_GENERATING, link = false })

        assert.equal(0x333333, pending.fg)
        assert.equal(0x444444, generating.fg)
    end)
end)
