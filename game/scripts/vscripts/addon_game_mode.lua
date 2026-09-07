-- addon_game_mode.lua
-- Entry point for AI-LOD (addon folder: dota-lod-deathroll).

require("gamemode")

function Precache(context)
	print("[AI-LOD] Precache")
end

function Activate()
	print("[AI-LOD] Activate")
	GameRules.AILOD = AILODGameMode()
	GameRules.LODDeathroll = GameRules.AILOD
	GameRules.AILOD:InitGameMode()
end
