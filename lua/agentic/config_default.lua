--- @alias agentic.UserConfig.ProviderName
--- | "claude-acp"
--- | "claude-agent-acp"
--- | "gemini-acp"
--- | "codex-acp"
--- | "opencode-acp"
--- | "cursor-acp"
--- | "copilot-acp"
--- | "auggie-acp"
--- | "mistral-vibe-acp"
--- | "cline-acp"
--- | "goose-acp"

--- @alias agentic.UserConfig.HeaderRenderFn fun(parts: agentic.ui.ChatWidget.HeaderParts): string|nil

--- User config headers - each panel can have either config parts or a custom render function
--- Customize window headers for each panel in the chat widget.
--- Each header can be either:
--- 1. A table with title and suffix fields
--- 2. A function that receives header parts and returns a custom header string
---
--- The context field is managed internally and shows dynamic info like counts.
---
--- @alias agentic.UserConfig.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts|agentic.UserConfig.HeaderRenderFn|nil>

--- Data passed to the on_prompt_submit hook
--- @class agentic.UserConfig.PromptSubmitData
--- @field prompt string The user's prompt text
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID

--- Data passed to the on_response_complete hook
--- @class agentic.UserConfig.ResponseCompleteData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field success boolean Whether response completed without error
--- @field error? table Error details if failed
---
--- Data passed to the on_session_update hook
--- @class agentic.UserConfig.SessionUpdateData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field update agentic.acp.SessionUpdateMessage ACP session update details.

--- @class agentic.UserConfig.KeymapEntry
--- @field [1] string The key binding
--- @field mode string|string[] The mode(s) for this binding

--- @alias agentic.UserConfig.KeymapValue string | string[] | (string | agentic.UserConfig.KeymapEntry)[]

--- @class agentic.UserConfig.Keymaps
--- @field widget table<string, agentic.UserConfig.KeymapValue>
--- @field prompt table<string, agentic.UserConfig.KeymapValue>
--- @field inline table<string, agentic.UserConfig.KeymapValue>
--- @field diff_preview agentic.UserConfig.DiffPreviewKeymaps

--- @class agentic.UserConfig.DiffPreviewKeymaps
--- @field next_hunk string
--- @field prev_hunk string
--- @field accept string
--- @field reject string
--- @field accept_all string
--- @field reject_all string

--- Window options passed to nvim_set_option_value
--- Overrides default options (wrap, linebreak, winfixbuf, winfixheight)
--- @alias agentic.UserConfig.WinOpts table<string, any>

--- @class agentic.UserConfig.Windows.Chat
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Queue
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Input
--- @field height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Code
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Files
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Diagnostics
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Todos
--- @field display boolean
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @alias agentic.UserConfig.Windows.Position "right"|"left"|"bottom"

--- @class agentic.UserConfig.Windows
--- @field position agentic.UserConfig.Windows.Position
--- @field width string|number
--- @field height string|number
--- @field stack_width_ratio number
--- @field stack_min_width integer
--- @field stack_max_width integer
--- @field chat agentic.UserConfig.Windows.Chat
--- @field queue agentic.UserConfig.Windows.Queue
--- @field input agentic.UserConfig.Windows.Input
--- @field code agentic.UserConfig.Windows.Code
--- @field files agentic.UserConfig.Windows.Files
--- @field diagnostics agentic.UserConfig.Windows.Diagnostics
--- @field todos agentic.UserConfig.Windows.Todos

--- @class agentic.UserConfig.SpinnerChars
--- @field generating string[]
--- @field thinking string[]
--- @field searching string[]
--- @field busy string[]
--- @field waiting string[]

--- Icons used to identify tool call states
--- @class agentic.UserConfig.StatusIcons
--- @field pending string
--- @field in_progress string
--- @field failed string

--- Icons used for diagnostics in the context panel
--- @class agentic.UserConfig.DiagnosticIcons
--- @field error string
--- @field warn string
--- @field info string
--- @field hint string

--- @class agentic.UserConfig.PermissionIcons
--- @field allow_once string
--- @field allow_always string
--- @field reject_once string
--- @field reject_always string

--- @class agentic.UserConfig.FilePicker
--- @field enabled boolean
--- @field hidden boolean Include dotfiles and files inside hidden directories

--- @alias agentic.UserConfig.CompletionAcceptCommand
--- | "accept"
--- | "select_and_accept"

--- @class agentic.UserConfig.Completion
--- @field slash_trigger string Single-character trigger for slash command completions
--- @field file_trigger string Single-character trigger for file mention completions
--- @field accept string|fun(cmp: table): boolean|nil|boolean Blink accept command used by prompt submit keys while the menu is visible. Set false to disable.

--- @class agentic.UserConfig.ImagePaste
--- @field enabled boolean Enable image drag-and-drop to add images to referenced files

