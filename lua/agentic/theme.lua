local FileSystem = require("agentic.utils.file_system")

--- @alias agentic.Theme.SpinnerState "generating" | "thinking" | "searching" | "busy" | "waiting"

--- @class agentic.Theme
local Theme = {}

Theme.HL_GROUPS = {
    DIFF_DELETE = "AgenticDiffDelete",
    DIFF_ADD = "AgenticDiffAdd",
    DIFF_DELETE_WORD = "AgenticDiffDeleteWord",
    DIFF_ADD_WORD = "AgenticDiffAddWord",
    STATUS_PENDING = "AgenticStatusPending",
    STATUS_COMPLETED = "AgenticStatusCompleted",
    STATUS_FAILED = "AgenticStatusFailed",
    CODE_BLOCK_FENCE = "AgenticCodeBlockFence",
    WIN_BAR_TITLE = "AgenticTitle",
    WIN_BAR_CONTEXT = "AgenticTitleContext",
    WIN_BAR_HINT = "AgenticTitleHint",
    WIN_SEPARATOR = "AgenticWinSeparator",
    STATUS_LINE = "AgenticStatusLine",
    REVIEW_BANNER = "AgenticReviewBanner",
    REVIEW_BANNER_ACCENT = "AgenticReviewBannerAccent",
    ACTIVITY_TEXT = "AgenticActivityText",
    TRANSCRIPT_REQUEST_META = "AgenticTranscriptRequestMeta",
    TRANSCRIPT_RESPONSE_META = "AgenticTranscriptResponseMeta",
    TRANSCRIPT_SYSTEM_META = "AgenticTranscriptSystemMeta",
    CHUNK_BOUNDARY = "AgenticChunkBoundary",
    THOUGHT_TEXT = "AgenticThoughtText",
    RESOURCE_LINK = "AgenticResourceLink",
    FOLD_HINT = "AgenticFoldHint",
    CARD_TITLE = "AgenticCardTitle",
    CARD_BODY = "AgenticCardBody",
    CARD_DETAIL = "AgenticCardDetail",
    INLINE_FADE = "AgenticInlineFade",

    SPINNER_GENERATING = "AgenticSpinnerGenerating",
    SPINNER_THINKING = "AgenticSpinnerThinking",
    SPINNER_SEARCHING = "AgenticSpinnerSearching",
    SPINNER_BUSY = "AgenticSpinnerBusy",
    SPINNER_WAITING = "AgenticSpinnerWaiting",
}

--- A lang map of extension to language identifier for markdown code fences
--- Keep only possible unknown mappings
local lang_map = {
    py = "python",
    rb = "ruby",
    rs = "rust",
    kt = "kotlin",
    htm = "html",
    yml = "yaml",
    sh = "bash",
    typescriptreact = "tsx",
    javascriptreact = "jsx",
    markdown = "md",
}

local status_hl = {
    pending = Theme.HL_GROUPS.STATUS_PENDING,
    in_progress = Theme.HL_GROUPS.STATUS_PENDING, -- pending and in_progress should look the same, to avoid too many colors, added initially because of Codex, but not limited to it
    completed = Theme.HL_GROUPS.STATUS_COMPLETED,
    failed = Theme.HL_GROUPS.STATUS_FAILED,
}

local spinner_hl = {
    generating = Theme.HL_GROUPS.SPINNER_GENERATING,
    thinking = Theme.HL_GROUPS.SPINNER_THINKING,
    searching = Theme.HL_GROUPS.SPINNER_SEARCHING,
    busy = Theme.HL_GROUPS.SPINNER_BUSY,
    waiting = Theme.HL_GROUPS.SPINNER_WAITING,
}

--- @param group string|nil
--- @return boolean
local function highlight_exists(group)
    if not group or group == "" then
        return false
    end

    if vim.fn.hlexists(group) ~= 1 then
        return false
    end

    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    return ok and vim.tbl_count(hl) > 0
end

--- @param candidates string[]|string
--- @param fallback string|nil
--- @return string|nil
local function resolve_group(candidates, fallback)
    if type(candidates) == "string" then
        candidates = { candidates }
    end

    for _, group in ipairs(candidates or {}) do
        if highlight_exists(group) then
            return group
        end
    end

    if fallback and highlight_exists(fallback) then
        return fallback
    end

    return fallback
end

--- @param candidates string[]|string
--- @param fallback string|nil
--- @return table
local function build_link(candidates, fallback)
    return {
        link = resolve_group(candidates, fallback),
    }
end

--- @param candidates string[]|string
--- @param overrides table|nil
--- @param fallback_link string|nil
--- @return table
local function build_derived_highlight(candidates, overrides, fallback_link)
    local base_group = resolve_group(candidates, fallback_link)
    if not base_group then
        return overrides or {}
    end

    local ok, base = pcall(vim.api.nvim_get_hl, 0, {
        name = base_group,
        link = false,
    })

    if not ok or vim.tbl_count(base) == 0 then
        return build_link(base_group, fallback_link)
    end

    base.link = nil
    return vim.tbl_extend("force", base, overrides or {})
end

