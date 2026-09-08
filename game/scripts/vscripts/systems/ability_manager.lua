-- systems/ability_manager.lua
-- Ability database, blacklist, compatibility, kit application.

AbilityManager = AbilityManager or class({})
local DraftRandom = require("systems/seeded_random")

local KEEP_ABILITY = {
	attribute_bonus = true,
	generic_hidden = true,
}

function AbilityManager:constructor()
	self.db = {}
	self.blacklist = {}
	self.usedAbilities = {}
	self.usedUltimates = {}
	self.engineDefinitions = {}
	self.precachedUnits = {}
	self.precachePending = {}
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
	self.loaded = true

	local function collect(section, outList, outSet, kind)
		if not section then return end
		for ability, enabled in pairs(section) do
			if (enabled == 1 or enabled == "1") and self:ValidateAbility(ability)
				and ((kind == "basic" and self:IsRegular(ability))
					or (kind == "ultimate" and self:IsUltimate(ability))) then
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
		collect(root.Regular, self.pools.regular, self.pools.regularSet, "basic")
		collect(root.Ultimate, self.pools.ultimate, self.pools.ultimateSet, "ultimate")
		collect(root.ExtraUltimate, self.pools.extraUltimate, nil, "ultimate")
		collect(root.DeathReroll, self.pools.deathReroll, nil, "basic")
	end

	if #self.pools.regular == 0 or #self.pools.ultimate == 0 then
		self.pools.regular = {}
		self.pools.ultimate = {}
		self.pools.regularSet = {}
		self.pools.ultimateSet = {}
		for name, def in pairs(self.db) do
			if self:ValidateAbility(name) then
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
	local def = self.upgrades[abilityName] or self.db[abilityName]
	return def and (def.type == "ultimate" or def.Type == "ultimate")
end

function AbilityManager:IsRegular(abilityName)
	self:Load()
	local def = self.upgrades[abilityName] or self.db[abilityName]
	if not def then return false end
	local t = def.type or def.Type
	return t == "basic"
end

function AbilityManager:GetEngineDefinition(name)
	if self.engineDefinitions[name] ~= nil then return self.engineDefinitions[name] or nil end
	-- Stock engine scripts cannot reliably be enumerated by LoadKeyValues.
	if type(GetAbilityKeyValuesByName) ~= "function" then return nil end
	local ok, definition = pcall(GetAbilityKeyValuesByName, name)
	self.engineDefinitions[name] = ok and type(definition) == "table"
		and next(definition) ~= nil and definition or false
	return self.engineDefinitions[name] or nil
end

function AbilityManager:ValidateAbility(name)
	self:Load()
	if type(name) ~= "string" or not name:match("^[%w_]+$") then return false, "invalid_name" end
	local def = self.upgrades[name] or self.db[name]
	if type(def) ~= "table" then return false, "unknown_ability" end
	if self:IsBlacklisted(name) then return false, "blacklisted" end
	if def.enabled == false or def.enabled == 0 or def.enabled == "0"
		or def.Enabled == false or def.Enabled == 0 or def.Enabled == "0" then return false, "disabled" end
	if not self:IsRegular(name) and not self:IsUltimate(name) then return false, "wrong_type" end
	if def.hidden == true or def.hidden == "1" or def.hidden == 1
		or def.internal == true or def.internal == "1" or def.internal == 1
		or name:match("^special_bonus") or name == "attribute_bonus"
		or name == "generic_hidden" then return false, "internal_ability" end
	local engine = self:GetEngineDefinition(name)
	if type(GetAbilityKeyValuesByName) == "function" and not engine then
		return false, "missing_engine_ability"
	end
	local behavior = engine and tonumber(engine.AbilityBehavior)
	local hiddenFlag = DOTA_ABILITY_BEHAVIOR_HIDDEN or 1
	local hidden = engine and (tostring(engine.AbilityBehavior):find("DOTA_ABILITY_BEHAVIOR_HIDDEN", 1, true)
		or behavior and behavior % (hiddenFlag * 2) >= hiddenFlag)
	if engine and (hidden and not self.upgrades[name]
		or tonumber(engine.IsGrantedByScepter) == 1 and not def.upgrade
		or tonumber(engine.IsGrantedByShard) == 1 and not def.upgrade) then
		return false, "internal_ability"
	end
	return true
