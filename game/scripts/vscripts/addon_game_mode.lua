-- addon_game_mode.lua
-- Entry point for AI-LOD (addon folder: dota-lod-deathroll).

require("gamemode")

-- Link as early as possible so placeholder wisps/bots can receive the hold modifier.
if LinkLuaModifier then
	LinkLuaModifier("modifier_ai_lod_preparation", "modifiers/modifier_ai_lod_preparation", LUA_MODIFIER_MOTION_NONE)
end

function Precache(context)
	print("[AI-LOD] Precache")
	-- Io is the temporary ForceHero body during native selection; keep it resident.
	if PrecacheUnitByNameSync then
		pcall(function() PrecacheUnitByNameSync("npc_dota_hero_wisp", context) end)
	elseif PrecacheUnitByNameAsync then
		pcall(function() PrecacheUnitByNameAsync("npc_dota_hero_wisp", function() end) end)
	end
end

function Activate()
	print("[AI-LOD] Activate")
	if LinkLuaModifier then
		LinkLuaModifier("modifier_ai_lod_preparation", "modifiers/modifier_ai_lod_preparation", LUA_MODIFIER_MOTION_NONE)
	end
	GameRules.AILOD = AILODGameMode()
	GameRules.LODDeathroll = GameRules.AILOD
	GameRules.AILOD:InitGameMode()
end
