-- ============================================================
--  CMessangerMP - entry point
--
--  Joins our Render relay server, broadcasts the local player's
--  position and polls others' positions back. Drives a UI tab in
--  the UE4SS Debugging Tools window so the user can change lobby
--  code at runtime without editing config.lua.
-- ============================================================

local config   = require("config")
local log      = require("log")
local http     = require("http")
local player   = require("player")
local ghosts   = require("ghosts")
local settings = require("settings")
local ui       = require("ui")

local sess = {
    playerId = nil,
    isHost   = false,
    code     = nil,
    eventSeq = 0,
    joining  = false,
    joined   = false,
}

-- ----- bootstrap UI state -----
-- Order of preference: saved settings > config.lua > empty
local saved = settings.load()
ui.state.server = config.SERVER_URL
ui.state.code   = saved.code
                 or (config.LOBBY_CODE ~= "CHANGE" and config.LOBBY_CODE or "")
                 or ""
ui.state.name   = saved.name or config.PLAYER_NAME or "Player"
ui.state.statusText = "Not connected"
ui.refresh_inputs()

-- ----- server URL helper -----
local function url(path) return config.SERVER_URL .. path end

local function setStatus(status, text)
    ui.state.status     = status
    ui.state.statusText = text or status
end

-- ----- leave / join -----

local function leave()
    if sess.joined and sess.code and sess.playerId then
        http.post(url("/api/lobby/" .. sess.code .. "/leave"),
            { playerId = sess.playerId }, function() end)
    end
    sess.joined   = false
    sess.code     = nil
    sess.playerId = nil
    sess.eventSeq = 0
    ghosts.cleanup()
    ui.state.isHost     = false
    ui.state.ghostCount = 0
    setStatus("idle", "Disconnected")
    log.info("Left lobby")
end

local function joinWithCode(code, name)
    if sess.joining or sess.joined then
        log.info("Already %s, ignoring join", sess.joined and "joined" or "joining")
        return
    end

    code = string.upper(tostring(code or ""))
    name = tostring(name or "Player")
    if #code ~= 6 then
        log.error("Lobby code must be 6 chars (got '%s')", code)
        setStatus("error", "Invalid code (need 6 chars)")
        return
    end

    -- Persist for next launch
    settings.save({ code = code, name = name })

    sess.joining = true
    setStatus("connecting", "Connecting to " .. code .. " ...")
    log.info("Joining lobby %s as %s ...", code, name)

    http.post(url("/api/lobby/" .. code .. "/join"),
        { name = name },
        function(resp, err)
            sess.joining = false
            if not resp or not resp.playerId then
                local msg = (resp and resp.error) or err or "unknown"
                log.error("Join failed: %s", tostring(msg))
                setStatus("error", "Join failed: " .. tostring(msg))
                return
            end
            sess.playerId = resp.playerId
            sess.isHost   = resp.isHost == true
            sess.code     = code
            sess.joined   = true
            ui.state.isHost = sess.isHost
            local n = (resp.lobby and resp.lobby.players and #resp.lobby.players) or 1
            setStatus("connected",
                string.format("In lobby %s  (host=%s, %d players)",
                    code, tostring(sess.isHost), n))
            log.info("JOINED  code=%s playerId=%s host=%s players=%d",
                code, resp.playerId, tostring(sess.isHost), n)
        end)
end

-- ----- per-tick send/receive -----

local function pushState()
    if not sess.joined then return end
    local s = player.get_state()
    if not s then
        ui.state.hasSelf = false
        return
    end
    ui.state.hasSelf = true
    ui.state.selfX, ui.state.selfY, ui.state.selfZ = s.x, s.y, s.z
    ui.state.selfYaw = s.yaw

    http.post(url("/api/lobby/" .. sess.code .. "/state"),
        { playerId = sess.playerId, state = s },
        function(_, err) if err then log.debug("state err: %s", err) end end)
end

local function pollSnapshot()
    if not sess.joined then return end
    local u = url("/api/lobby/" .. sess.code ..
        "/snapshot?playerId=" .. sess.playerId ..
        "&since=" .. tostring(sess.eventSeq))
    http.get(u, function(resp, err)
        if not resp then
            if err then log.debug("snap err: %s", err) end
            return
        end
        if type(resp.seq) == "number" then sess.eventSeq = resp.seq end
        ghosts.update_from_snapshot(resp.players)
        ui.state.ghostCount = ghosts.count()
        for _, ev in ipairs(resp.events or {}) do
            if ev.name == "chat" then
                log.info("[chat] %s", (ev.data and ev.data.text) or "")
            elseif ev.name == "started" then
                log.info("[lobby] host started the game")
            else
                log.debug("[event] %s from %s", ev.name, ev.fromPlayerId)
            end
        end
    end)
end

local function dumpStatus()
    log.info("=== status ===")
    log.info("server : %s", config.SERVER_URL)
    log.info("lobby  : %s", sess.code or "(not joined)")
    log.info("player : %s host=%s", sess.playerId or "(none)", tostring(sess.isHost))
    log.info("ghosts : %d", ghosts.count())
    local s = player.get_state()
    if s then
        log.info("self   : x=%.0f y=%.0f z=%.0f yaw=%.0f", s.x, s.y, s.z, s.yaw)
    else
        log.info("self   : (no BP_Human_C found yet - main menu?)")
    end
end

-- ----- wire UI callbacks -----
ui.on_connect     = function(code, name) joinWithCode(code, name) end
ui.on_disconnect  = function() leave() end
ui.on_dump_status = dumpStatus

-- ----- ticker -----
LoopAsync(config.TICK_MS, function()
    if sess.joined then
        pushState()
        pollSnapshot()
    end
    return false
end)

-- ----- hotkeys -----
RegisterKeyBind(Key.F8, function() dumpStatus() end)

RegisterKeyBind(Key.F7, function()
    log.info("Force rejoin (F7)")
    local code = ui.state.code
    local name = ui.state.name
    leave()
    if code and #code == 6 then
        ExecuteWithDelay(500, function() joinWithCode(code, name) end)
    end
end)

-- ----- auto-join if we already have a code from a previous session -----
if ui.state.code and #ui.state.code == 6 then
    ExecuteWithDelay(3000, function()
        joinWithCode(ui.state.code, ui.state.name)
    end)
else
    log.info("No saved lobby code. Open the UE4SS Debugging Tools window -> 'C-meSsanger' tab to enter one.")
end

log.info("CMessangerMP loaded.  server=%s  saved-lobby=%s  name=%s  tick=%dms",
    config.SERVER_URL, ui.state.code or "(none)", ui.state.name, config.TICK_MS)
log.info("Hotkeys:  F9 = toggle in-game UI,  F8 = status,  F7 = force rejoin.")
log.info("Press F9 in game to open the connect window. Type a 6-char lobby code and click Connect or Change room.")