--- @class agentic.UserConfig.AutoScroll
--- @field threshold integer Lines from bottom to trigger auto-scroll (default: 10)
--- @field debounce_ms integer Milliseconds to debounce repeated auto-scroll requests (default: 150)

--- Show diff preview for edit tool calls in the buffer
--- @class agentic.UserConfig.DiffPreview
--- @field enabled boolean
--- @field layout "inline" | "interwoven" | "split"
--- @field center_on_navigate_hunks boolean
--- @field split_width_ratio number
--- @field split_min_width integer
--- @field split_max_width integer

--- @class agentic.UserConfig.Hooks
--- @field on_prompt_submit? fun(data: agentic.UserConfig.PromptSubmitData): nil
--- @field on_response_complete? fun(data: agentic.UserConfig.ResponseCompleteData): nil
--- @field on_session_update? fun(data: agentic.UserConfig.SessionUpdateData): nil

--- @class agentic.UserConfig.Inline
--- @field enabled boolean
--- @field prompt_width integer
--- @field prompt_height integer
--- @field show_thoughts boolean
--- @field max_thought_lines integer
--- @field overlay_width integer
--- @field result_ttl_ms integer

--- Control various behaviors and features of the plugin
--- @class agentic.UserConfig.Settings
--- @field move_cursor_to_chat_on_submit boolean Automatically move cursor to chat window after submitting a prompt

--- @class agentic.UserConfig.SessionRestore
--- @field storage_path? string Path to store session data; if nil, default path is used: ~/.cache/nvim/agentic/sessions/

--- All the user config configurable options are optional
--- @class agentic.PartialUserConfig
--- @field debug? boolean Enable printing debug messages which can be read via `:messages`
--- @field provider? agentic.UserConfig.ProviderName
--- @field acp_providers? table<agentic.UserConfig.ProviderName, agentic.acp.ACPProviderConfig|nil>
--- @field windows? agentic.UserConfig.Windows
--- @field keymaps? agentic.UserConfig.Keymaps
--- @field spinner_chars? agentic.UserConfig.SpinnerChars
--- @field status_icons? agentic.UserConfig.StatusIcons
--- @field diagnostic_icons? agentic.UserConfig.DiagnosticIcons
--- @field permission_icons? agentic.UserConfig.PermissionIcons
--- @field file_picker? agentic.UserConfig.FilePicker
--- @field completion? agentic.UserConfig.Completion
--- @field image_paste? agentic.UserConfig.ImagePaste
--- @field auto_scroll? agentic.UserConfig.AutoScroll
--- @field diff_preview? agentic.UserConfig.DiffPreview
--- @field inline? agentic.UserConfig.Inline
--- @field hooks? agentic.UserConfig.Hooks
--- @field headers? agentic.UserConfig.Headers
--- @field settings? agentic.UserConfig.Settings
--- @field session_restore? agentic.UserConfig.SessionRestore

