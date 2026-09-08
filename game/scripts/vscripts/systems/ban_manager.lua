-- systems/ban_manager.lua
-- Server-validated hero ban.

BanManager = BanManager or class({})

local BAN_TIME = 50

function BanManager:constructor(heroManager)
	self.heroManager = heroManager
	self.playerBanned = {}
	self.finished = false
	self.onComplete = nil
	self.timeLeft = BAN_TIME
	self.timer = nil
	self.active = false
end

function BanManager:Start(onComplete)
	self:Cancel()
	print("[BanManager] Start — hero ban, " .. BAN_TIME .. "s")
	self.onComplete = onComplete
	self.finished = false
	self.playerBanned = {}
	self.timeLeft = BAN_TIME
	self.active = true
	self.deadline = Time() + BAN_TIME
	PlayerState:ForEachParticipant(function(_, record) record.draftState = "BAN_HEROES" end)

	if self.heroManager then
		self.heroManager:LoadPool()
	end

	local pool = (self.heroManager and self.heroManager:LoadPool()) or {}
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_start", {
		time = BAN_TIME,
		heroes = table.concat(pool, ","),
		banned = table.concat(self.heroManager:GetBannedList(), ","),
		locked = false,
	})

	self.timer = Timers:CreateTimer(function()
		if not self.active or self.finished then return nil end
		self.timeLeft = math.max(0, math.ceil(self.deadline - Time()))
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_timer", { time = self.timeLeft })
		if GameState.owner and GameState.owner.PublishRoster then GameState.owner:PublishRoster() end
		if self.timeLeft <= 0 then
			self:Finish()
			return nil
		end
		return 1
	end, false)
end

function BanManager:HandleBan(playerID, heroName)
	if not self.active or self.finished then return end
	if not GameState or not GameState:Is(GameState.BAN) then return end
	if not PlayerState:IsParticipant(playerID) or Time() >= self.deadline then return end
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
	self:SyncPlayer(playerID)
	if GameState.owner and GameState.owner.PublishRoster then GameState.owner:PublishRoster() end

	-- Disconnected participants retain their slot until the server deadline.
	local pending = false
	if PlayerState then
		PlayerState:ForEachParticipant(function(pid, _)
			if not self.playerBanned[pid] then pending = true end
		end)
	end
	if not pending then
		self:Finish()
	end
end

function BanManager:Finish()
	if not self.active or self.finished then return end
	PlayerState:ForEachParticipant(function(playerID, record)
		if self.playerBanned[playerID] then return end
		for _, hero in ipairs(self.heroManager:LoadPool()) do
			if self.heroManager:Ban(hero, playerID) then
				self.playerBanned[playerID] = true
				table.insert(record.bannedHeroes, hero)
				CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_banned", { playerID = playerID, hero = hero })
				break
			end
		end
	end)
	self.finished = true
	self.active = false
	if self.timer then Timers:RemoveTimer(self.timer) self.timer = nil end
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_end", {
		banned = table.concat((self.heroManager and self.heroManager:GetBannedList()) or {}, ","),
	})
	print("[BanManager] Complete")
	local cb = self.onComplete
	self.onComplete = nil
	if cb then cb() end
end

function BanManager:Cancel()
	self.active = false
	self.finished = true
	self.onComplete = nil
	if self.timer then Timers:RemoveTimer(self.timer) self.timer = nil end
end

function BanManager:SyncPlayer(playerID)
	if not self.active or self.finished then return end
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local record = PlayerState and PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ban_start", {
		time = self.timeLeft,
		heroes = table.concat(self.heroManager:LoadPool(), ","),
		banned = table.concat(self.heroManager:GetBannedList(), ","),
		picked = table.concat(record and record.bannedHeroes or {}, ","),
		locked = self.playerBanned[playerID] == true,
	})
end
