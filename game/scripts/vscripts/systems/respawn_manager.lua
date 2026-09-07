-- systems/respawn_manager.lua
-- Phase 10-12: per-player death draft (3 rerolls, slot replace). Stays in PLAYING.

RespawnManager = RespawnManager or class({})

local DEATH_DRAFT_TIME = 25
local DEATH_OFFER_COUNT = 6

local function Join(list)
	if not list or #list == 0 then return "" end
	return table.concat(list, ",")
end

function RespawnManager:constructor(abilityManager, rerollManager)
	self.abilityManager = abilityManager
	self.rerollManager = rerollManager
	self.enabledDraft = true
	self.pending = {} -- playerID -> draft session
end

function RespawnManager:OnHeroDeath(hero)
	if not hero or hero:IsNull() or not hero:IsRealHero() then
		return
	end

	local playerID = hero:GetPlayerOwnerID()
	if not PlayerResource:IsValidPlayerID(playerID) then
		return
	end

	if PlayerState then
		PlayerState:IncDeath(playerID)
	end

	print(string.format("[RespawnManager] Hero death player=%d (draft=%s)",
		playerID, tostring(self.enabledDraft)))

	if self.enabledDraft and GameState and GameState:Is(GameState.PLAYING) then
		self:StartDeathDraft(playerID, hero)
	end
end

function RespawnManager:StartDeathDraft(playerID, hero)
	if self.pending[playerID] then return end

	local record = PlayerState and PlayerState:Get(playerID)
	if record then
		record.respawnPending = true
		PlayerState:ResetRespawnRerolls(playerID)
		record.draftState = "RESPAWN_DRAFT"
	end

	-- Hold hero until draft finishes
	if hero and not hero:IsNull() then
		hero:SetTimeUntilRespawn(DEATH_DRAFT_TIME + 5)
	end

	local pools = self.abilityManager and self.abilityManager:GetPools() or {}
	local source = pools.deathReroll or pools.regular or {}
	local owned = {}
	if record and record.abilities then
		for _, a in ipairs(record.abilities.basic or {}) do table.insert(owned, a) end
		for _, a in ipairs(record.abilities.ultimate or {}) do table.insert(owned, a) end
	end
	local exclude = {}
	for _, a in ipairs(owned) do exclude[a] = true end

	local offers = {}
	if self.abilityManager then
		offers = self.abilityManager:Sample(source, DEATH_OFFER_COUNT, exclude)
	end

	local slots = {}
	if record and record.abilities and record.abilities.basic then
		for i, a in ipairs(record.abilities.basic) do
			table.insert(slots, a)
		end
	end

	self.pending[playerID] = {
		offers = offers,
		slots = slots,
		selectedSlot = nil,
		selectedAbility = nil,
		timeLeft = DEATH_DRAFT_TIME,
		hero = hero,
	}

	self:SendDeathDraft(playerID)

	local session = self.pending[playerID]
	session.timer = Timers:CreateTimer(function()
		local s = self.pending[playerID]
		if not s then return nil end
		s.timeLeft = s.timeLeft - 1
		local player = PlayerResource:GetPlayer(playerID)
		if player then
			CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_death_timer", { time = s.timeLeft })
		end
		if s.timeLeft <= 0 then
			self:FinishDeathDraft(playerID, true)
			return nil
		end
		return 1
	end)

	print(string.format("[RespawnManager] Death draft started for player %d", playerID))
end

function RespawnManager:SendDeathDraft(playerID)
	local s = self.pending[playerID]
	if not s then return end
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local record = PlayerState and PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_death_draft", {
		offers = Join(s.offers),
		slots = Join(s.slots),
		selected_slot = s.selectedSlot or "",
		selected_ability = s.selectedAbility or "",
		rerolls = record and record.rerolls and record.rerolls.respawn or 0,
		time = s.timeLeft,
	})
end

function RespawnManager:HandleDeathSelectSlot(playerID, slotName)
	local s = self.pending[playerID]
	if not s then return end
	local ok = false
	for _, a in ipairs(s.slots or {}) do
		if a == slotName then ok = true break end
	end
	if not ok then return end
	s.selectedSlot = slotName
	self:SendDeathDraft(playerID)
end

function RespawnManager:HandleDeathSelectAbility(playerID, abilityName)
	local s = self.pending[playerID]
	if not s then return end
	local ok = false
	for _, a in ipairs(s.offers or {}) do
		if a == abilityName then ok = true break end
	end
	if not ok then return end
	s.selectedAbility = abilityName
	self:SendDeathDraft(playerID)
