-- Persistent settings store. Saves the last lobby code and player name
-- to a JSON file next to the mod so the user doesn't need to retype
-- after restarting the game.
--
-- Also acts as a tiny "external editor" interface: while the game is
-- running, edit Mods/CMessangerMP/settings.json in any text editor and
-- save. The mod polls the file every ~2 seconds (see main.lua) and
-- auto-reconnects to the new lobby. No UE4SS UI required.

local http = require("http")
local M = {}

-- Path is relative to the game's working directory (Binaries/Win64/)
local PATH = "Mods/CMessangerMP/settings.json"

-- Last content we read or wrote, so poll_disk() can ignore self-writes.
local _last_str = nil

function M.load()
    local f = io.open(PATH, "rb")
    if not f then return {} end
    local data = f:read("*a") or ""
    f:close()
    _last_str = data
    if data == "" then return {} end
    local ok, parsed = pcall(http.json_decode, data)
    if ok and type(parsed) == "table" then return parsed end
    return {}
end

function M.save(t)
    local encoded = http.json_encode(t or {})
    local f, ferr = io.open(PATH, "wb")
    if not f then return false, ferr end
    f:write(encoded)
    f:close()
    _last_str = encoded
    return true
end

-- Returns (changed_bool, parsed_table_or_nil).
-- True only when the on-disk content differs from what we last wrote
-- or read; calling code can use the parsed value to react to it.
function M.poll_disk()
    local f = io.open(PATH, "rb")
    if not f then return false end
    local data = f:read("*a") or ""
    f:close()
    if data == _last_str then return false end
    _last_str = data
    if data == "" then return true, {} end
    local ok, parsed = pcall(http.json_decode, data)
    if ok and type(parsed) == "table" then return true, parsed end
    -- corrupt JSON - silently ignore until the next save fixes it
    return false
end

return M
