-- Per-death transactional draft. Choices never change the normal respawn deadline.
RespawnManager = RespawnManager or class({})

local DEATH_DRAFT_TIME = 25
local DEATH_OFFER_COUNT = 6

local function Copy(list)
	local result = {}
	for _, name in ipairs(list or {}) do table.insert(result, name) end
	return result
end

local function Contains(list, name)
	for _, value in ipairs(list or {}) do
		if value == name then return true end
	end
	return false
end

local function Same(a, b)
	if not a or not b or #a ~= #b then return false end
	for i, name in ipairs(a) do
		if b[i] ~= name then return false end
	end
	return true
end

local function Playing()
	return GameState and GameState:Is(GameState.PLAYING)
end

function RespawnManager:constructor(abilityManager, rerollManager)
	self.abilityManager = abilityManager
	self.rerollManager = rerollManager
	self.enabledDraft = true
	self.pending = {}
	self.nextDraftId = 0
end

function RespawnManager:NextDraftId()
	self.nextDraftId = self.nextDraftId + 1
	return self.nextDraftId
end

function RespawnManager:OnHeroDeath(hero)
	if not hero or hero:IsNull() or not hero:IsRealHero() or hero:IsAlive() then return end
	local playerID = hero:GetPlayerOwnerID()
	if not PlayerResource:IsValidPlayerID(playerID)
		or PlayerResource:GetSelectedHeroEntity(playerID) ~= hero or self.pending[playerID] then return end
	if PlayerState then
		PlayerState:IncDeath(playerID)
		PlayerState:ResetRespawnRerolls(playerID)
	end
	if self.enabledDraft and Playing() then self:StartDeathDraft(playerID, hero) end
end

function RespawnManager:StartDeathDraft(playerID, hero)
	if self.pending[playerID] or not Playing() or not self.abilityManager
		or not hero or hero:IsNull() or hero:IsAlive() then return false end
	local record = PlayerState and PlayerState:Get(playerID)
	if not record or not record.abilities or #record.abilities.basic ~= 3
		or #record.abilities.ultimate ~= 2 then return false end
	local now = GameRules:GetGameTime()
	local remaining = math.max(0, hero:GetTimeUntilRespawn())
	if remaining <= 0 then return false end
	local s = {
		playerID = playerID,
		draftId = self:NextDraftId(),
		slots = { basic = Copy(record.abilities.basic), ultimate = Copy(record.abilities.ultimate) },
		candidate = { basic = Copy(record.abilities.basic), ultimate = Copy(record.abilities.ultimate) },
		offers = { basic = {}, ultimate = {} },
		hero = hero,
		expiresAt = now + math.min(DEATH_DRAFT_TIME, remaining),
	}
	self.pending[playerID] = s
	record.respawnPending = true
	record.draftState = "RESPAWN_DRAFT"
	PlayerState:ResetRespawnRerolls(playerID)
	self:RollOffers(s)
	self:SendDeathDraft(playerID)
	s.timer = Timers:CreateTimer(function()
		if self.pending[playerID] ~= s then return nil end
		if not Playing() or s.hero:IsNull() or s.hero:IsAlive()
			or PlayerResource:GetSelectedHeroEntity(playerID) ~= s.hero then
			self:FinishDeathDraft(playerID, false, true)
			return nil
		end
		local remaining = s.expiresAt - GameRules:GetGameTime()
		if remaining <= 0 then
			self:FinishDeathDraft(playerID, true, false)
			return nil
		end
		self:SendDeathDraft(playerID)
		return math.min(1, remaining)
	end)
	return true
end

