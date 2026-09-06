-- addon_game_mode.lua
-- Entry point for the LOD Deathroll custom game mode.
require("gamemode")

function Precache(context)
	-- Precache resources used by the draft UI and custom abilities here.
	print("[LOD Deathroll] Precaching resources")
end

function Activate()
	print("[LOD Deathroll] Activating game mode")
	GameRules.LODDeathroll = LODDeathrollGameMode()
	GameRules.LODDeathroll:InitGameMode()
end
