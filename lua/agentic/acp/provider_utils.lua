--- @class agentic.acp.ProviderUtils
local ProviderUtils = {}

--- @param text string|nil
--- @return string
local function normalize_label(text)
    return vim.trim((text or ""):lower())
end

--- @param provider_config agentic.acp.ACPProviderConfig|nil
--- @return boolean
function ProviderUtils.is_codex_provider(provider_config)
    if not provider_config then
        return false
    end

    local command = provider_config.command
    local command_name = type(command) == "string" and vim.fs.basename(command)
        or ""
    if normalize_label(command_name) == "codex-acp" then
        return true
    end

    local provider_name = normalize_label(provider_config.name)
    return provider_name == "codex acp" or provider_name == "codex"
end

return ProviderUtils
