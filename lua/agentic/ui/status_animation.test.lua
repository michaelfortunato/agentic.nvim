---@diagnostic disable: need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Theme = require("agentic.theme")

describe("agentic.ui.StatusAnimation", function()
    local StatusAnimation = require("agentic.ui.status_animation")
    local active_animations = {}
    local progress_spy

    local function stub_progress_echo()
        progress_spy = spy.stub(vim.api, "nvim_echo")
        progress_spy:returns(101)
    end

    after_each(function()
        for _, animation in ipairs(active_animations) do
            pcall(function()
                animation:stop()
            end)
        end

        if progress_spy then
            progress_spy:revert()
            progress_spy = nil
        end

        active_animations = {}
    end)

    it("emits native progress with a human activity label", function()
        stub_progress_echo()

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

        local animation = StatusAnimation:new(bufnr)
        active_animations[#active_animations + 1] = animation

        animation:start("thinking")

        assert.equal(1, progress_spy.call_count)

        local call = progress_spy.calls[1]
        local chunks = call[1]
        local opts = call[3]

        assert.equal("Thinking", chunks[1][1])
        assert.equal(Theme.HL_GROUPS.ACTIVITY_TEXT, chunks[1][2])
        assert.equal("progress", opts.kind)
        assert.equal("agentic.nvim.chat", opts.source)
        assert.equal("running", opts.status)
        assert.equal(20, opts.percent)
        assert.equal("Agentic Chat", opts.title)
    end)

    it(
        "emits activity detail without chat-buffer overlay indentation",
        function()
            stub_progress_echo()

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "tool card", "" })

            local animation = StatusAnimation:new(bufnr)
            active_animations[#active_animations + 1] = animation

            animation:start(
                "searching",
                { detail = "Read ~/demo/file_picker.lua" }
            )

            assert.equal(1, progress_spy.call_count)

            local call = progress_spy.calls[1]
            local chunks = call[1]
            local opts = call[3]

            assert.equal(
                "Using tools · Read ~/demo/file_picker.lua",
                chunks[1][1]
            )
            assert.equal("progress", opts.kind)
            assert.equal("agentic.nvim.chat", opts.source)
            assert.equal("running", opts.status)
            assert.equal(72, opts.percent)
            assert.equal("Agentic Chat", opts.title)
        end
    )

    it("dismisses native progress when chat activity stops", function()
        stub_progress_echo()

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

        local animation = StatusAnimation:new(bufnr)
        active_animations[#active_animations + 1] = animation

        animation:start("generating")
        animation:stop()

        assert.equal(2, progress_spy.call_count)

        local dismiss_call = progress_spy.calls[2]
        local chunks = dismiss_call[1]
        local opts = dismiss_call[3]

        assert.equal("dismissed", chunks[1][1])
        assert.equal("progress", opts.kind)
        assert.equal("agentic.nvim.chat", opts.source)
        assert.equal("success", opts.status)
        assert.equal(100, opts.percent)
        assert.equal("Agentic Chat", opts.title)
    end)

    it("does not spam identical native progress refreshes", function()
        stub_progress_echo()

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

        local animation = StatusAnimation:new(bufnr)
        active_animations[#active_animations + 1] = animation

        animation:start("generating")
        animation:start("generating")

        assert.equal(1, progress_spy.call_count)
    end)

    it("uses the returned message id when the activity changes", function()
        stub_progress_echo()

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

        local animation = StatusAnimation:new(bufnr)
        active_animations[#active_animations + 1] = animation

        animation:start("thinking")
        animation:start("generating")

        assert.equal(2, progress_spy.call_count)

        local update_opts = progress_spy.calls[2][3]
        assert.equal(101, update_opts.id)
        assert.equal("running", update_opts.status)
        assert.equal(55, update_opts.percent)
    end)
end)
