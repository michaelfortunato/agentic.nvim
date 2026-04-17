local Common = require("agentic.ui.message_writer.common")
local DiffPreview = require("agentic.ui.diff_preview")
local Theme = require("agentic.theme")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- @class agentic.ui.MessageWriterCardRenderer
local M = {}

local MAX_DIFF_CARD_HUNKS = 2
local MAX_DIFF_CARD_CHANGES = 4

local function append_comment_line(lines, highlight_ranges, text, hl_group)
    table.insert(lines, text)
    highlight_ranges[#highlight_ranges + 1] = {
        type = "comment",
        line_index = #lines - 1,
        hl_group = hl_group,
    }
end

local function append_highlighted_line(lines, highlight_ranges, text, hl_group)
    table.insert(lines, text)
    highlight_ranges[#highlight_ranges + 1] = {
        type = "span",
        line_index = #lines - 1,
        start_col = 0,
        end_col = #text,
        hl_group = hl_group,
    }
end

local function append_spanned_line(lines, highlight_ranges, spans)
    local line_index = #lines
    local line = {}
    local start_col = 0

    for _, span in ipairs(spans) do
        local text = span[1] or ""
        local hl_group = span[2]
        line[#line + 1] = text

        if hl_group and text ~= "" then
            highlight_ranges[#highlight_ranges + 1] = {
                type = "span",
                line_index = line_index,
                start_col = start_col,
                end_col = start_col + #text,
                hl_group = hl_group,
            }
        end

        start_col = start_col + #text
    end

    table.insert(lines, table.concat(line))
end

local function count_body_lines(lines)
    return Common.count_body_lines(lines)
end

local function build_tool_semantic_content_nodes(tool_call_block)
    return tool_call_block.content_nodes or {}
end

local function count_tool_output_lines(tool_call_block)
    local line_count = 0
    local buffered_text = nil

    local function flush_text_count()
        line_count = line_count + #Common.split_content_lines(buffered_text)
        buffered_text = nil
    end

    for _, content_node in
        ipairs(build_tool_semantic_content_nodes(tool_call_block))
    do
        if
            content_node.type == "content_output"
            and content_node.content_node
        then
            if content_node.content_node.type == "text_content" then
                buffered_text = (buffered_text or "")
                    .. (content_node.content_node.text or "")
            else
                flush_text_count()
                line_count = line_count
                    + Common.count_content_lines(content_node.content_node)
            end
        else
            flush_text_count()
        end
    end

    flush_text_count()

    if line_count > 0 then
        return line_count
    end

    return count_body_lines(tool_call_block.body)
end

local function build_tool_semantic_summaries(tool_call_block)
    local summaries = {}
    local resource_links = 0
    local resources = 0
    local images = 0
    local audio = 0
    local terminals = 0

    for _, content_node in
        ipairs(build_tool_semantic_content_nodes(tool_call_block))
    do
        if
            content_node.type == "content_output" and content_node.content_node
        then
            local semantic = content_node.content_node
            if semantic.type == "resource_link_content" then
                resource_links = resource_links + 1
            elseif semantic.type == "resource_content" then
                resources = resources + 1
            elseif semantic.type == "image_content" then
                images = images + 1
            elseif semantic.type == "audio_content" then
                audio = audio + 1
            end
        elseif content_node.type == "terminal_output" then
            terminals = terminals + 1
        end
    end

    local line_count = count_tool_output_lines(tool_call_block)
    if line_count > 0 then
        if tool_call_block.kind == "read" then
            summaries[#summaries + 1] = string.format(
                "%s loaded into context",
                Common.pluralize(line_count, "line")
            )
        else
            summaries[#summaries + 1] =
                Common.build_output_summary(tool_call_block, line_count)
        end
    end
    if resource_links > 0 then
        summaries[#summaries + 1] =
            Common.pluralize(resource_links, "linked resource")
    end
    if resources > 0 then
        summaries[#summaries + 1] =
            Common.pluralize(resources, "embedded resource")
    end
    if images > 0 then
        summaries[#summaries + 1] = Common.pluralize(images, "image")
    end
    if audio > 0 then
        summaries[#summaries + 1] =
            Common.pluralize(audio, "audio clip", "audio clips")
    end
    if terminals > 0 then
        summaries[#summaries + 1] = Common.pluralize(terminals, "terminal")
    end

    return summaries
end

local function append_semantic_tool_content_node(
    lines,
    highlight_ranges,
    level,
    content_node
)
    if content_node.type == "text_content" then
        for _, line in ipairs(Common.split_content_lines(content_node.text)) do
            append_highlighted_line(
                lines,
                highlight_ranges,
                Common.indent_text(line, level),
                Theme.HL_GROUPS.CARD_BODY
            )
        end
    elseif content_node.type == "resource_link_content" then
        append_spanned_line(lines, highlight_ranges, {
            { Common.indent_prefix(level), nil },
            {
                "@" .. Common.get_content_display_name(content_node),
                Theme.HL_GROUPS.RESOURCE_LINK,
            },
        })
        if content_node.description and content_node.description ~= "" then
            append_highlighted_line(
                lines,
                highlight_ranges,
                Common.indent_text(
                    Common.sanitize_single_line(content_node.description),
                    level
                ),
                Theme.HL_GROUPS.CARD_DETAIL
            )
        end
    elseif content_node.type == "resource_content" then
        append_spanned_line(lines, highlight_ranges, {
            { Common.indent_prefix(level), nil },
            {
                "@" .. Common.get_content_display_name(content_node),
                Theme.HL_GROUPS.RESOURCE_LINK,
            },
        })
        local detail = "embedded context"
        local line_count = Common.count_content_lines(content_node)
        if line_count > 0 then
            detail = detail .. " · " .. Common.pluralize(line_count, "line")
        elseif content_node.blob then
            detail = detail .. " · binary data"
        end
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. Common.sanitize_single_line(content_node.mime_type)
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(detail, level),
            Theme.HL_GROUPS.CARD_DETAIL
        )
        if content_node.text and content_node.text ~= "" then
            for _, line in ipairs(Common.split_content_lines(content_node.text)) do
                append_highlighted_line(
                    lines,
                    highlight_ranges,
                    Common.indent_text(line, level + 1),
                    Theme.HL_GROUPS.CARD_BODY
                )
            end
        end
    elseif content_node.type == "image_content" then
        local label = "image"
        if content_node.mime_type and content_node.mime_type ~= "" then
            label = label
                .. " · "
                .. Common.sanitize_single_line(content_node.mime_type)
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(label, level),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    elseif content_node.type == "audio_content" then
        local label = "audio"
        if content_node.mime_type and content_node.mime_type ~= "" then
            label = label
                .. " · "
                .. Common.sanitize_single_line(content_node.mime_type)
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(label, level),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    elseif content_node.type == "unknown_content" then
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                "content · "
                    .. Common.sanitize_single_line(
                        content_node.content.type or "unknown"
                    ),
                level
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end
end

local function append_tool_semantic_details(
    lines,
    highlight_ranges,
    tool_call_block
)
    local rendered_semantic_content = false
    local buffered_text = nil

    for _, content_node in
        ipairs(build_tool_semantic_content_nodes(tool_call_block))
    do
        if
            content_node.type == "content_output"
            and content_node.content_node
            and content_node.content_node.type == "text_content"
        then
            buffered_text = (buffered_text or "")
                .. (content_node.content_node.text or "")
        elseif
            content_node.type == "content_output" and content_node.content_node
        then
            if buffered_text ~= nil then
                rendered_semantic_content = true
                for _, line in ipairs(Common.split_content_lines(buffered_text)) do
                    append_highlighted_line(
                        lines,
                        highlight_ranges,
                        Common.indent_text(line, Common.HIERARCHY_LEVEL.detail),
                        Theme.HL_GROUPS.CARD_BODY
                    )
                end
                buffered_text = nil
            end
            rendered_semantic_content = true
            append_semantic_tool_content_node(
                lines,
                highlight_ranges,
                Common.HIERARCHY_LEVEL.detail,
                content_node.content_node
            )
        elseif content_node.type == "terminal_output" then
            if buffered_text ~= nil then
                rendered_semantic_content = true
                for _, line in ipairs(Common.split_content_lines(buffered_text)) do
                    append_highlighted_line(
                        lines,
                        highlight_ranges,
                        Common.indent_text(line, Common.HIERARCHY_LEVEL.detail),
                        Theme.HL_GROUPS.CARD_BODY
                    )
                end
                buffered_text = nil
            end
            rendered_semantic_content = true
            append_highlighted_line(
                lines,
                highlight_ranges,
                Common.indent_text(
                    "terminal attached · "
                        .. Common.sanitize_single_line(content_node.terminal_id),
                    Common.HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.CARD_DETAIL
            )
        end
    end

    if buffered_text ~= nil then
        rendered_semantic_content = true
        for _, line in ipairs(Common.split_content_lines(buffered_text)) do
            append_highlighted_line(
                lines,
                highlight_ranges,
                Common.indent_text(line, Common.HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.CARD_BODY
            )
        end
    end

    if rendered_semantic_content or not tool_call_block.body then
        return
    end

    for _, line in ipairs(tool_call_block.body) do
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(line, Common.HIERARCHY_LEVEL.detail),
            Theme.HL_GROUPS.CARD_BODY
        )
    end
end

local function should_default_collapse(tool_call_block)
    if tool_call_block.diff then
        return true
    end

    if #build_tool_semantic_content_nodes(tool_call_block) > 0 then
        return true
    end

    return count_body_lines(tool_call_block.body) > 0
end

local function append_tool_header(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    local is_collapsible = tool_call_block.collapsed ~= nil
    local prefix = is_collapsible
            and (tool_call_block.collapsed and "▸ " or "▾ ")
        or ""
    local title = Common.truncate_single_line(
        Common.build_tool_title(tool_call_block),
        Common.get_available_line_width(
            render_width,
            Common.HIERARCHY_LEVEL.detail,
            prefix
        )
    )

    append_spanned_line(lines, highlight_ranges, {
        { prefix, "Comment" },
        { title, Theme.HL_GROUPS.CARD_TITLE },
    })
end

local function append_read_card(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    append_tool_header(lines, highlight_ranges, tool_call_block, render_width)

    local summaries = build_tool_semantic_summaries(tool_call_block)
    if #summaries == 0 then
        return
    end

    for _, summary in ipairs(summaries) do
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                Common.truncate_single_line(
                    summary,
                    Common.get_available_line_width(
                        render_width,
                        Common.HIERARCHY_LEVEL.nested
                    )
                ),
                Common.HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end

    if tool_call_block.collapsed == false then
        append_tool_semantic_details(lines, highlight_ranges, tool_call_block)
        append_spanned_line(lines, highlight_ranges, {
            { Common.indent_prefix(Common.HIERARCHY_LEVEL.detail), nil },
            { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
        })
        return
    end

    if tool_call_block.collapsed ~= nil then
        append_spanned_line(lines, highlight_ranges, {
            {
                Common.indent_text(
                    "Details hidden · ",
                    Common.HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
        })
    end
end

local function append_result_card(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    append_tool_header(lines, highlight_ranges, tool_call_block, render_width)

    local summaries = build_tool_semantic_summaries(tool_call_block)
    if #summaries == 0 then
        return
    end

    for _, summary in ipairs(summaries) do
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                Common.truncate_single_line(
                    summary,
                    Common.get_available_line_width(
                        render_width,
                        Common.HIERARCHY_LEVEL.nested
                    )
                ),
                Common.HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end

    if tool_call_block.collapsed == false then
        append_tool_semantic_details(lines, highlight_ranges, tool_call_block)
        append_spanned_line(lines, highlight_ranges, {
            { Common.indent_prefix(Common.HIERARCHY_LEVEL.detail), nil },
            { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
        })
        return
    end

    if tool_call_block.collapsed ~= nil then
        append_spanned_line(lines, highlight_ranges, {
            {
                Common.indent_text(
                    "Details hidden · ",
                    Common.HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
        })
    end
end

local function build_diff_block_label(diff_block)
    if #diff_block.old_lines == 0 then
        return string.format("@@ insert near line %d @@", diff_block.start_line)
    end

    if diff_block.start_line == diff_block.end_line then
        return string.format("@@ line %d @@", diff_block.start_line)
    end

    return string.format(
        "@@ lines %d-%d @@",
        diff_block.start_line,
        diff_block.end_line
    )
end

local function append_diff_line(
    lines,
    highlight_ranges,
    line_type,
    line_text,
    old_line,
    new_line,
    prefix
)
    local display_line = prefix .. line_text
    table.insert(lines, display_line)

    highlight_ranges[#highlight_ranges + 1] = {
        line_index = #lines - 1,
        type = line_type,
        old_line = old_line,
        new_line = new_line,
        display_prefix_len = #prefix,
    }
end

local function should_render_status_line(status)
    return status == "failed"
end

local function build_diff_summary_line(stats)
    local parts = { Common.pluralize(stats.hunk_count, "hunk") }

    if stats.modifications > 0 then
        parts[#parts + 1] =
            Common.pluralize(stats.modifications, "modified line")
    end
    if stats.additions > 0 then
        parts[#parts + 1] = Common.pluralize(stats.additions, "added line")
    end
    if stats.deletions > 0 then
        parts[#parts + 1] = Common.pluralize(stats.deletions, "deleted line")
    end

    return table.concat(parts, " · ")
end

local function build_diff_totals(stats)
    local additions = stats.additions + stats.modifications
    local deletions = stats.deletions + stats.modifications
    return additions, deletions
end

local function summarize_diff_blocks(diff_blocks)
    local stats = {
        edit_count = 1,
        hunk_count = #diff_blocks,
        modifications = 0,
        additions = 0,
        deletions = 0,
    }

    local samples = {}
    local sampled_changes = 0

    for _, block in ipairs(diff_blocks) do
        local filtered = ToolCallDiff.filter_unchanged_lines(
            block.old_lines,
            block.new_lines
        )

        for _, pair in ipairs(filtered.pairs) do
            if pair.old_line and pair.new_line then
                stats.modifications = stats.modifications + 1
            elseif pair.old_line then
                stats.deletions = stats.deletions + 1
            elseif pair.new_line then
                stats.additions = stats.additions + 1
            end
        end

        if
            #filtered.pairs > 0
            and #samples < MAX_DIFF_CARD_HUNKS
            and sampled_changes < MAX_DIFF_CARD_CHANGES
        then
            local sample_pairs = {}

            for _, pair in ipairs(filtered.pairs) do
                if sampled_changes >= MAX_DIFF_CARD_CHANGES then
                    break
                end

                sample_pairs[#sample_pairs + 1] = pair
                sampled_changes = sampled_changes + 1
            end

            if #sample_pairs > 0 then
                samples[#samples + 1] = {
                    label = build_diff_block_label(block),
                    pairs = sample_pairs,
                }
            end
        end
    end

    return stats, samples, sampled_changes
end

local function summarize_diff_tracker(tool_call_block)
    if
        not tool_call_block._diff_sources
        or not tool_call_block._diff_source_order
    then
        return summarize_diff_blocks(ToolCallDiff.extract_diff_blocks({
            path = tool_call_block.file_path or "",
            old_text = tool_call_block.diff.old,
            new_text = tool_call_block.diff.new,
            replace_all = tool_call_block.diff.all,
        }))
    end

    local stats = {
        edit_count = 0,
        hunk_count = 0,
        modifications = 0,
        additions = 0,
        deletions = 0,
    }
    local samples = {}
    local sampled_changes = 0

    for _, source_id in ipairs(tool_call_block._diff_source_order) do
        local source = tool_call_block._diff_sources[source_id]
        if source and source.diff then
            local source_blocks = ToolCallDiff.extract_diff_blocks({
                path = source.file_path or tool_call_block.file_path or "",
                old_text = source.diff.old,
                new_text = source.diff.new,
                replace_all = source.diff.all,
            })
            local source_stats, source_samples, source_sampled_changes =
                summarize_diff_blocks(source_blocks)

            if source_stats.hunk_count > 0 then
                stats.edit_count = stats.edit_count + 1
            end
            stats.hunk_count = stats.hunk_count + source_stats.hunk_count
            stats.modifications = stats.modifications
                + source_stats.modifications
            stats.additions = stats.additions + source_stats.additions
            stats.deletions = stats.deletions + source_stats.deletions

            for _, sample in ipairs(source_samples) do
                samples[#samples + 1] = sample
            end
            sampled_changes = sampled_changes + source_sampled_changes
        end
    end

    return stats, samples, sampled_changes
end

local function append_diff_card_sample(lines, highlight_ranges, sample)
    append_comment_line(
        lines,
        highlight_ranges,
        Common.indent_text(sample.label, Common.HIERARCHY_LEVEL.detail),
        Theme.HL_GROUPS.CARD_DETAIL
    )

    for _, pair in ipairs(sample.pairs) do
        if pair.old_line and pair.new_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "old",
                pair.old_line,
                pair.old_line,
                pair.new_line,
                Common.indent_prefix(Common.HIERARCHY_LEVEL.nested) .. "- "
            )
            append_diff_line(
                lines,
                highlight_ranges,
                "new_modification",
                pair.new_line,
                pair.old_line,
                pair.new_line,
                Common.indent_prefix(Common.HIERARCHY_LEVEL.nested) .. "+ "
            )
        elseif pair.old_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "old",
                pair.old_line,
                pair.old_line,
                nil,
                Common.indent_prefix(Common.HIERARCHY_LEVEL.nested) .. "- "
            )
        elseif pair.new_line then
            append_diff_line(
                lines,
                highlight_ranges,
                "new",
                pair.new_line,
                nil,
                pair.new_line,
                Common.indent_prefix(Common.HIERARCHY_LEVEL.nested) .. "+ "
            )
        end
    end
end

local function append_diff_card(
    lines,
    highlight_ranges,
    tool_call_block,
    render_width
)
    local diff_path = tool_call_block.file_path or ""
    local stats, samples, sampled_changes
    if tool_call_block.diff or tool_call_block._diff_sources then
        stats, samples, sampled_changes =
            summarize_diff_tracker(tool_call_block)
    else
        stats = {
            edit_count = 1,
            hunk_count = 0,
            modifications = 0,
            additions = 0,
            deletions = 0,
        }
        samples = {}
        sampled_changes = 0
    end
    local additions, deletions = build_diff_totals(stats)
    local is_collapsed = tool_call_block.collapsed ~= false
    local prefix = is_collapsed and "▸ " or "▾ "
    local action_text = Common.get_diff_action_label(tool_call_block.kind)
        .. " "
    local additions_text = string.format("+%d", additions)
    local deletions_text = string.format("-%d", deletions)
    local path_text = Common.truncate_single_line(
        diff_path ~= "" and Common.format_compact_path(diff_path) or "untitled",
        Common.get_available_line_width(
            render_width,
            Common.HIERARCHY_LEVEL.detail,
            prefix
                .. action_text
                .. " "
                .. additions_text
                .. " "
                .. deletions_text
        )
    )

    append_spanned_line(lines, highlight_ranges, {
        { prefix, "Comment" },
        { action_text, "Comment" },
        { path_text, "Directory" },
        { " ", "Comment" },
        { additions_text, Theme.HL_GROUPS.DIFF_ADD },
        { " ", "Comment" },
        { deletions_text, Theme.HL_GROUPS.DIFF_DELETE },
    })

    local summary = build_diff_summary_line(stats)
    if stats.edit_count > 1 then
        summary = string.format(
            "%s · %s",
            Common.pluralize(stats.edit_count, "edit"),
            summary
        )
    end
    append_highlighted_line(
        lines,
        highlight_ranges,
        Common.indent_text(summary, Common.HIERARCHY_LEVEL.detail),
        Theme.HL_GROUPS.CARD_DETAIL
    )

    local hint_lines = {}
    local hint_line_index =
        DiffPreview.add_navigation_hint(tool_call_block, hint_lines)
    if hint_line_index ~= nil then
        local hint = hint_lines[hint_line_index + 1]
        if is_collapsed then
            append_spanned_line(lines, highlight_ranges, {
                {
                    Common.indent_text(
                        hint .. " · ",
                        Common.HIERARCHY_LEVEL.detail
                    ),
                    Theme.HL_GROUPS.FOLD_HINT,
                },
                { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
            })
        else
            append_spanned_line(lines, highlight_ranges, {
                {
                    Common.indent_text(
                        hint .. " · ",
                        Common.HIERARCHY_LEVEL.detail
                    ),
                    Theme.HL_GROUPS.FOLD_HINT,
                },
                { "<CR> collapse", Theme.HL_GROUPS.FOLD_HINT },
            })
        end
    elseif is_collapsed then
        append_spanned_line(lines, highlight_ranges, {
            {
                Common.indent_text(
                    "Details hidden · ",
                    Common.HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
        })
    else
        append_spanned_line(lines, highlight_ranges, {
            {
                Common.indent_text(
                    "Inline details expanded · ",
                    Common.HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> collapse", Theme.HL_GROUPS.FOLD_HINT },
        })
    end

    if is_collapsed then
        return
    end

    if #samples == 0 then
        append_comment_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                tool_call_block.status == "pending"
                        and "Preparing change preview"
                    or "No diff details available",
                Common.HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
        return
    end

    for _, sample in ipairs(samples) do
        append_diff_card_sample(lines, highlight_ranges, sample)
    end

    local total_changes = stats.modifications
        + stats.additions
        + stats.deletions
    if total_changes > sampled_changes then
        append_comment_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                string.format(
                    "... %s in buffer review",
                    Common.pluralize(
                        total_changes - sampled_changes,
                        "more change"
                    )
                ),
                Common.HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end
end

local function append_request_field_line(
    lines,
    highlight_ranges,
    label,
    value,
    level
)
    append_spanned_line(lines, highlight_ranges, {
        {
            Common.indent_text(label .. ": ", level),
            Theme.HL_GROUPS.CARD_DETAIL,
        },
        { value, Theme.HL_GROUPS.CARD_BODY },
    })
end

local function build_request_content_summaries(content_node)
    if content_node.type == "text_content" then
        local root_tag = content_node.xml_root_tag
        local line_count = Common.count_content_lines(content_node)
        if root_tag then
            return {
                string.format(
                    "structured text · %s · %s",
                    root_tag,
                    Common.pluralize(line_count, "line")
                ),
            }
        end

        local preview = Common.truncate_single_line(content_node.text, 72)
        if preview ~= "" and line_count > 1 then
            preview = preview .. " · " .. Common.pluralize(line_count, "line")
        elseif preview == "" then
            preview = Common.pluralize(line_count, "line")
        end

        return { preview }
    end

    if content_node.type == "resource_link_content" then
        return { Common.get_content_display_name(content_node) }
    end

    if content_node.type == "resource_content" then
        local detail = Common.get_content_display_name(content_node)
        local line_count = Common.count_content_lines(content_node)
        if line_count > 0 then
            detail = detail .. " · " .. Common.pluralize(line_count, "line")
        elseif content_node.blob then
            detail = detail .. " · binary data"
        end
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. Common.sanitize_single_line(content_node.mime_type)
        end

        return { detail }
    end

    if content_node.type == "image_content" then
        local detail = "image"
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. Common.sanitize_single_line(content_node.mime_type)
        end
        if content_node.uri and content_node.uri ~= "" then
            detail = detail
                .. " · "
                .. Common.format_content_uri(content_node.uri)
        end
        return { detail }
    end

    if content_node.type == "audio_content" then
        local detail = "audio"
        if content_node.mime_type and content_node.mime_type ~= "" then
            detail = detail
                .. " · "
                .. Common.sanitize_single_line(content_node.mime_type)
        end
        return { detail }
    end

    return {
        "content · " .. Common.sanitize_single_line(
            content_node.content.type or "unknown"
        ),
    }
end

local function append_request_content_details(
    lines,
    highlight_ranges,
    content_node
)
    if content_node.type == "text_content" then
        for _, line in ipairs(Common.split_content_lines(content_node.text)) do
            append_highlighted_line(
                lines,
                highlight_ranges,
                Common.indent_text(line, Common.HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.CARD_BODY
            )
        end
        return
    end

    if content_node.type == "resource_link_content" then
        append_request_field_line(
            lines,
            highlight_ranges,
            "uri",
            Common.sanitize_single_line(content_node.uri),
            Common.HIERARCHY_LEVEL.detail
        )
        append_request_field_line(
            lines,
            highlight_ranges,
            "name",
            Common.sanitize_single_line(content_node.name),
            Common.HIERARCHY_LEVEL.detail
        )
        if content_node.title and content_node.title ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "title",
                Common.sanitize_single_line(content_node.title),
                Common.HIERARCHY_LEVEL.detail
            )
        end
        if content_node.description and content_node.description ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "description",
                Common.sanitize_single_line(content_node.description),
                Common.HIERARCHY_LEVEL.detail
            )
        end
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                Common.sanitize_single_line(content_node.mime_type),
                Common.HIERARCHY_LEVEL.detail
            )
        end
        return
    end

    if content_node.type == "resource_content" then
        append_request_field_line(
            lines,
            highlight_ranges,
            "uri",
            Common.sanitize_single_line(content_node.uri),
            Common.HIERARCHY_LEVEL.detail
        )
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                Common.sanitize_single_line(content_node.mime_type),
                Common.HIERARCHY_LEVEL.detail
            )
        end
        if content_node.text and content_node.text ~= "" then
            append_highlighted_line(
                lines,
                highlight_ranges,
                Common.indent_text("text:", Common.HIERARCHY_LEVEL.detail),
                Theme.HL_GROUPS.CARD_DETAIL
            )
            for _, line in ipairs(Common.split_content_lines(content_node.text)) do
                append_highlighted_line(
                    lines,
                    highlight_ranges,
                    Common.indent_text(line, Common.HIERARCHY_LEVEL.nested),
                    Theme.HL_GROUPS.CARD_BODY
                )
            end
        elseif content_node.blob then
            append_highlighted_line(
                lines,
                highlight_ranges,
                Common.indent_text(
                    "blob: binary payload omitted",
                    Common.HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.CARD_DETAIL
            )
        end
        return
    end

    if content_node.type == "image_content" then
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                Common.sanitize_single_line(content_node.mime_type),
                Common.HIERARCHY_LEVEL.detail
            )
        end
        if content_node.uri and content_node.uri ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "uri",
                Common.sanitize_single_line(content_node.uri),
                Common.HIERARCHY_LEVEL.detail
            )
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                "data: binary payload omitted",
                Common.HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
        return
    end

    if content_node.type == "audio_content" then
        if content_node.mime_type and content_node.mime_type ~= "" then
            append_request_field_line(
                lines,
                highlight_ranges,
                "mimeType",
                Common.sanitize_single_line(content_node.mime_type),
                Common.HIERARCHY_LEVEL.detail
            )
        end
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                "data: binary payload omitted",
                Common.HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
        return
    end

    append_highlighted_line(
        lines,
        highlight_ranges,
        Common.indent_text(
            "content type: "
                .. Common.sanitize_single_line(
                    content_node.content.type or "unknown"
                ),
            Common.HIERARCHY_LEVEL.detail
        ),
        Theme.HL_GROUPS.CARD_DETAIL
    )
end

local function append_request_content_card(
    lines,
    highlight_ranges,
    tracker,
    render_width
)
    append_spanned_line(lines, highlight_ranges, {
        { tracker.collapsed and "▸ " or "▾ ", "Comment" },
        {
            Common.get_request_content_type_label(tracker.content_node),
            Theme.HL_GROUPS.CARD_TITLE,
        },
    })

    for _, summary in
        ipairs(build_request_content_summaries(tracker.content_node))
    do
        append_highlighted_line(
            lines,
            highlight_ranges,
            Common.indent_text(
                Common.truncate_single_line(
                    summary,
                    Common.get_available_line_width(
                        render_width,
                        Common.HIERARCHY_LEVEL.nested
                    )
                ),
                Common.HIERARCHY_LEVEL.detail
            ),
            Theme.HL_GROUPS.CARD_DETAIL
        )
    end

    if tracker.collapsed then
        append_spanned_line(lines, highlight_ranges, {
            {
                Common.indent_text(
                    "Details hidden · ",
                    Common.HIERARCHY_LEVEL.detail
                ),
                Theme.HL_GROUPS.FOLD_HINT,
            },
            { "<CR> expand", Theme.HL_GROUPS.FOLD_HINT },
        })
        return
    end

    append_request_content_details(
        lines,
        highlight_ranges,
        tracker.content_node
    )
    append_spanned_line(lines, highlight_ranges, {
        { Common.indent_prefix(Common.HIERARCHY_LEVEL.detail), nil },
        { "<CR> collapse", Theme.HL_GROUPS.CARD_DETAIL },
    })
end

local function append_status_line(lines, highlight_ranges, status)
    append_spanned_line(lines, highlight_ranges, {
        { Common.indent_prefix(Common.HIERARCHY_LEVEL.detail), nil },
        { status:gsub("_", " "), Theme.get_status_hl_group(status) },
    })
end

local function build_request_content_block_id(turn_index, content_index)
    return string.format("request:%d:%d", turn_index, content_index)
end

local function build_request_items(request, turn_index, previous_blocks)
    local items = {}

    for _, request_node in ipairs(request.nodes or {}) do
        if request_node.type == "request_text" then
            items[#items + 1] = {
                type = "lines",
                lines = Common.split_content_lines(request_node.text),
            }
        else
            local block_id = build_request_content_block_id(
                turn_index,
                request_node.content_index
            )
            local previous = previous_blocks[block_id]

            local tracker = {
                block_id = block_id,
                content_node = vim.deepcopy(request_node.content_node),
                collapsed = previous and previous.collapsed or true,
            }

            if previous and previous.collapsed == false then
                tracker.collapsed = false
            end

            items[#items + 1] = {
                type = "request_content",
                tracker = tracker,
            }
        end
    end

    if #items == 0 and request.text ~= "" then
        items[#items + 1] = {
            type = "lines",
            lines = vim.split(request.text, "\n", { plain = true }),
        }
    end

    return items
end

function M.should_default_collapse(tool_call_block)
    return should_default_collapse(tool_call_block)
end

function M.get_active_diff_group_id(writer, tool_call_block)
    if not Common.is_diff_group_candidate(tool_call_block) then
        return nil
    end

    local group_key = Common.build_turn_diff_group_key(
        writer._current_turn_id,
        tool_call_block.file_path
    )
    return writer._active_turn_diff_cards[group_key]
end

function M.merge_diff_source(writer, tracker, tool_call_block)
    tracker.turn_id = tracker.turn_id or writer._current_turn_id
    tracker.group_key = tracker.group_key
        or Common.build_turn_diff_group_key(tracker.turn_id, tracker.file_path)
    tracker._diff_sources = tracker._diff_sources or {}
    tracker._diff_source_order = tracker._diff_source_order or {}

    local source_id = tool_call_block.tool_call_id
    local source = tracker._diff_sources[source_id]
    if not source then
        source = { tool_call_id = source_id }
        tracker._diff_sources[source_id] = source
        tracker._diff_source_order[#tracker._diff_source_order + 1] = source_id
    end

    local merged = vim.tbl_deep_extend("force", source, tool_call_block)
    merged.group_key = nil
    merged._diff_sources = nil
    merged._diff_source_order = nil
    tracker._diff_sources[source_id] = merged
    writer.tool_call_blocks[source_id] = tracker

    local statuses = {}
    for _, ordered_id in ipairs(tracker._diff_source_order) do
        local current = tracker._diff_sources[ordered_id]
        if current and current.status then
            statuses[#statuses + 1] = current.status
        end
    end

    tracker.file_path = tool_call_block.file_path or tracker.file_path
    tracker.kind = tool_call_block.kind or tracker.kind
    tracker.argument = tool_call_block.argument or tracker.argument
    tracker.status = Common.aggregate_tool_statuses(statuses)
        or tool_call_block.status
end

function M.initialize_diff_group(writer, tool_call_block)
    tool_call_block.turn_id = writer._current_turn_id
    tool_call_block.group_key = Common.build_turn_diff_group_key(
        writer._current_turn_id,
        tool_call_block.file_path
    )
    tool_call_block._diff_sources = {}
    tool_call_block._diff_source_order = {}

    writer._active_turn_diff_cards[tool_call_block.group_key] =
        tool_call_block.tool_call_id
    M.merge_diff_source(writer, tool_call_block, tool_call_block)

    return tool_call_block
end

function M.build_tool_call_block_from_node(_writer, node, previous_blocks)
    local block = {
        tool_call_id = node.tool_call_id or tostring(vim.loop.hrtime()),
        kind = node.kind,
        argument = node.title,
        status = node.status,
        file_path = node.file_path,
        terminal_id = node.terminal_id,
        body = {},
        diff = nil,
        content_nodes = vim.deepcopy(node.content_nodes or {}),
        collapsed = nil,
    }

    local function append_body_lines(lines)
        if not lines or #lines == 0 then
            return
        end

        if #block.body > 0 then
            vim.list_extend(block.body, { "", "---", "" })
        end

        for _, line in ipairs(lines) do
            block.body[#block.body + 1] = line
        end
    end

    local buffered_body_text = nil

    local function flush_body_text()
        if buffered_body_text == nil then
            return
        end

        append_body_lines(Common.split_content_lines(buffered_body_text))
        buffered_body_text = nil
    end

    for _, content_node in ipairs(node.content_nodes or {}) do
        if
            content_node.type == "content_output"
            and content_node.content_node
            and content_node.content_node.type == "text_content"
        then
            buffered_body_text = (buffered_body_text or "")
                .. (content_node.content_node.text or "")
        elseif
            content_node.type == "diff_output"
            and content_node.old_lines
            and content_node.new_lines
        then
            flush_body_text()
            block.diff = {
                old = vim.deepcopy(content_node.old_lines),
                new = vim.deepcopy(content_node.new_lines),
            }
            block.file_path = content_node.file_path or block.file_path
        elseif content_node.type == "terminal_output" then
            flush_body_text()
            block.terminal_id = content_node.terminal_id
        end
    end

    flush_body_text()

    if #block.body == 0 then
        block.body = nil
    end

    local previous = previous_blocks[node.tool_call_id or ""]
    if previous and previous.collapsed ~= nil then
        block.collapsed = previous.collapsed
    end

    return block
end

function M.register_interaction_tool_block(
    writer,
    tool_call_block,
    previous_blocks,
    ordered_items
)
    local existing_group_id =
        M.get_active_diff_group_id(writer, tool_call_block)
    if
        existing_group_id
        and existing_group_id ~= tool_call_block.tool_call_id
    then
        local tracker = writer.tool_call_blocks[existing_group_id]
        if tracker then
            M.merge_diff_source(writer, tracker, tool_call_block)
        end
        return
    end

    if Common.is_diff_group_candidate(tool_call_block) then
        tool_call_block = M.initialize_diff_group(writer, tool_call_block)
    end

    local previous = previous_blocks[tool_call_block.tool_call_id]
    if previous and previous.collapsed ~= nil then
        tool_call_block.collapsed = previous.collapsed
    end

    if
        should_default_collapse(tool_call_block)
        and tool_call_block.collapsed == nil
    then
        tool_call_block.collapsed = true
    end

    writer.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block
    ordered_items[#ordered_items + 1] = {
        type = "tool_call",
        tracker = tool_call_block,
    }
end

function M.prepare_block_lines(_writer, tool_call_block, render_width)
    local lines = {}
    local highlight_ranges = {}

    if tool_call_block.kind == "read" then
        append_read_card(lines, highlight_ranges, tool_call_block, render_width)
    elseif tool_call_block.diff then
        append_diff_card(lines, highlight_ranges, tool_call_block, render_width)
    else
        append_result_card(
            lines,
            highlight_ranges,
            tool_call_block,
            render_width
        )
    end

    if should_render_status_line(tool_call_block.status) then
        append_status_line(lines, highlight_ranges, tool_call_block.status)
    end

    table.insert(lines, "")
    Common.offset_highlight_ranges(
        highlight_ranges,
        lines,
        Common.HIERARCHY_LEVEL.detail
    )
    lines = Common.apply_block_hierarchy(lines, Common.HIERARCHY_LEVEL.detail)
    return lines, highlight_ranges
end

function M.prepare_request_content_block_lines(_writer, tracker, render_width)
    local lines = {}
    local highlight_ranges = {}

    append_request_content_card(lines, highlight_ranges, tracker, render_width)
    table.insert(lines, "")

    Common.offset_highlight_ranges(
        highlight_ranges,
        lines,
        Common.HIERARCHY_LEVEL.detail
    )
    lines = Common.apply_block_hierarchy(lines, Common.HIERARCHY_LEVEL.detail)

    return lines, highlight_ranges
end

function M.build_request_items(_writer, request, turn_index, previous_blocks)
    return build_request_items(request, turn_index, previous_blocks)
end

return M
