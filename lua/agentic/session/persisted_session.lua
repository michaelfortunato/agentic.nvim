local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.session.PersistedSession.SessionMeta
--- @field session_id string
--- @field title string
--- @field timestamp integer
--- @field current_mode_id? string|nil

--- @class agentic.session.PersistedSession.StorageData : agentic.session.PersistedSession.SessionMeta
--- @field config_options agentic.acp.ConfigOption[]
--- @field available_commands agentic.acp.AvailableCommand[]
--- @field turns agentic.session.InteractionTurn[]

--- @class agentic.session.PersistedSession
--- @field session_id? string
--- @field timestamp integer Unix timestamp when session was created
--- @field title string
--- @field current_mode_id? string|nil
--- @field config_options agentic.acp.ConfigOption[]
--- @field available_commands agentic.acp.AvailableCommand[]
--- @field turns agentic.session.InteractionTurn[]
local PersistedSession = {}
PersistedSession.__index = PersistedSession

--- @return agentic.session.PersistedSession
function PersistedSession:new()
    --- @type agentic.session.PersistedSession
    local instance = {
        session_id = nil,
        timestamp = os.time(),
        title = "",
        current_mode_id = nil,
        config_options = {},
        available_commands = {},
        turns = {},
    }

    setmetatable(instance, self)
    return instance
end

--- Generate the project folder name from CWD
--- Normalizes path by replacing slashes, spaces, and colons with underscores
--- Appends first 8 chars of SHA256 hash for collision resistance
function PersistedSession.get_project_folder()
    local cwd = vim.uv.cwd() or ""

    local normalized = cwd:gsub("[/\\%s:]", "_"):gsub("^_+", "")
    local hash = vim.fn.sha256(cwd):sub(1, 8)

    return normalized .. "_" .. hash
end

--- Get the folder path for storing sessions for the current project
--- @return string folder_path
function PersistedSession.get_sessions_folder()
    local base = Config.session_restore.storage_path
        or vim.fs.joinpath(vim.fn.stdpath("cache"), "agentic", "sessions")
    local project_folder = PersistedSession.get_project_folder()
    return vim.fs.joinpath(base, project_folder)
end

--- Generate the full file path for this session's JSON file
--- @param session_id string
--- @return string file_path
function PersistedSession.get_file_path(session_id)
    return vim.fs.joinpath(
        PersistedSession.get_sessions_folder(),
        session_id .. ".json"
    )
end

