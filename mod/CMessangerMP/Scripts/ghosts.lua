-- Ghost manager.
--
-- UE4SS issue #527: UWorld:SpawnActor() and BeginDeferredActorSpawnFromClass
-- both go through the ProcessEvent hook and crash the game after a few
-- spawns (or even on the first one for some classes). Stable UE4SS has no
-- fix as of 2025; PR #864 is about scale, not the crash.
--
-- Workaround used here: invoke the native UE console command "summon"
-- via APlayerController::ConsoleCommand. ConsoleCommand is a UFUNCTION
-- exposed through Lua, but its native implementation routes the command
-- through UEngine::Exec / UWorld::Exec which calls SpawnActor directly
-- in C++ - bypassing UE4SS's ProcessEvent hook and therefore the crash.
-- Once the actor is in the world we just teleport it every tick with
-- K2_SetActorLocationAndRotation, which is a normal UFUNCTION call we
-- already know works.

local log         = require("log")
local player_mod  = require("player")

local M = {}

-- Class found in the UHT dump:
-- /Game/Multiplayer/BP_HumanReplicated.BP_HumanReplicated_C
local GHOST_CLASS_PATH = "/Game/Multiplayer/BP_HumanReplicated.BP_HumanReplicated_C"
local GHOST_CLASS_NAME = "BP_HumanReplicated_C"

-- ghosts[playerId] = { actor, summoned_at_ms }
local ghosts        = {}
-- Players for whom we already issued a summon and didn't get an actor.
-- We don't retry every tick so we don't spam summons.
local summon_failed = {}

-- Toggle: if anything still crashes, set this to false and you'll only
-- get [GHOST_DATA] logs without any in-world body.
local SUMMON_ENABLED = true

local function is_valid(obj)
    if obj == nil then return false end
    if obj.IsValid == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- Get the local PlayerController, which owns ConsoleCommand.
local function get_pc()
    local p = player_mod.get_local_player()
    if p and p.GetController then
        local ok, c = pcall(function() return p:GetController() end)
        if ok and is_valid(c) then return c end
    end
    -- Fallbacks
    for _, name in ipairs({ "PlayerController", "BP_PlayerController_C" }) do
        local ok, pc = pcall(FindFirstOf, name)
        if ok and is_valid(pc) then
            local fname = ""
            pcall(function() fname = pc:GetFullName() end)
            if not fname:find("Default__") then return pc end
        end
    end
    return nil
end

-- Snapshot the set of currently-existing BP_HumanReplicated_C instances
-- so we can detect the one that gets created by our summon command.
local function snapshot_existing()
    local set = {}
    pcall(function()
        local all = FindAllOf(GHOST_CLASS_NAME)
        if all then
            for _, a in ipairs(all) do
                if is_valid(a) then
                    local n
                    pcall(function() n = a:GetFullName() end)
                    if n then set[n] = true end
                end
            end
        end
    end)
    return set
end

-- Try to find a freshly-summoned BP_HumanReplicated_C that wasn't in the
-- snapshot we took before the summon command.
local function find_new_after(snapshot)
    local found = nil
    pcall(function()
        local all = FindAllOf(GHOST_CLASS_NAME)
        if not all then return end
        for _, a in ipairs(all) do
            if is_valid(a) then
                local n = ""
                pcall(function() n = a:GetFullName() end)
                if n ~= "" and not n:find("Default__") and not snapshot[n] then
                    found = a
                    return
                end
            end
        end
    end)
    return found
end

-- Issue the native UE "summon" command. This is the core trick that
-- avoids the ProcessEvent crash documented in UE4SS issue #527.
local function summon_ghost(player_name)
    local pc = get_pc()
    if not pc then return nil, "no PlayerController (am I in a level?)" end
    if not pc.ConsoleCommand then return nil, "PlayerController.ConsoleCommand not available" end

    local before = snapshot_existing()
    local cmd = "summon " .. GHOST_CLASS_PATH

    local ok, err = pcall(function() pc:ConsoleCommand(cmd, false) end)
    if not ok then return nil, "ConsoleCommand threw: " .. tostring(err) end

    -- The actor is created synchronously inside Exec, but its FullName
    -- might race with FindAllOf indexing. Try a couple of times.
    local actor = find_new_after(before)
    if not actor then
        -- One more attempt after a short tick delay -- but we can't
        -- block here, so we just retry a couple of times in a tight
        -- loop. UE4SS FindAllOf rebuilds its cache on demand.
        for _ = 1, 3 do
            actor = find_new_after(before)
            if actor then break end
        end
    end
    if not actor then
        return nil, "summon issued but new actor not found in FindAllOf"
    end
    log.info("Summoned ghost via ConsoleCommand for %s -> %s",
        player_name or "?", actor:GetFullName())
    return actor
end

local function move_ghost(actor, state)
    pcall(function()
        local loc = { X = state.x,            Y = state.y,         Z = state.z }
        local rot = { Pitch = state.pitch or 0, Yaw = state.yaw or 0, Roll = 0 }
        actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
    end)
end

local function destroy_ghost(actor)
    if not is_valid(actor) then return end
    pcall(function() actor:K2_DestroyActor() end)
end

function M.update_from_snapshot(players)
    local seen = {}
    for _, p in ipairs(players or {}) do
        seen[p.id] = true
        if p.state then
            local g = ghosts[p.id]
            if g and is_valid(g.actor) then
                move_ghost(g.actor, p.state)
            elseif SUMMON_ENABLED and not summon_failed[p.id] then
                local actor, err = summon_ghost(p.name)
                if actor then
                    ghosts[p.id] = { actor = actor }
                    -- Teleport immediately so the new actor doesn't sit
                    -- on top of the local player for a frame.
                    move_ghost(actor, p.state)
                else
                    summon_failed[p.id] = true
                    log.error("Summon failed for %s: %s", p.name or "?", tostring(err))
                    log.info("[GHOST_DATA] %s @ %.0f,%.0f,%.0f yaw=%.0f (no actor; data still flowing)",
                        p.name or "?", p.state.x, p.state.y, p.state.z, p.state.yaw or 0)
                end
            else
                log.debug("[GHOST_DATA] %s @ %.0f,%.0f,%.0f yaw=%.0f",
                    p.name or "?", p.state.x, p.state.y, p.state.z, p.state.yaw or 0)
            end
        end
    end
    -- Despawn ghosts for players who left
    for id, g in pairs(ghosts) do
        if not seen[id] then
            destroy_ghost(g.actor)
            ghosts[id]        = nil
            summon_failed[id] = nil
        end
    end
end

function M.cleanup()
    for _, g in pairs(ghosts) do
        destroy_ghost(g.actor)
    end
    ghosts        = {}
    summon_failed = {}
end

function M.count()
    local n = 0
    for _ in pairs(ghosts) do n = n + 1 end
    return n
end

function M.reset_failures()
    summon_failed = {}
end

return M
