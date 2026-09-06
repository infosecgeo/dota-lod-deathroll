-- ban_phase.lua
-- Phase 1: each player bans one ability before the draft begins.

BanPhase = BanPhase or class({})

local BAN_TIME = 30 -- seconds

function BanPhase:constructor()
	self.bans = {} -- ability -> true
	self.playerBanned = {} -- playerID -> true
	self.onComplete = nil
end

function BanPhase:Start(onComplete)
	print("[BanPhase] Starting ban phase")
	self.onComplete = onComplete
	self.timeLeft = BAN_TIME
	self:BroadcastPool()
	self.timer = Timers:CreateTimer(function()
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
	local pool = LoadKeyValues("scripts/npc/npc_abilities_custom.txt")
	local regular = pool and pool.DraftAbilities and pool.DraftAbilities.Regular or {}
	local abilities = {}
	for ability, _ in pairs(regular) do
		table.insert(abilities, ability)
	end
	CustomGameEventManager:Send_ServerToAllClients("lod_ban_phase_start", {
		abilities = table.concat(abilities, ","),
		time = BAN_TIME,
	})
end

function BanPhase:HandleBan(playerID, ability)
	if self.playerBanned[playerID] then return end
	if self.bans[ability] then return end -- already banned
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
	print("[BanPhase] Ban phase complete")
	if self.timer then Timers:RemoveTimer(self.timer) end
	CustomGameEventManager:Send_ServerToAllClients("lod_ban_phase_end", {})
	if self.onComplete then self.onComplete() end
end