--- Prepend restored session turns to prompt in ACP Content format
--- @param turns agentic.session.InteractionTurn[]
--- @param prompt agentic.acp.Content[] The prompt array to prepend to
function PersistedSession.prepend_restored_turns(turns, prompt)
    for _, turn in ipairs(turns or {}) do
        if turn.request and turn.request.text and turn.request.text ~= "" then
            table.insert(prompt, {
                type = "text",
                text = "User: " .. turn.request.text,
            })
        end

        for _, node in ipairs(turn.response and turn.response.nodes or {}) do
            if node.type == "message" then
                table.insert(prompt, {
                    type = "text",
                    text = "Assistant: " .. (node.text or ""),
                })
            elseif node.type == "thought" then
                table.insert(prompt, {
                    type = "text",
                    text = "Assistant (thinking): " .. (node.text or ""),
                })
            elseif
                node.type == "plan"
                and node.entries
                and #node.entries > 0
            then
                local plan_lines = { "Plan:" }
                for _, entry in ipairs(node.entries) do
                    local status = entry.status or "pending"
                    plan_lines[#plan_lines + 1] =
                        string.format("- [%s] %s", status, entry.content or "")
                end
                table.insert(prompt, {
                    type = "text",
                    text = table.concat(plan_lines, "\n"),
                })
            elseif
                node.type == "tool_call"
                and node.title
                and node.title ~= ""
            then
                local tool_text = string.format(
                    "Tool call (%s): %s",
                    node.kind or "unknown",
                    node.title
                )
                local body_lines = {}
                for _, content_node in ipairs(node.content_nodes or {}) do
                    if
                        content_node.type == "content_output"
                        and content_node.content_node
                        and content_node.content_node.type == "text_content"
                        and content_node.content_node.text
                    then
                        vim.list_extend(
                            body_lines,
                            vim.split(
                                content_node.content_node.text,
                                "\n",
                                { plain = true }
                            )
                        )
                    end
                end
                if #body_lines > 0 then
                    tool_text = tool_text
                        .. "\nResult:\n"
                        .. table.concat(body_lines, "\n")
                end
                table.insert(prompt, { type = "text", text = tool_text })
            end
        end
    end
end

--- @param callback fun(err: string|nil)|nil
function PersistedSession:save(callback)
    if not self.session_id then
        Logger.notify("PersistedSession:save() skipped: no session_id")
        if callback then
            callback("No session_id set")
        end
        return
    end

    local path = PersistedSession.get_file_path(self.session_id)
    local dir = vim.fn.fnamemodify(path, ":h")

    local dir_ok, dir_err = FileSystem.mkdirp(dir)
    if not dir_ok then
        Logger.debug("Failed to create directory:", dir, dir_err)
        if callback then
            callback(
                "Failed to create directory: " .. (dir_err or "unknown error")
            )
        end
        return
    end

    --- @type agentic.session.PersistedSession.StorageData
    local data = {
        session_id = self.session_id,
        title = self.title,
        timestamp = self.timestamp,
        current_mode_id = self.current_mode_id,
        config_options = self.config_options,
        available_commands = self.available_commands,
        turns = self.turns,
    }

    local encode_ok, json = pcall(vim.json.encode, data)
    if not encode_ok then
        Logger.debug("JSON encoding failed:", json)
        if callback then
            callback("JSON encoding error")
        end
        return
    end

    FileSystem.write_file(path, json, function(write_err)
        if callback then
            vim.schedule(function()
                callback(write_err)
            end)
        end
    end)
end

--- @param data agentic.session.PersistedSession.StorageData
--- @param callback fun(err: string|nil)|nil
function PersistedSession.save_data(data, callback)
    local instance = PersistedSession:new()
    instance.session_id = data.session_id
    instance.title = data.title or ""
    instance.timestamp = data.timestamp or instance.timestamp
    instance.current_mode_id = data.current_mode_id
    instance.config_options = vim.deepcopy(data.config_options or {})
    instance.available_commands = vim.deepcopy(data.available_commands or {})
    instance.turns = vim.deepcopy(data.turns or {})
    instance:save(callback)
end

--- @param session_id string
--- @param callback fun(session_data: agentic.session.PersistedSession|nil, err: string|nil)
function PersistedSession.load(session_id, callback)
    local path = PersistedSession.get_file_path(session_id)

    FileSystem.read_file(path, nil, nil, function(content)
        if not content then
            vim.schedule(function()
                callback(nil, "Failed to read file")
            end)
            return
        end

        local ok, parsed = pcall(vim.json.decode, content)
        if not ok then
            Logger.debug("JSON decode failed:", parsed)
            vim.schedule(function()
                callback(nil, "JSON decode error")
            end)
            return
        end

        --- @cast parsed agentic.session.PersistedSession.StorageData

        local instance = PersistedSession:new()
        instance.session_id = parsed.session_id
        instance.timestamp = parsed.timestamp
        instance.title = parsed.title
        instance.current_mode_id = parsed.current_mode_id
        instance.config_options = vim.deepcopy(parsed.config_options or {})
        instance.available_commands =
            vim.deepcopy(parsed.available_commands or {})
        instance.turns = vim.deepcopy(parsed.turns or {})
        vim.schedule(function()
            callback(instance, nil)
        end)
    end)
end

--- List all sessions for the current project, sorted by timestamp descending
--- @param callback fun(sessions: agentic.session.PersistedSession.SessionMeta[])
function PersistedSession.list_sessions(callback)
    local folder = PersistedSession.get_sessions_folder()
    local sessions = {}

    if vim.fn.isdirectory(folder) == 0 then
        Logger.debug("Session folder does not exist:", folder)
        callback(sessions)
        return
    end

    for filename, file_type in vim.fs.dir(folder) do
        if file_type == "file" and filename:match("%.json$") then
            local file_path = vim.fs.joinpath(folder, filename)
            local content = vim.fn.readfile(file_path)
            if #content > 0 then
                local ok, parsed =
                    pcall(vim.json.decode, table.concat(content, "\n"))
                if ok and parsed then
                    table.insert(sessions, {
                        session_id = filename:gsub("%.json$", ""),
                        title = parsed.title or "",
                        timestamp = parsed.timestamp or 0,
                    })
                else
                    Logger.debug(
                        "Failed to parse session file:",
                        file_path,
                        parsed
                    )
                end
            end
        end
    end

    table.sort(sessions, function(a, b)
        return a.timestamp > b.timestamp
    end)

    callback(sessions)
end

return PersistedSession