function Theme.setup()
    -- stylua: ignore start
    local highlights = {
        -- Diff highlights
        { Theme.HL_GROUPS.DIFF_DELETE, build_link({ "DiffDelete", "Removed" }, "DiffDelete") },
        { Theme.HL_GROUPS.DIFF_ADD, build_link({ "DiffAdd", "Added" }, "DiffAdd") },
        { Theme.HL_GROUPS.DIFF_DELETE_WORD, build_derived_highlight({ "DiffDelete", "DiffText", "Removed", "Comment" }, { underline = true }, "Comment") },
        { Theme.HL_GROUPS.DIFF_ADD_WORD, build_derived_highlight({ "DiffAdd", "DiffText", "Added", "Comment" }, { underline = true }, "Comment") },

        -- Status highlights
        { Theme.HL_GROUPS.STATUS_PENDING, build_link({ "DiagnosticWarn", "Changed", "WarningMsg", "Type" }, "Comment") },
        { Theme.HL_GROUPS.STATUS_COMPLETED, build_link({ "DiagnosticOk", "Added", "DiffAdd", "MoreMsg" }, "Comment") },
        { Theme.HL_GROUPS.STATUS_FAILED, build_link({ "DiagnosticError", "Removed", "DiffDelete", "ErrorMsg" }, "Comment") },
        { Theme.HL_GROUPS.CODE_BLOCK_FENCE, build_link({ "Comment", "Directory" }, "Comment") },

        -- Title highlight
        { Theme.HL_GROUPS.WIN_BAR_TITLE, build_link({ "Title", "Directory" }, "Title") },
        { Theme.HL_GROUPS.WIN_BAR_CONTEXT, build_link("Comment", "Comment") },
        { Theme.HL_GROUPS.WIN_BAR_HINT, build_link("Comment", "Comment") },
        { Theme.HL_GROUPS.WIN_SEPARATOR, build_link({ "WinSeparator", "VertSplit" }, "WinSeparator") },
        { Theme.HL_GROUPS.STATUS_LINE, build_link("StatusLine", "StatusLine") },
        { Theme.HL_GROUPS.REVIEW_BANNER, build_link({ "Comment", "Folded" }, "Comment") },
        { Theme.HL_GROUPS.REVIEW_BANNER_ACCENT, build_link({ "Title", "Directory" }, "Title") },
        { Theme.HL_GROUPS.ACTIVITY_TEXT, build_link({ "Comment", "Folded" }, "Comment") },
        { Theme.HL_GROUPS.TRANSCRIPT_REQUEST_META, build_derived_highlight({ "Comment", "Label" }, { italic = true }, "Comment") },
        { Theme.HL_GROUPS.TRANSCRIPT_RESPONSE_META, build_derived_highlight({ "Comment", "Normal" }, {}, "Comment") },
        { Theme.HL_GROUPS.TRANSCRIPT_SYSTEM_META, build_link({ "Comment", "Folded" }, "Comment") },
        { Theme.HL_GROUPS.CHUNK_BOUNDARY, build_derived_highlight({ "DiagnosticHint", "Special", "Comment" }, { underline = true, nocombine = true }, "Comment") },
        { Theme.HL_GROUPS.THOUGHT_TEXT, build_derived_highlight({ "Comment", "Folded" }, { italic = true }, "Comment") },
        { Theme.HL_GROUPS.RESOURCE_LINK, build_derived_highlight({ "Directory", "Underlined", "Identifier" }, { underline = true }, "Directory") },
        { Theme.HL_GROUPS.FOLD_HINT, build_derived_highlight({ "Comment", "NonText" }, { italic = true }, "Comment") },
        { Theme.HL_GROUPS.CARD_TITLE, build_derived_highlight({ "Normal", "Title" }, { bold = true }, "Normal") },
        { Theme.HL_GROUPS.CARD_BODY, build_link({ "Normal", "NormalFloat" }, "Normal") },
        { Theme.HL_GROUPS.CARD_DETAIL, build_link({ "Comment", "Folded" }, "Comment") },
        { Theme.HL_GROUPS.INLINE_FADE, build_derived_highlight({ "Comment", "Folded", "NonText" }, { blend = 55, italic = true }, "Comment") },

        -- Spinner highlights
        { Theme.HL_GROUPS.SPINNER_GENERATING, build_link({ "DiagnosticInfo", "Identifier", "Function" }, "Comment") },
        { Theme.HL_GROUPS.SPINNER_THINKING, build_link({ "DiagnosticHint", "Type", "Special" }, "Comment") },
        { Theme.HL_GROUPS.SPINNER_SEARCHING, build_link({ "Directory", "Constant", "Statement" }, "Comment") },
        { Theme.HL_GROUPS.SPINNER_BUSY, build_link("Comment", "Comment") },
        { Theme.HL_GROUPS.SPINNER_WAITING, build_link({ "DiagnosticWarn", "Changed", "WarningMsg" }, "Comment") },
    }
    -- stylua: ignore end

    for _, hl in ipairs(highlights) do
        Theme._set_hl(hl[1], hl[2])
    end
end

---Get language identifier from file path for markdown code fences
--- @param file_path string
--- @return string language
function Theme.get_language_from_path(file_path)
    local ext = FileSystem.get_file_extension(file_path)
    if not ext or ext == "" then
        return ""
    end

    return lang_map[ext] or ext
end

--- @param status string
--- @return string hl_group
function Theme.get_status_hl_group(status)
    return status_hl[status] or "Comment"
end

--- @param state agentic.Theme.SpinnerState
--- @return string hl_group
function Theme.get_spinner_hl_group(state)
    return spinner_hl[state] or Theme.HL_GROUPS.SPINNER_GENERATING
end

--- @return string hl_group
function Theme.get_activity_text_hl_group()
    return Theme.HL_GROUPS.ACTIVITY_TEXT
end

--- @private
--- @param group string
--- @param opts table
function Theme._set_hl(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
end

return Theme
