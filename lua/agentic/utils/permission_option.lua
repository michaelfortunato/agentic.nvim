--- Helpers for interpreting ACP permission options across providers.
--- @class agentic.utils.PermissionOption
local M = {}

local PERMISSION_STATES = {
    allow_once = "approved",
    allow_always = "approved",
    reject_once = "rejected",
    reject_always = "rejected",
}

--- @param value string|nil
--- @return string|nil
local function normalize_token(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end

    local normalized = value:lower():gsub("[^%w]+", "_")
    normalized = normalized:gsub("^_+", ""):gsub("_+$", ""):gsub("_+", "_")

    if normalized == "" then
        return nil
    end

    return normalized
end

--- @param option agentic.acp.PermissionOption|nil
--- @return string|nil
function M.get_kind(option)
    if not option then
        return nil
    end

    for _, candidate in pairs({
        option.kind,
        option.optionId,
        option.name,
    }) do
        local normalized = normalize_token(candidate)
        if normalized and PERMISSION_STATES[normalized] ~= nil then
            return normalized
        end
    end

    return normalize_token(option.kind)
end

--- @param options agentic.acp.PermissionOption[]|nil
--- @param preferred_kinds string[]
--- @return string|nil
function M.find_option_id(options, preferred_kinds)
    if not options then
        return nil
    end

    for _, preferred_kind in ipairs(preferred_kinds) do
        local normalized_preferred = normalize_token(preferred_kind)
        for _, option in ipairs(options) do
            if M.get_kind(option) == normalized_preferred then
                return option.optionId
            end
        end
    end

    return nil
end

--- @param option agentic.acp.PermissionOption|nil
--- @return "approved"|"rejected"|"dismissed"
function M.get_state(option)
    local kind = M.get_kind(option)
    return PERMISSION_STATES[kind] or "dismissed"
end

--- @param options agentic.acp.PermissionOption[]|nil
--- @param option_id string|nil
--- @return "approved"|"rejected"|"dismissed"
function M.get_state_for_option_id(options, option_id)
    if option_id == nil then
        return "dismissed"
    end

    for _, option in ipairs(options or {}) do
        if option.optionId == option_id then
            return M.get_state(option)
        end
    end

    local normalized_id = normalize_token(option_id)
    return PERMISSION_STATES[normalized_id] or "dismissed"
end

return M
