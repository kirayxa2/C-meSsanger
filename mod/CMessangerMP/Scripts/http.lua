-- Async HTTP via Windows curl.exe (ships with Windows 10+).
-- Heavy lifting runs on a worker thread (ExecuteAsync) so the game
-- doesn't stall; the callback is marshalled back to the game thread
-- (ExecuteInGameThread) so it's safe to touch UObjects from there.

local log = require("log")
local M = {}

-- ===== JSON encoder (just enough for our protocol) =====

local function encode_string(s, sb)
    sb[#sb + 1] = '"'
    for i = 1, #s do
        local b = s:byte(i)
        if b == 0x22 then sb[#sb + 1] = '\\"'
        elseif b == 0x5C then sb[#sb + 1] = "\\\\"
        elseif b == 0x0A then sb[#sb + 1] = "\\n"
        elseif b == 0x0D then sb[#sb + 1] = "\\r"
        elseif b == 0x09 then sb[#sb + 1] = "\\t"
        elseif b < 0x20 then sb[#sb + 1] = string.format("\\u%04x", b)
        else sb[#sb + 1] = string.char(b) end
    end
    sb[#sb + 1] = '"'
end

local function encode(v, sb)
    local t = type(v)
    if v == nil then sb[#sb + 1] = "null"
    elseif t == "boolean" then sb[#sb + 1] = (v and "true" or "false")
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then sb[#sb + 1] = "0"
        else sb[#sb + 1] = string.format("%.6g", v) end
    elseif t == "string" then encode_string(v, sb)
    elseif t == "table" then
        local n = #v
        local key_count, all_int = 0, true
        for k, _ in pairs(v) do
            key_count = key_count + 1
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
                all_int = false
            end
        end
        if key_count == 0 then sb[#sb + 1] = "{}"
        elseif all_int then
            sb[#sb + 1] = "["
            for i, item in ipairs(v) do
                if i > 1 then sb[#sb + 1] = "," end
                encode(item, sb)
            end
            sb[#sb + 1] = "]"
        else
            sb[#sb + 1] = "{"
            local first = true
            for k, item in pairs(v) do
                if not first then sb[#sb + 1] = "," end
                first = false
                encode_string(tostring(k), sb)
                sb[#sb + 1] = ":"
                encode(item, sb)
            end
            sb[#sb + 1] = "}"
        end
    else
        sb[#sb + 1] = "null"
    end
end

function M.json_encode(v)
    local sb = {}
    encode(v, sb)
    return table.concat(sb)
end

-- ===== JSON decoder =====

function M.json_decode(str)
    local pos = 1
    local function err(msg) error(("JSON decode: %s at pos %d"):format(msg, pos), 0) end
    local function skip_ws()
        while pos <= #str do
            local c = str:byte(pos)
            if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D then pos = pos + 1
            else break end
        end
    end
    local parse
    local function parse_string()
        if str:sub(pos, pos) ~= '"' then err("expected string") end
        pos = pos + 1
        local buf = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(buf) end
            if c == "\\" then
                local nx = str:sub(pos + 1, pos + 1)
                pos = pos + 2
                if nx == "n" then buf[#buf + 1] = "\n"
                elseif nx == "r" then buf[#buf + 1] = "\r"
                elseif nx == "t" then buf[#buf + 1] = "\t"
                elseif nx == '"' then buf[#buf + 1] = '"'
                elseif nx == "\\" then buf[#buf + 1] = "\\"
                elseif nx == "/" then buf[#buf + 1] = "/"
                elseif nx == "u" then
                    local hex = str:sub(pos, pos + 3); pos = pos + 4
                    local code = tonumber(hex, 16) or 63
                    if code < 0x80 then buf[#buf + 1] = string.char(code)
                    elseif code < 0x800 then
                        buf[#buf + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
                    else
                        buf[#buf + 1] = string.char(0xE0 + math.floor(code / 0x1000),
                                                    0x80 + math.floor(code / 0x40) % 0x40,
                                                    0x80 + (code % 0x40))
                    end
                else buf[#buf + 1] = nx end
            else buf[#buf + 1] = c; pos = pos + 1 end
        end
        err("unterminated string")
    end
    local function parse_number()
        local s = pos
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c:match("[%-%+%d%.eE]") then pos = pos + 1 else break end
        end
        return tonumber(str:sub(s, pos - 1))
    end
    parse = function()
        skip_ws()
        if pos > #str then err("unexpected EOF") end
        local c = str:sub(pos, pos)
        if c == "{" then
            pos = pos + 1; skip_ws()
            local obj = {}
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while pos <= #str do
                skip_ws()
                local k = parse_string()
                skip_ws()
                if str:sub(pos, pos) ~= ":" then err("expected ':'") end
                pos = pos + 1
                obj[k] = parse()
                skip_ws()
                local nx = str:sub(pos, pos)
                if nx == "," then pos = pos + 1
                elseif nx == "}" then pos = pos + 1; return obj
                else err("expected ',' or '}'") end
            end
        elseif c == "[" then
            pos = pos + 1; skip_ws()
            local arr = {}
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while pos <= #str do
                arr[#arr + 1] = parse()
                skip_ws()
                local nx = str:sub(pos, pos)
                if nx == "," then pos = pos + 1
                elseif nx == "]" then pos = pos + 1; return arr
                else err("expected ',' or ']'") end
            end
        elseif c == '"' then return parse_string()
        elseif c == "t" then
            if str:sub(pos, pos + 3) ~= "true" then err("expected 'true'") end
            pos = pos + 4; return true
        elseif c == "f" then
            if str:sub(pos, pos + 4) ~= "false" then err("expected 'false'") end
            pos = pos + 5; return false
        elseif c == "n" then
            if str:sub(pos, pos + 3) ~= "null" then err("expected 'null'") end
            pos = pos + 4; return nil
        else return parse_number() end
    end
    return parse()
end

-- ===== curl wrapper =====

local _file_seq = 0
local function tempfile(suffix)
    _file_seq = _file_seq + 1
    local base = os.getenv("TEMP") or os.getenv("TMP") or "."
    return ("%s\\cmess_%d_%d%s"):format(base, os.time(), _file_seq, suffix or "")
end

-- Run curl with the given args, return stdout text or nil + err.
-- BLOCKING: must be called from inside ExecuteAsync.
local function run_curl(args)
    local parts = { 'curl.exe', '-s', '-m', '5' }
    for _, a in ipairs(args) do
        parts[#parts + 1] = '"' .. tostring(a):gsub('"', '""') .. '"'
    end
    local out_file = tempfile(".out")
    local cmd = table.concat(parts, " ") .. (" > \"%s\" 2>NUL"):format(out_file)
    local h = io.popen(cmd, "r")
    if h then h:close() end

    local f = io.open(out_file, "rb")
    if not f then return nil, "no output file" end
    local body = f:read("*a") or ""
    f:close()
    pcall(os.remove, out_file)
    return body
end

local function decode_response(body)
    if not body or body == "" then return nil end
    local ok, data = pcall(M.json_decode, body)
    if ok then return data end
    return nil, "decode failed: " .. tostring(data) .. " body=" .. body:sub(1, 200)
end

-- ===== Public API =====

-- POST JSON body. callback(decoded_json|nil, err_str|nil)
function M.post(url, body, callback)
    local body_str = M.json_encode(body or {})
    local body_file = tempfile(".body")
    local f, ferr = io.open(body_file, "wb")
    if not f then
        if callback then callback(nil, "open body file: " .. tostring(ferr)) end
        return
    end
    f:write(body_str); f:close()

    ExecuteAsync(function()
        local args = {
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "--data-binary", "@" .. body_file,
            url,
        }
        local out, err = run_curl(args)
        pcall(os.remove, body_file)
        local data, derr = decode_response(out)
        ExecuteInGameThread(function()
            if callback then callback(data, err or derr) end
        end)
    end)
end

-- GET. callback(decoded_json|nil, err_str|nil)
function M.get(url, callback)
    ExecuteAsync(function()
        local out, err = run_curl({ url })
        local data, derr = decode_response(out)
        ExecuteInGameThread(function()
            if callback then callback(data, err or derr) end
        end)
    end)
end

return M