end

function AbilityManager:IsAvailable(name, playerID)
	if not self:ValidateAbility(name) then return false end
	local owner = self.usedAbilities[name]
	if owner == nil then owner = self.usedUltimates[name] end
	return owner == nil or (playerID ~= nil and owner == playerID)
end

function AbilityManager:Reserve(name, playerID)
	if type(playerID) ~= "number" or playerID < 0 or playerID == math.huge or playerID ~= math.floor(playerID)
		or not self:IsAvailable(name, playerID) then return false end
	local owners = self:IsUltimate(name) and self.usedUltimates or self.usedAbilities
	owners[name] = playerID
	return true
end

function AbilityManager:Release(name, playerID)
	local released = false
	for _, owners in ipairs({ self.usedAbilities, self.usedUltimates }) do
		if owners[name] ~= nil and owners[name] == playerID then
			owners[name], released = nil, true
		end
	end
	return released
end

function AbilityManager:CommitBuild(playerID, basics, ultimates)
	if type(playerID) ~= "number" or playerID < 0 or playerID == math.huge or playerID ~= math.floor(playerID)
		or type(basics) ~= "table" or type(ultimates) ~= "table"
		or #basics ~= 3 or #ultimates ~= 2 then return false end
	local seen = {}
	for index, list in ipairs({ basics, ultimates }) do
		for slot = 1, (index == 1 and 3 or 2) do
			local name = list[slot]
			if seen[name] or not self:IsAvailable(name, playerID)
				or (index == 1 and not self:IsRegular(name))
				or (index == 2 and not self:IsUltimate(name)) then return false end
			seen[name] = true
		end
	end
	-- No ownership is changed until the entire replacement has passed.
	for _, owners in ipairs({ self.usedAbilities, self.usedUltimates }) do
		for name, owner in pairs(owners) do
			if owner == playerID and not seen[name] then owners[name] = nil end
		end
	end
	for _, name in ipairs(basics) do self.usedAbilities[name] = playerID end
	for _, name in ipairs(ultimates) do self.usedUltimates[name] = playerID end
	return true
end

function AbilityManager:GetAbilityMetadata(name)
	if not self:ValidateAbility(name) then return nil end
	local def = self:Get(name)
	local engine = self:GetEngineDefinition(name) or {}
	return {
		name = name, type = def.type or def.Type, enabled = 1,
		display_name = "#DOTA_Tooltip_ability_" .. name,
		description = "#DOTA_Tooltip_ability_" .. name .. "_Description",
		cooldown = engine.AbilityCooldown, mana_cost = engine.AbilityManaCost,
	}
end

local function Names(value)
	local out = {}
	if type(value) == "table" then
		for key, item in pairs(value) do
			if type(key) == "number" then table.insert(out, item)
			elseif item == true or item == 1 or item == "1" then table.insert(out, key) end
		end
		table.sort(out)
		return out
	end
	for name in string.gmatch(type(value) == "string" and value or "", "[^,%s]+") do
		table.insert(out, name)
	end
	return out
end

