local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local PersistedSession
    local InteractionModel
    local SessionRegistry
    local Logger

    --- @type TestStub
    local persisted_session_load_stub
    --- @type TestStub
    local persisted_session_list_stub
    --- @type TestStub
    local session_registry_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local vim_ui_select_stub

    local test_sessions = {
        {
            session_id = "session-1",
            title = "First chat",
            timestamp = 1704067200,
        },
        {
            session_id = "session-2",
            title = "Second chat",
            timestamp = 1704153600,
        },
    }

    local mock_persisted_session = {
        session_id = "restored-session",
        turns = {
            {
                index = 1,
                request = {
                    kind = "user",
                    text = "Previous chat",
                    timestamp = 1,
                    content = {
                        { type = "text", text = "Previous chat" },
                    },
                    content_nodes = {},
                },
                response = {
                    provider_name = "Codex ACP",
                    nodes = {},
                },
                result = nil,
            },
        },
    }

    local function create_mock_session(opts)
        opts = opts or {}
        local turns = opts.turns or {}
        return {
            session_id = opts.session_id or "current-session",
            session_state = {
                get_state = function()
                    return {
                        interaction = {
                            turns = vim.deepcopy(turns),
                        },
                    }
                end,
            },
            agent = { cancel_session = spy.new(function() end) },
            widget = {
                clear = spy.new(function() end),
                show = spy.new(function() end),
            },
            restore_session_data = spy.new(function() end),
        }
    end

    local function setup_list_stub(sessions)
        persisted_session_list_stub:invokes(function(callback)
            callback(sessions or test_sessions)
        end)
    end

    local function setup_load_stub(persisted_session, err)
        persisted_session_load_stub:invokes(function(_sid, callback)
            callback(persisted_session, err)
        end)
    end

    local function setup_registry_stub(session)
        session_registry_stub:invokes(function(_tab_id, callback)
            callback(session)
        end)
    end

    local function select_session(index)
        local callback = vim_ui_select_stub.calls[index][3]
        local items = vim_ui_select_stub.calls[index][1]
        return callback, items
    end

    before_each(function()
        package.loaded["agentic.session_restore"] = nil
        package.loaded["agentic.session.persisted_session"] = nil
        package.loaded["agentic.session.interaction_model"] = nil
        package.loaded["agentic.session_registry"] = nil
        package.loaded["agentic.utils.logger"] = nil

        SessionRestore = require("agentic.session_restore")
        PersistedSession = require("agentic.session.persisted_session")
        InteractionModel = require("agentic.session.interaction_model")
        SessionRegistry = require("agentic.session_registry")
        Logger = require("agentic.utils.logger")

        persisted_session_load_stub = spy.stub(PersistedSession, "load")
        persisted_session_list_stub =
            spy.stub(PersistedSession, "list_sessions")
        session_registry_stub =
            spy.stub(SessionRegistry, "get_session_for_tab_page")
        logger_notify_stub = spy.stub(Logger, "notify")
        vim_ui_select_stub = spy.stub(vim.ui, "select")
    end)

    after_each(function()
        persisted_session_load_stub:revert()
        persisted_session_list_stub:revert()
        session_registry_stub:revert()
        logger_notify_stub:revert()
        vim_ui_select_stub:revert()
    end)

    describe("show_picker", function()
        it("notifies and skips picker when no sessions exist", function()
            setup_list_stub({})

            SessionRestore.show_picker(1, nil)

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No saved sessions found",
                logger_notify_stub.calls[1][1]
            )
            assert.equal(vim.log.levels.INFO, logger_notify_stub.calls[1][2])
            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("displays formatted sessions with date and title", function()
            setup_list_stub()

            SessionRestore.show_picker(1, nil)

            local items = vim_ui_select_stub.calls[1][1]
            local opts = vim_ui_select_stub.calls[1][2]

            assert.equal(2, #items)
            assert.equal("session-1", items[1].session_id)
            assert.truthy(items[1].display:match("First chat"))
            assert.equal("Select session to restore:", opts.prompt)
            assert.equal(items[1].display, opts.format_item(items[1]))
        end)

        it("handles sessions with missing title", function()
            setup_list_stub({ { session_id = "s1" } })

            SessionRestore.show_picker(1, nil)

            local items = vim_ui_select_stub.calls[1][1]
            assert.truthy(items[1].display:match("%(no title%)"))
        end)

        it("does nothing when user cancels picker", function()
            setup_list_stub()

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback(nil)

            assert.spy(persisted_session_load_stub).was.called(0)
        end)
    end)

    describe("restore without conflict", function()
        it("restores directly with reuse_session=true", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_persisted_session)
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(mock_session.agent.cancel_session).was.called(0)
            assert.spy(mock_session.widget.clear).was.called(0)
            assert.spy(mock_session.restore_session_data).was.called(1)

            local restore_call = mock_session.restore_session_data.calls[1]
            assert.equal(mock_persisted_session, restore_call[2])
            assert.is_true(restore_call[3].reuse_session)
            assert.spy(mock_session.widget.show).was.called(1)
        end)
    end)

    describe("restore with conflict", function()
        local function session_with_content()
            return create_mock_session({
                turns = vim.deepcopy(mock_persisted_session.turns),
            })
        end

        it("prompts user when current session has content", function()
            local mock_session = session_with_content()
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                mock_session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(2)

            local conflict_opts = vim_ui_select_stub.calls[2][2]
            assert.truthy(
                conflict_opts.prompt:match("Current session has content")
            )
        end)

        it("cancels restore when user chooses Cancel", function()
            local mock_session = session_with_content()
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                mock_session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            local conflict_callback = vim_ui_select_stub.calls[2][3]
            conflict_callback("Cancel")

            assert.spy(persisted_session_load_stub).was.called(0)
        end)

        it(
            "clears session and restores with reuse_session=false when confirmed",
            function()
                local mock_session = session_with_content()
                setup_list_stub()
                setup_load_stub(mock_persisted_session)
                setup_registry_stub(mock_session)

                SessionRestore.show_picker(
                    1,
                    mock_session --[[@as agentic.SessionManager]]
                )

                local callback = select_session(1)
                callback({ session_id = "session-1" })

                local conflict_callback = vim_ui_select_stub.calls[2][3]
                conflict_callback("Clear current session and restore")

                assert.spy(mock_session.agent.cancel_session).was.called(1)
                assert.spy(mock_session.widget.clear).was.called(1)

                local restore_call = mock_session.restore_session_data.calls[1]
                assert.is_false(restore_call[3].reuse_session)
            end
        )
    end)

    describe("load failures", function()
        it("shows warning on load error", function()
            setup_list_stub()
            setup_load_stub(nil, "File not found")

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("File not found")
            )
            assert.equal(vim.log.levels.WARN, logger_notify_stub.calls[1][2])
            assert.spy(session_registry_stub).was.called(0)
        end)

        it("shows warning on nil history without error", function()
            setup_list_stub()
            setup_load_stub(nil, nil)

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(logger_notify_stub.calls[1][1]:match("unknown error"))
            assert.spy(session_registry_stub).was.called(0)
        end)
    end)

    describe("conflict detection", function()
        it("detects no conflict when current_session is nil", function()
            setup_list_stub()

            SessionRestore.show_picker(1, nil)

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when session_id is nil", function()
            local session = {
                session_id = nil,
                session_state = {
                    get_state = function()
                        return {
                            interaction = {
                                turns = vim.deepcopy(
                                    mock_persisted_session.turns
                                ),
                            },
                        }
                    end,
                },
            }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when session_state is nil", function()
            local session = { session_id = "current", session_state = nil }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)

        it("detects no conflict when turns array is empty", function()
            local session = create_mock_session({
                session_id = "current",
                turns = {},
            })
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            local callback = select_session(1)
            callback({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
        end)
    end)
end)
