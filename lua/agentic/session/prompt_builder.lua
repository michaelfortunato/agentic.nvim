local ACPPayloads = require("agentic.acp.acp_payloads")
local PersistedSession = require("agentic.session.persisted_session")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")

local PromptBuilder = {}
local ENVIRONMENT_INFO_URI = "agentic://environment_info"

local SELECTION_WARNING = table.concat({
    "IMPORTANT: Focus and respect the line bounds in <line_start>/<line_end> and the optional visual bounds in <col_start>/<col_end> for each <selected_code> tag.",
    "The selection shows ONLY the specified line range, not the entire file!",
    "When <col_start> and <col_end> are present, only that visual sub-range inside the selected lines is the direct inline target.",
    "The file may contain duplicated content of the selected snippet.",
    "When using edit tools, on the referenced files, MAKE SURE your changes target the correct lines by including sufficient surrounding context to make the match unique.",
    "After you make edits to the referenced files, go back and read the file to verify your changes were applied correctly.",
}, "\n")

local INLINE_REQUEST_INSTRUCTIONS = table.concat({
    "You are handling an inline editing request from a visual selection in Neovim.",
    "Keep changes tightly scoped to the selected range unless nearby context must also change to make the edit correct.",
    "When the current approval settings allow edits, prefer using ACP file-edit tools directly.",
    "When edits require review, make the smallest precise edit possible so the diff is easy to inspect and approve.",
    "If the user's inline request is a question or asks for explanation, answer by adding a language-appropriate inline or block comment about the selected region near that region.",
    "Do not answer inline questions as plain chat text unless the selected buffer cannot safely be edited.",
    "If no file change is appropriate and the request is not a question, answer briefly with the result for the selected code.",
}, "\n")

--- @return string
local function build_system_info()
    local os_name = vim.uv.os_uname().sysname
    local os_version = vim.uv.os_uname().release
    local os_machine = vim.uv.os_uname().machine
    local shell = os.getenv("SHELL")
    local neovim_version = tostring(vim.version())
    local today = os.date("%Y-%m-%d")

    local res = string.format(
        [[
- Platform: %s-%s-%s
- Shell: %s
- Editor: Neovim %s
- Current date: %s]],
        os_name,
        os_version,
        os_machine,
        shell,
        neovim_version,
        today
    )

    local project_root = vim.uv.cwd()

    local git_root = vim.fs.root(project_root or 0, ".git")
    if git_root then
        project_root = git_root
        res = res .. "\n- This is a Git repository."

        local branch =
            vim.fn.system("git rev-parse --abbrev-ref HEAD"):gsub("\n", "")
        if vim.v.shell_error == 0 and branch ~= "" then
            res = res .. string.format("\n- Current branch: %s", branch)
        end

        local changed = vim.fn.system("git status --porcelain"):gsub("\n$", "")
        if vim.v.shell_error == 0 and changed ~= "" then
            local files = vim.split(changed, "\n")
            res = res .. "\n- Changed files:"
            for _, file in ipairs(files) do
                res = res .. "\n  - " .. file
            end
        end

        local commits = vim.fn
            .system("git log -3 --oneline --format='%h (%ar) %an: %s'")
            :gsub("\n$", "")
        if vim.v.shell_error == 0 and commits ~= "" then
            local commit_lines = vim.split(commits, "\n")
            res = res .. "\n- Recent commits:"
            for _, commit in ipairs(commit_lines) do
                res = res .. "\n  - " .. commit
            end
        end
    end

    if project_root then
        res = res .. string.format("\n- Project root: %s", project_root)
    end

    return res
end

