local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local Theme = require("agentic.theme")
local Common = require("agentic.ui.message_writer.common")

--- @class agentic.ui.MessageWriterDecorations
local M = {}

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_THOUGHT = vim.api.nvim_create_namespace("agentic_thought_chunks")
local NS_TRANSCRIPT_META =
    vim.api.nvim_create_namespace("agentic_transcript_meta")
local NS_CHUNK_BOUNDARIES =
    vim.api.nvim_create_namespace("agentic_chunk_boundaries")

local function apply_thought_block_highlights(bufnr, start_row, end_row)
    if start_row > end_row then
        return
    end

    pcall(
        vim.api.nvim_buf_clear_namespace,
        bufnr,
        NS_THOUGHT,
        start_row,
        end_row + 1
    )

    for line_idx = start_row, end_row do
        local line =
            vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1]

        if line and #line > 0 then
            vim.api.nvim_buf_set_extmark(bufnr, NS_THOUGHT, line_idx, 0, {
                end_col = #line,
                hl_group = Theme.HL_GROUPS.THOUGHT_TEXT,
            })
        end
    end
end

local function apply_transcript_meta_highlights(bufnr, start_row, lines)
    if not lines or #lines == 0 then
        return
    end

    pcall(
        vim.api.nvim_buf_clear_namespace,
        bufnr,
        NS_TRANSCRIPT_META,
        start_row,
        start_row + #lines
    )

    for index, line in ipairs(lines) do
        local line_idx = start_row + index - 1
        if Common.is_meta_line(line) then
            local end_col = Common.get_meta_prefix_end_col(line) or #line
            vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_TRANSCRIPT_META,
                line_idx,
                0,
                {
                    end_col = end_col,
                    hl_group = Common.get_transcript_meta_hl_group(line),
                }
            )
        elseif Common.is_reference_line(line) then
            vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_TRANSCRIPT_META,
                line_idx,
                2,
                {
                    end_col = #line,
                    hl_group = Theme.HL_GROUPS.RESOURCE_LINK,
                }
            )
        end
    end
end

local function apply_chunk_boundary_highlights(bufnr, start_row, boundaries)
    if not Config.debug or not boundaries or #boundaries == 0 then
        return
    end

    for _, boundary in ipairs(boundaries) do
        local buffer_line = start_row + boundary.line_index
        local line = vim.api.nvim_buf_get_lines(
            bufnr,
            buffer_line,
            buffer_line + 1,
            false
        )[1] or ""

        if line ~= "" then
            local start_col = boundary.col
            local end_col = boundary.col + 1

            if boundary.col > 0 then
                start_col = boundary.col - 1
                end_col = boundary.col
            end

            start_col = math.max(0, math.min(start_col, #line - 1))
            end_col = math.max(start_col + 1, math.min(end_col, #line))

            if end_col > start_col then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_CHUNK_BOUNDARIES,
                    buffer_line,
                    start_col,
                    {
                        end_col = end_col,
                        hl_group = Theme.HL_GROUPS.CHUNK_BOUNDARY,
                        right_gravity = false,
                    }
                )
            end
        end
    end
end

local function apply_diff_highlights(bufnr, start_row, highlight_ranges)
    if not highlight_ranges or #highlight_ranges == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local buffer_line = start_row + hl_range.line_index
        local col_offset = hl_range.display_prefix_len or 0

        if hl_range.type == "old" then
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line,
                col_offset
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                nil,
                hl_range.new_line,
                col_offset
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line,
                col_offset
            )
        elseif hl_range.type == "comment" then
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                buffer_line,
                buffer_line + 1,
                false
            )[1]

            if line then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_DIFF_HIGHLIGHTS,
                    buffer_line,
                    0,
                    {
                        end_col = #line,
                        hl_group = hl_range.hl_group
                            or Theme.HL_GROUPS.CARD_DETAIL,
                    }
                )
            end
        elseif
            hl_range.type == "span"
            and hl_range.start_col ~= nil
            and hl_range.end_col ~= nil
            and hl_range.hl_group
        then
            vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.start_col,
                {
                    end_col = hl_range.end_col,
                    hl_group = hl_range.hl_group,
                }
            )
        end
    end
end

local function apply_block_highlights(
    bufnr,
    start_row,
    _end_row,
    _kind,
    highlight_ranges
)
    if #highlight_ranges > 0 then
        apply_diff_highlights(bufnr, start_row, highlight_ranges)
    end
end

--- @param writer agentic.ui.MessageWriter
--- @param render_state table
function M.apply_render_state(writer, render_state)
    writer._with_modifiable_and_notify_change(writer, function(bufnr)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_TOOL_BLOCKS, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_DIFF_HIGHLIGHTS, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_THOUGHT, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_TRANSCRIPT_META, 0, -1)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_CHUNK_BOUNDARIES, 0, -1)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, render_state.lines)

        for _, block in ipairs(render_state.meta_blocks or {}) do
            apply_transcript_meta_highlights(
                bufnr,
                block.start_row,
                block.lines
            )
        end

        for _, block in ipairs(render_state.thought_blocks or {}) do
            apply_thought_block_highlights(
                bufnr,
                block.start_row,
                block.end_row
            )
        end

        for _, block in ipairs(render_state.chunk_boundary_blocks or {}) do
            apply_chunk_boundary_highlights(
                bufnr,
                block.start_row,
                block.boundaries
            )
        end

        for _, block in ipairs(render_state.fold_blocks or {}) do
            apply_block_highlights(
                bufnr,
                block.start_row,
                block.end_row,
                block.kind or "other",
                block.highlight_ranges or {}
            )

            block.tracker.extmark_id = vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_TOOL_BLOCKS,
                block.start_row,
                0,
                {
                    end_row = block.end_row,
                    right_gravity = false,
                }
            )
        end
    end)
end

function M.apply_thought_block_highlights(writer, start_row, end_row)
    apply_thought_block_highlights(writer.bufnr, start_row, end_row)
end

function M.apply_transcript_meta_highlights(writer, start_row, lines)
    apply_transcript_meta_highlights(writer.bufnr, start_row, lines)
end

function M.apply_chunk_boundary_highlights(writer, start_row, boundaries)
    apply_chunk_boundary_highlights(writer.bufnr, start_row, boundaries)
end

function M.apply_diff_highlights(writer, start_row, highlight_ranges)
    apply_diff_highlights(writer.bufnr, start_row, highlight_ranges)
end

function M.apply_block_highlights(
    _writer,
    bufnr,
    start_row,
    _end_row,
    _kind,
    highlight_ranges
)
    apply_block_highlights(bufnr, start_row, _end_row, _kind, highlight_ranges)
end

return M
