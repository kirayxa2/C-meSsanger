-- ====================================================
--  CMessangerMP - config
--  Edit the values below before launching the game.
-- ====================================================

local M = {}

-- Address of your relay server. No trailing slash.
M.SERVER_URL = "https://c-messanger.onrender.com"

-- Lobby code (6 characters, A-Z 0-9). Get one from the test page:
--   https://c-messanger.onrender.com/test.html  ->  "Create lobby"
-- Then paste it here AND give it to your friend.
M.LOBBY_CODE = "CHANGE"

-- Display name shown to other players (max 32 chars)
M.PLAYER_NAME = "Player"

-- How often (ms) we push our position and poll for others.
-- 100 = 10 Hz. Lower = smoother but more network traffic.
M.TICK_MS = 100

-- Print verbose logs to the UE4SS console. Set to false for clean play.
M.DEBUG = true

return M