--- @class agentic.UserConfig
--- @field debug boolean Enable printing debug messages which can be read via `:messages`
--- @field provider agentic.UserConfig.ProviderName
--- @field acp_providers table<agentic.UserConfig.ProviderName, agentic.acp.ACPProviderConfig|nil>
--- @field windows agentic.UserConfig.Windows
--- @field keymaps agentic.UserConfig.Keymaps
--- @field spinner_chars agentic.UserConfig.SpinnerChars
--- @field status_icons agentic.UserConfig.StatusIcons
--- @field diagnostic_icons agentic.UserConfig.DiagnosticIcons
--- @field permission_icons agentic.UserConfig.PermissionIcons
--- @field file_picker agentic.UserConfig.FilePicker
--- @field completion agentic.UserConfig.Completion
--- @field image_paste agentic.UserConfig.ImagePaste
--- @field auto_scroll agentic.UserConfig.AutoScroll
--- @field diff_preview agentic.UserConfig.DiffPreview
--- @field inline agentic.UserConfig.Inline
--- @field hooks agentic.UserConfig.Hooks
--- @field headers agentic.UserConfig.Headers
--- @field settings agentic.UserConfig.Settings
--- @field session_restore agentic.UserConfig.SessionRestore
local ConfigDefault = {
    debug = false,

    provider = "claude-agent-acp",

    acp_providers = {
        ["claude-agent-acp"] = {
            name = "Claude Agent ACP",
            command = "claude-agent-acp",
            env = {},
        },

        ["claude-acp"] = {
            name = "Claude ACP",
            command = "claude-code-acp",
            env = {},
        },

        ["gemini-acp"] = {
            name = "Gemini ACP",
            command = "gemini",
            args = { "--acp" },
            env = {},
        },

        ["codex-acp"] = {
            name = "Codex ACP",
            -- https://github.com/zed-industries/codex-acp/releases
            -- xattr -dr com.apple.quarantine ~/.local/bin/codex-acp
            command = "codex-acp",
            default_model = "gpt-5.5",
            args = {
                -- Equivalent to Codex CLI `/fast on`.
                "-c",
                'service_tier="fast"',
                "-c",
                "features.fast_mode=true",
                -- "-c",
                -- "features.web_search_request=true", -- disabled as it doesn't send proper tool call messages
            },
            env = {},
        },

        ["opencode-acp"] = {
            name = "OpenCode ACP",
            command = "opencode",
            args = { "acp" },
            env = {},
        },

        ["cursor-acp"] = {
            name = "Cursor Agent ACP",
            command = "cursor-agent",
            args = {
                "acp",
            },
            env = {},
        },

        ["copilot-acp"] = {
            name = "Copilot ACP",
            command = "copilot",
            args = {
                "--acp",
                "--stdio",
            },
            env = {},
        },

        ["auggie-acp"] = {
            name = "Auggie ACP",
            command = "auggie",
            args = {
                "--acp",
            },
            env = {},
        },

        ["mistral-vibe-acp"] = {
            name = "Mistral Vibe ACP",
            command = "vibe-acp",
            args = {},
            env = {},
        },

        ["cline-acp"] = {
            name = "Cline ACP",
            command = "cline",
            args = { "--acp" },
            env = {},
        },

        ["goose-acp"] = {
            name = "Goose ACP",
            command = "goose",
            args = { "acp" },
            env = {},
        },
    },

    windows = {
        position = "right",
        width = "32%",
        height = "30%",
        stack_width_ratio = 0.28,
        stack_min_width = 32,
        stack_max_width = 68,
        chat = {
            win_opts = {
                breakindent = true,
                breakindentopt = "shift:2",
            },
        },
        queue = {
            max_height = 12,
            win_opts = {
                cursorline = true,
                wrap = false,
                linebreak = false,
            },
        },
        input = { height = 10, win_opts = {} },
        code = { max_height = 15, win_opts = {} },
        files = { max_height = 10, win_opts = {} },
        diagnostics = { max_height = 10, win_opts = {} },
        todos = { display = true, max_height = math.huge, win_opts = {} },
    },

    keymaps = {
        --- Keys bindings for ALL buffers in the widget
        widget = {
            close = "q",
            change_mode = {},
            switch_provider = "<localLeader>s",
            switch_model = {},
            switch_thought_level = {},
            switch_approval_preset = {},
            manage_queue = "<localLeader>q",
        },

        --- Keys bindings for the prompt buffer
        prompt = {
            submit = {
                {
                    "<CR>",
                    mode = { "i", "n" },
                },
                {
                    "<C-s>",
                    mode = { "i", "n", "v" },
                },
            },

            paste_image = {
                {
                    "<C-v>", -- Same as Claude-code in insert mode
                    mode = { "i" },
                },
            },
        },

        inline = {
            open = {
                {
                    "<C-S-k>",
                    mode = { "x" },
                },
            },
        },

        --- Keys bindings for diff preview navigation
        diff_preview = {
            next_hunk = "]c",
            prev_hunk = "[c",
            accept = "m",
            reject = "n",
            accept_all = "M",
            reject_all = "N",
        },
    },

    -- stylua: ignore start
    spinner_chars = {
        generating = { "·", "∙", "•", "∙" },
        thinking = { "·", "∙", "•", "∙" },
        searching = { "·", "∙", "•", "∙" },
        busy = { "·", "∙", "•", "∙" },
        waiting = { "·", "∙", "•", "∙" },
    },
    -- stylua: ignore end

    status_icons = {
        pending = "󰔛",
        in_progress = "󰔛",
        completed = "✔",
        failed = "",
    },

    diagnostic_icons = {
        error = "❌",
        warn = "⚠️",
        info = "ℹ️",
        hint = "✨",
    },

    permission_icons = {
        allow_once = "",
        allow_always = "",
        reject_once = "",
        reject_always = "󰜺",
    },

    file_picker = {
        enabled = true,
        hidden = false,
    },

    completion = {
        slash_trigger = "/",
        file_trigger = "@",
        accept = "select_and_accept",
    },

    image_paste = {
        enabled = true,
    },

    auto_scroll = {
        threshold = 10,
        debounce_ms = 150,
    },

    diff_preview = {
        enabled = true,
        layout = "interwoven",
        center_on_navigate_hunks = true,
        split_width_ratio = 0.36,
        split_min_width = 44,
        split_max_width = 88,
    },

    inline = {
        enabled = true,
        prompt_width = 56,
        prompt_height = 1,
        show_thoughts = true,
        max_thought_lines = 6,
        overlay_width = 80,
        result_ttl_ms = 2500,
    },

    hooks = {
        on_prompt_submit = nil,
        on_response_complete = nil,
        on_session_update = nil,
    },

    headers = {},

    settings = {
        move_cursor_to_chat_on_submit = false,
    },

    session_restore = {
        storage_path = nil,
    },
}

return ConfigDefault
