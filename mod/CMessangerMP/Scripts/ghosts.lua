-- Ghost manager.
--
-- UE4SS issue #527: UWorld:SpawnActor() goes through the ProcessEvent
-- hook and crashes the game. Native UE console "summon" works (UE4SS
-- doesn't intercept the engine-internal Exec path). So we issue summon
-- through one of the two UFUNCTIONs that wrap Exec:
--   1. UKismetSystemLibrary::ExecuteConsoleCommand(world, cmd, pc)
--   2. APlayerController::ConsoleCommand(cmd, bWriteToLog)
-- Then we look up the freshly-spawned actor with FindAllOf and move it
-- with K2_SetActorLocationAndRotation each tick.
--
-- The PlayerController must be obtained as APlayerController, not the
-- generic AController returned by Pawn:GetController(); UE4SS Lua calls
-- the base-class binding and ConsoleCommand throws. We use
-- UGameplayStatics::GetPlayerController(world, 0) which returns a
-- properly-typed APlayerController.

local log         = require("log")
local player_mod  = require("player")

local M = {}

-- Class to summon. summon accepts a short class name; if that fails we
-- fall back to the full path. Both forms are tried for each command path.
local GHOST_CLASS_NAME  = "BP_HumanReplicated_C"
local GHOST_CLASS_PATHS = {
    GHOST_CLASS_NAME,
    "/Game/Multiplayer/BP_HumanReplicated.BP_HumanReplicated_C",
}

-- ghosts[playerId] = { actor = AActor }
local ghosts        = {}
-- summoning[playerId] = snapshot of FullNames before summon was issued.
-- We pick the actor up on the NEXT tick because summon may not be done
-- in the same Lua call.
local summoning     = {}
-- Players for whom every summon strategy already failed; don't retry.
local summon_failed = {}

-- Master kill-switch. If even ExecuteConsoleCommand crashes, edit this
-- to false and reload the game; mod will run without spawning ghosts.
local SUMMON_ENABLED = true

local function is_valid(obj)
    if obj == nil then return false end
    if obj.IsValid == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- World pointer via the local player (we know it's valid since we read
-- transform from it every tick).
local function get_world()
    local p = player_mod.get_local_player()
    if p and p.GetWorld then
        local ok, w = pcall(function() return p:GetWorld() end)
        if ok and is_valid(w) then return w end
    end
    return nil
end

-- Cached UGameplayStatics CDO and UKismetSystemLibrary CDO
local _gs_cdo, _ksl_cdo
local function get_gs_cdo()
    if is_valid(_gs_cdo) then return _gs_cdo end
    local ok, c = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok and is_valid(c) then _gs_cdo = c; return c end
    ok, c = pcall(StaticFindObject, "Default__GameplayStatics")
    if ok and is_valid(c) then _gs_cdo = c; return c end
    return nil
end
local function get_ksl_cdo()
    if is_valid(_ksl_cdo) then return _ksl_cdo end
    local ok, c = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if ok and is_valid(c) then _ksl_cdo = c; return c end
    ok, c = pcall(StaticFindObject, "Default__KismetSystemLibrary")
    if ok and is_valid(c) then _ksl_cdo = c; return c end
    return nil
end

-- Get the local APlayerController. The proper way is GameplayStatics:
-- Pawn:GetController() returns the base AController, whose Lua binding
-- doesn't expose ConsoleCommand correctly.
local function get_pc()
    local world = get_world()
    if world then
        local gs = get_gs_cdo()
        if gs and gs.GetPlayerController then
            local ok, pc = pcall(function() return gs:GetPlayerController(world, 0) end)
            if ok and is_valid(pc) then return pc end
        end
    end
    -- Fallbacks
    local p = player_mod.get_local_player()
    if p and p.GetController then
        local ok, c = pcall(function() return p:GetController() end)
        if ok and is_valid(c) then return c end
    end
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

-- Sometimes pcall returns a non-string error value. Normalise it for
-- the log so we don't print "function: 0x...".
local function fmt_err(e)
    if e == nil then return "nil" end
    local t = type(e)
    if t == "string" then return e end
    if t == "table" or t == "userdata" then
        local ok, s = pcall(function() return tostring(e) end)
        return ("(%s) %s"):format(t, ok and s or "?")
    end
    return ("(%s)"):format(t)
end

-- Try a single command/path combination. Returns true on success.
local function try_command_via_ksl(cmd)
    local ksl = get_ksl_cdo()
    if not ksl or not ksl.ExecuteConsoleCommand then return false, "no KSL.ExecuteConsoleCommand" end
    local world = get_world()
    if not world then return false, "no world" end
    local pc = get_pc()  -- nil is OK, ExecuteConsoleCommand falls back to player 0
    local ok, err = pcall(function()
        ksl:ExecuteConsoleCommand(world, cmd, pc)
    end)
    if not ok then return false, fmt_err(err) end
    return true
end

local function try_command_via_pc(cmd)
    local pc = get_pc()
    if not pc then return false, "no PlayerController" end
    if not pc.ConsoleCommand then return false, "no PC.ConsoleCommand" end
    local ok, err = pcall(function()
        pc:ConsoleCommand(cmd, false)
    end)
    if not ok then return false, fmt_err(err) end
    return true
end

-- Issue every (path) x (command-path) combination, return the first that
-- doesn't throw. We do NOT verify that an actor was spawned here, just
-- that the command didn't crash; pickup happens on the next tick via
-- find_new_after().
local function issue_summon()
    for _, path in ipairs(GHOST_CLASS_PATHS) do
        local cmd = "summon " .. path
        local ok, err = try_command_via_ksl(cmd)
        if ok then return true, "ksl(" .. path .. ")" end
        log.debug("ksl summon failed for %s: %s", path, tostring(err))
        ok, err = try_command_via_pc(cmd)
        if ok then return true, "pc(" .. path .. ")" end
        log.debug("pc summon failed for %s: %s", path, tostring(err))
    end
    return false, "all summon paths failed"
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
            elseif summoning[p.id] then
                -- Look for the actor we asked the engine to summon last tick
                local actor = find_new_after(summoning[p.id])
                if actor then
                    log.info("Picked up summoned ghost for %s -> %s",
                        p.name or "?", actor:GetFullName())
                    ghosts[p.id] = { actor = actor }
                    summoning[p.id] = nil
                    summoning[p.id .. ":age"] = nil
                    move_ghost(actor, p.state)
                else
                    -- Retry the lookup next tick. After ~10 ticks (1s) give up.
                    summoning[p.id .. ":age"] = (summoning[p.id .. ":age"] or 0) + 1
                    if summoning[p.id .. ":age"] > 10 then
                        log.error("Summoned ghost for %s never appeared in FindAllOf", p.name or "?")
                        summon_failed[p.id] = true
                        summoning[p.id] = nil
                        summoning[p.id .. ":age"] = nil
                    end
                end
            elseif SUMMON_ENABLED and not summon_failed[p.id] then
                local before = snapshot_existing()
                local ok, info = issue_summon()
                if ok then
                    log.info("Summon issued for %s via %s, will pick up next tick", p.name or "?", info)
                    summoning[p.id] = before
                else
                    summon_failed[p.id] = true
                    log.error("Summon failed for %s: %s", p.name or "?", tostring(info))
                    log.info("[GHOST_DATA] %s @ %.0f,%.0f,%.0f yaw=%.0f (no actor; data still flowing)",
                        p.name or "?", p.state.x, p.state.y, p.state.z, p.state.yaw or 0)
                end
            else
                log.debug("[GHOST_DATA] %s @ %.0f,%.0f,%.0f yaw=%.0f",
                    p.name or "?", p.state.x, p.state.y, p.state.z, p.state.yaw or 0)
            end
        end
    end
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
    summoning     = {}
    summon_failed = {}
end

function M.count()
    local n = 0
    for _ in pairs(ghosts) do n = n + 1 end
    return n
end

function M.reset_failures()
    summon_failed = {}
    summoning     = {}
end

return M
