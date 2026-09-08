-- systems/ban_manager.lua
-- Server-validated hero ban.

BanManager = BanManager or class({})

local BAN_TIME = 60
-- Keep BAN_HEROES on screen long enough for the panel to open before an
-- all-ready early finish (bots ban quickly once the phase is live).
local BAN_MIN_VISIBLE = 5

function BanManager:constructor(heroManager)
	self.heroManager = heroManager
	self.playerBanned = {}
	self.finished = false
	self.onComplete = nil
	self.timeLeft = BAN_TIME
	self.timer = nil
	self.active = false
end

function BanManager:BanStartPayload(locked)
	local pool = (self.heroManager and self.heroManager:LoadPool()) or {}
	return {
		time = self.timeLeft or BAN_TIME,
		heroes = table.concat(pool, ","),
		banned = table.concat((self.heroManager and self.heroManager:GetBannedList()) or {}, ","),
		locked = locked == true,
	}
end

function BanManager:BroadcastStart(force)
	if not self.active or self.finished then return end
	-- Re-send the full ban panel payload so late/failed nettable clients still open BAN_HEROES.
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_state", {
		state = GameState.BAN, name = "BAN_HEROES",
	})
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_start", self:BanStartPayload(false))
	if force and GameState.owner and GameState.owner.PublishRoster then
		GameState.owner:PublishRoster()
	end
end

function BanManager:Start(onComplete)
	self:Cancel()
	print("[BanManager] Start — hero ban, " .. BAN_TIME .. "s")
	self.onComplete = onComplete
	self.finished = false
	self.playerBanned = {}
	self.timeLeft = BAN_TIME
	self.active = true
	self.startedAt = Time()
	self.deadline = Time() + BAN_TIME
	self.rebroadcasts = 0
	PlayerState:ForEachParticipant(function(_, record) record.draftState = "BAN_HEROES" end)

	if self.heroManager then
		self.heroManager:LoadPool()
	end

	self:BroadcastStart(true)

	self.timer = Timers:CreateTimer(function()
		if not self.active or self.finished then return nil end
		self.timeLeft = math.max(0, math.ceil(self.deadline - Time()))
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_ban_timer", { time = self.timeLeft })
		-- First few seconds: rebroadcast the ban panel so panorama that missed
		-- the initial event (or failed the nettable snapshot) still opens it.
		if self.rebroadcasts < 6 and (self.rebroadcasts == 0 or self.timeLeft % 1 == 0) then
			self.rebroadcasts = self.rebroadcasts + 1
			self:BroadcastStart(false)
		end
		if GameState.owner and GameState.owner.PublishRoster then GameState.owner:PublishRoster() end
		if self.timeLeft <= 0 then
			self:Finish()
			return nil
		end
		if self:AllParticipantsBanned() and self:MinVisibleElapsed() then
			self:Finish()
			return nil
		end
		return 0.25
	end, false)
end

function BanManager:MinVisibleElapsed()
	return self.startedAt ~= nil and Time() >= (self.startedAt + BAN_MIN_VISIBLE)
end

function BanManager:AllParticipantsBanned()
	local pending = false
	if PlayerState then
		PlayerState:ForEachParticipant(function(pid, _)
			if not self.playerBanned[pid] then pending = true end
		end)
	end
	return not pending
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

	-- Early finish only after the ban panel has had time to appear. Bots alone
	-- must never collapse BAN_HEROES into hero select before humans see it.
	if self:AllParticipantsBanned() and self:MinVisibleElapsed() then
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
	local payload = self:BanStartPayload(self.playerBanned[playerID] == true)
	payload.picked = table.concat(record and record.bannedHeroes or {}, ",")
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_state", {
		state = GameState.BAN, name = "BAN_HEROES",
	})
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ban_start", payload)
end
