-- systems/ban_manager.lua
-- Phase 3: 50s server-validated hero ban.

BanManager = BanManager or class({})

local BAN_TIME = 50

function BanManager:constructor(heroManager)
	self.heroManager = heroManager
	self.playerBanned = {}
	self.finished = false
	self.onComplete = nil
	self.timeLeft = BAN_TIME
	self.timer = nil
end

function BanManager:Start(onComplete)
	print("[BanManager] Start — hero ban, " .. BAN_TIME .. "s")
	self.onComplete = onComplete
	self.finished = false
	self.playerBanned = {}
	self.timeLeft = BAN_TIME

	if self.heroManager then
		self.heroManager:LoadPool()
	end

	local pool = (self.heroManager and self.heroManager:LoadPool()) or {}
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_start", {
		time = BAN_TIME,
		heroes = table.concat(pool, ","),
	})

	self.timer = Timers:CreateTimer(function()
		if self.finished then return nil end
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:Finish()
			return nil
		end
		return 1
	end)
end

function BanManager:HandleBan(playerID, heroName)
	if self.finished then return end
	if not GameState or not GameState:Is(GameState.BAN) then return end
	if playerID == nil then return end
	if self.playerBanned[playerID] then return end

	local ok, reason = self.heroManager:Ban(heroName, playerID)
	if not ok then
		print(string.format("[BanManager] Reject ban from %s: %s (%s)",
			tostring(playerID), tostring(heroName), tostring(reason)))
		return
	end

	self.playerBanned[playerID] = true
	local record = PlayerState and PlayerState:Get(playerID)
	if record then
		table.insert(record.bannedHeroes, heroName)
	end
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_banned", {
		playerID = playerID,
		hero = heroName,
	})

	-- Early finish when every connected player has banned
	local pending = false
	if PlayerState then
		PlayerState:ForEachConnected(function(pid, _)
			if not self.playerBanned[pid] then pending = true end
		end)
	end
	if not pending then
		self:Finish()
	end
end

function BanManager:Finish()
	if self.finished then return end
	self.finished = true
	if self.timer then Timers:RemoveTimer(self.timer) self.timer = nil end
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_end", {
		banned = table.concat((self.heroManager and self.heroManager:GetBannedList()) or {}, ","),
	})
	print("[BanManager] Complete")
	if self.onComplete then self.onComplete() end
end
