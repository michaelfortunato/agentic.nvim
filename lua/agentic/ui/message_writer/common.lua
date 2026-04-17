local Theme = require("agentic.theme")

--- @class agentic.ui.MessageWriterCommon
local M = {}

local INDENT_UNIT = "  "
local ENVIRONMENT_INFO_URI = "agentic://environment_info"

--- @type table<string, integer>
M.HIERARCHY_LEVEL = {
    root = 0,
    detail = 1,
    nested = 2,
}

M.ENVIRONMENT_INFO_URI = ENVIRONMENT_INFO_URI

local META_LINE_PATTERNS = {
    "^Agentic · ",
    "^Session · ",
    "^Started · ",
    "^User · ",
    "^Review · ",
    "^Agent · ",
    "^Files$",
    "^Code$",
    "^Diagnostics$",
    "^Turn complete · ",
    "^Stopped · ",
    "^Agent error · ",
}

local TRANSCRIPT_PARENT_META_PATTERNS = {
    "^User · ",
    "^Review · ",
    "^Agent · ",
    "^Agent error · ",
}

local DIFF_TOOL_KINDS = {
    edit = true,
    create = true,
    write = true,
}

local DIFF_ACTION_LABELS = {
    edit = "Edited",
    create = "Created",
    write = "Wrote",
}

local TOOL_ACTION_LABELS = {
    read = "Read",
    search = "Search",
    execute = "Run",
    fetch = "Fetch",
    think = "Think",
    delete = "Delete",
    move = "Move",
    switch_mode = "Switch Mode",
    create = "Create",
    write = "Write",
    edit = "Edit",
    WebSearch = "Search Web",
    SlashCommand = "Slash Command",
    SubAgent = "Sub-Agent",
    Skill = "Use Skill",
    other = "Tool",
}

local OUTPUT_SUMMARY_LABELS = {
    search = "result line",
    fetch = "result line",
    WebSearch = "result line",
    execute = "output line",
    SlashCommand = "output line",
    SubAgent = "update line",
    Skill = "update line",
    think = "thought line",
    other = "line",
}

--- @param line string
--- @return boolean
function M.is_meta_line(line)
    if not line or line == "" then
        return false
    end

    for _, pattern in ipairs(META_LINE_PATTERNS) do
        if line:match(pattern) then
            return true
        end
    end

    return false
end

--- @param line string|nil
--- @return boolean
function M.is_reference_line(line)
    return line ~= nil and line:match("^  @") ~= nil
end

--- @param line string|nil
--- @return string
function M.get_transcript_meta_hl_group(line)
    if not line then
        return Theme.HL_GROUPS.TRANSCRIPT_SYSTEM_META
    end

    if line:match("^User · ") or line:match("^Review · ") then
        return Theme.HL_GROUPS.TRANSCRIPT_REQUEST_META
    end

    if line:match("^Agent · ") then
        return Theme.HL_GROUPS.TRANSCRIPT_RESPONSE_META
    end

    return Theme.HL_GROUPS.TRANSCRIPT_SYSTEM_META
end

--- @param line string|nil
--- @return integer|nil
function M.get_transcript_body_level(line)
    if not line or line == "" then
        return nil
    end

    for _, pattern in ipairs(TRANSCRIPT_PARENT_META_PATTERNS) do
        if line:match(pattern) then
            return M.HIERARCHY_LEVEL.detail
        end
    end

    return nil
end

--- @param line string
--- @return integer|nil
function M.get_meta_prefix_end_col(line)
    if not line or line == "" then
        return nil
    end

    local _, separator_end = line:find(" · ", 1, true)
    if separator_end then
        return separator_end
    end

    if line == "Files" or line == "Code" or line == "Diagnostics" then
        return #line
    end

    return nil
end

--- @param label string
--- @param value string
--- @return string
function M.build_meta_line(label, value)
    return string.format("%s · %s", label, value)
end

--- @param text string|nil
--- @return string
function M.sanitize_single_line(text)
    if not text or text == "" then
        return ""
    end

    local sanitized =
        text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return sanitized