--- @param prompt agentic.acp.Content[]
--- @param selections agentic.Selection[]|nil
local function append_selections(prompt, selections)
    if not selections or #selections == 0 then
        return
    end

    table.insert(prompt, {
        type = "text",
        text = SELECTION_WARNING,
    })

    for _, selection in ipairs(selections) do
        if selection and #selection.lines > 0 then
            local numbered_lines = {}
            for i, line in ipairs(selection.lines) do
                local line_num = selection.start_line + i - 1
                numbered_lines[#numbered_lines + 1] =
                    string.format("Line %d: %s", line_num, line)
            end

            local selection_lines = {
                "<selected_code>",
                string.format(
                    "<path>%s</path>",
                    FileSystem.to_absolute_path(selection.file_path)
                ),
                string.format(
                    "<line_start>%s</line_start>",
                    selection.start_line
                ),
                string.format("<line_end>%s</line_end>", selection.end_line),
            }

            if selection.start_col ~= nil then
                selection_lines[#selection_lines + 1] = string.format(
                    "<col_start>%s</col_start>",
                    selection.start_col
                )
            end

            if selection.end_col ~= nil then
                selection_lines[#selection_lines + 1] =
                    string.format("<col_end>%s</col_end>", selection.end_col)
            end

            selection_lines[#selection_lines + 1] = "<snippet>"
            selection_lines[#selection_lines + 1] =
                table.concat(numbered_lines, "\n")
            selection_lines[#selection_lines + 1] = "</snippet>"
            selection_lines[#selection_lines + 1] = "</selected_code>"

            table.insert(prompt, {
                type = "text",
                text = table.concat(selection_lines, "\n"),
            })
        end
    end
end

--- @param prompt agentic.acp.Content[]
--- @param code_selection agentic.ui.CodeSelection|nil
local function append_code_selection_context(prompt, code_selection)
    if
        not code_selection
        or not code_selection.is_empty
        or code_selection:is_empty()
    then
        return
    end

    local selections = code_selection:get_selections()
    code_selection:clear()
    append_selections(prompt, selections)
end

--- @param prompt agentic.acp.Content[]
--- @param file_list agentic.ui.FileList|nil
local function append_file_context(prompt, file_list)
    if not file_list or not file_list.is_empty or file_list:is_empty() then
        return
    end

    local files = file_list:get_files()
    file_list:clear()

    for _, file_path in ipairs(files) do
        prompt[#prompt + 1] = ACPPayloads.create_file_content(file_path)
    end
end

--- @param prompt agentic.acp.Content[]
--- @param diagnostics_list agentic.ui.DiagnosticsList|nil
--- @param chat_winid integer|nil
local function append_diagnostics_context(prompt, diagnostics_list, chat_winid)
    if
        not diagnostics_list
        or not diagnostics_list.is_empty
        or diagnostics_list:is_empty()
    then
        return
    end

    local diagnostics = diagnostics_list:get_diagnostics()
    diagnostics_list:clear()

    local WidgetLayout = require("agentic.ui.widget_layout")
    local DiagnosticsContext = require("agentic.ui.diagnostics_context")

    local chat_width = WidgetLayout.calculate_width(Config.windows.width)
    if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
        chat_width = vim.api.nvim_win_get_width(chat_winid)
    end

    local formatted_diagnostics =
        DiagnosticsContext.format_diagnostics(diagnostics, chat_width)

    for _, prompt_entry in ipairs(formatted_diagnostics.prompt_entries) do
        prompt[#prompt + 1] = prompt_entry
    end
end

--- @class agentic.session.PromptBuilder.Submission
--- @field prompt agentic.acp.Content[]
--- @field request {kind: "user"|"review", surface: "chat"|"inline", text: string, timestamp: integer, content: agentic.acp.Content[]}
--- @field consumed_restored_turns boolean
--- @field consumed_first_message boolean

--- @param opts {input_text: string, provider_name: string, restored_turns_to_send?: agentic.session.InteractionTurn[]|nil, include_system_info?: boolean|nil, code_selection?: agentic.ui.CodeSelection|nil, file_list?: agentic.ui.FileList|nil, diagnostics_list?: agentic.ui.DiagnosticsList|nil, chat_winid?: integer|nil, selections?: agentic.Selection[]|nil, inline_instructions?: string|nil, surface?: "chat"|"inline"|nil}
--- @return agentic.session.PromptBuilder.Submission
function PromptBuilder.build_submission(opts)
    local prompt = {}

    if opts.restored_turns_to_send then
        PersistedSession.prepend_restored_turns(
            opts.restored_turns_to_send,
            prompt
        )
    end

    prompt[#prompt + 1] = {
        type = "text",
        text = opts.input_text,
    }

    if opts.inline_instructions and opts.inline_instructions ~= "" then
        prompt[#prompt + 1] = {
            type = "text",
            text = opts.inline_instructions,
        }
    end

    if opts.include_system_info then
        prompt[#prompt + 1] = ACPPayloads.create_text_resource_content(
            ENVIRONMENT_INFO_URI,
            build_system_info(),
            "text/plain"
        )
    end

    if opts.selections and #opts.selections > 0 then
        append_selections(prompt, opts.selections)
    else
        append_code_selection_context(prompt, opts.code_selection)
    end
    append_file_context(prompt, opts.file_list)
    append_diagnostics_context(prompt, opts.diagnostics_list, opts.chat_winid)

    return {
        prompt = prompt,
        request = {
            kind = opts.input_text:match("^/review%s*") and "review" or "user",
            surface = opts.surface or "chat",
            text = opts.input_text,
            timestamp = os.time(),
            content = vim.deepcopy(prompt),
        },
        consumed_restored_turns = opts.restored_turns_to_send ~= nil,
        consumed_first_message = opts.include_system_info == true,
    }
end

--- @return string
function PromptBuilder.build_inline_instructions()
    return INLINE_REQUEST_INSTRUCTIONS
end

return PromptBuilder
