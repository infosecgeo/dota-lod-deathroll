-- extra_ult.lua
-- Assigns each player an extra ultimate from the ExtraUltimate pool
-- (including shard skills) once the draft completes.

ExtraUlt = ExtraUlt or class({})

function ExtraUlt:constructor()
	self.assigned = {} -- playerID -> abilityName
end

function ExtraUlt:AssignExtraUltimates()
	print("[ExtraUlt] Assigning extra ultimates")
	local kv = LoadKeyValues("scripts/npc/npc_abilities_custom.txt")
	local pool = {}
	if kv and kv.DraftAbilities and kv.DraftAbilities.ExtraUltimate then
		for ability, _ in pairs(kv.DraftAbilities.ExtraUltimate) do
			table.insert(pool, ability)
		end
	end
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
				hero:AddAbility(ability)
			end
			local player = PlayerResource:GetPlayer(playerID)
			if player then
				CustomGameEventManager:Send_ServerToPlayer(player, "lod_extra_ult", { ability = ability })
			end
		end
	end
end

function ExtraUlt:GetExtraUltimate(playerID)
	return self.assigned[playerID]
end
