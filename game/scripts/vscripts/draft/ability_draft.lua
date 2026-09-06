-- ability_draft.lua
-- Phase 3: 4+1 ability draft.
-- Players draft 4 regular abilities and 1 ultimate from the pool,
-- excluding abilities banned during the ban phase.

AbilityDraft = AbilityDraft or class({})

local DRAFT_TIME = 60 -- seconds
local REGULAR_SLOTS = 4
local ULTIMATE_SLOTS = 1

function AbilityDraft:constructor()
	self.picks = {} -- playerID -> { regular = {..}, ultimate = "..." }
	self.onComplete = nil
	self.banPhase = nil
end

function AbilityDraft:Start(onComplete)
	print("[AbilityDraft] Starting 4+1 ability draft")
	self.onComplete = onComplete
	self.timeLeft = DRAFT_TIME

	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			self.picks[playerID] = { regular = {}, ultimate = nil }
		end
	end

	self:BroadcastPool()

	self.timer = Timers:CreateTimer(function()
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
	local kv = LoadKeyValues("scripts/npc/npc_abilities_custom.txt")
	local regular = {}
	local ultimate = {}
	if kv and kv.DraftAbilities then
		for ability, _ in pairs(kv.DraftAbilities.Regular or {}) do
			if not self:IsBanned(ability) then table.insert(regular, ability) end
		end
		for ability, _ in pairs(kv.DraftAbilities.Ultimate or {}) do
			if not self:IsBanned(ability) then table.insert(ultimate, ability) end
		end
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
	local p = self.picks[playerID]
	if not p then return end

	local kv = LoadKeyValues("scripts/npc/npc_abilities_custom.txt")
	local isUltimate = kv and kv.DraftAbilities and kv.DraftAbilities.Ultimate and kv.DraftAbilities.Ultimate[ability] ~= nil

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
		if PlayerResource:IsValidPlayerID(playerID) then
			local p = self.picks[playerID]
			if not p or #p.regular < REGULAR_SLOTS or not p.ultimate then return end
		end
	end
	self:Finish()
end

function AbilityDraft:Finish()
	if self.timer then Timers:RemoveTimer(self.timer) end
	CustomGameEventManager:Send_ServerToAllClients("lod_draft_phase_end", {})
	if self.onComplete then self.onComplete() end
end

function AbilityDraft:GetPicks(playerID)
	return self.picks[playerID]
end
