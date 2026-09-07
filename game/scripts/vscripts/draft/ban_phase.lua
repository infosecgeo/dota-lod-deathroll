-- ban_phase.lua
-- Phase 1: each player bans one ability before the draft begins.

BanPhase = BanPhase or class({})

local BAN_TIME = 30 -- seconds

function BanPhase:constructor()
	self.bans = {} -- ability -> true
	self.playerBanned = {} -- playerID -> true
	self.onComplete = nil
	self.finished = false
end

function BanPhase:LoadRegularPool()
	local kv = LoadKeyValues("scripts/npc/draft_abilities.txt")
	if kv and kv.DraftAbilities then
		kv = kv.DraftAbilities
	end
	local abilities = {}
	local regular = kv and kv.Regular or {}
	for ability, enabled in pairs(regular) do
		if enabled == 1 or enabled == "1" then
			table.insert(abilities, ability)
		end
	end
	table.sort(abilities)
	return abilities
end

function BanPhase:Start(onComplete)
	print("[BanPhase] Starting ban phase")
	self.onComplete = onComplete
	self.timeLeft = BAN_TIME
	self.finished = false
	self:BroadcastPool()
	self.timer = Timers:CreateTimer(function()
		if self.finished then return nil end
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("lod_ban_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:Finish()
			return nil
		end
		return 1
	end)
end

function BanPhase:BroadcastPool()
	local abilities = self:LoadRegularPool()
	print(string.format("[BanPhase] Broadcasting %d ban-able abilities", #abilities))
	CustomGameEventManager:Send_ServerToAllClients("lod_ban_phase_start", {
		abilities = table.concat(abilities, ","),
		time = BAN_TIME,
	})
end

function BanPhase:HandleBan(playerID, ability)
	if self.finished then return end
	if self.playerBanned[playerID] then return end
	if not ability or ability == "" then return end
	if self.bans[ability] then return end
	self.bans[ability] = true
	self.playerBanned[playerID] = true
	CustomGameEventManager:Send_ServerToAllClients("lod_ability_banned", {
		playerID = playerID,
		ability = ability,
	})
	print(string.format("[BanPhase] Player %d banned %s", playerID, tostring(ability)))
end

function BanPhase:IsBanned(ability)
	return self.bans[ability] == true
end

function BanPhase:GetBannedAbilities()
	local list = {}
	for ability, _ in pairs(self.bans) do
		table.insert(list, ability)
	end
	return list
end

function BanPhase:Finish()
	if self.finished then return end
	self.finished = true
	print("[BanPhase] Ban phase complete")
	if self.timer then Timers:RemoveTimer(self.timer) end
	CustomGameEventManager:Send_ServerToAllClients("lod_ban_phase_end", {})
	if self.onComplete then self.onComplete() end
end
