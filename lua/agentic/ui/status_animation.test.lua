local assert = require("tests.helpers.assert")

describe("agentic.ui.StatusAnimation", function()
    local StatusAnimation = require("agentic.ui.status_animation")
    local active_animations = {}

    local function find_activity_mark(bufnr)
        local marks =
            vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })

        for _, mark in ipairs(marks) do
            local details = mark[4]
            if details and details.virt_lines then
                return mark
            end
        end

        return nil
    end

    local function activity_text(mark)
        local chunks = mark[4].virt_lines[1] or {}
        local parts = {}

        for _, chunk in ipairs(chunks) do
            parts[#parts + 1] = chunk[1]
        end

        return table.concat(parts)
    end

    after_each(function()
        for _, animation in ipairs(active_animations) do
            pcall(function()
                animation:stop()
            end)
        end

        active_animations = {}
    end)

    it("renders a human activity label in the chat buffer", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

        local animation = StatusAnimation:new(bufnr)
        active_animations[#active_animations + 1] = animation

        animation:start("thinking")

        assert.is_true(vim.wait(100, function()
            return find_activity_mark(bufnr) ~= nil
        end))

        local mark = find_activity_mark(bufnr)
        assert.truthy(mark)
        assert.truthy(activity_text(mark):match("Thinking"))
        local chunks = mark[4].virt_lines[1] or {}
        assert.equal(2, #chunks)
        assert.equal(" Thinking", chunks[2][1])
    end)

    it("reanchors the activity line when the chat buffer grows", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1" })

        local animation = StatusAnimation:new(bufnr)
        active_animations[#active_animations + 1] = animation

        animation:start("generating")

        assert.is_true(vim.wait(100, function()
            return find_activity_mark(bufnr) ~= nil
        end))

        local initial_mark = find_activity_mark(bufnr)
        assert.equal(0, initial_mark[2])

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
            "line 2",
            "line 3",
        })

        assert.is_true(vim.wait(100, function()
            local mark = find_activity_mark(bufnr)
            return mark ~= nil and mark[2] == 2
        end))
    end)

    it(
        "renders activity detail without indenting it under tool cards",
        function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "tool card", "" })

            local animation = StatusAnimation:new(bufnr)
            active_animations[#active_animations + 1] = animation

            animation:start(
                "searching",
                { detail = "Read ~/demo/file_picker.lua" }
            )

            assert.is_true(vim.wait(100, function()
                return find_activity_mark(bufnr) ~= nil
            end))

            local mark = find_activity_mark(bufnr)
            assert.truthy(mark)
            assert.equal(1, mark[2])
            assert.truthy(
                activity_text(mark):match(
                    "Using tools · Read ~/demo/file_picker.lua"
                )
            )
        end
    )
end)