end

function RespawnManager:HandleDeathReroll(playerID)
	local s = self.pending[playerID]
	if not s then return end
	local can = false
	if self.rerollManager then
		can = self.rerollManager:Consume(playerID, "respawn")
	else
		local p = PlayerState and PlayerState:Get(playerID)
		if p and p.rerolls and (p.rerolls.respawn or 0) > 0 then
			p.rerolls.respawn = p.rerolls.respawn - 1
			can = true
		end
	end
	if not can then return end

	local pools = self.abilityManager and self.abilityManager:GetPools() or {}
	local source = pools.deathReroll or pools.regular or {}
	local exclude = {}
	for _, a in ipairs(s.offers or {}) do exclude[a] = true end
	for _, a in ipairs(s.slots or {}) do exclude[a] = true end
	if self.abilityManager then
		s.offers = self.abilityManager:Sample(source, DEATH_OFFER_COUNT, exclude)
	end
	s.selectedAbility = nil
	self:SendDeathDraft(playerID)
end

function RespawnManager:HandleDeathConfirm(playerID)
	local s = self.pending[playerID]
	if not s then return end
	if not s.selectedSlot or not s.selectedAbility then return end
	self:FinishDeathDraft(playerID, false)
end

function RespawnManager:FinishDeathDraft(playerID, timedOut)
	local s = self.pending[playerID]
	if not s then return end
	if s.timer then Timers:RemoveTimer(s.timer) end

	local slot = s.selectedSlot
	local gained = s.selectedAbility
	if (not slot or not gained) and timedOut then
		-- Auto: replace first basic with first offer
		slot = s.slots and s.slots[1]
		gained = s.offers and s.offers[1]
	end

	local record = PlayerState and PlayerState:Get(playerID)
	local hero = PlayerResource:GetSelectedHeroEntity(playerID)
	if not hero or hero:IsNull() then
		hero = s.hero
	end

	local replaced = nil
	if slot and gained and record and record.abilities and record.abilities.basic then
		for i, a in ipairs(record.abilities.basic) do
			if a == slot then
				record.abilities.basic[i] = gained
				replaced = slot
				break
			end
		end
		-- If slot was an ultimate somehow
		if not replaced and record.abilities.ultimate then
			for i, a in ipairs(record.abilities.ultimate) do
				if a == slot then
					record.abilities.ultimate[i] = gained
					replaced = slot
					break
				end
			end
		end
	end

	if replaced and gained and hero and not hero:IsNull() and self.abilityManager then
		self.abilityManager:ReplaceAbility(hero, replaced, gained)
	end

	if record then
		record.respawnPending = false
		record.draftState = "PLAYING"
	end

	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_death_end", {
			replaced = replaced or "",
			gained = gained or "",
		})
		-- legacy UI event
		CustomGameEventManager:Send_ServerToPlayer(player, "lod_deathroll", {
			replaced = replaced or "",
			gained = gained or "",
		})
	end

	-- Speed up respawn after draft
	if hero and not hero:IsNull() and hero.SetTimeUntilRespawn then
		if hero:IsAlive() == false then
			hero:SetTimeUntilRespawn(math.min(hero:GetTimeUntilRespawn(), 3))
		end
	end

	self.pending[playerID] = nil
	print(string.format("[RespawnManager] Death draft done player %d: %s -> %s",
		playerID, tostring(replaced), tostring(gained)))
end

function RespawnManager:OnHeroSpawn(hero)
	if not hero or hero:IsNull() or not hero:IsRealHero() then
		return
	end
	hero:RemoveModifierByName("modifier_stunned")

	-- Re-apply kit if player has drafted abilities (covers first spawn edge cases)
	local playerID = hero:GetPlayerOwnerID()
	if not PlayerResource:IsValidPlayerID(playerID) then return end
	local record = PlayerState and PlayerState:Get(playerID)
	if record and record.abilities and self.abilityManager and GameState and GameState:Is(GameState.PLAYING) then
		local basics = record.abilities.basic or {}
		local ults = record.abilities.ultimate or {}
		if #basics > 0 or #ults > 0 then
			-- Only re-apply if hero is missing drafted skills
			local current = self.abilityManager:ListHeroAbilities(hero)
			local need = false
			for _, a in ipairs(basics) do
				local found = false
				for _, c in ipairs(current) do if c == a then found = true break end end
				if not found then need = true break end
			end
			if need then
				self.abilityManager:ApplyKit(hero, basics, ults)
			end
		end
	end
end