function AbilityManager:PrecacheBuild(heroName, basics, ultimates, playerID, callback)
	self:Load()
	if type(callback) ~= "function" then return false end
	if type(heroName) ~= "string" or not heroName:match("^npc_dota_hero_[%w_]+$")
		or type(basics) ~= "table" or type(ultimates) ~= "table"
		or #basics ~= 3 or #ultimates ~= 2 then
		callback(false, "invalid_build")
		return false
	end
	local units, visited = { [heroName] = true }, {}
	local function donor(name)
		if visited[name] then return false end
		visited[name] = true
		if not self:ValidateAbility(name) then return false end
		local def = self:Get(name)
		if type(def.hero) == "string" and def.hero:match("^npc_dota_hero_[%w_]+$") then
			units[def.hero] = true
			return true
		end
		-- Upgrade-only spells inherit the donor of their required parent spell.
		local found = false
		for _, required in ipairs(Names(def.requires)) do
			if donor(required) then found = true end
		end
		return found
	end
	for _, list in ipairs({ basics, ultimates }) do
		for _, name in ipairs(list) do
			visited = {}
			if not donor(name) then callback(false, "missing_donor") return false end
		end
	end
	local names = {}
	for name in pairs(units) do table.insert(names, name) end
	table.sort(names)
	local remaining, finished = #names, false
	local function complete(ok)
		if finished then return end
		remaining = remaining - 1
		if not ok or remaining == 0 then
			finished = true
			if ok then callback(true) else callback(false, "precache_failed") end
		end
	end
	for _, name in ipairs(names) do
		if finished then break end
		if self.precachedUnits[name] then
			complete(true)
		elseif self.precachePending[name] then
			table.insert(self.precachePending[name], complete)
		elseif type(PrecacheUnitByNameAsync) ~= "function" then
			complete(false)
		else
			local pending = { complete }
			self.precachePending[name] = pending
			local function loaded(ok)
				local waiters = self.precachePending[name]
				if waiters ~= pending then return end
				self.precachePending[name] = nil
				if ok then self.precachedUnits[name] = true end
				for _, waiter in ipairs(waiters) do
					local success, err = pcall(waiter, ok)
					if not success then print("[AbilityManager] Precache callback failed: " .. tostring(err)) end
				end
			end
			local ok = pcall(PrecacheUnitByNameAsync, name, function() loaded(true) end, playerID or -1)
			if not ok then loaded(false) end
		end
	end
	return true
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
	local valid, reason = self:ValidateAbility(name)
	if not valid then return false, reason end
	local def = self.upgrades[name] or self.db[name]
	if not self:HasRequiredUpgrade(hero, def.upgrade) then return false, "missing_upgrade" end
	for _, required in ipairs(Names(def.requires)) do
		if not kitSet[required] then return false, "missing_dependency" end
	end

	for _, incompatible in ipairs(Names(def.incompatible)) do
		if kitSet[incompatible] then return false, "incompatible" end
	end
	return true
end

function AbilityManager:ValidateHeroRestriction(name, heroName)
	local def = self:Get(name)
	local allowed = Names(def.allowed_heroes or def.hero_allowlist)
	if #allowed > 0 then
		local found = false
		for _, name in ipairs(allowed) do if name == heroName then found = true end end
		if not found then return false, "hero_not_allowed" end
	end
	for _, name in ipairs(Names(def.denied_heroes or def.hero_denylist)) do
		if name == heroName then return false, "hero_denied" end
	end
	return true
end

function AbilityManager:ValidateKit(hero, basics, ultimates, playerID)
	self:Load()
	local heroName
	if type(hero) == "string" then
		heroName, hero = hero, nil
	elseif hero and not hero:IsNull() then
		heroName = hero:GetUnitName()
		playerID = playerID or (hero.GetPlayerOwnerID and hero:GetPlayerOwnerID())
	end
	if not heroName or heroName == "" then return false, "missing_hero" end
	if type(basics) ~= "table" or type(ultimates) ~= "table"
		or #basics ~= 3 or #ultimates ~= 2 then return false, "slot_count" end
	local seen = {}
	for kind, list in ipairs({ basics, ultimates }) do
		for slot = 1, (kind == 1 and 3 or 2) do
			local name = list[slot]
			if not self:IsAvailable(name, playerID) then return false, "unavailable_ability" end
			if seen[name] then return false, "duplicate" end
			if (kind == 1 and not self:IsRegular(name))
				or (kind == 2 and not self:IsUltimate(name)) then return false, "wrong_type" end
			seen[name] = true
		end
	end
	for name in pairs(seen) do
		local ok, reason = self:ValidateAbilityRequirements(name, seen, hero)
		if not ok then return false, reason end
		ok, reason = self:ValidateHeroRestriction(name, heroName)
		if not ok then return false, reason end
	end
	return true
end

