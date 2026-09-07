-- LEGACY (not required by V0.1). Kept for reference until systems/* fully replace this.
-- ability_draft.lua
-- Phase 3: 4+1 ability draft from the LOD hero pool skills.

AbilityDraft = AbilityDraft or class({})

local DRAFT_TIME = 60 -- seconds
local REGULAR_SLOTS = 4

function AbilityDraft:constructor()
	self.picks = {} -- playerID -> { regular = {..}, ultimate = "..." }
	self.onComplete = nil
	self.poolCache = nil
end

function AbilityDraft:LoadPools()
	if self.poolCache then return self.poolCache end
	local kv = LoadKeyValues("scripts/npc/draft_abilities.txt")
	if kv and kv.DraftAbilities then
		kv = kv.DraftAbilities
	end
	self.poolCache = {
		regular = {},
		ultimate = {},
		regularSet = {},
		ultimateSet = {},
	}
	if kv then
		for ability, enabled in pairs(kv.Regular or {}) do
			if enabled == 1 or enabled == "1" then
				table.insert(self.poolCache.regular, ability)
				self.poolCache.regularSet[ability] = true
			end
		end
		for ability, enabled in pairs(kv.Ultimate or {}) do
			if enabled == 1 or enabled == "1" then
				table.insert(self.poolCache.ultimate, ability)
				self.poolCache.ultimateSet[ability] = true
			end
		end
	end
	table.sort(self.poolCache.regular)
	table.sort(self.poolCache.ultimate)
	print(string.format("[AbilityDraft] Pool loaded: %d regular, %d ultimate",
		#self.poolCache.regular, #self.poolCache.ultimate))
	return self.poolCache
end

function AbilityDraft:Start(onComplete)
	print("[AbilityDraft] Starting 4+1 ability draft")
	self.onComplete = onComplete
	self.timeLeft = DRAFT_TIME
	self.finished = false
	self.poolCache = nil

	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			self.picks[playerID] = { regular = {}, ultimate = nil }
		end
	end

	self:BroadcastPool()

	self.timer = Timers:CreateTimer(function()
		if self.finished then return nil end
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("lod_draft_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:Finish()
			return nil
		end
		return 1
	end)
end

function AbilityDraft:BroadcastPool()
	local pools = self:LoadPools()
	local regular = {}
	local ultimate = {}
	for _, ability in ipairs(pools.regular) do
		if not self:IsBanned(ability) then table.insert(regular, ability) end
	end
	for _, ability in ipairs(pools.ultimate) do
		if not self:IsBanned(ability) then table.insert(ultimate, ability) end
	end
	CustomGameEventManager:Send_ServerToAllClients("lod_draft_phase_start", {
		regular = table.concat(regular, ","),
		ultimate = table.concat(ultimate, ","),
		time = DRAFT_TIME,
	})
end

function AbilityDraft:IsBanned(ability)
	local gm = GameRules.LODDeathroll
	return gm and gm.banPhase and gm.banPhase:IsBanned(ability)
end

function AbilityDraft:HandlePick(playerID, ability)
	if self.finished then return end
	local p = self.picks[playerID]
	if not p or not ability then return end
	if self:IsBanned(ability) then return end

	local pools = self:LoadPools()
	local isUltimate = pools.ultimateSet[ability] == true
	local isRegular = pools.regularSet[ability] == true
	if not isUltimate and not isRegular then return end

	if p.ultimate == ability then return end
	for _, a in ipairs(p.regular) do
		if a == ability then return end
	end

	if isUltimate then
		if p.ultimate then return end
		p.ultimate = ability
	else
		if #p.regular >= REGULAR_SLOTS then return end
		table.insert(p.regular, ability)
	end

	print(string.format("[AbilityDraft] Player %d picked %s", playerID, tostring(ability)))

	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "lod_ability_picked", {
			ability = ability,
			regularCount = #p.regular,
			hasUltimate = p.ultimate ~= nil,
		})
	end

	self:CheckDone()
end

function AbilityDraft:CheckDone()
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID)
			and PlayerResource:GetConnectionState(playerID) ~= DOTA_CONNECTION_STATE_ABANDONED then
			local p = self.picks[playerID]
			if not p or #p.regular < REGULAR_SLOTS or not p.ultimate then return end
		end
	end
	self:Finish()
end

function AbilityDraft:Finish()
	if self.finished then return end
	self.finished = true
	if self.timer then Timers:RemoveTimer(self.timer) end

	local pools = self:LoadPools()
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			local p = self.picks[playerID]
			if not p then
				p = { regular = {}, ultimate = nil }
				self.picks[playerID] = p
			end
			local guard = 0
			while #p.regular < REGULAR_SLOTS and #pools.regular > 0 and guard < 100 do
				guard = guard + 1
				local ability = pools.regular[RandomInt(1, #pools.regular)]
				local dup = false
				for _, a in ipairs(p.regular) do if a == ability then dup = true break end end
				if not dup and ability ~= p.ultimate and not self:IsBanned(ability) then
					table.insert(p.regular, ability)
				end
			end
			if not p.ultimate and #pools.ultimate > 0 then
				p.ultimate = pools.ultimate[RandomInt(1, #pools.ultimate)]
			end
		end
	end

	CustomGameEventManager:Send_ServerToAllClients("lod_draft_phase_end", {})
	if self.onComplete then self.onComplete() end
end

function AbilityDraft:GetPicks(playerID)
	return self.picks[playerID]
end
