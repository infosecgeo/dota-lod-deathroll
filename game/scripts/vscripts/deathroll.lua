-- deathroll.lua
-- Death-reroll: when a hero dies, one of its drafted regular abilities
-- is replaced with a random ability from the DeathReroll pool.

Deathroll = Deathroll or class({})

local DEATHROLL_COOLDOWN = 30 -- seconds between deathrolls per player

function Deathroll:constructor()
	self.lastRoll = {} -- playerID -> game time of last roll
end

function Deathroll:OnHeroDeath(hero)
	local playerID = hero:GetPlayerOwnerID()
	if not PlayerResource:IsValidPlayerID(playerID) then return end

	local now = GameRules:GetGameTime()
	if self.lastRoll[playerID] and (now - self.lastRoll[playerID]) < DEATHROLL_COOLDOWN then
		return
	end
	self.lastRoll[playerID] = now

	local newAbility = self:RollAbility()
	if not newAbility then
		print("[Deathroll] No abilities in DeathReroll pool")
		return
	end

	local replaced = self:ReplaceRandomAbility(hero, newAbility)
	if replaced then
		print(string.format("[Deathroll] Player %d: %s -> %s", playerID, replaced, newAbility))
		local player = PlayerResource:GetPlayer(playerID)
		if player then
			CustomGameEventManager:Send_ServerToPlayer(player, "lod_deathroll", {
				replaced = replaced,
				gained = newAbility,
			})
		end
	end
end

function Deathroll:RollAbility()
	local kv = LoadKeyValues("scripts/npc/draft_abilities.txt")
	if kv and kv.DraftAbilities then
		kv = kv.DraftAbilities
	end
	local pool = {}
	if kv and kv.DeathReroll then
		for ability, enabled in pairs(kv.DeathReroll) do
			if enabled == 1 or enabled == "1" then
				table.insert(pool, ability)
			end
		end
	end
	if #pool == 0 then return nil end
	return pool[RandomInt(1, #pool)]
end

function Deathroll:ReplaceRandomAbility(hero, newAbility)
	local candidates = {}
	for i = 0, hero:GetAbilityCount() - 1 do
		local ability = hero:GetAbilityByIndex(i)
		if ability and not ability:IsHidden() and not ability:IsAttributeBonus() then
			local name = ability:GetAbilityName()
			if name and name ~= "generic_hidden" and not string.find(name, "special_bonus") then
				table.insert(candidates, ability)
			end
		end
	end
	if #candidates == 0 then return nil end

	local victim = candidates[RandomInt(1, #candidates)]
	local name = victim:GetAbilityName()
	local level = victim:GetLevel()
	if level < 1 then level = 1 end

	hero:RemoveAbility(name)
	local ab = hero:AddAbility(newAbility)
	if ab then
		ab:SetLevel(math.min(level, ab:GetMaxLevel()))
		ab:SetHidden(false)
	end
	return name
end