function AbilityManager:GetDeathPool(kind, hero, basics, ultimates)
	self:Load()
	local owned, ownedList, out, seen = {}, {}, {}, {}
	if not hero or hero:IsNull() or (kind ~= "basic" and kind ~= "ultimate") then return out end
	local playerID = hero.GetPlayerOwnerID and hero:GetPlayerOwnerID() or nil
	for _, list in ipairs({ basics or {}, ultimates or {} }) do
		for _, name in ipairs(list) do owned[name] = true table.insert(ownedList, name) end
	end
	local function include(name)
		local correctType = (kind == "basic" and self:IsRegular(name))
			or (kind == "ultimate" and self:IsUltimate(name))
		if not seen[name] and not owned[name] and correctType
			and self:IsCompatible(name, ownedList, hero:GetUnitName(), playerID, hero) then
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

function AbilityManager:IsCompatible(candidate, ownedList, heroName, playerID, hero)
	self:Load()
	if type(heroName) ~= "string" and heroName then
		hero = heroName
		if hero:IsNull() then return false, "missing_hero" end
		heroName = hero:GetUnitName()
		playerID = playerID or (hero.GetPlayerOwnerID and hero:GetPlayerOwnerID())
	end
	if not self:IsAvailable(candidate, playerID) then return false, "unavailable_ability" end
	local allowed, reason = self:ValidateHeroRestriction(candidate, heroName)
	if not allowed then return false, reason end
	local owned = {}
	if ownedList then
		for _, a in ipairs(ownedList) do
			if a == candidate or owned[a] then return false, "duplicate" end
			if not self:IsAvailable(a, playerID) then return false, "unavailable_ability" end
			owned[a] = true
			local def = self:Get(a)
			for _, incompatible in ipairs(Names(def.incompatible)) do
				if incompatible == candidate then return false, "incompatible" end
			end
		end
	end
	return self:ValidateAbilityRequirements(candidate, owned, hero)
end

function AbilityManager:Sample(list, count, excludeSet)
	self:Load()
	excludeSet = excludeSet or {}
	local filtered, seen = {}, {}
	for _, a in ipairs(list or {}) do
		if not seen[a] and not excludeSet[a] and self:IsAvailable(a) then
			seen[a] = true
			table.insert(filtered, a)
		end
	end
	if #filtered == 0 then return {} end
	table.sort(filtered)
	for i = #filtered, 2, -1 do
		local j = DraftRandom:Int(1, i)
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
	return false
end

function AbilityManager:RemoveAbilityCleanly(hero, name)
	local ability = hero:FindAbilityByName(name)
	if ability and not ability:IsNull() and ability.GetIntrinsicModifierName then
		local intrinsic = ability:GetIntrinsicModifierName()
		if intrinsic and intrinsic ~= "" then hero:RemoveModifierByName(intrinsic) end
	end
	-- Remove lingering self-passives from removed spells, not unrelated buffs.
	if ability and hero.FindAllModifiers then
		for _, modifier in ipairs(hero:FindAllModifiers()) do
			if modifier.GetAbility and modifier:GetAbility() == ability and modifier.Destroy then
				modifier:Destroy()
			end
		end
	end
	hero:RemoveAbility(name)
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
		self:RemoveAbilityCleanly(hero, name)
	end
end

