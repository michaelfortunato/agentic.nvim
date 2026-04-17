---@diagnostic disable: assign-type-mismatch, missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local TEST_CWD = "/test/project"

describe("PersistedSession", function()
    --- @type agentic.session.PersistedSession
    local PersistedSession
    --- @type agentic.utils.FileSystem
    local FileSystem
    local original_storage_path
    --- @type TestStub|nil
    local cwd_stub
    --- @type TestStub
    local mkdirp_stub
    --- @type TestStub
    local write_file_stub
    --- @type TestStub
    local read_file_stub
    --- @type table<string, string>
    local mock_files

    before_each(function()
        package.loaded["agentic.session.persisted_session"] = nil

        mock_files = {}

        FileSystem = require("agentic.utils.file_system")

        mkdirp_stub = spy.stub(FileSystem, "mkdirp")
        mkdirp_stub:returns(true)

        write_file_stub = spy.stub(FileSystem, "write_file")
        write_file_stub:invokes(function(path, content, callback)
            mock_files[path] = content
            callback(nil)
        end)

        read_file_stub = spy.stub(FileSystem, "read_file")
        read_file_stub:invokes(function(path, _, _, callback)
            callback(mock_files[path])
        end)

        local Config = require("agentic.config")
        original_storage_path = Config.session_restore.storage_path
        Config.session_restore.storage_path = "/test/storage"

        PersistedSession = require("agentic.session.persisted_session")
    end)

    after_each(function()
        if cwd_stub then
            cwd_stub:revert()
            cwd_stub = nil
        end
        mkdirp_stub:revert()
        write_file_stub:revert()
        read_file_stub:revert()
        local Config = require("agentic.config")
        Config.session_restore.storage_path = original_storage_path
        package.loaded["agentic.session.persisted_session"] = nil
    end)

    --- @param path string|nil
    local function stub_cwd(path)
        if cwd_stub then
            cwd_stub:revert()
        end
        cwd_stub = spy.stub(vim.uv, "cwd")
        cwd_stub:returns(path or TEST_CWD)
    end

    --- @param text string
    --- @param surface "chat"|"inline"|nil
    local function make_turn(text, surface)
        return {
            index = 1,
            request = {
                kind = "user",
                surface = surface or "chat",
                text = text,
                timestamp = 1,
                content = {
                    { type = "text", text = text },
                },
                content_nodes = {},
            },
            response = {
                provider_name = "Codex ACP",
                nodes = {
                    {
                        type = "message",
                        text = "done",
                        provider_name = "Codex ACP",
                        content = {
                            { type = "text", text = "done" },
                        },
                        content_nodes = {},
                    },
                },
            },
            result = {
                stop_reason = "end_turn",
                timestamp = 2,
                error_text = nil,
            },
        }
    end

    describe("get_project_folder", function()
        it("normalizes paths and appends hash suffix", function()
            local test_cases = {
                {
                    path = "/Users/me/projects/myapp",
                    pattern = "Users_me_projects_myapp",
                },
                {
                    path = "/Users/my user/my projects",
                    pattern = "my_user.*my_projects",
                },
                {
                    path = "C:\\Users\\me\\projects",
                    pattern = "C_.*Users_me_projects",
                },
            }

            for _, tc in ipairs(test_cases) do
                stub_cwd(tc.path)
                local folder = PersistedSession.get_project_folder()

                assert.truthy(folder:match(tc.pattern))
                assert.is_nil(folder:match("^_"))

                local hash = folder:match("_(%x+)$")
                assert.is_not_nil(hash)
                assert.equal(8, #hash)
            end
        end)

        it("produces unique hashes for different paths", function()
            stub_cwd("/path/one")
            local folder1 = PersistedSession.get_project_folder()

            stub_cwd("/path/two")
            local folder2 = PersistedSession.get_project_folder()

            assert.are_not.equal(folder1, folder2)
        end)
    end)

    describe("get_file_path", function()
        it(
            "combines storage_path, project_folder, and session_id.json",
            function()
                stub_cwd()
                local path = PersistedSession.get_file_path("session-abc")
                local project_folder = PersistedSession.get_project_folder()

                assert.truthy(path:match("^" .. vim.pesc("/test/storage")))
                assert.truthy(path:find(project_folder, 1, true))
                assert.truthy(path:match("session%-abc%.json$"))
            end
        )
    end)

    describe("turn storage", function()
        it("preserves turn insertion order", function()
            local persisted_session = PersistedSession:new()

            persisted_session.turns[1] = make_turn("First")
            persisted_session.turns[2] = make_turn("Second")

            assert.equal(2, #persisted_session.turns)
            assert.equal("First", persisted_session.turns[1].request.text)
            assert.equal("Second", persisted_session.turns[2].request.text)
        end)
    end)

    describe("save and load", function()
        before_each(function()
            stub_cwd()
        end)

        it("persists and restores interaction turns", function()
            local original = PersistedSession:new()
            original.session_id = "roundtrip-test"
            original.title = "Roundtrip"
            original.current_mode_id = "plan"
            original.config_options = {
                { id = "mode", name = "Mode" },
            }
            original.available_commands = {
                { name = "review", description = "Review changes" },
            }
            original.turns = { make_turn("Test message", "inline") }

            local save_done = false
            local save_err = nil
            original:save(function(err)
                save_err = err
                save_done = true
            end)

            vim.wait(1000, function()
                return save_done
            end)
            assert.is_nil(save_err)

            local path = PersistedSession.get_file_path(original.session_id)
            assert.equal(1, mkdirp_stub.call_count)
            assert.equal(1, write_file_stub.call_count)

            local saved_content = mock_files[path]
            assert.is_not_nil(saved_content)

            local parsed = vim.json.decode(saved_content)
            assert.equal(original.session_id, parsed.session_id)
            assert.equal("Roundtrip", parsed.title)
            assert.equal("plan", parsed.current_mode_id)
            assert.equal(1, #parsed.turns)
            assert.equal("Test message", parsed.turns[1].request.text)
            assert.equal("inline", parsed.turns[1].request.surface)

            local loaded = nil
            local load_err = nil
            local load_done = false
            PersistedSession.load(
                original.session_id,
                function(session_data, err)
                    loaded = session_data
                    load_err = err
                    load_done = true
                end
            )

            vim.wait(1000, function()
                return load_done
            end)

            assert.is_nil(load_err)
            assert.is_not_nil(loaded)
            --- @cast loaded agentic.session.PersistedSession
            assert.equal(original.session_id, loaded.session_id)
            assert.equal(original.timestamp, loaded.timestamp)
            assert.equal("plan", loaded.current_mode_id)
            assert.equal(1, #loaded.turns)
            assert.equal("Test message", loaded.turns[1].request.text)
            assert.equal("inline", loaded.turns[1].request.surface)
        end)

        it("returns error for missing or corrupted files", function()
            local test_cases = {
                { session_id = "non-existent" },
                {
                    session_id = "corrupted",
                    content = "not valid json {{{",
                },
            }

            for _, tc in ipairs(test_cases) do
                if tc.content then
                    local path = PersistedSession.get_file_path(tc.session_id)
                    mock_files[path] = tc.content
                end

                local loaded = nil
                local load_err = nil
                local done = false

                PersistedSession.load(tc.session_id, function(session_data, err)
                    loaded = session_data
                    load_err = err
                    done = true
                end)

                vim.wait(1000, function()
                    return done
                end)

                assert.is_nil(loaded)
                assert.is_not_nil(load_err)
            end
        end)
    end)

    describe("list_sessions", function()
        before_each(function()
            stub_cwd()
        end)

        it("returns empty array when no sessions exist", function()
            local sessions = nil
            local done = false

            PersistedSession.list_sessions(function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.equal(0, #sessions)
        end)

        it("returns all saved sessions in project folder", function()
            local session_ids = { "session-1", "session-2" }

            for _, id in ipairs(session_ids) do
                local persisted_session = PersistedSession:new()
                persisted_session.session_id = id
                persisted_session.title = id
                persisted_session.turns = { make_turn(id .. " message") }

                local saved = false
                persisted_session:save(function()
                    saved = true
                end)
                vim.wait(1000, function()
                    return saved
                end)
            end

            local sessions = nil
            local done = false

            PersistedSession.list_sessions(function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.equal(2, #sessions)

            local ids = {}
            for _, session_meta in ipairs(sessions or {}) do
                ids[session_meta.session_id] = true
            end
            assert.is_true(ids["session-1"])
            assert.is_true(ids["session-2"])
        end)
    end)
end)