end

--- @param text string|nil
--- @param max_length integer|nil
--- @return string
function M.truncate_single_line(text, max_length)
    local sanitized = M.sanitize_single_line(text)
    if not max_length or max_length <= 0 then
        return sanitized
    end

    if vim.fn.strdisplaywidth(sanitized) <= max_length then
        return sanitized
    end

    local ellipsis = "..."
    local limit = math.max(1, max_length - vim.fn.strdisplaywidth(ellipsis))
    local truncated = sanitized

    while truncated ~= "" and vim.fn.strdisplaywidth(truncated) > limit do
        truncated =
            vim.fn.strcharpart(truncated, 0, vim.fn.strchars(truncated) - 1)
    end

    if truncated == "" then
        return ellipsis
    end

    return truncated .. ellipsis
end

--- @param render_width integer|nil
--- @param level integer
--- @param prefix string|nil
--- @return integer|nil
function M.get_available_line_width(render_width, level, prefix)
    if not render_width or render_width <= 0 then
        return nil
    end

    local reserved =
        vim.fn.strdisplaywidth(M.indent_prefix(level) .. (prefix or ""))
    return math.max(1, render_width - reserved)
end

--- @param path string
--- @return string
function M.format_compact_path(path)
    local compact = vim.fn.fnamemodify(path, ":~:.")
    return compact ~= "" and compact or path
end

--- @param uri string|nil
--- @return string
function M.format_content_uri(uri)
    if not uri or uri == "" then
        return "resource"
    end

    if uri == ENVIRONMENT_INFO_URI then
        return "environment_info"
    end

    if vim.startswith(uri, "file://") then
        local ok, path = pcall(vim.uri_to_fname, uri)
        if ok and path and path ~= "" then
            return M.format_compact_path(path)
        end
    end

    return M.sanitize_single_line(uri)
end

--- @param content_node agentic.session.InteractionContentNode
--- @return string
function M.get_content_display_name(content_node)
    if content_node.type == "resource_link_content" then
        return content_node.title
            or content_node.name
            or M.format_content_uri(content_node.uri)
    end

    if content_node.type == "resource_content" then
        return M.format_content_uri(content_node.uri)
    end

    if content_node.type == "image_content" then
        return content_node.mime_type or "image"
    end

    if content_node.type == "audio_content" then
        return content_node.mime_type or "audio"
    end

    if content_node.type == "text_content" then
        local first_line =
            vim.split(content_node.text or "", "\n", { plain = true })[1]
        return M.sanitize_single_line(first_line)
    end

    return "content"
end

--- @param content_node agentic.session.InteractionContentNode
--- @return integer
function M.count_content_lines(content_node)
    if content_node.type == "text_content" then
        return #vim.split(content_node.text or "", "\n", { plain = true })
    end

    if content_node.type == "resource_content" and content_node.text then
        return #vim.split(content_node.text, "\n", { plain = true })
    end

    return 0
end

--- @param text string|nil
--- @return string[]
function M.split_content_lines(text)
    if not text or text == "" then
        return {}
    end

    return vim.split(text, "\n", { plain = true })
end

