-- Persistent settings store. Saves the last lobby code and player name
-- to a JSON file next to the mod so the user doesn't need to retype after
-- restarting the game. Uses our own JSON codec from http.lua.

local http = require("http")
local M = {}

-- Path is relative to the game's working directory (Binaries/Win64/)
local PATH = "Mods/CMessangerMP/settings.json"

function M.load()
    local f = io.open(PATH, "rb")
    if not f then return {} end
    local data = f:read("*a") or ""
    f:close()
    if data == "" then return {} end
    local ok, parsed = pcall(http.json_decode, data)
    if ok and type(parsed) == "table" then return parsed end
    return {}
end

function M.save(t)
    local f, ferr = io.open(PATH, "wb")
    if not f then return false, ferr end
    f:write(http.json_encode(t or {}))
    f:close()
    return true
end

return M
