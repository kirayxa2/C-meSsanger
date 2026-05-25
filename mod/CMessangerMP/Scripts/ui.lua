-- In-game UI for the CMessangerMP mod.
--
-- Two surfaces are registered so the user can use whichever works on
-- their UE4SS build:
--   1) An ImGui overlay window that renders directly over Hello Neighbor.
--      Toggled with F9.  Drag-able.  This is the one you actually want.
--   2) A "C-meSsanger" tab inside the UE4SS Debugging Tools window, as a
--      fallback in case the in-game overlay API isn't available.
--
-- Both surfaces draw the same controls via draw_controls().

local log = require("log")
local M = {}

-- State that main.lua reads/writes around. The UI also writes back
-- M.state.code / M.state.name as the user types.
M.state = {
    code        = "",
    name        = "Player",
    server      = "",
    status      = "idle",        -- "idle" | "connecting" | "connected" | "error"
    statusText  = "Not connected",
    isHost      = false,
    ghostCount  = 0,
    selfX = 0, selfY = 0, selfZ = 0, selfYaw = 0,
    hasSelf = false,
}

-- Wired up by main.lua
M.on_connect       = nil   -- (code, name) -> nil
M.on_disconnect    = nil   -- () -> nil
M.on_dump_status   = nil   -- () -> nil

-- Whether the in-game overlay window is shown. Toggled with F9.
local overlay_visible = true

local _code_buf = ""
local _name_buf = "Player"
local _initialized = false

local function ensure_init()
    if _initialized then return end
    _code_buf = M.state.code or ""
    _name_buf = M.state.name or "Player"
    _initialized = true
end

-- Called from main.lua after settings have been loaded.
function M.refresh_inputs()
    _code_buf = M.state.code or ""
    _name_buf = M.state.name or "Player"
    _initialized = true
end