--- @param chunks string[]
--- @return string[] lines
--- @return agentic.ui.MessageWriter.ChunkBoundary[] boundaries
function M.merge_text_chunks(chunks)
    local lines = {}
    --- @type agentic.ui.MessageWriter.ChunkBoundary[]
    local boundaries = {}

    if not chunks or #chunks == 0 then
        return lines, boundaries
    end

    local current_line = {}
    local current_col = 0
    local line_index = 0
    local has_any_chunk = false

    local function append_segment(segment)
        if segment == "" then
            return
        end

        current_line[#current_line + 1] = segment
        current_col = current_col + #segment
    end

    local function flush_line()
        lines[#lines + 1] = table.concat(current_line)
        current_line = {}
        current_col = 0
        line_index = line_index + 1
    end

    for chunk_index, chunk in ipairs(chunks) do
        if chunk ~= "" then
            has_any_chunk = true
            local start_col = 1

            while true do
                local newline_col = chunk:find("\n", start_col, true)
                if not newline_col then
                    append_segment(chunk:sub(start_col))
                    break
                end

                append_segment(chunk:sub(start_col, newline_col - 1))
                flush_line()
                start_col = newline_col + 1
            end
        end

        if chunk_index < #chunks then
            boundaries[#boundaries + 1] = {
                line_index = line_index,
                col = current_col,
            }
        end
    end

    if not has_any_chunk then
        return {}, {}
    end

    lines[#lines + 1] = table.concat(current_line)

    return lines, boundaries
end

--- @param level integer
--- @return string
function M.indent_prefix(level)
    return string.rep(INDENT_UNIT, math.max(level or 0, 0))
end

--- @param text string
--- @param level integer
--- @return string
function M.indent_text(text, level)
    if text == "" then
        return ""
    end

    return M.indent_prefix(level) .. text
end

--- @param lines string[]
--- @return string[]
function M.apply_transcript_hierarchy(lines)
    local formatted = {}
    local body_level = nil

    for _, line in ipairs(lines) do
        if M.is_meta_line(line) then
            formatted[#formatted + 1] = line
            body_level = M.get_transcript_body_level(line)
        elseif line == "" then
            formatted[#formatted + 1] = ""
        elseif body_level ~= nil then
            formatted[#formatted + 1] = M.indent_text(line, body_level)
        else
            formatted[#formatted + 1] = line
        end
    end

    return formatted
end

--- @param lines string[]
--- @param base_level integer|nil
--- @return string[]
function M.apply_block_hierarchy(lines, base_level)
    if not base_level or base_level <= 0 then
        return lines
    end

    local formatted = {}

    for _, line in ipairs(lines) do
        if line == "" then
            formatted[#formatted + 1] = ""
        else
            formatted[#formatted + 1] = M.indent_text(line, base_level)
        end
    end

    return formatted
end

--- @param chunk_boundaries agentic.ui.MessageWriter.ChunkBoundary[]|nil
--- @param lines string[]
--- @param base_level integer|nil
function M.offset_chunk_boundaries(chunk_boundaries, lines, base_level)
    if not base_level or base_level <= 0 then
        return
    end

    local offset = #M.indent_prefix(base_level)
    if offset == 0 then
        return
    end

    for _, boundary in ipairs(chunk_boundaries or {}) do
        local line = lines[boundary.line_index + 1]
        if line and line ~= "" then
            boundary.col = boundary.col + offset
        end
    end
end

--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
--- @param lines string[]
--- @param base_level integer|nil
function M.offset_highlight_ranges(highlight_ranges, lines, base_level)
    if not base_level or base_level <= 0 then
        return
    end

    local offset = #M.indent_prefix(base_level)
    if offset == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local line = lines[hl_range.line_index + 1]
        if line and line ~= "" then
            if hl_range.start_col ~= nil then
                hl_range.start_col = hl_range.start_col + offset
            end
            if hl_range.end_col ~= nil then
                hl_range.end_col = hl_range.end_col + offset
            end
            if hl_range.display_prefix_len ~= nil then
                hl_range.display_prefix_len = hl_range.display_prefix_len
                    + offset
            end
        end
    end
end

--- @param lines string[]|nil
--- @return integer
function M.count_body_lines(lines)
    if not lines then
        return 0
    end

    return #lines
end

--- @param count integer
--- @param singular string
--- @param plural? string
--- @return string
function M.pluralize(count, singular, plural)
    return string.format(
        "%d %s",
        count,
        count == 1 and singular or (plural or (singular .. "s"))
    )
end

--- @param kind string|nil
--- @return string
function M.get_tool_action_label(kind)
    return TOOL_ACTION_LABELS[kind or ""] or TOOL_ACTION_LABELS.other
end

--- @param kind string|nil
--- @return string
function M.get_output_summary_label(kind)
    return OUTPUT_SUMMARY_LABELS[kind or ""] or OUTPUT_SUMMARY_LABELS.other
end

--- @param status string|nil
--- @return string
function M.get_diff_action_label(status)
    return DIFF_ACTION_LABELS[status or ""] or "Changed"
end

--- @param value string|nil
--- @return string
function M.normalize_tool_token(value)
    local normalized_token = (value or ""):lower():gsub("[%s_%-]", "")
    return normalized_token
end

--- @param kind string|nil
--- @return boolean
function M.is_diff_group_kind(kind)
    return DIFF_TOOL_KINDS[kind or ""] == true
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return boolean
function M.is_diff_group_candidate(tool_call_block)
    return tool_call_block ~= nil
        and M.is_diff_group_kind(tool_call_block.kind)
        and tool_call_block.file_path ~= nil
        and tool_call_block.file_path ~= ""
end

--- @param turn_id integer
--- @param file_path string
--- @return string
function M.build_turn_diff_group_key(turn_id, file_path)
    return string.format("%d::%s", turn_id, file_path)
end

--- @param statuses string[]
--- @return string|nil
function M.aggregate_tool_statuses(statuses)
    local has_in_progress = false
    local has_pending = false
    local has_completed = false

    for _, status in ipairs(statuses) do
        if status == "failed" then
            return "failed"
        end
        if status == "in_progress" then
            has_in_progress = true
        elseif status == "pending" then
            has_pending = true
        elseif status == "completed" then
            has_completed = true
        end
    end

    if has_in_progress then
        return "in_progress"
    end
    if has_pending then
        return "pending"
    end
    if has_completed then
        return "completed"
    end

    return nil
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param title string
--- @return string
function M.normalize_tool_title(tool_call_block, title)
    local head, inner = title:match("^([^%(]+)%((.*)%)$")
    if head and inner then
        local normalized_head = M.normalize_tool_token(head)
        local normalized_kind = M.normalize_tool_token(tool_call_block.kind)
        local normalized_action = M.normalize_tool_token(
            M.get_tool_action_label(tool_call_block.kind)
        )

        if
            normalized_head ~= ""
            and (
                normalized_head == normalized_kind
                or normalized_head == normalized_action
            )
        then
            title = M.sanitize_single_line(inner)
        end
    end

    return title
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string
function M.build_tool_title(tool_call_block)
    local action = M.get_tool_action_label(tool_call_block.kind)
    local title = M.normalize_tool_title(
        tool_call_block,
        M.sanitize_single_line(tool_call_block.argument)
    )

    if tool_call_block.file_path and tool_call_block.file_path ~= "" then
        if tool_call_block.kind == "read" then
            return string.format(
                "%s %s",
                action,
                M.format_compact_path(tool_call_block.file_path)
            )
        end
    end

    if title ~= "" then
        if tool_call_block.kind == "execute" then
            local normalized_title = M.normalize_tool_token(title)
            local normalized_action = M.normalize_tool_token(action)

            if not vim.startswith(normalized_title, normalized_action) then
                return string.format("%s %s", action, title)
            end
        end

        return title
    end

    if tool_call_block.file_path and tool_call_block.file_path ~= "" then
        return string.format(
            "%s %s",
            action,
            M.format_compact_path(tool_call_block.file_path)
        )
    end

    return action
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @param line_count integer
--- @return string
function M.build_output_summary(tool_call_block, line_count)
    if tool_call_block.status == "failed" then
        return M.pluralize(line_count, "error line")
    end

    return M.pluralize(
        line_count,
        M.get_output_summary_label(tool_call_block.kind)
    )
end

--- @param content_node agentic.session.InteractionContentNode
--- @return string
function M.get_request_content_type_label(content_node)
    if content_node.type == "text_content" then
        return "text"
    end

    if content_node.type == "resource_link_content" then
        return "resource_link"
    end

    if content_node.type == "resource_content" then
        return "resource"
    end

    if content_node.type == "image_content" then
        return "image"
    end

    if content_node.type == "audio_content" then
        return "audio"
    end

    return "unknown"
end

return M
