-- Tiny logger that prepends a tag so we can spot our messages
-- in the UE4SS console.
local config = require("config")
local M = {}

local function emit(level, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    print(("[CMessanger:%s] %s\n"):format(level, msg))
end

function M.info(fmt, ...)  emit("info",  fmt, ...) end
function M.error(fmt, ...) emit("ERROR", fmt, ...) end
function M.debug(fmt, ...)
    if config.DEBUG then emit("debug", fmt, ...) end
end

return M
