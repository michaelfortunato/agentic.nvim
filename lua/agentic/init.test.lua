local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic", function()
    local Agentic
    local SessionRegistry
    local SessionRestore

    --- @type TestStub|nil
    local new_signal_stub
    --- @type TestStub|nil
    local get_session_stub
    --- @type TestStub|nil
    local new_session_stub
    --- @type TestStub|nil
    local show_picker_stub
    --- @type TestStub|nil
    local current_session_stub
    --- @type TestStub|nil
    local clear_inline_buffer_stub
    --- @type integer
    local test_bufnr

    local function clear_window_active_session_state()
        for _, winid in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_is_valid(winid) then
                vim.w[winid]._agentic_active_session_instance_id = nil
            end
        end
    end

    local function delete_commands()
        pcall(vim.api.nvim_del_user_command, "AgenticChat")
        pcall(vim.api.nvim_del_user_command, "AgenticInline")
        pcall(vim.api.nvim_del_user_command, "AgenticInlineClear")
    end

    --- @param opts {is_open?: boolean}|nil
    local function create_session(opts)
        opts = opts or {}

        local widget = {
            _open = opts.is_open == true,
            is_open = function(self)
                return self._open
            end,
            hide = spy.new(function(self)
                self._open = false
            end),
            show = spy.new(function(self)
                self._open = true
            end),
            set_input_text = spy.new(function() end),
            focus_input = spy.new(function() end),
        }

        return {
            widget = widget,
            add_selection_or_file_to_session = spy.new(function() end),
            open_inline_chat = spy.new(function() end),
        }
    end

    before_each(function()
        delete_commands()
        package.loaded["agentic"] = nil

        Agentic = require("agentic")
        SessionRegistry = require("agentic.session_registry")
        SessionRestore = require("agentic.session_restore")

        new_signal_stub = spy.stub(vim.uv, "new_signal")
        Agentic.setup({})

        test_bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_set_current_buf(test_bufnr)
        vim.api.nvim_buf_set_name(test_bufnr, "/tmp/agentic_init_test.lua")
        vim.api.nvim_buf_set_lines(test_bufnr, 0, -1, false, {
            "first line",
            "second line",
            "third line",
        })
    end)

    after_each(function()
        for key in pairs(SessionRegistry.sessions) do
            SessionRegistry.sessions[key] = nil
        end

        clear_window_active_session_state()

        if get_session_stub then
            get_session_stub:revert()
            get_session_stub = nil
        end

        if new_session_stub then
            new_session_stub:revert()
            new_session_stub = nil
        end

        if show_picker_stub then
            show_picker_stub:revert()
            show_picker_stub = nil
        end

        if current_session_stub then
            current_session_stub:revert()
            current_session_stub = nil
        end

        if clear_inline_buffer_stub then
            clear_inline_buffer_stub:revert()
            clear_inline_buffer_stub = nil
        end

        if new_signal_stub then
            new_signal_stub:revert()
            new_signal_stub = nil
        end

        if vim.api.nvim_buf_is_valid(test_bufnr) then
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end

        delete_commands()
    end)

    it("toggles the chat closed when no range is provided", function()
        local session = create_session({ is_open = true })

        get_session_stub = spy.stub(SessionRegistry, "get_or_create_session")
        get_session_stub:invokes(function(callback)
            if callback then
                callback(session)
            end
            return session
        end)

        vim.cmd("AgenticChat")

        assert.spy(session.widget.hide).was.called(1)
        assert.spy(session.widget.show).was.called(0)
    end)

    it("prefills the prompt when AgenticChat is called with a range", function()
        local session = create_session({ is_open = true })

        get_session_stub = spy.stub(SessionRegistry, "get_or_create_session")
        get_session_stub:invokes(function(callback)
            if callback then
                callback(session)
            end
            return session
        end)

        vim.cmd("1,2AgenticChat")

        assert.spy(session.widget.hide).was.called(0)
        assert.spy(session.widget.show).was.called(1)
        assert
            .spy(session.widget.set_input_text).was
            .called_with(session.widget, "first line\nsecond line")
        assert.spy(session.widget.focus_input).was.called(1)
        assert.spy(session.add_selection_or_file_to_session).was.called(0)
    end)

    it(
        "starts a new session and prefills the prompt for AgenticChat new",
        function()
            local session = create_session()

            new_session_stub = spy.stub(SessionRegistry, "new_session")
            new_session_stub:returns(session)

            vim.cmd("2,3AgenticChat new")

            assert.spy(session.widget.show).was.called(1)
            assert
                .spy(session.widget.set_input_text).was
                .called_with(session.widget, "second line\nthird line")
            assert.spy(session.widget.focus_input).was.called(1)
            assert.spy(session.add_selection_or_file_to_session).was.called(0)
        end
    )

    it("routes AgenticChat restore through the session picker", function()
        local session = create_session()

        current_session_stub = spy.stub(SessionRegistry, "get_current_session")
        current_session_stub:returns(session)
        show_picker_stub = spy.stub(SessionRestore, "show_picker")

        vim.cmd("AgenticChat restore")

        assert.spy(show_picker_stub).was.called(1)
        assert.equal(session, show_picker_stub.calls[1][1])
    end)

    it("passes the provided range to AgenticInline", function()
        local session = create_session()

        get_session_stub = spy.stub(SessionRegistry, "get_or_create_session")
        get_session_stub:invokes(function(callback)
            if callback then
                callback(session)
            end
            return session
        end)

        vim.cmd("2,3AgenticInline")

        assert.spy(session.open_inline_chat).was.called(1)

        local selection = session.open_inline_chat.calls[1][2]
        assert.is_not_nil(selection)
        assert.equal(2, selection.start_line)
        assert.equal(3, selection.end_line)
        assert.same({ "second line", "third line" }, selection.lines)
        assert.truthy(selection.file_path:match("agentic_init_test%.lua$"))
    end)

    it(
        "clears current-buffer inline artifacts through AgenticInlineClear",
        function()
            clear_inline_buffer_stub =
                spy.stub(SessionRegistry, "clear_inline_buffer")

            vim.cmd("AgenticInlineClear")

            assert.spy(clear_inline_buffer_stub).was.called_with(test_bufnr)
        end
    )

    it(
        "stops the dedicated inline session when inline generation is active",
        function()
            local stop_generation_spy = spy.new(function() end)
            local clear_permissions_spy = spy.new(function() end)
            local session = {
                is_generating = true,
                session_id = "chat-session",
                _inline_session_id = "inline-session",
                agent = {
                    stop_generation = stop_generation_spy,
                },
                get_active_generation_session_id = function(self)
                    return self._inline_session_id
                end,
                inline_chat = {
                    is_active = function()
                        return true
                    end,
                },
                permission_manager = {
                    clear = clear_permissions_spy,
                },
            }

            current_session_stub =
                spy.stub(SessionRegistry, "get_current_session")
            current_session_stub:invokes(function(callback)
                if callback then
                    callback(session)
                end
                return session
            end)

            Agentic.stop_generation()

            assert
                .spy(stop_generation_spy).was
                .called_with(session.agent, "inline-session")
            assert.spy(clear_permissions_spy).was.called(1)
        end
    )
end)
