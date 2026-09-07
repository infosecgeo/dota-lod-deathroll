-- systems/respawn_manager.lua
-- V0.1: normal Dota respawn. Later phases hook RESPAWN_DRAFT here.

RespawnManager = RespawnManager or class({})

function RespawnManager:constructor()
	self.enabledDraft = false -- set true when death-draft ships
end

function RespawnManager:OnHeroDeath(hero)
	if not hero or hero:IsNull() or not hero:IsRealHero() then
		return
	end

	local playerID = hero:GetPlayerOwnerID()
	if not PlayerResource:IsValidPlayerID(playerID) then
		return
	end

	if PlayerState then
		PlayerState:IncDeath(playerID)
	end

	print(string.format("[RespawnManager] Hero death player=%d (draft=%s)",
		playerID, tostring(self.enabledDraft)))

	-- V0.1: do nothing special — engine handles buyback/respawn timers.
	-- Later: GameState:Transition(GameState.RESPAWN_DRAFT, { playerID = playerID })
	if self.enabledDraft and GameState and GameState:Is(GameState.PLAYING) then
		-- Reserved for Phase 10+
	end
end

function RespawnManager:OnHeroSpawn(hero)
	if not hero or hero:IsNull() or not hero:IsRealHero() then
		return
	end
	-- V0.1: ensure hero is controllable after respawn
	hero:RemoveModifierByName("modifier_stunned")
end