function AbilityManager:AddAbilityLeveled(hero, abilityName, level)
	if not hero or hero:IsNull() or not abilityName then return nil end
	if not self:ValidateAbility(abilityName) then return nil end
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
		if not desired[name] then self:RemoveAbilityCleanly(hero, name) end
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
		local names, kitSet = {}, {}
		for name in pairs(before) do kitSet[name] = true end
		for name in pairs(desired) do
			table.insert(names, name)
			kitSet[name] = true
		end
		table.sort(names)
		for _, name in ipairs(names) do
			if not self:ValidateAbility(name) then error("invalid_ability:" .. name) end
			if self.upgrades[name] and not self:ValidateAbilityRequirements(name, kitSet, hero) then
				error("missing_upgrade_requirement:" .. name)
			end
			if not hero:FindAbilityByName(name) then
				-- Leave staged spells untrained until every engine handle exists.
				local ability = hero:AddAbility(name)
				if not ability or ability:IsNull() then error("add_failed:" .. name) end
				if ability.IsHidden and ability:IsHidden() and not self.upgrades[name] then
					error("hidden_ability:" .. name)
				end
			end
		end
		for _, name in ipairs(names) do
			if not before[name] then
				local ability = hero:FindAbilityByName(name)
				local maxLevel = ability:GetMaxLevel()
				ability:SetLevel(math.min(desired[name], maxLevel > 0 and maxLevel or 4))
				ability:SetHidden(false)
			end
		end
		for i = 0, hero:GetAbilityCount() - 1 do
			local ability = hero:GetAbilityByIndex(i)
			if ability and not ability:IsNull() then
				local name = ability:GetAbilityName()
				if not before[name] and not desired[name] and not self:ShouldKeepAbility(name) then
					error("unexpected_linked_ability:" .. name)
				end
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
		for _, name in ipairs(added) do self:RemoveAbilityCleanly(hero, name) end
		print("[AbilityManager] Kit preparation failed: " .. tostring(reason))
		return false, "add_failed"
	end
	return true
end

function AbilityManager:ApplyDraftChanges(hero, oldBasics, oldUltimates, basics, ultimates)
	if not hero or hero:IsNull() or hero:IsAlive() then return false, "hero_not_dead" end
	local playerID = hero.GetPlayerOwnerID and hero:GetPlayerOwnerID()
	if type(playerID) ~= "number" or playerID < 0 or playerID == math.huge
		or playerID ~= math.floor(playerID) then return false, "invalid_owner" end
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
	local reserved = {}
	local function releaseNewReservations()
		for _, name in ipairs(reserved) do self:Release(name, playerID) end
	end
	for _, list in ipairs({ basics, ultimates }) do
		for _, name in ipairs(list) do
			local unowned = self.usedAbilities[name] == nil and self.usedUltimates[name] == nil
			if not self:Reserve(name, playerID) then
				releaseNewReservations()
				return false, "unavailable_ability"
			end
			if unowned then table.insert(reserved, name) end
		end
	end
	local prepared, why = self:PrepareAbilities(hero, desired)
	if not prepared then
		releaseNewReservations()
		return false, why
	end
	for _, change in ipairs(removals) do
		self:RemoveAbilityCleanly(hero, change.name)
		local gained = hero:FindAbilityByName(change.gained)
		local maxLevel = gained:GetMaxLevel()
		gained:SetLevel(math.min(desired[change.gained], maxLevel > 0 and maxLevel or 4))
		gained:SetHidden(false)
		if gained.SetAbilityIndex then gained:SetAbilityIndex(change.index) end
	end
	-- Unchanged handles are untouched: levels, charges and running cooldowns survive.
	-- All five names are reserved by this owner; no asynchronous work occurs here.
	return self:CommitBuild(playerID, basics, ultimates)
end

function AbilityManager:ReplaceAbility(hero, oldName, newName)
	if not hero or hero:IsNull() then return false end
	local level = 1
	local old = hero:FindAbilityByName(oldName)
	if old then
		level = math.max(1, old:GetLevel())
	end
	if not self:PrepareAbilities(hero, { [newName] = level }) then return false end
	if oldName ~= newName then self:RemoveAbilityCleanly(hero, oldName) end
	local gained = hero:FindAbilityByName(newName)
	local maxLevel = gained:GetMaxLevel()
	gained:SetLevel(math.min(level, maxLevel > 0 and maxLevel or 4))
	gained:SetHidden(false)
	return true
end

function AbilityManager:ListHeroAbilities(hero)
	local list = {}
	if not hero or hero:IsNull() then return list end
	for i = 0, hero:GetAbilityCount() - 1 do
		local ab = hero:GetAbilityByIndex(i)
		if ab and not ab:IsNull() then
			local name = ab:GetAbilityName()
			if not self:ShouldKeepAbility(name) then
				table.insert(list, name)
			end
		end
	end
	return list
end
