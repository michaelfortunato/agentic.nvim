local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local NativeProgress = require("agentic.ui.native_progress")
local Theme = require("agentic.theme")

describe("agentic.ui.NativeProgress", function()
    local echo_stub

    after_each(function()
        if echo_stub then
            echo_stub:revert()
            echo_stub = nil
        end
    end)

    it("emits Nvim progress messages with a source", function()
        if not NativeProgress.is_supported() then
            return
        end

        echo_stub = spy.stub(vim.api, "nvim_echo")
        echo_stub:returns(27)

        local progress_id, ok = NativeProgress.update({
            title = "Agentic Test",
            source = "agentic.nvim.test",
            message = "Working",
            status = "running",
            percent = 140,
        })

        assert.is_true(ok)
        assert.equal(27, progress_id)
        assert.equal(1, echo_stub.call_count)

        local call = echo_stub.calls[1]
        local chunks = call[1]
        local history = call[2]
        local opts = call[3]

        assert.equal("Working", chunks[1][1])
        assert.equal(Theme.HL_GROUPS.ACTIVITY_TEXT, chunks[1][2])
        assert.is_true(history)
        assert.equal("progress", opts.kind)
        assert.equal("agentic.nvim.test", opts.source)
        assert.equal("running", opts.status)
        assert.equal(100, opts.percent)
        assert.equal("Agentic Test", opts.title)
    end)
end)
