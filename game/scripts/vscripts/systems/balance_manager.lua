-- systems/balance_manager.lua
-- Power budget checks. Data comes from scripts/config/balance.kv
-- and offline Python tools — never live AI during a match.

BalanceManager = BalanceManager or class({})

function BalanceManager:constructor(abilityManager)
	self.abilityManager = abilityManager
	self.maxBudget = 20
end

function BalanceManager:Load()
	local kv = LoadKeyValues("scripts/config/balance.kv")
	if kv and kv.Settings and kv.Settings.MaxBudget then
		self.maxBudget = tonumber(kv.Settings.MaxBudget) or 20
	end
end

function BalanceManager:Score(abilityName)
	if not self.abilityManager then return 0 end
	local def = self.abilityManager:Get(abilityName)
	if def and def.power_score then
		return tonumber(def.power_score) or 0
	end
	return 0
end

function BalanceManager:Total(abilityNames)
	local sum = 0
	for _, name in ipairs(abilityNames or {}) do
		sum = sum + self:Score(name)
	end
	return sum
end

function BalanceManager:WithinBudget(abilityNames)
	return self:Total(abilityNames) <= self.maxBudget
end
