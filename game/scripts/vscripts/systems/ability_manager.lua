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
	local upgrades = LoadKeyValues("scripts/config/upgrade_abilities.kv")

	self.db = (abilities and (abilities.Abilities or abilities)) or {}
	self.upgrades = (upgrades and (upgrades.UpgradeAbilities or upgrades)) or {}
	self.blacklist = {}
	if blacklist then
		for name, enabled in pairs(blacklist.Blacklist or blacklist) do
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
	return self.upgrades[abilityName] or self.db[abilityName]
end

function AbilityManager:GetPools()
	self:Load()
	return self.pools
end

function AbilityManager:IsUltimate(abilityName)
	self:Load()
	if self.upgrades[abilityName] then return self.upgrades[abilityName].type == "ultimate" end
	if self.pools.ultimateSet[abilityName] then return true end
	local def = self.db[abilityName]
	return def and (def.type == "ultimate" or def.Type == "ultimate")
end

function AbilityManager:IsRegular(abilityName)
	self:Load()
	if self.upgrades[abilityName] then return self.upgrades[abilityName].type == "basic" end
	if self.pools.regularSet[abilityName] then return true end
	local def = self.db[abilityName]
	if not def then return false end
	local t = def.type or def.Type
	return t ~= "ultimate"
end

local function Names(value)
	local out = {}
	for name in string.gmatch(type(value) == "string" and value or "", "[^,%s]+") do
		table.insert(out, name)
	end
	return out
end

function AbilityManager:HasRequiredUpgrade(hero, requirement)
	if not requirement then return true end
	if not hero or hero:IsNull() then return false end
	if requirement == "scepter" then
		return hero.HasScepter ~= nil and hero:HasScepter()
	elseif requirement == "shard" then
		return (hero.HasShard ~= nil and hero:HasShard())
			or (hero.HasModifier ~= nil and hero:HasModifier("modifier_item_aghanims_shard"))
	end
	return false
end

function AbilityManager:ValidateAbilityRequirements(name, kitSet, hero)
	local def = self.upgrades[name] or self.db[name] or {}
	if not self:HasRequiredUpgrade(hero, def.upgrade) then return false, "missing_upgrade" end
	for _, required in ipairs(Names(def.requires)) do
		if not kitSet[required] then return false, "missing_dependency" end
	end
	for _, incompatible in ipairs(Names(def.incompatible)) do
		if kitSet[incompatible] then return false, "incompatible" end
	end
	return true
end

function AbilityManager:ValidateKit(hero, basics, ultimates)
	self:Load()
	if not hero or hero:IsNull() then return false, "missing_hero" end
	if type(basics) ~= "table" or type(ultimates) ~= "table"
		or #basics ~= 3 or #ultimates ~= 2 then return false, "slot_count" end
	local seen = {}
	for kind, list in pairs({ basic = basics, ultimate = ultimates }) do
		for _, name in ipairs(list) do
			if type(name) ~= "string" or self:IsBlacklisted(name) then return false, "invalid_ability" end
			if seen[name] then return false, "duplicate" end
			if (kind == "basic" and not self:IsRegular(name))
				or (kind == "ultimate" and not self:IsUltimate(name)) then return false, "wrong_type" end
			seen[name] = true
		end
	end
	for name in pairs(seen) do
		local ok, reason = self:ValidateAbilityRequirements(name, seen, hero)
		if not ok then return false, reason end
	end
	return true
end

function AbilityManager:GetDeathPool(kind, hero, basics, ultimates)
	self:Load()
	local owned, out, seen = {}, {}, {}
	for _, list in ipairs({ basics or {}, ultimates or {} }) do
		for _, name in ipairs(list) do owned[name] = true end
	end
	local function include(name)
		local correctType = (kind == "basic" and self:IsRegular(name))
			or (kind == "ultimate" and self:IsUltimate(name))
		if not seen[name] and not owned[name] and not self:IsBlacklisted(name) and correctType
			and self:ValidateAbilityRequirements(name, owned, hero) then
			seen[name] = true
			table.insert(out, name)
		end
	end
	-- All players use the global pools, never their selected hero's native spells.
	for _, name in ipairs(kind == "basic" and self.pools.regular or self.pools.ultimate) do include(name) end
	for name in pairs(self.upgrades) do include(name) end
	table.sort(out)
	return out
end

