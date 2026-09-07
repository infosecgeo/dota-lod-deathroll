-- systems/ability_manager.lua
-- Ability database, blacklist, compatibility, kit application.

AbilityManager = AbilityManager or class({})

local KEEP_ABILITY = {
	attribute_bonus = true,
	generic_hidden = true,
	special_bonus = true,
}

function AbilityManager:constructor()
	self.db = {}
	self.blacklist = {}
	self.pools = {
		regular = {},
		ultimate = {},
		extraUltimate = {},
		deathReroll = {},
		regularSet = {},
		ultimateSet = {},
	}
	self.loaded = false
end

function AbilityManager:Load()
	if self.loaded then return self.db end

	local abilities = LoadKeyValues("scripts/config/abilities.kv")
	local blacklist = LoadKeyValues("scripts/config/blacklist.kv")
	local balance = LoadKeyValues("scripts/config/balance.kv")
	local draft = LoadKeyValues("scripts/npc/draft_abilities.txt")

	self.db = (abilities and (abilities.Abilities or abilities)) or {}
	self.blacklist = {}
	if blacklist and blacklist.Blacklist then
		for name, enabled in pairs(blacklist.Blacklist) do
			if enabled == 1 or enabled == "1" then
				self.blacklist[name] = true
			end
		end
	end
	self.balance = balance or {}

	local function collect(section, outList, outSet)
		if not section then return end
		for ability, enabled in pairs(section) do
			if (enabled == 1 or enabled == "1") and not self.blacklist[ability] then
				table.insert(outList, ability)
				if outSet then outSet[ability] = true end
			end
		end
		table.sort(outList)
	end

	self.pools = {
		regular = {},
		ultimate = {},
		extraUltimate = {},
		deathReroll = {},
		regularSet = {},
		ultimateSet = {},
	}

	local root = draft and (draft.DraftAbilities or draft) or nil
	if root then
		collect(root.Regular, self.pools.regular, self.pools.regularSet)
		collect(root.Ultimate, self.pools.ultimate, self.pools.ultimateSet)
		collect(root.ExtraUltimate, self.pools.extraUltimate, nil)
		collect(root.DeathReroll, self.pools.deathReroll, nil)
	end

	if #self.pools.regular == 0 or #self.pools.ultimate == 0 then
		self.pools.regular = {}
		self.pools.ultimate = {}
		self.pools.regularSet = {}
		self.pools.ultimateSet = {}
		for name, def in pairs(self.db) do
			if type(def) == "table" and not self.blacklist[name] then
				local t = def.type or def.Type
				if t == "ultimate" then
					table.insert(self.pools.ultimate, name)
					self.pools.ultimateSet[name] = true
				else
					table.insert(self.pools.regular, name)
					self.pools.regularSet[name] = true
				end
			end
		end
		table.sort(self.pools.regular)
		table.sort(self.pools.ultimate)
		if #self.pools.extraUltimate == 0 then
			for _, a in ipairs(self.pools.ultimate) do
				table.insert(self.pools.extraUltimate, a)
			end
		end
		if #self.pools.deathReroll == 0 then
			for _, a in ipairs(self.pools.regular) do
				table.insert(self.pools.deathReroll, a)
			end
		end
	end

	self.loaded = true
	local count = 0
	for _ in pairs(self.db) do count = count + 1 end
	print(string.format(
		"[AbilityManager] Loaded %d defs, %d blacklisted, pools R=%d U=%d XU=%d DR=%d",
		count, self:CountBlacklist(),
		#self.pools.regular, #self.pools.ultimate,
		#self.pools.extraUltimate, #self.pools.deathReroll))
	return self.db
end

function AbilityManager:CountBlacklist()
	local n = 0
	for _ in pairs(self.blacklist) do n = n + 1 end
	return n
end

function AbilityManager:IsBlacklisted(abilityName)
	return self.blacklist[abilityName] == true
end

function AbilityManager:Get(abilityName)
	self:Load()
	return self.db[abilityName]
end

function AbilityManager:GetPools()
	self:Load()
	return self.pools
end

function AbilityManager:IsUltimate(abilityName)
	self:Load()
	if self.pools.ultimateSet[abilityName] then return true end
	local def = self.db[abilityName]
	return def and (def.type == "ultimate" or def.Type == "ultimate")
end

function AbilityManager:IsRegular(abilityName)
	self:Load()
	if self.pools.regularSet[abilityName] then return true end
	local def = self.db[abilityName]
	if not def then return false end
	local t = def.type or def.Type
	return t ~= "ultimate"
end

function AbilityManager:IsCompatible(candidate, ownedList, heroName)
	if not candidate or candidate == "" then
		return false, "empty"
	end
	if self:IsBlacklisted(candidate) then
		return false, "blacklisted"
	end
	if ownedList then
		for _, a in ipairs(ownedList) do
			if a == candidate then
				return false, "duplicate"
			end
		end
	end
	return true
end

function AbilityManager:Sample(list, count, excludeSet)
	self:Load()
	excludeSet = excludeSet or {}
	local filtered = {}
	for _, a in ipairs(list or {}) do
		if not excludeSet[a] and not self:IsBlacklisted(a) then
			table.insert(filtered, a)
		end
	end
	if #filtered == 0 then return {} end
	for i = #filtered, 2, -1 do
		local j = RandomInt(1, i)
		filtered[i], filtered[j] = filtered[j], filtered[i]
	end
	local n = math.min(count or 1, #filtered)
	local out = {}
	for i = 1, n do table.insert(out, filtered[i]) end
	return out
end

function AbilityManager:RandomFrom(list, excludeSet)
	local s = self:Sample(list, 1, excludeSet)
	return s[1]
end

function AbilityManager:ShouldKeepAbility(name)
	if not name then return true end
	if KEEP_ABILITY[name] then return true end
	if string.find(name, "special_bonus", 1, true) then return true end
	if string.find(name, "attribute", 1, true) then return true end
	return false
end

function AbilityManager:ClearDraftableAbilities(hero)
	if not hero or hero:IsNull() then return end
	local toRemove = {}
	for i = 0, hero:GetAbilityCount() - 1 do
		local ab = hero:GetAbilityByIndex(i)
		if ab and not ab:IsNull() then
			local name = ab:GetAbilityName()
			if not self:ShouldKeepAbility(name) then
				table.insert(toRemove, name)
			end
		end
	end
	for _, name in ipairs(toRemove) do
		hero:RemoveAbility(name)
	end
end

function AbilityManager:AddAbilityLeveled(hero, abilityName, level)
	if not hero or hero:IsNull() or not abilityName then return nil end
	if self:IsBlacklisted(abilityName) then return nil end
	local existing = hero:FindAbilityByName(abilityName)
	if existing then
		local maxLvl = existing:GetMaxLevel()
		existing:SetLevel(math.min(level or 1, maxLvl > 0 and maxLvl or 4))
		existing:SetHidden(false)
		return existing
	end
	local ab = hero:AddAbility(abilityName)
	if ab then
		local maxLvl = ab:GetMaxLevel()
		ab:SetLevel(math.min(level or 1, maxLvl > 0 and maxLvl or 4))
		ab:SetHidden(false)
	else
		print("[AbilityManager] Failed to add ability " .. tostring(abilityName))
	end
	return ab
end

function AbilityManager:ApplyKit(hero, basics, ultimates)
	if not hero or hero:IsNull() then return false end
	basics = basics or {}
	ultimates = ultimates or {}
	self:ClearDraftableAbilities(hero)
	for _, name in ipairs(basics) do
		self:AddAbilityLeveled(hero, name, 1)
	end
	for _, name in ipairs(ultimates) do
		self:AddAbilityLeveled(hero, name, 1)
	end
	print(string.format("[AbilityManager] Applied kit to %s: %d basic, %d ult",
		hero:GetUnitName(), #basics, #ultimates))
	return true
end

function AbilityManager:ReplaceAbility(hero, oldName, newName)
	if not hero or hero:IsNull() then return false end
	local level = 1
	local old = hero:FindAbilityByName(oldName)
	if old then
		level = math.max(1, old:GetLevel())
		hero:RemoveAbility(oldName)
	end
	local ab = self:AddAbilityLeveled(hero, newName, level)
	return ab ~= nil
end

function AbilityManager:ListHeroAbilities(hero)
	local list = {}
	if not hero or hero:IsNull() then return list end
	for i = 0, hero:GetAbilityCount() - 1 do
		local ab = hero:GetAbilityByIndex(i)
		if ab and not ab:IsNull() then
			local name = ab:GetAbilityName()
			if not self:ShouldKeepAbility(name) and not ab:IsAttributeBonus() then
				table.insert(list, name)
			end
		end
	end
	return list
end
