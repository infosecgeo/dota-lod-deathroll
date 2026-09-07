-- systems/hero_manager.lua
-- Hero pool loading, bans (future), spawn helpers.

HeroManager = HeroManager or class({})

function HeroManager:constructor()
	self.pool = {}
	self.banned = {}
	self.loaded = false
end

function HeroManager:LoadPool()
	if self.loaded then
		return self.pool
	end

	local kv = LoadKeyValues("scripts/config/heroes.kv")
	if not kv then
		kv = LoadKeyValues("scripts/npc/hero_categories.txt")
	end
	if kv and kv.CustomHeroList then
		kv = kv.CustomHeroList
	elseif kv and kv.Heroes then
		kv = kv.Heroes
	end

	local pool = {}
	local function addHero(name, enabled)
		if (enabled == 1 or enabled == "1") and name and name ~= "" then
			table.insert(pool, name)
		end
	end

	if kv then
		for key, value in pairs(kv) do
			if type(value) == "table" then
				for hero, enabled in pairs(value) do
					addHero(hero, enabled)
				end
			else
				addHero(key, value)
			end
		end
	end

	table.sort(pool)
	self.pool = pool
	self.loaded = true
	print(string.format("[HeroManager] Loaded %d heroes", #pool))
	return pool
end

function HeroManager:IsBanned(heroName)
	return self.banned[heroName] == true
end

function HeroManager:Ban(heroName, playerID)
	if not heroName or heroName == "" then
		return false, "empty"
	end
	if self.banned[heroName] then
		return false, "already_banned"
	end
	local valid = false
	for _, h in ipairs(self:LoadPool()) do
		if h == heroName then
			valid = true
			break
		end
	end
	if not valid then
		return false, "invalid"
	end
	self.banned[heroName] = true
	print(string.format("[HeroManager] Banned %s by player %s", heroName, tostring(playerID)))
	return true
end

function HeroManager:GetDefaultHero()
	local pool = self:LoadPool()
	return pool[1] or "npc_dota_hero_axe"
end

function HeroManager:EnsureHeroForPlayer(playerID, preferredHero)
	local heroName = preferredHero or self:GetDefaultHero()
	local hero = PlayerResource:GetSelectedHeroEntity(playerID)

	if hero and not hero:IsNull() then
		if preferredHero and hero:GetUnitName() ~= preferredHero then
			local gold = hero.GetGold and hero:GetGold() or 0
			local replaced = PlayerResource:ReplaceHeroWith(playerID, preferredHero, gold, 0)
			if replaced then
				hero = replaced
				heroName = preferredHero
			end
		else
			heroName = hero:GetUnitName()
		end
	else
		local player = PlayerResource:GetPlayer(playerID)
		if player then
			hero = CreateHeroForPlayer(heroName, player)
		end
	end

	if hero and not hero:IsNull() then
		-- Clear any leftover foundation stun/hold
		hero:RemoveModifierByName("modifier_stunned")
		hero:RemoveModifierByName("modifier_fountain_invulnerability")
		if PlayerState then
			PlayerState:SetHero(playerID, hero:GetUnitName())
		end
	end

	return hero, heroName
end
