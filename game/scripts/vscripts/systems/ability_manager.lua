-- systems/ability_manager.lua
-- Ability database / compatibility / blacklist (Phase 5+).
-- V0.1: load scaffolding only; native hero abilities stay intact.

AbilityManager = AbilityManager or class({})

function AbilityManager:constructor()
	self.db = {}
	self.blacklist = {}
	self.loaded = false
end

function AbilityManager:Load()
	if self.loaded then return self.db end

	local abilities = LoadKeyValues("scripts/config/abilities.kv")
	local blacklist = LoadKeyValues("scripts/config/blacklist.kv")
	local balance = LoadKeyValues("scripts/config/balance.kv")

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
	self.loaded = true

	local count = 0
	for _ in pairs(self.db) do count = count + 1 end
	print(string.format("[AbilityManager] Loaded %d ability defs, %d blacklisted",
		count, self:CountBlacklist()))
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

-- Compatibility engine placeholder (Phase 11–14)
function AbilityManager:IsCompatible(candidate, ownedList, heroName)
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
