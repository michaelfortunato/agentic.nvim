local CardRenderer = require("agentic.ui.message_writer.card_renderer")
local Common = require("agentic.ui.message_writer.common")

--- @class agentic.ui.MessageWriterTranscriptRenderer
local M = {}

local function build_request_header_lines(request)
    if not request then
        return {}
    end

    local timestamp = tostring(
        request.timestamp and os.date("%Y-%m-%d %H:%M:%S", request.timestamp)
            or os.date("%Y-%m-%d %H:%M:%S")
    )
    local label = request.kind == "review" and "Review" or "User"

    return {
        Common.build_meta_line(label, timestamp),
    }
end

local function build_request_lines(request)
    return Common.apply_transcript_hierarchy(
        build_request_header_lines(request)
    )
end

local function append_semantic_content_lines(lines, content_nodes, opts)
    opts = opts or {}
    local buffered_text_chunks = {}

    local function flush_text_content()
        local start_line = #lines
        local merged_lines, chunk_boundaries =
            Common.merge_text_chunks(buffered_text_chunks)

        for _, line in ipairs(merged_lines) do
            lines[#lines + 1] = line
        end

        if opts.chunk_boundaries then
            for _, boundary in ipairs(chunk_boundaries) do
                opts.chunk_boundaries[#opts.chunk_boundaries + 1] = {
                    line_index = start_line + boundary.line_index,
                    col = boundary.col,
                }
            end
        end

        buffered_text_chunks = {}
    end

    for _, content_node in ipairs(content_nodes or {}) do
        if content_node.type == "text_content" then
            local text = content_node.text or ""
            if text ~= "" then
                buffered_text_chunks[#buffered_text_chunks + 1] = text
            end
        elseif content_node.type == "resource_link_content" then
            flush_text_content()
            local label = Common.get_content_display_name(content_node)
            lines[#lines + 1] = "@" .. label
            if content_node.description and content_node.description ~= "" then
                lines[#lines + 1] = "linked resource · "
                    .. Common.sanitize_single_line(content_node.description)
            elseif content_node.mime_type and content_node.mime_type ~= "" then
                lines[#lines + 1] = "linked resource · "
                    .. Common.sanitize_single_line(content_node.mime_type)
            else
                lines[#lines + 1] = "linked resource"
            end
        elseif content_node.type == "resource_content" then
            flush_text_content()
            local label = Common.get_content_display_name(content_node)
            lines[#lines + 1] = "@" .. label

            local detail = "embedded context"
            local line_count = Common.count_content_lines(content_node)
            if line_count > 0 then
                detail = detail
                    .. " · "
                    .. Common.pluralize(line_count, "line")
            elseif content_node.blob then
                detail = detail .. " · binary data"
            end
            if content_node.mime_type and content_node.mime_type ~= "" then
                detail = detail
                    .. " · "
                    .. Common.sanitize_single_line(content_node.mime_type)
            end
            lines[#lines + 1] = detail

            if
                opts.show_embedded_text
                and content_node.text
                and content_node.text ~= ""
            then
                for _, line in
                    ipairs(Common.split_content_lines(content_node.text))
                do
                    lines[#lines + 1] = line
                end
            end
        elseif content_node.type == "image_content" then
            flush_text_content()
            local label = "image"
            if content_node.mime_type and content_node.mime_type ~= "" then
                label = label
                    .. " · "
                    .. Common.sanitize_single_line(content_node.mime_type)
            end
            if content_node.uri and content_node.uri ~= "" then
                label = label
                    .. " · "
                    .. Common.format_content_uri(content_node.uri)
            end
            lines[#lines + 1] = label
        elseif content_node.type == "audio_content" then
            flush_text_content()
            local label = "audio"
            if content_node.mime_type and content_node.mime_type ~= "" then
                label = label
                    .. " · "
                    .. Common.sanitize_single_line(content_node.mime_type)
            end
            lines[#lines + 1] = label
        elseif content_node.type == "unknown_content" then
            flush_text_content()
            local raw_type = Common.sanitize_single_line(
                content_node.content.type or "unknown"
            )
            lines[#lines + 1] = "content · " .. raw_type
        end
    end

    flush_text_content()
end

local function build_semantic_content_lines(content_nodes)
    local lines = {}
    local chunk_boundaries = {}

    append_semantic_content_lines(lines, content_nodes, {
        show_embedded_text = false,
        chunk_boundaries = chunk_boundaries,
    })
    return lines, chunk_boundaries
end

local function build_turn_result_lines(result)
    local lines = {}

    if result.error_text and result.error_text ~= "" then
        lines[#lines + 1] =
            Common.build_meta_line("Agent error", "details below")
        for _, line in
            ipairs(vim.split(result.error_text, "\n", { plain = true }))
        do
            lines[#lines + 1] = line
        end
    elseif result.stop_reason == "cancelled" then
        lines[#lines + 1] = Common.build_meta_line("Stopped", "user request")
    end

    lines[#lines + 1] = Common.build_meta_line(
        "Turn complete",
        tostring(os.date("%Y-%m-%d %H:%M:%S", result.timestamp or os.time()))
    )

    return Common.apply_transcript_hierarchy(lines)
end

local function build_plan_lines(node)
    local lines = {
        Common.indent_text("Plan", Common.HIERARCHY_LEVEL.detail),
    }

    for _, entry in ipairs(node.entries or {}) do
        local status = Common.sanitize_single_line(entry.status or "pending")
        local content = Common.sanitize_single_line(entry.content or "")
        if content ~= "" then
            lines[#lines + 1] = Common.indent_text(
                string.format("[%s] %s", status, content),
                Common.HIERARCHY_LEVEL.nested
            )
        end
    end

    return lines
end

local function build_agent_header_lines(writer, provider_name)
    return {
        Common.build_meta_line(
            "Agent",
            provider_name or writer._provider_name or "Unknown provider"
        ),
    }
end

local function append_block(render_state, block_lines, block_opts)
    if not block_lines or #block_lines == 0 then
        return
    end

    local lines = render_state.lines
    local join_with_previous = block_opts and block_opts.join_with_previous
    if not join_with_previous and #lines > 0 and lines[#lines] ~= "" then
        lines[#lines + 1] = ""
    end

    local start_row = #lines
    vim.list_extend(lines, block_lines)
    local end_row = #lines - 1

    if block_opts and block_opts.meta then
        render_state.meta_blocks[#render_state.meta_blocks + 1] = {
            start_row = start_row,
            lines = vim.deepcopy(block_lines),
        }
    end

    if block_opts and block_opts.thought then
        render_state.thought_blocks[#render_state.thought_blocks + 1] = {
            start_row = start_row,
            end_row = end_row,
        }
    end

    if block_opts and block_opts.fold then
        render_state.fold_blocks[#render_state.fold_blocks + 1] = {
            start_row = start_row,
            end_row = end_row,
            kind = block_opts.fold.kind,
            highlight_ranges = block_opts.fold.highlight_ranges,
            tracker = block_opts.fold.tracker,
        }
    end

    if block_opts and block_opts.chunk_boundaries then
        render_state.chunk_boundary_blocks[#render_state.chunk_boundary_blocks + 1] =
            {
                start_row = start_row,
                boundaries = vim.deepcopy(block_opts.chunk_boundaries),
            }
    end
end

--- @param writer agentic.ui.MessageWriter
--- @param interaction_session agentic.session.InteractionSession
--- @param opts {welcome_lines?: string[]|nil}|nil
--- @param previous_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param previous_request_blocks table<string, agentic.ui.MessageWriter.RequestContentBlock>
--- @return table render_state
function M.build_render_state(
    writer,
    interaction_session,
    opts,
    previous_blocks,
    previous_request_blocks
)
    opts = opts or {}
    previous_blocks = previous_blocks or {}
    previous_request_blocks = previous_request_blocks or {}

    local winid = vim.fn.bufwinid(writer.bufnr)
    local render_width = nil
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
        render_width = math.max(8, vim.api.nvim_win_get_width(winid) - 1)
    end

    --- @type table
    local render_state = {
        lines = {},
        meta_blocks = {},
        thought_blocks = {},
        fold_blocks = {},
        chunk_boundary_blocks = {},
    }

    append_block(render_state, opts.welcome_lines or {}, { meta = true })

    for _, turn in ipairs(interaction_session.turns or {}) do
        writer._current_turn_id = turn.index
        writer._active_turn_diff_cards = {}

        append_block(
            render_state,
            build_request_lines(turn.request),
            { meta = true }
        )

        local request_items = CardRenderer.build_request_items(
            writer,
            turn.request,
            turn.index,
            previous_request_blocks
        )
        local joined_to_request_header = true
        for _, item in ipairs(request_items) do
            local join_with_previous = joined_to_request_header
            joined_to_request_header = false

            if item.type == "lines" then
                append_block(
                    render_state,
                    Common.apply_block_hierarchy(
                        item.lines,
                        Common.HIERARCHY_LEVEL.detail
                    ),
                    { join_with_previous = join_with_previous }
                )
            elseif item.type == "request_content" and item.tracker then
                writer._request_content_blocks[item.tracker.block_id] =
                    item.tracker
                local block_lines, highlight_ranges =
                    CardRenderer.prepare_request_content_block_lines(
                        writer,
                        item.tracker,
                        render_width
                    )
                append_block(render_state, block_lines, {
                    join_with_previous = join_with_previous,
                    fold = {
                        kind = "request_content",
                        highlight_ranges = highlight_ranges,
                        tracker = item.tracker,
                    },
                })
            end
        end

        local response_items = {}
        for _, node in ipairs(turn.response.nodes or {}) do
            if node.type == "tool_call" then
                local block = CardRenderer.build_tool_call_block_from_node(
                    writer,
                    node,
                    previous_blocks
                )
                CardRenderer.register_interaction_tool_block(
                    writer,
                    block,
                    previous_blocks,
                    response_items
                )
            else
                response_items[#response_items + 1] = node
            end
        end

        local joined_to_response_header = false
        if #response_items > 0 and turn.response.provider_name then
            local header_lines =
                build_agent_header_lines(writer, turn.response.provider_name)
            append_block(render_state, header_lines, { meta = true })
            joined_to_response_header = true
        end

        for _, item in ipairs(response_items) do
            local join_with_previous = joined_to_response_header
            joined_to_response_header = false
            if item.type == "message" then
                local block_lines, chunk_boundaries =
                    build_semantic_content_lines(item.content_nodes)
                if #block_lines == 0 then
                    block_lines =
                        vim.split(item.text or "", "\n", { plain = true })
                    chunk_boundaries = {}
                end
                block_lines = Common.apply_block_hierarchy(
                    block_lines,
                    Common.HIERARCHY_LEVEL.detail
                )
                Common.offset_chunk_boundaries(
                    chunk_boundaries,
                    block_lines,
                    Common.HIERARCHY_LEVEL.detail
                )
                append_block(render_state, block_lines, {
                    join_with_previous = join_with_previous,
                    chunk_boundaries = chunk_boundaries,
                })
            elseif item.type == "thought" then
                local block_lines, chunk_boundaries =
                    build_semantic_content_lines(item.content_nodes)
                if #block_lines == 0 then
                    block_lines =
                        vim.split(item.text or "", "\n", { plain = true })
                    chunk_boundaries = {}
                end
                block_lines = Common.apply_block_hierarchy(
                    block_lines,
                    Common.HIERARCHY_LEVEL.detail
                )
                Common.offset_chunk_boundaries(
                    chunk_boundaries,
                    block_lines,
                    Common.HIERARCHY_LEVEL.detail
                )
                append_block(render_state, block_lines, {
                    thought = true,
                    join_with_previous = join_with_previous,
                    chunk_boundaries = chunk_boundaries,
                })
            elseif item.type == "plan" then
                append_block(render_state, build_plan_lines(item), {
                    join_with_previous = join_with_previous,
                })
            elseif item.type == "tool_call" and item.tracker then
                local block_lines, highlight_ranges =
                    CardRenderer.prepare_block_lines(
                        writer,
                        item.tracker,
                        render_width
                    )
                append_block(render_state, block_lines, {
                    join_with_previous = join_with_previous,
                    fold = {
                        kind = item.tracker.kind or "other",
                        highlight_ranges = highlight_ranges,
                        tracker = item.tracker,
                    },
                })
            end
        end

        if turn.result then
            append_block(render_state, build_turn_result_lines(turn.result), {
                meta = true,
            })
        end
    end

    return render_state
end

return M
