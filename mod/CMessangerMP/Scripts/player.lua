-- Locates the local player (BP_Human_C) and reads its world transform.

local log = require("log")
local M = {}

-- Cache the pawn so we don't burn CPU on FindFirstOf every tick.
-- We re-validate via :IsValid() on each access.
local cached = nil

local function lookup_pawn()
    -- BP_Human_C is the gameplay class used by the level instance
    -- /Game/Maps/Main_Level.Main_Level:PersistentLevel.BP_Human_C_0
    local p = FindFirstOf("BP_Human_C")
    if p and p.IsValid and p:IsValid() then return p end
    return nil
end

function M.get_local_player()
    if cached and cached.IsValid and cached:IsValid() then return cached end
    cached = lookup_pawn()
    if cached then log.debug("Local player resolved: %s", cached:GetFullName()) end
    return cached
end

-- Returns { x, y, z, yaw, pitch } or nil if no pawn yet (e.g. main menu).
function M.get_state()
    local p = M.get_local_player()
    if not p then return nil end
    local ok_loc, loc = pcall(function() return p:K2_GetActorLocation() end)
    local ok_rot, rot = pcall(function() return p:K2_GetActorRotation() end)
    if not (ok_loc and ok_rot and loc and rot) then return nil end
    return {
        x = loc.X,
        y = loc.Y,
        z = loc.Z,
        yaw = rot.Yaw,
        pitch = rot.Pitch,
    }
end

function M.invalidate()
    cached = nil
end

return M
