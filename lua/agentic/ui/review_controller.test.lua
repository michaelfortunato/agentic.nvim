--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, need-check-nil, undefined-field, redundant-parameter
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local FileSystem = require("agentic.utils.file_system")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local Logger = require("agentic.utils.logger")
local ReviewState = require("agentic.ui.diff_preview.review_state")
local ReviewController = require("agentic.ui.review_controller")
local SessionEvents = require("agentic.session.session_events")
local SessionState = require("agentic.session.session_state")

describe("agentic.ui.ReviewController", function()
    local read_stub
    local original_layout
    local session_state
    local review_controller
    local permission_manager
    local bufnr
    local file_path
    local notify_spy

    --- @param predicate fun(): boolean
    local function wait_for(predicate)
        assert.is_true(vim.wait(100, predicate))
    end

    before_each(function()
        read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
        read_stub:invokes(function()
            return { "local x = 1", "print(x)", "" }, nil
        end)
        notify_spy = spy.on(Logger, "notify")
        original_layout = Config.diff_preview.layout
        Config.diff_preview.layout = "inline"

        file_path = vim.fn.tempname() .. ".lua"
        bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "local x = 1",
            "print(x)",
            "",
        })
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)

        session_state = SessionState:new()
        permission_manager = {
            complete_current_request = spy.new(function() end),
            show_current_request_chooser = spy.new(function() end),
        }

        review_controller = ReviewController:new(session_state, {
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            find_first_editor_window = function()
                return vim.api.nvim_get_current_win()
            end,
            open_left_window = function(_self, target_bufnr)
                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    target_bufnr
                )
                return vim.api.nvim_get_current_win()
            end,
        } --[[@as agentic.ui.ChatWidget]], permission_manager --[[@as agentic.ui.PermissionManager]])
    end)

    after_each(function()
        if review_controller then
            review_controller:destroy()
        end

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            DiffPreview.clear_diff(bufnr)
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end

        read_stub:revert()
        notify_spy:revert()
        Config.diff_preview.layout = original_layout
    end)

    it(
        "shows review actions and binds m/n/M/N for hyphenated permission options",
        function()
            session_state:dispatch(SessionEvents.append_interaction_request({
                kind = "user",
                text = "review this edit",
                timestamp = 1,
                content = {
                    { type = "text", text = "review this edit" },
                },
            }))
            session_state:dispatch(
                SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                    tool_call_id = "tc-review-1",
                    kind = "edit",
                    status = "pending",
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                })
            )
            session_state:dispatch(
                SessionEvents.set_review_target("tc-review-1")
            )
            session_state:dispatch(SessionEvents.enqueue_permission({
                sessionId = "sess-1",
                toolCall = {
                    toolCallId = "tc-review-1",
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "allow-always",
                        name = "Allow always",
                        kind = "allow_always",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                    {
                        optionId = "reject-always",
                        name = "Reject always",
                        kind = "reject_always",
                    },
                },
            }, function() end))
            session_state:dispatch(SessionEvents.show_next_permission())

            local review_marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                DiffPreview.NS_REVIEW,
                0,
                -1,
                { details = true }
            )
            local diff_marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                HunkNavigation.NS_DIFF,
                0,
                -1,
                { details = true }
            )
            local virt_lines = review_marks[1] and review_marks[1][4].virt_lines

            assert.equal(2, #virt_lines)

            local action_segments = virt_lines and virt_lines[2] or nil
            assert.is_not_nil(action_segments)
            --- @type table
            local banner_segments = action_segments
            local action_banner = table.concat(
                vim.tbl_map(function(segment)
                    return segment[1]
                end, banner_segments),
                ""
            )
            assert.truthy(action_banner:find("M accept-all", 1, true))
            assert.truthy(action_banner:find("N reject-all", 1, true))

            local footer_banner = nil
            for _, mark in ipairs(diff_marks) do
                local details = mark[4] or {}
                local mark_lines = details.virt_lines
                if mark_lines and #mark_lines > 0 then
                    local footer_segments = mark_lines[#mark_lines]
                    local footer_text = table.concat(
                        vim.tbl_map(function(segment)
                            return segment[1]
                        end, footer_segments),
                        ""
                    )
                    if footer_text:find("m accept", 1, true) then
                        footer_banner = footer_text
                        break
                    end
                end
            end

            assert.is_not_nil(footer_banner)
            assert.truthy(footer_banner:find("m accept", 1, true))
            assert.truthy(footer_banner:find("n reject", 1, true))

            local function get_map(key)
                return vim.api.nvim_buf_call(bufnr, function()
                    return vim.fn.maparg(key, "n", false, true)
                end)
            end

            vim.api.nvim_win_set_cursor(
                vim.api.nvim_get_current_win(),
                { 2, 0 }
            )
            get_map("m").callback()
            get_map("n").callback()
            get_map("M").callback()
            get_map("N").callback()

            wait_for(function()
                return permission_manager.complete_current_request.call_count
                    == 4
            end)
            assert.equal(
                "allow-once",
                permission_manager.complete_current_request.calls[1][2]
            )
            assert.equal(
                "reject-once",
                permission_manager.complete_current_request.calls[2][2]
            )
            assert.equal(
                "allow-always",
                permission_manager.complete_current_request.calls[3][2]
            )
            assert.equal(
                "reject-always",
                permission_manager.complete_current_request.calls[4][2]
            )
        end
    )

    it(
        "activates diff review from diff content even for non-whitelisted tool kinds",
        function()
            session_state:dispatch(SessionEvents.append_interaction_request({
                kind = "user",
                text = "review this write",
                timestamp = 1,
                content = {
                    { type = "text", text = "review this write" },
                },
            }))
            session_state:dispatch(
                SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                    tool_call_id = "tc-review-2",
                    kind = "other",
                    status = "pending",
                    content_items = {
                        {
                            type = "diff",
                            path = file_path,
                            oldText = table.concat({
                                "local x = 1",
                                "print(x)",
                                "",
                            }, "\n"),
                            newText = table.concat({
                                "local x = 3",
                                "print(x)",
                                "",
                            }, "\n"),
                        },
                    },
                })
            )
            session_state:dispatch(
                SessionEvents.set_review_target("tc-review-2")
            )
            session_state:dispatch(SessionEvents.enqueue_permission({
                sessionId = "sess-2",
                toolCall = {
                    toolCallId = "tc-review-2",
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }, function() end))
            session_state:dispatch(SessionEvents.show_next_permission())

            local review_marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                DiffPreview.NS_REVIEW,
                0,
                -1,
                { details = true }
            )

            assert.equal(1, #review_marks)

            local function get_map(key)
                return vim.api.nvim_buf_call(bufnr, function()
                    return vim.fn.maparg(key, "n", false, true)
                end)
            end

            assert.is_not_nil(get_map("m").callback)
            assert.is_not_nil(get_map("n").callback)
        end
    )

    it(
        "notifies when an active diff review is restored after detaching the buffer",
        function()
            local review_key =
                ReviewState.create_review_key("sess-detach", "tc-review-detach")

            session_state:dispatch(SessionEvents.append_interaction_request({
                kind = "user",
                text = "review this edit",
                timestamp = 1,
                content = {
                    { type = "text", text = "review this edit" },
                },
            }))
            session_state:dispatch(
                SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                    tool_call_id = "tc-review-detach",
                    kind = "edit",
                    status = "pending",
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                })
            )
            session_state:dispatch(
                SessionEvents.set_review_target("tc-review-detach")
            )
            session_state:dispatch(SessionEvents.enqueue_permission({
                sessionId = "sess-detach",
                toolCall = {
                    toolCallId = "tc-review-detach",
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }, function() end))
            session_state:dispatch(SessionEvents.show_next_permission())

            notify_spy:reset()
            DiffPreview.clear_diff(bufnr, {
                reason = "buffer_detached",
                review_key = review_key,
            })

            wait_for(function()
                local diff_marks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    HunkNavigation.NS_DIFF,
                    0,
                    -1,
                    { details = true }
                )
                return notify_spy.call_count == 1 and #diff_marks > 0
            end)

            assert.equal(
                "This diff review is still pending for "
                    .. vim.fs.basename(file_path)
                    .. ". Accept or reject it before leaving the preview.",
                notify_spy.calls[1][1]
            )
            assert.equal(vim.log.levels.WARN, notify_spy.calls[1][2])
            assert
                .spy(permission_manager.show_current_request_chooser).was
                .called(0)
        end
    )

    it(
        "suppresses approximate preview notifications when restoring enforced review",
        function()
            local review_key =
                ReviewState.create_review_key("sess-approx", "tc-review-approx")

            session_state:dispatch(SessionEvents.append_interaction_request({
                kind = "user",
                text = "review this edit",
                timestamp = 1,
                content = {
                    { type = "text", text = "review this edit" },
                },
            }))
            session_state:dispatch(
                SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                    tool_call_id = "tc-review-approx",
                    kind = "edit",
                    status = "pending",
                    file_path = file_path,
                    diff = {
                        old = { "nonexistent content that wont match" },
                        new = { "replacement" },
                    },
                })
            )
            session_state:dispatch(
                SessionEvents.set_review_target("tc-review-approx")
            )
            session_state:dispatch(SessionEvents.enqueue_permission({
                sessionId = "sess-approx",
                toolCall = {
                    toolCallId = "tc-review-approx",
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }, function() end))
            session_state:dispatch(SessionEvents.show_next_permission())

            notify_spy:reset()
            DiffPreview.clear_diff(bufnr, {
                reason = "buffer_detached",
                review_key = review_key,
            })

            wait_for(function()
                local diff_marks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    HunkNavigation.NS_DIFF,
                    0,
                    -1,
                    { details = true }
                )
                return notify_spy.call_count == 1 and #diff_marks > 0
            end)

            assert.equal(
                "This diff review is still pending for "
                    .. vim.fs.basename(file_path)
                    .. ". Accept or reject it before leaving the preview.",
                notify_spy.calls[1][1]
            )
            assert.equal(vim.log.levels.WARN, notify_spy.calls[1][2])
        end
    )

    it(
        "falls back to the chooser when the inline review is manually cleared",
        function()
            local review_key =
                ReviewState.create_review_key("sess-manual", "tc-review-manual")

            session_state:dispatch(SessionEvents.append_interaction_request({
                kind = "user",
                text = "review this edit",
                timestamp = 1,
                content = {
                    { type = "text", text = "review this edit" },
                },
            }))
            session_state:dispatch(
                SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                    tool_call_id = "tc-review-manual",
                    kind = "edit",
                    status = "pending",
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                })
            )
            session_state:dispatch(
                SessionEvents.set_review_target("tc-review-manual")
            )
            session_state:dispatch(SessionEvents.enqueue_permission({
                sessionId = "sess-manual",
                toolCall = {
                    toolCallId = "tc-review-manual",
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }, function() end))
            session_state:dispatch(SessionEvents.show_next_permission())

            DiffPreview.clear_diff(bufnr, {
                reason = "manual_clear",
                review_key = review_key,
            })

            wait_for(function()
                return permission_manager.show_current_request_chooser.call_count
                    == 1
            end)

            assert
                .spy(permission_manager.show_current_request_chooser).was
                .called(1)
            assert.equal(
                "tc-review-manual",
                session_state:get_state().permissions.current_request.toolCallId
            )
        end
    )

    it(
        "clears preserved review state when the tool review completes",
        function()
            session_state:dispatch(SessionEvents.append_interaction_request({
                kind = "user",
                text = "review this edit",
                timestamp = 1,
                content = {
                    { type = "text", text = "review this edit" },
                },
            }))
            session_state:dispatch(
                SessionEvents.upsert_interaction_tool_call("Codex ACP", {
                    tool_call_id = "tc-review-terminal",
                    kind = "edit",
                    status = "pending",
                    file_path = file_path,
                    diff = {
                        old = { "local x = 1", "print(x)", "" },
                        new = { "local x = 2", "print(x)", "" },
                    },
                })
            )
            session_state:dispatch(
                SessionEvents.set_review_target("tc-review-terminal")
            )
            session_state:dispatch(SessionEvents.enqueue_permission({
                sessionId = "sess-terminal",
                toolCall = {
                    toolCallId = "tc-review-terminal",
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }, function() end))
            session_state:dispatch(SessionEvents.show_next_permission())

            local review_key = ReviewState.create_review_key(
                "sess-terminal",
                "tc-review-terminal"
            )
            assert.is_not_nil(review_key)
            --- @cast review_key string

            assert.is_not_nil(
                ReviewState.get_review_session_by_key(
                    review_key,
                    vim.api.nvim_get_current_tabpage()
                )
            )
            assert.is_not_nil(
                ReviewState.get_buffer_review_attachment(bufnr, review_key)
            )

            session_state:dispatch(
                SessionEvents.clear_review_target(
                    "tc-review-terminal",
                    "tool_completed"
                )
            )

            assert.is_nil(
                ReviewState.get_review_session_by_key(
                    review_key,
                    vim.api.nvim_get_current_tabpage()
                )
            )
            assert.is_nil(
                ReviewState.get_buffer_review_attachment(bufnr, review_key)
            )
        end
    )
end)