function RespawnManager:RollOffers(s)
	for _, kind in ipairs({ "basic", "ultimate" }) do
		local source = self.abilityManager:GetDeathPool(kind, s.hero, s.slots.basic, s.slots.ultimate)
		local available = {}
		for _, name in ipairs(source) do
			if self.abilityManager:IsAvailable(name, s.playerID) then
				table.insert(available, name)
			end
		end
		local exclude = {}
		for _, name in ipairs(s.offers[kind]) do exclude[name] = true end
		s.offers[kind] = self.abilityManager:Sample(available, DEATH_OFFER_COUNT, exclude)
		if #s.offers[kind] == 0 then
			s.offers[kind] = self.abilityManager:Sample(available, DEATH_OFFER_COUNT, {})
		end
	end
end

function RespawnManager:GetSession(playerID, draftId)
	local s = self.pending[playerID]
	if not s or tonumber(draftId) ~= s.draftId then return nil end
	if not Playing() or s.hero:IsNull() or s.hero:IsAlive()
		or PlayerResource:GetSelectedHeroEntity(playerID) ~= s.hero then
		self:FinishDeathDraft(playerID, false, true)
		return nil
	end
	if GameRules:GetGameTime() >= s.expiresAt then
		self:FinishDeathDraft(playerID, true, false)
		return nil
	end
	return s
end

function RespawnManager:SendDeathDraft(playerID)
	local s = self.pending[playerID]
	local player = PlayerResource:GetPlayer(playerID)
	if not s or not player then return end
	local record = PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_death_draft", {
		draft_id = s.draftId,
		basic_offers = table.concat(s.offers.basic, ","),
		ultimate_offers = table.concat(s.offers.ultimate, ","),
		basic_slots = table.concat(s.slots.basic, ","),
		ultimate_slots = table.concat(s.slots.ultimate, ","),
		pending_basic = table.concat(s.candidate.basic, ","),
		pending_ultimate = table.concat(s.candidate.ultimate, ","),
		selected_slot = s.selectedSlot or "",
		error = s.error or "",
		rerolls = record.rerolls.respawn,
		time = math.max(0, math.ceil(s.expiresAt - GameRules:GetGameTime())),
	})
end

function RespawnManager:SyncPlayer(playerID)
	local s = self.pending[playerID]
	if s then
		if self:GetSession(playerID, s.draftId) then self:SendDeathDraft(playerID) end
		return
	end
	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_death_end", {
			timed_out = false, cancelled = true, replaced = "", gained = "",
		})
	end
end

function RespawnManager:HandleDeathSelectSlot(playerID, slotName, draftId)
	local s = self:GetSession(playerID, draftId)
	if not s or type(slotName) ~= "string" then return end
	for _, kind in ipairs({ "basic", "ultimate" }) do
		if Contains(s.slots[kind], slotName) then
			s.selectedSlot, s.selectedKind = slotName, kind
			s.error = nil
			self:SendDeathDraft(playerID)
			return
		end
	end
end

function RespawnManager:HandleDeathSelectAbility(playerID, abilityName, draftId)
	local s = self:GetSession(playerID, draftId)
	if not s or not s.selectedKind or type(abilityName) ~= "string"
		or (abilityName ~= s.selectedSlot
			and not Contains(s.offers[s.selectedKind], abilityName)) then return end
	local index
	for i, name in ipairs(s.slots[s.selectedKind]) do
		if name == s.selectedSlot then index = i break end
	end
	if not index then return end
	if not self.abilityManager:IsAvailable(abilityName, playerID) then
		s.error = "ability_taken"
		self:SendDeathDraft(playerID)
		return
	end
	for _, kind in ipairs({ "basic", "ultimate" }) do
		for i, name in ipairs(s.candidate[kind]) do
			if name == abilityName and (kind ~= s.selectedKind or i ~= index) then return end
		end
	end
	s.candidate[s.selectedKind][index] = abilityName
	s.error = nil
	self:SendDeathDraft(playerID)
end

