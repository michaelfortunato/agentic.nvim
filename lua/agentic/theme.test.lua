local assert = require("tests.helpers.assert")

describe("agentic.Theme", function()
    local Theme = require("agentic.theme")

    local tracked_groups = {
        "DiffAdd",
        "DiffDelete",
        "DiagnosticWarn",
        "DiagnosticInfo",
        "DiagnosticHint",
        "Comment",
        "Directory",
        Theme.HL_GROUPS.DIFF_ADD_WORD,
        Theme.HL_GROUPS.DIFF_DELETE_WORD,
        Theme.HL_GROUPS.STATUS_PENDING,
        Theme.HL_GROUPS.SPINNER_GENERATING,
        Theme.HL_GROUPS.TRANSCRIPT_REQUEST_META,
        Theme.HL_GROUPS.TRANSCRIPT_RESPONSE_META,
        Theme.HL_GROUPS.CHUNK_BOUNDARY,
        Theme.HL_GROUPS.THOUGHT_TEXT,
        Theme.HL_GROUPS.RESOURCE_LINK,
        Theme.HL_GROUPS.FOLD_HINT,
        Theme.HL_GROUPS.INLINE_FADE,
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

        local add_word = vim.api.nvim_get_hl(
            0,
            { name = Theme.HL_GROUPS.DIFF_ADD_WORD, link = false }
        )
        local delete_word = vim.api.nvim_get_hl(
            0,
            { name = Theme.HL_GROUPS.DIFF_DELETE_WORD, link = false }
        )

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

        local pending = vim.api.nvim_get_hl(
            0,
            { name = Theme.HL_GROUPS.STATUS_PENDING, link = false }
        )
        local generating = vim.api.nvim_get_hl(
            0,
            { name = Theme.HL_GROUPS.SPINNER_GENERATING, link = false }
        )

        assert.equal(0x111111, pending.fg)
        assert.equal(0x222222, generating.fg)

        vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0x333333 })
        vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x444444 })

        Theme.setup()

        pending = vim.api.nvim_get_hl(
            0,
            { name = Theme.HL_GROUPS.STATUS_PENDING, link = false }
        )
        generating = vim.api.nvim_get_hl(
            0,
            { name = Theme.HL_GROUPS.SPINNER_GENERATING, link = false }
        )

        assert.equal(0x333333, pending.fg)
        assert.equal(0x444444, generating.fg)
    end)

    it(
        "derives semantic transcript groups from comment and directory highlights",
        function()
            vim.api.nvim_set_hl(0, "Comment", { fg = 0x111111, italic = false })
            vim.api.nvim_set_hl(
                0,
                "DiagnosticHint",
                { fg = 0x333333, italic = false }
            )
            vim.api.nvim_set_hl(
                0,
                "Directory",
                { fg = 0x222222, italic = false }
            )

            Theme.setup()

            local request_meta = vim.api.nvim_get_hl(
                0,
                { name = Theme.HL_GROUPS.TRANSCRIPT_REQUEST_META, link = false }
            )
            local response_meta = vim.api.nvim_get_hl(0, {
                name = Theme.HL_GROUPS.TRANSCRIPT_RESPONSE_META,
                link = false,
            })
            local chunk_boundary = vim.api.nvim_get_hl(
                0,
                { name = Theme.HL_GROUPS.CHUNK_BOUNDARY, link = false }
            )
            local thought = vim.api.nvim_get_hl(
                0,
                { name = Theme.HL_GROUPS.THOUGHT_TEXT, link = false }
            )
            local resource_link = vim.api.nvim_get_hl(
                0,
                { name = Theme.HL_GROUPS.RESOURCE_LINK, link = false }
            )
            local fold_hint = vim.api.nvim_get_hl(
                0,
                { name = Theme.HL_GROUPS.FOLD_HINT, link = false }
            )
            local inline_fade = vim.api.nvim_get_hl(
                0,
                { name = Theme.HL_GROUPS.INLINE_FADE, link = false }
            )
            assert.equal(0x111111, request_meta.fg)
            assert.is_true(request_meta.italic)
            assert.equal(0x111111, response_meta.fg)
            assert.equal(0x333333, chunk_boundary.fg)
            assert.is_true(chunk_boundary.underline)
            assert.equal(0x111111, thought.fg)
            assert.is_true(thought.italic)
            assert.equal(0x222222, resource_link.fg)
            assert.is_true(resource_link.underline)
            assert.equal(0x111111, fold_hint.fg)
            assert.is_true(fold_hint.italic)
            assert.equal(0x111111, inline_fade.fg)
            assert.is_true(inline_fade.italic)
            assert.equal(1, vim.fn.hlexists(Theme.HL_GROUPS.INLINE_FADE))
        end
    )
end)