-- The actual ImGui controls. Used both by the in-game overlay and by
-- the UE4SS Debugging Tools tab so the two surfaces stay in sync.
local function draw_controls()
    ensure_init()

    ImGui.Text("Server: " .. tostring(M.state.server))
    ImGui.Separator()

    -- Lobby code input
    local changed_c, new_c = ImGui.InputText("Lobby code", _code_buf, 8)
    if changed_c then
        local s = tostring(new_c or "")
        s = s:gsub("[^A-Za-z0-9]", ""):upper():sub(1, 6)
        _code_buf = s
        M.state.code = s
    end

    -- Player name input
    local changed_n, new_n = ImGui.InputText("Name", _name_buf, 32)
    if changed_n then
        _name_buf = tostring(new_n or ""):sub(1, 32)
        M.state.name = _name_buf
    end

    ImGui.Separator()

    if M.state.status == "connected" then
        if ImGui.Button("Disconnect") then
            if M.on_disconnect then M.on_disconnect() end
        end
        ImGui.SameLine()
        if ImGui.Button("Change room") then
            if M.on_disconnect then M.on_disconnect() end
            if M.on_connect and #_code_buf == 6 then
                M.on_connect(_code_buf, _name_buf)
            end
        end
    elseif M.state.status == "connecting" then
        ImGui.Text("Connecting...")
    else
        local can_connect = (#_code_buf == 6) and (#_name_buf > 0)
        if can_connect then
            if ImGui.Button("Connect") then
                if M.on_connect then M.on_connect(_code_buf, _name_buf) end
            end
        else
            ImGui.Text("(enter 6-char code and a name to connect)")
        end
    end

    ImGui.Separator()

    ImGui.Text("Status: " .. tostring(M.state.statusText))
    ImGui.Text(string.format("Host: %s   Ghosts: %d",
        tostring(M.state.isHost), M.state.ghostCount))

    if M.state.hasSelf then
        ImGui.Text(string.format("Self pos: x=%.0f y=%.0f z=%.0f yaw=%.0f",
            M.state.selfX, M.state.selfY, M.state.selfZ, M.state.selfYaw))
    else
        ImGui.Text("Self pos: (no BP_Human_C yet - load a level)")
    end

    ImGui.Separator()
    ImGui.Text("F9 to hide,  F8 to print status,  F7 to force rejoin")

    if ImGui.Button("Print status to log") then
        if M.on_dump_status then M.on_dump_status() end
    end
end

-- ---- Surface 1: in-game overlay window ----

local function overlay_render()
    if not overlay_visible then return end

    -- Default size on first use; user can drag/resize freely afterwards.
    pcall(function() ImGui.SetNextWindowSize(420, 280, 4) end)  -- 4 = ImGuiCond_FirstUseEver

    local should_draw = true
    local ok = pcall(function()
        -- ImGui.Begin returns a bool indicating whether the window
        -- should be rendered. Some bindings return (ret, open) - we
        -- handle either shape.
        local r1, r2 = ImGui.Begin("C-meSsanger")
        if type(r1) == "boolean" then should_draw = r1 end
        if type(r2) == "boolean" then
            -- if ImGui returned a 'p_open' bool that's false, user
            -- clicked the X button - treat as toggle off
            if r2 == false then overlay_visible = false end
        end
    end)
    if not ok then
        -- Begin failed - bail out without End()
        return
    end

    if should_draw then
        local cok, cerr = pcall(draw_controls)
        if not cok then
            pcall(function() ImGui.Text("UI draw error: " .. tostring(cerr)) end)
            log.error("overlay draw error: %s", tostring(cerr))
        end
    end

    pcall(function() ImGui.End() end)
end

-- ---- Surface 2: tab in UE4SS Debugging Tools (fallback) ----

local function tab_content()
    local ok, err = pcall(draw_controls)
    if not ok then
        pcall(function() ImGui.Text("UI error: " .. tostring(err)) end)
        log.error("tab draw error: %s", tostring(err))
    end
end

-- ---- Hotkey: F9 toggles the overlay ----

do
    local ok, err = pcall(function()
        RegisterKeyBind(Key.F9, function()
            overlay_visible = not overlay_visible
            log.info("In-game overlay: %s (F9 to toggle)",
                overlay_visible and "shown" or "hidden")
        end)
    end)
    if not ok then log.error("F9 keybind failed: %s", tostring(err)) end
end

-- ---- Helper: look up a global through every channel ----

local function get_global(name)
    local v
    -- Through _G with metatable (proper lookup)
    pcall(function() v = _G[name] end)
    if v ~= nil then return v end
    -- Raw _G (skip metatable)
    pcall(function() v = rawget(_G, name) end)
    if v ~= nil then return v end
    return nil
end

-- ---- Diagnostic: dump every plausible UI/render registration global ----
-- This runs once at mod load. Lets us identify the correct API name in
-- whatever UE4SS build the user has, since names move between releases.
do
    log.info("--- UE4SS API probe (diagnostic) ---")
    local found = {}
    local seen = {}
    local function add(name, kind)
        if seen[name] then return end
        seen[name] = true
        found[#found + 1] = string.format("%s(%s)", name, kind)
    end

    -- 1) iterate every key visible in _G
    pcall(function()
        for k, v in pairs(_G) do
            if type(k) == "string" then
                local lower = k:lower()
                if lower:find("register") or lower:find("imgui")
                   or lower:find("hook") or lower:find("tab")
                   or lower:find("draw") or lower:find("render")
                   or lower:find("custom") or lower:find("ui") then
                    add(k, type(v))
                end
            end
        end
    end)

    -- 2) probe specific names directly through _G[name]
    local probes = {
        "RegisterImGuiTab", "RegisterImGuiHook", "RegisterCustomEvent",
        "RegisterTabRenderer", "RegisterUIHook", "RegisterDrawHook",
        "RegisterPostBeginPlay", "RegisterHook", "RegisterKeyBind",
        "RegisterProcessConsoleExecPreHook", "RegisterUI",
        "ImGuiNewFrame", "DrawImGui", "OnDraw",
    }
    for _, name in ipairs(probes) do
        local v = get_global(name)
        if v ~= nil then add(name, "PROBE:" .. type(v)) end
    end

    table.sort(found)
    if #found == 0 then
        log.info("NO matching globals found. Listing first 30 globals as last resort:")
        local n = 0
        pcall(function()
            for k, v in pairs(_G) do
                if n < 30 and type(k) == "string" then
                    log.info("  _G.%s = %s", k, type(v))
                    n = n + 1
                end
            end
        end)
    else
        log.info("Found %d globals matching UI/Register/Hook keywords:", #found)
        for _, s in ipairs(found) do log.info("  %s", s) end
    end
    log.info("--- end probe ---")
end

-- ---- Try to register the in-game overlay render hook ----

do
    local registered = false
    local tried = {}
    local candidates = {
        "RegisterImGuiHook",
        "RegisterUIHook",
        "RegisterDrawHook",
        "RegisterRenderHook",
        "RegisterFrameRender",
        "RegisterCustomImGui",
        "RegisterUI",
        "RegisterImGui",
    }
    for _, name in ipairs(candidates) do
        local fn = get_global(name)
        if type(fn) == "function" then
            tried[#tried + 1] = name
            local ok, err = pcall(function() fn(overlay_render) end)
            if ok then
                registered = true
                log.info("In-game overlay registered via %s. Press F9 to toggle.", name)
                break
            else
                log.error("%s exists but failed: %s", name, tostring(err))
            end
        end
    end
    if not registered then
        log.info("No in-game overlay API found (tried %d candidates: %s).",
            #tried, tried[1] and table.concat(tried, ", ") or "none of the known names existed")
        log.info("Use settings.json (auto-reload) or the C-meSsanger tab in UE4SS Debugging Tools.")
    end
end

-- ---- Always also try to register the UE4SS console tab as a fallback ----

do
    local registered = false
    local tried = {}
    local candidates = { "RegisterImGuiTab", "RegisterTabRenderer", "RegisterImGuiTabRenderer" }
    for _, name in ipairs(candidates) do
        local fn = get_global(name)
        if type(fn) == "function" then
            tried[#tried + 1] = name
            local ok, err = pcall(function() fn("C-meSsanger", tab_content) end)
            if ok then
                registered = true
                log.info("UE4SS tab registered via %s", name)
                break
            else
                log.error("%s exists but failed: %s", name, tostring(err))
            end
        end
    end
    if not registered then
        log.info("No tab API found either. That's fine - settings.json auto-reload still works.")
        log.info("Edit Mods/CMessangerMP/settings.json in notepad to change room without restart.")
    end
end

return M