function RespawnManager:HandleDeathReroll(playerID, draftId)
	local s = self:GetSession(playerID, draftId)
	if not s then return end
	local record = PlayerState:Get(playerID)
	if self.rerollManager then
		if not self.rerollManager:Consume(playerID, "respawn") then return end
	else
		if (record.rerolls.respawn or 0) <= 0 then return end
		record.rerolls.respawn = record.rerolls.respawn - 1
	end
	-- The token identifies both the death and its current offer generation.
	s.draftId = self:NextDraftId()
	s.error = nil
	s.candidate = { basic = Copy(s.slots.basic), ultimate = Copy(s.slots.ultimate) }
	self:RollOffers(s)
	self:SendDeathDraft(playerID)
end

function RespawnManager:HandleDeathConfirm(playerID, draftId)
	if self:GetSession(playerID, draftId) then self:FinishDeathDraft(playerID, false, false) end
end

function RespawnManager:HandleDeathSkip(playerID, draftId)
	local s = self:GetSession(playerID, draftId)
	if not s then return end
	s.skipped = true
	self:FinishDeathDraft(playerID, false, true)
end

function RespawnManager:FinishDeathDraft(playerID, timedOut, cancelled)
	local s = self.pending[playerID]
	if not s then return false end
	local record = PlayerState:Get(playerID)
	local replaced, gained = {}, {}
	if not timedOut and not cancelled then
		if not Same(record.abilities.basic, s.slots.basic)
			or not Same(record.abilities.ultimate, s.slots.ultimate) then
			return self:FinishDeathDraft(playerID, false, true)
		end
		for _, kind in ipairs({ "basic", "ultimate" }) do
			for i, name in ipairs(s.slots[kind]) do
				local newName = s.candidate[kind][i]
				if newName ~= name then
					if not self.abilityManager:IsAvailable(newName, playerID) then
						s.error = "ability_taken"
						self:SendDeathDraft(playerID)
						return false
					end
					if not Contains(s.offers[kind], newName) then
						s.error = "stale_offer"
						self:SendDeathDraft(playerID)
						return false
					end
					table.insert(replaced, name)
					table.insert(gained, newName)
				end
			end
		end
		if #gained > 0 then
			local ok, reason = self.abilityManager:ApplyDraftChanges(s.hero, s.slots.basic, s.slots.ultimate,
				s.candidate.basic, s.candidate.ultimate)
			if not ok then
				s.error = reason or "invalid_kit"
				self:SendDeathDraft(playerID)
				return false
			end
			self.abilityManager:CommitBuild(playerID, s.candidate.basic, s.candidate.ultimate)
		end
		record.abilities = { basic = Copy(s.candidate.basic), ultimate = Copy(s.candidate.ultimate) }
	end
	self.pending[playerID] = nil
	if s.timer then Timers:RemoveTimer(s.timer) end
	record.respawnPending = false
	record.draftState = Playing() and "GAME" or "FINISHED"
	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_death_end", {
			draft_id = s.draftId,
			timed_out = timedOut == true,
			cancelled = cancelled == true,
			skipped = s.skipped == true,
			replaced = table.concat(replaced, ","),
			gained = table.concat(gained, ","),
		})
	end
	return true
end

function RespawnManager:CancelAll()
	local ids = {}
	for playerID in pairs(self.pending) do table.insert(ids, playerID) end
	for _, playerID in ipairs(ids) do self:FinishDeathDraft(playerID, false, true) end
end

function RespawnManager:OnHeroSpawn(hero)
	if not hero or hero:IsNull() or not hero:IsRealHero() then return end
	local playerID = hero:GetPlayerOwnerID()
	if not PlayerResource:IsValidPlayerID(playerID) then return end
	local s = self.pending[playerID]
	if s and (hero == s.hero or PlayerResource:GetSelectedHeroEntity(playerID) == hero) then
		-- Buyback is disabled by the game mode. Forced/reincarnation spawns can
		-- still happen: discard staged edits rather than ever changing a live kit.
		self:FinishDeathDraft(playerID, false, true)
	end
end
