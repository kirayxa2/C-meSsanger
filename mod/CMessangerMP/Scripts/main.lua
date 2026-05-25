-- ============================================================
--  CMessangerMP - entry point
--  Joins the lobby on our Render relay server, sends our position
--  every TICK_MS, polls others' positions back and (tries to)
--  spawn ghost bodies for them.
-- ============================================================

local config  = require("config")
local log     = require("log")
local http    = require("http")
local player  = require("player")
local ghosts  = require("ghosts")

local sess = {
    playerId  = nil,
    isHost    = false,
    code      = nil,
    eventSeq  = 0,
    joining   = false,
    joined    = false,
    lastError = nil,
    nextJoinAttempt = 0,
}

local function url(path) return config.SERVER_URL .. path end

local function tryJoin()
    if sess.joining or sess.joined then return end
    local now = os.time()
    if now < sess.nextJoinAttempt then return end

    local code = config.LOBBY_CODE
    if not code or code == "" or code == "CHANGE" or #code ~= 6 then
        log.error("Set LOBBY_CODE in config.lua (got '%s'). Get a code from %s/test.html",
            tostring(code), config.SERVER_URL)
        sess.nextJoinAttempt = now + 10
        return
    end
    sess.joining = true
    log.info("Joining lobby %s as %s ...", code, config.PLAYER_NAME)
    http.post(url("/api/lobby/" .. code .. "/join"),
        { name = config.PLAYER_NAME },
        function(resp, err)
            sess.joining = false
            if not resp or not resp.playerId then
                local msg = (resp and resp.error) or err or "unknown"
                log.error("Join failed: %s", tostring(msg))
                sess.lastError = msg
                sess.nextJoinAttempt = os.time() + 5
                return
            end
            sess.playerId = resp.playerId
            sess.isHost   = resp.isHost == true
            sess.code     = code
            sess.joined   = true
            sess.lastError = nil
            local n = (resp.lobby and resp.lobby.players and #resp.lobby.players) or 1
            log.info("JOINED  code=%s playerId=%s host=%s players=%d",
                code, resp.playerId, tostring(sess.isHost), n)
        end)
end

local function pushState()
    if not sess.joined then return end
    local s = player.get_state()
    if not s then return end
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
        for _, ev in ipairs(resp.events or {}) do
            if ev.name == "chat" then
                log.info("[chat] %s", (ev.data and ev.data.text) or "")
            elseif ev.name == "started" then
                log.info("[lobby] host started the game")
            else
                log.debug("[event] %s from %s data=%s",
                    ev.name, ev.fromPlayerId, http.json_encode(ev.data or {}))
            end
        end
    end)
end

local function onLeave()
    if not sess.joined then return end
    http.post(url("/api/lobby/" .. sess.code .. "/leave"),
        { playerId = sess.playerId }, function() end)
    sess.joined = false
end

-- ===== Schedule =====

-- Give the level a moment to load before the first join attempt.
ExecuteWithDelay(3000, function() tryJoin() end)

-- Periodic tick: send our state, poll snapshot, retry join if needed.
LoopAsync(config.TICK_MS, function()
    if not sess.joined then
        if not sess.joining then tryJoin() end
        return false
    end
    pushState()
    pollSnapshot()
    return false
end)

-- F8 dumps current status into the UE4SS console.
RegisterKeyBind(Key.F8, function()
    log.info("=== status ===")
    log.info("server : %s", config.SERVER_URL)
    log.info("lobby  : %s", sess.code or "(not joined)")
    log.info("player : %s host=%s", sess.playerId or "(none)", tostring(sess.isHost))
    log.info("ghosts : %d", ghosts.count())
    if sess.lastError then log.info("lastErr: %s", sess.lastError) end
    local s = player.get_state()
    if s then log.info("self   : x=%.0f y=%.0f z=%.0f yaw=%.0f", s.x, s.y, s.z, s.yaw)
    else log.info("self   : (no BP_Human_C found yet)") end
end)

-- F7 forces an immediate (re)join - useful after editing config.lua and
-- using the UE4SS hot-reload feature.
RegisterKeyBind(Key.F7, function()
    log.info("Force rejoin requested (F7)")
    if sess.joined then onLeave() end
    sess.code = nil
    sess.playerId = nil
    sess.eventSeq = 0
    ghosts.cleanup()
    sess.nextJoinAttempt = 0
    tryJoin()
end)

log.info("CMessangerMP loaded.  server=%s  lobby=%s  name=%s  tick=%dms",
    config.SERVER_URL, config.LOBBY_CODE, config.PLAYER_NAME, config.TICK_MS)
log.info("Hotkeys:  F8 = status,  F7 = force rejoin")
