-- Ghost manager: spawns BP_HumanReplicated_C for each remote player and
-- moves it to match their position from the server snapshot.
--
-- Spawn API in UE4SS varies by version; we try the simple binding first
-- and fall back to logging-only if it fails so the rest of the mod stays
-- functional and you can see in the console that data IS flowing.

local log = require("log")
local M = {}

-- The "other player" body class found in the dump:
-- /Game/Multiplayer/BP_HumanReplicated.BP_HumanReplicated_C
local GHOST_CLASS_PATH = "/Game/Multiplayer/BP_HumanReplicated.BP_HumanReplicated_C"

-- ghosts[playerId] = { actor = AActor, lastSeen = ms }
local ghosts = {}
-- Players for whom we already tried to spawn and failed; don't spam attempts.
local spawn_failed = {}
local cached_class = nil

local function get_class()
    if cached_class and cached_class.IsValid and cached_class:IsValid() then
        return cached_class
    end
    local c = StaticFindObject(GHOST_CLASS_PATH)
    if c and c.IsValid and c:IsValid() then
        cached_class = c
        log.debug("Resolved ghost class: %s", GHOST_CLASS_PATH)
        return c
    end
    return nil
end

-- Returns AActor or nil + err string
local function try_spawn(state)
    local world = UEHelpers.GetWorld()
    if not world or not world.IsValid or not world:IsValid() then
        return nil, "no world"
    end
    local class = get_class()
    if not class then
        return nil, "ghost class not found at " .. GHOST_CLASS_PATH
    end

    local loc = { X = state.x, Y = state.y, Z = state.z }
    local rot = { Pitch = state.pitch or 0, Yaw = state.yaw or 0, Roll = 0 }

    -- Attempt 1: world:SpawnActor(class, loc, rot) - works in many UE4SS versions
    local ok, actor = pcall(function() return world:SpawnActor(class, loc, rot) end)
    if ok and actor and actor.IsValid and actor:IsValid() then return actor end

    -- Attempt 2: GameplayStatics::BeginDeferredActorSpawnFromClass + FinishSpawningActor
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if gs and gs.IsValid and gs:IsValid() then
        local transform = {
            Translation = loc,
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Scale3D = { X = 1, Y = 1, Z = 1 },
        }
        local ok2, actor2 = pcall(function()
            local a = gs:BeginDeferredActorSpawnFromClass(world, class, transform, 0, nil)
            if a and a.IsValid and a:IsValid() then
                gs:FinishSpawningActor(a, transform)
                return a
            end
            return nil
        end)
        if ok2 and actor2 and actor2.IsValid and actor2:IsValid() then return actor2 end
    end

    return nil, "all spawn methods failed"
end

local function move_ghost(actor, state)
    local loc = { X = state.x, Y = state.y, Z = state.z }
    local rot = { Pitch = state.pitch or 0, Yaw = state.yaw or 0, Roll = 0 }
    pcall(function()
        actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
    end)
end

-- Apply a snapshot from the server. `players` is an array of:
--   { id, name, isHost, state = {x,y,z,yaw,pitch} | nil }
function M.update_from_snapshot(players)
    local seen = {}
    players = players or {}
    for _, p in ipairs(players) do
        seen[p.id] = true
        if p.state then
            local g = ghosts[p.id]
            if g and g.actor and g.actor.IsValid and g.actor:IsValid() then
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
    -- Despawn ghosts for players no longer in the lobby
    for id, g in pairs(ghosts) do
        if not seen[id] then
            if g.actor and g.actor.IsValid and g.actor:IsValid() then
                pcall(function() g.actor:K2_DestroyActor() end)
            end
            ghosts[id] = nil
            spawn_failed[id] = nil
        end
    end
end

function M.cleanup()
    for id, g in pairs(ghosts) do
        if g.actor and g.actor.IsValid and g.actor:IsValid() then
            pcall(function() g.actor:K2_DestroyActor() end)
        end
    end
    ghosts = {}
    spawn_failed = {}
end

function M.count()
    local n = 0
    for _ in pairs(ghosts) do n = n + 1 end
    return n
end

return M
