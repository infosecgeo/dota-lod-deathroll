-- LEGACY (not required by V0.1). Kept for reference until systems/* fully replace this.
-- extra_ult.lua
-- Assigns each player an extra ultimate from the ExtraUltimate pool
-- once the draft completes.

ExtraUlt = ExtraUlt or class({})

function ExtraUlt:constructor()
	self.assigned = {} -- playerID -> abilityName
end

function ExtraUlt:LoadPool()
	local kv = LoadKeyValues("scripts/npc/draft_abilities.txt")
	if kv and kv.DraftAbilities then
		kv = kv.DraftAbilities
	end
	local pool = {}
	if kv and kv.ExtraUltimate then
		for ability, enabled in pairs(kv.ExtraUltimate) do
			if enabled == 1 or enabled == "1" then
				table.insert(pool, ability)
			end
		end
	end
	return pool
end

function ExtraUlt:AssignExtraUltimates()
	print("[ExtraUlt] Assigning extra ultimates")
	local pool = self:LoadPool()
	if #pool == 0 then
		print("[ExtraUlt] WARNING: ExtraUltimate pool is empty")
		return
	end

	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			local ability = pool[RandomInt(1, #pool)]
			self.assigned[playerID] = ability
			local hero = PlayerResource:GetSelectedHeroEntity(playerID)
			if hero then
				local ab = hero:AddAbility(ability)
				if ab then
					ab:SetLevel(1)
					ab:SetHidden(false)
				end
			end
			local player = PlayerResource:GetPlayer(playerID)
			if player then
				CustomGameEventManager:Send_ServerToPlayer(player, "lod_extra_ult", { ability = ability })
			end
			print(string.format("[ExtraUlt] Player %d got %s", playerID, ability))
		end
	end
end

function ExtraUlt:GetExtraUltimate(playerID)
	return self.assigned[playerID]
end