function AbilityManager:IsCompatible(candidate, ownedList, heroName)
	self:Load()
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
	local ok, reason = self:ValidateKit(hero, basics, ultimates)
	if not ok then return false, reason end
	local desired = {}
	for _, list in ipairs({ basics, ultimates }) do
		for _, name in ipairs(list) do desired[name] = 1 end
	end
	local prepared, why = self:PrepareAbilities(hero, desired)
	if not prepared then return false, why end
	for _, name in ipairs(self:ListHeroAbilities(hero)) do
		if not desired[name] then hero:RemoveAbility(name) end
	end
	local index = 0
	for _, list in ipairs({ basics, ultimates }) do
		for _, name in ipairs(list) do
			local ability = hero:FindAbilityByName(name)
			ability:SetLevel(1)
			ability:SetHidden(false)
			if ability.SetAbilityIndex then ability:SetAbilityIndex(index) end
			index = index + 1
		end
	end
	print(string.format("[AbilityManager] Applied kit to %s: %d basic, %d ult",
		hero:GetUnitName(), #basics, #ultimates))
	return true
end

-- Add first, remove last: a missing/unsupported engine ability must not destroy
-- the old kit. Snapshot all names because AddAbility can create linked abilities.
function AbilityManager:PrepareAbilities(hero, desired)
	local before = {}
	for i = 0, hero:GetAbilityCount() - 1 do
		local ability = hero:GetAbilityByIndex(i)
		if ability and not ability:IsNull() then before[ability:GetAbilityName()] = true end
	end
	local ok, reason = pcall(function()
		for name, level in pairs(desired) do
			if not hero:FindAbilityByName(name) then
				local ability = self:AddAbilityLeveled(hero, name, level)
				if not ability or ability:IsNull() then error("add_failed:" .. name) end
			end
		end
	end)
	if not ok then
		local added = {}
		for i = 0, hero:GetAbilityCount() - 1 do
			local ability = hero:GetAbilityByIndex(i)
			if ability and not ability:IsNull() and not before[ability:GetAbilityName()] then
				table.insert(added, ability:GetAbilityName())
			end
		end
		for _, name in ipairs(added) do hero:RemoveAbility(name) end
		print("[AbilityManager] Kit preparation failed: " .. tostring(reason))
		return false, "add_failed"
	end
	return true
end

function AbilityManager:ApplyDraftChanges(hero, oldBasics, oldUltimates, basics, ultimates)
	if not hero or hero:IsNull() or hero:IsAlive() then return false, "hero_not_dead" end
	local ok, reason = self:ValidateKit(hero, basics, ultimates)
	if not ok then return false, reason end
	if type(oldBasics) ~= "table" or type(oldUltimates) ~= "table"
		or #oldBasics ~= #basics or #oldUltimates ~= #ultimates then return false, "slot_count" end
	local oldSet = {}
	for _, list in ipairs({ oldBasics, oldUltimates }) do
		for _, name in ipairs(list) do
			if oldSet[name] then return false, "duplicate_old_ability" end
			oldSet[name] = true
		end
	end
	local desired, removals = {}, {}
	for _, pair in ipairs({ { oldBasics, basics }, { oldUltimates, ultimates } }) do
		for i, oldName in ipairs(pair[1]) do
			local old = hero:FindAbilityByName(oldName)
			if not old or old:IsNull() then return false, "missing_old_ability" end
			local newName = pair[2][i]
			if oldName ~= newName then
				if oldSet[newName] then return false, "owned_ability" end
				desired[newName] = math.max(1, old:GetLevel())
				table.insert(removals, { name = oldName, gained = newName, index = old:GetAbilityIndex() })
			end
		end
	end
	local prepared, why = self:PrepareAbilities(hero, desired)
	if not prepared then return false, why end
	for _, change in ipairs(removals) do
		hero:RemoveAbility(change.name)
		local gained = hero:FindAbilityByName(change.gained)
		local maxLevel = gained:GetMaxLevel()
		gained:SetLevel(math.min(desired[change.gained], maxLevel > 0 and maxLevel or 4))
		gained:SetHidden(false)
		if gained.SetAbilityIndex then gained:SetAbilityIndex(change.index) end
	end
	-- Unchanged handles are untouched: levels, charges and running cooldowns survive.
	return true
end

function AbilityManager:ReplaceAbility(hero, oldName, newName)
	if not hero or hero:IsNull() then return false end
	local level = 1
	local old = hero:FindAbilityByName(oldName)
	if old then
		level = math.max(1, old:GetLevel())
	end
	if not self:PrepareAbilities(hero, { [newName] = level }) then return false end
	if oldName ~= newName then hero:RemoveAbility(oldName) end
	return true
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
