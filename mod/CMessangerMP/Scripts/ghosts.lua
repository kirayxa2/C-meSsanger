-- Ghost manager: spawns BP_HumanReplicated_C for each remote player and
-- moves it to match their position from the server snapshot.
--
-- This file is wrapped in defensive pcall layers because UE4SS APIs vary
-- between versions and we want a single failure to be loud once, not
-- spam the console every tick.

local log         = require("log")
local player_mod  = require("player")

-- UEHelpers is part of UE4SS but it's a Lua module, not a global, so it
-- must be require()'d. We also try a couple of alternative paths and
-- fall back to the global if the user's install exposes it that way.
local UEHelpers
do
    for _, name in ipairs({ "UEHelpers", "UEHelpers/UEHelpers" }) do
        local ok, mod = pcall(require, name)
        if ok and mod then UEHelpers = mod; break end
    end
    if not UEHelpers then UEHelpers = rawget(_G, "UEHelpers") end
end

local M = {}

-- Class found in the UHT dump:
-- /Game/Multiplayer/BP_HumanReplicated.BP_HumanReplicated_C
local GHOST_CLASS_PATH = "/Game/Multiplayer/BP_HumanReplicated.BP_HumanReplicated_C"

-- ghosts[playerId] = { actor = AActor }
local ghosts        = {}
-- Players whose first spawn attempt threw. We don't retry them every
-- tick (the error would be the same), only on F7 / lobby rejoin.
local spawn_failed  = {}
local cached_class  = nil

local function is_valid(obj)
    if obj == nil then return false end
    if obj.IsValid == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function get_class()
    if is_valid(cached_class) then return cached_class end
    local ok, c = pcall(StaticFindObject, GHOST_CLASS_PATH)
    if ok and is_valid(c) then
        cached_class = c
        log.debug("Ghost class resolved: %s", GHOST_CLASS_PATH)
        return c
    end
    return nil
end

-- Three fallback strategies for getting a UWorld pointer.
-- Picking the right one depends on the UE4SS version the player has.
local function get_world()
    -- 1. The local player has a GetWorld() method - we already have it
    --    cached and validated, so this is the safest path.
    local p = player_mod.get_local_player()
    if p and p.GetWorld then
        local ok, w = pcall(function() return p:GetWorld() end)
        if ok and is_valid(w) then return w end
    end
    -- 2. UEHelpers (if the require() above succeeded)
    if UEHelpers and UEHelpers.GetWorld then
        local ok, w = pcall(UEHelpers.GetWorld)
        if ok and is_valid(w) then return w end
    end
    -- 3. Brute-force scan of all UObjects for any UWorld instance.
    local ok, w = pcall(FindFirstOf, "World")
    if ok and is_valid(w) then return w end
    return nil
end

-- Returns AActor or (nil, err_string). Never throws - all paths are
-- pcall-wrapped, so the caller can handle errors without nuking the
-- whole tick handler.
local function try_spawn(state)
    local ok, result, err = pcall(function()
        local world = get_world()
        if not world then return nil, "no world (am I in a level?)" end

        local class = get_class()
        if not class then return nil, "class missing: " .. GHOST_CLASS_PATH end

        local loc = { X = state.x,            Y = state.y,         Z = state.z }
        local rot = { Pitch = state.pitch or 0, Yaw = state.yaw or 0, Roll = 0 }

        -- Strategy 1: simple world:SpawnActor(class, loc, rot)
        local ok1, a1 = pcall(function() return world:SpawnActor(class, loc, rot) end)
        if ok1 and is_valid(a1) then return a1 end

        -- Strategy 2: GameplayStatics' deferred-spawn dance
        local ok_gs, gs = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
        if ok_gs and is_valid(gs) then
            local transform = {
                Translation = loc,
                Rotation    = { X = 0, Y = 0, Z = 0, W = 1 },
                Scale3D     = { X = 1, Y = 1, Z = 1 },
            }
            local ok2, a2 = pcall(function()
                local a = gs:BeginDeferredActorSpawnFromClass(world, class, transform, 0, nil)
                if is_valid(a) then
                    gs:FinishSpawningActor(a, transform)
                    return a
                end
                return nil
            end)
            if ok2 and is_valid(a2) then return a2 end
        end

        return nil, ("all spawn strategies failed (world ok, class ok, but SpawnActor returned invalid)")
    end)
    if not ok then return nil, "exception: " .. tostring(result) end
    return result, err
end

local function move_ghost(actor, state)
    pcall(function()
        local loc = { X = state.x,            Y = state.y,         Z = state.z }
        local rot = { Pitch = state.pitch or 0, Yaw = state.yaw or 0, Roll = 0 }
        actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
    end)
end

-- Apply a server snapshot. `players` is an array of:
--   { id, name, isHost, state = { x, y, z, yaw, pitch } | nil }
function M.update_from_snapshot(players)
    local seen = {}
    for _, p in ipairs(players or {}) do
        seen[p.id] = true
        if p.state then
            local g = ghosts[p.id]
            if g and is_valid(g.actor) then
                move_ghost(g.actor, p.state)
            elseif not spawn_failed[p.id] then
                local actor, err = try_spawn(p.state)
                if actor then
                    log.info("Spawned ghost for %s (%s) at %.0f,%.0f,%.0f",
                        p.name or "?", p.id, p.state.x, p.state.y, p.state.z)
                    ghosts[p.id] = { actor = actor }
                else
                    spawn_failed[p.id] = true
                    log.error("Spawn failed for %s: %s", p.name or "?", tostring(err))
                    log.info("[GHOST_DATA] %s @ %.0f,%.0f,%.0f yaw=%.0f (no actor; data still flowing)",
                        p.name or "?", p.state.x, p.state.y, p.state.z, p.state.yaw or 0)
                end
            else
                log.debug("[GHOST_DATA] %s @ %.0f,%.0f,%.0f yaw=%.0f",
                    p.name or "?", p.state.x, p.state.y, p.state.z, p.state.yaw or 0)
            end
        end
    end
    -- Despawn ghosts for players who left the lobby
    for id, g in pairs(ghosts) do
        if not seen[id] then
            if is_valid(g.actor) then
                pcall(function() g.actor:K2_DestroyActor() end)
            end
            ghosts[id]       = nil
            spawn_failed[id] = nil
        end
    end
end

function M.cleanup()
    for _, g in pairs(ghosts) do
        if is_valid(g.actor) then
            pcall(function() g.actor:K2_DestroyActor() end)
        end
    end
    ghosts        = {}
    spawn_failed  = {}
end

function M.count()
    local n = 0
    for _ in pairs(ghosts) do n = n + 1 end
    return n
end

-- Re-arm spawn attempts (used by F7 force-rejoin in main.lua)
function M.reset_failures()
    spawn_failed = {}
end

return M
