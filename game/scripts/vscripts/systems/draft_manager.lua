-- systems/draft_manager.lua
-- Hero draft (3x4 random + 1 reroll/cat), ability draft (4+1), ultimate draft (6 choices).

DraftManager = DraftManager or class({})

local HERO_DRAFT_TIME = 45
local ABILITY_DRAFT_TIME = 75
local ULTIMATE_DRAFT_TIME = 40
local BASIC_SLOTS = 4
local ABILITY_OFFER_BASICS = 12
local ABILITY_OFFER_ULTS = 6
local SECOND_ULT_CHOICES = 6

local function Join(list)
	if not list or #list == 0 then return "" end
	return table.concat(list, ",")
end

local function OwnedList(record)
	local owned = {}
	if not record or not record.abilities then return owned end
	for _, a in ipairs(record.abilities.basic or {}) do table.insert(owned, a) end
	for _, a in ipairs(record.abilities.ultimate or {}) do table.insert(owned, a) end
	return owned
end

function DraftManager:constructor(heroManager, abilityManager)
	self.heroManager = heroManager
	self.abilityManager = abilityManager
	self.active = false
	self.phase = nil
	self.onComplete = nil
	self.finished = false
	self.timeLeft = 0
	self.timer = nil
	self.heroOffers = {}
	self.heroPicks = {}
	self.abilityOffers = {}
	self.abilityDone = {}
	self.ultOffers = {}
	self.ultPicks = {}
	self.ultConfirmed = {}
end

function DraftManager:StartHeroDraft(onComplete)
	print("[DraftManager] Hero draft - 3x4 randomized pools, 1 reroll/category")
	self.phase = "hero"
	self.onComplete = onComplete
	self.finished = false
	self.timeLeft = HERO_DRAFT_TIME
	self.heroOffers = {}
	self.heroPicks = {}
	self.active = true

	PlayerState:ForEachConnected(function(playerID, record)
		record.draftState = "HERO_DRAFT"
		record.rerolls.heroCategory1 = 1
		record.rerolls.heroCategory2 = 1
		record.rerolls.heroCategory3 = 1
		local offers = self.heroManager:BuildPlayerOffers()
		self.heroOffers[playerID] = offers
		record.heroPools = offers
		self:SendHeroOffers(playerID)
	end)

	CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_draft_start", {
		time = HERO_DRAFT_TIME,
	})

	self.timer = Timers:CreateTimer(function()
		if self.finished or self.phase ~= "hero" then return nil end
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:FinishHeroDraft()
			return nil
		end
		return 1
	end)
end

function DraftManager:SendHeroOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local o = self.heroOffers[playerID] or {}
	local record = PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_hero_offers", {
		strength = Join(o.Strength),
		agility = Join(o.Agility),
		intelligence = Join(o.Intelligence),
		reroll_str = record and record.rerolls.heroCategory1 or 0,
		reroll_agi = record and record.rerolls.heroCategory2 or 0,
		reroll_int = record and record.rerolls.heroCategory3 or 0,
		time = self.timeLeft,
	})
end

function DraftManager:CategoryKey(name)
	if not name then return nil end
	local n = string.lower(name)
	if n == "strength" or n == "str" or n == "poolc" or n == "1" then return "Strength", "heroCategory1" end
	if n == "agility" or n == "agi" or n == "poola" or n == "2" then return "Agility", "heroCategory2" end
	if n == "intelligence" or n == "int" or n == "poolb" or n == "3" then return "Intelligence", "heroCategory3" end
	return nil
end

function DraftManager:HandleHeroReroll(playerID, categoryName)
	if self.finished or self.phase ~= "hero" then return end
	if self.heroPicks[playerID] then return end
	local cat, bucket = self:CategoryKey(categoryName)
	if not cat then return end
	local gm = GameRules.AILOD
	if gm and gm.rerollManager then
		if not gm.rerollManager:Consume(playerID, bucket) then
			return
		end
	else
		local p = PlayerState:Get(playerID)
		if not p or not p.rerolls or (p.rerolls[bucket] or 0) <= 0 then return end
		p.rerolls[bucket] = p.rerolls[bucket] - 1
	end

	local offers = self.heroOffers[playerID] or {}
	local exclude = {}
	for _, h in ipairs(offers[cat] or {}) do exclude[h] = true end
	offers[cat] = self.heroManager:SampleCategory(cat, 4, exclude)
	self.heroOffers[playerID] = offers
	local record = PlayerState:Get(playerID)
	if record then record.heroPools = offers end
	self:SendHeroOffers(playerID)
	print(string.format("[DraftManager] Player %d rerolled %s", playerID, cat))
end

function DraftManager:HandleHeroPick(playerID, heroName)
	if self.finished or self.phase ~= "hero" then return end
	if playerID == nil or self.heroPicks[playerID] then return end
	if not heroName or heroName == "" then return end
	if self.heroManager:IsBanned(heroName) then return end

	local offers = self.heroOffers[playerID]
	local valid = false
	if offers then
		for _, cat in ipairs(self.heroManager:GetCategories()) do
			for _, h in ipairs(offers[cat] or {}) do
				if h == heroName then valid = true break end
			end
			if valid then break end
		end
	end
	if not valid and self.heroManager:IsValidHero(heroName) and not self.heroManager:IsBanned(heroName) then
		valid = true
	end
	if not valid then
		print(string.format("[DraftManager] Reject hero pick %s from %s", tostring(heroName), tostring(playerID)))
		return
	end

	self.heroPicks[playerID] = heroName
	PlayerState:SetHero(playerID, heroName)
	local record = PlayerState:Get(playerID)
	if record then record.draftState = "HERO_LOCKED" end

	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_hero_picked", { hero = heroName })
	end
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_pick_public", {
		playerID = playerID,
		hero = heroName,
	})
	print(string.format("[DraftManager] Player %d picked hero %s", playerID, heroName))
	self:CheckHeroDone()
end

function DraftManager:CheckHeroDone()
	local pending = false
	PlayerState:ForEachConnected(function(playerID, _)
		if not self.heroPicks[playerID] then pending = true end
	end)
	if not pending then
		self:FinishHeroDraft()
	end
end

function DraftManager:FinishHeroDraft()
	if self.phase ~= "hero" then return end
	if self.finished then return end
	self.finished = true
	if self.timer then Timers:RemoveTimer(self.timer) self.timer = nil end

	PlayerState:ForEachConnected(function(playerID, _)
		if not self.heroPicks[playerID] then
			local offers = self.heroOffers[playerID]
			local fallback = self.heroManager:GetDefaultHero()
			if offers then
				for _, cat in ipairs(self.heroManager:GetCategories()) do
					if offers[cat] and offers[cat][1] then
						fallback = offers[cat][1]
						break
					end
				end
			end
			self.heroPicks[playerID] = fallback
			PlayerState:SetHero(playerID, fallback)
			print(string.format("[DraftManager] Auto-hero player %d -> %s", playerID, fallback))
		end
	end)

	CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_draft_end", {})
	self.active = false
	local cb = self.onComplete
	self.onComplete = nil
	if cb then cb() end
end

function DraftManager:StartAbilityDraft(onComplete)
	print("[DraftManager] Ability draft - 4 basic + 1 ultimate")
	self.phase = "ability"
	self.onComplete = onComplete
	self.finished = false
	self.timeLeft = ABILITY_DRAFT_TIME
	self.abilityOffers = {}
	self.abilityDone = {}
	self.active = true
	self.abilityManager:Load()

	PlayerState:ForEachConnected(function(playerID, record)
		record.draftState = "ABILITY_DRAFT"
		record.abilities.basic = {}
		record.abilities.ultimate = {}
		record.draftLocked = false
		local pools = self.abilityManager:GetPools()
		local basicOffers = self.abilityManager:Sample(pools.regular, ABILITY_OFFER_BASICS, {})
		local ultOffers = self.abilityManager:Sample(pools.ultimate, ABILITY_OFFER_ULTS, {})
		self.abilityOffers[playerID] = { basic = basicOffers, ultimate = ultOffers }
		self:SendAbilityOffers(playerID)
	end)

	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ability_draft_start", {
		time = ABILITY_DRAFT_TIME,
	})

	self.timer = Timers:CreateTimer(function()
		if self.finished or self.phase ~= "ability" then return nil end
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_ability_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:FinishAbilityDraft()
			return nil
		end
		return 1
	end)
end

function DraftManager:SendAbilityOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local o = self.abilityOffers[playerID] or { basic = {}, ultimate = {} }
	local record = PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ability_offers", {
		basic = Join(o.basic),
		ultimate = Join(o.ultimate),
		picked_basic = Join(record and record.abilities.basic or {}),
		picked_ultimate = Join(record and record.abilities.ultimate or {}),
		time = self.timeLeft,
	})
end

function DraftManager:HandleAbilityPick(playerID, abilityName)
	if self.finished or self.phase ~= "ability" then return end
	if playerID == nil or not abilityName then return end
	if self.abilityDone[playerID] then return end

	local record = PlayerState:Get(playerID)
	if not record then return end
	local offers = self.abilityOffers[playerID]
	if not offers then return end

	local isUlt = false
	local inOffer = false
	for _, a in ipairs(offers.ultimate or {}) do
		if a == abilityName then isUlt = true inOffer = true break end
	end
	if not inOffer then
		for _, a in ipairs(offers.basic or {}) do
			if a == abilityName then inOffer = true break end
		end
	end
	if not inOffer then
		if self.abilityManager:IsUltimate(abilityName) then
			isUlt = true inOffer = true
		elseif self.abilityManager:IsRegular(abilityName) then
			inOffer = true
		end
	end
	if not inOffer then return end

	local owned = OwnedList(record)
	local ok, reason = self.abilityManager:IsCompatible(abilityName, owned, record.hero)
	if not ok then
		print(string.format("[DraftManager] Ability reject %s: %s", abilityName, tostring(reason)))
		return
	end

	if isUlt then
		if #(record.abilities.ultimate or {}) >= 1 then return end
		table.insert(record.abilities.ultimate, abilityName)
	else
		if #(record.abilities.basic or {}) >= BASIC_SLOTS then return end
		table.insert(record.abilities.basic, abilityName)
	end

	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ability_picked", {
			ability = abilityName,
			regularCount = #(record.abilities.basic or {}),
			hasUltimate = #(record.abilities.ultimate or {}) > 0,
			isUltimate = isUlt,
		})
	end
	self:SendAbilityOffers(playerID)

	if #(record.abilities.basic or {}) >= BASIC_SLOTS and #(record.abilities.ultimate or {}) >= 1 then
		self.abilityDone[playerID] = true
		record.draftState = "ABILITY_LOCKED"
	end
	self:CheckAbilityDone()
end

function DraftManager:CheckAbilityDone()
	local pending = false
	PlayerState:ForEachConnected(function(playerID, _)
		if not self.abilityDone[playerID] then pending = true end
	end)
	if not pending then
		self:FinishAbilityDraft()
	end
end

function DraftManager:FinishAbilityDraft()
	if self.phase ~= "ability" then return end
	if self.finished then return end
	self.finished = true
	if self.timer then Timers:RemoveTimer(self.timer) self.timer = nil end

	local pools = self.abilityManager:GetPools()
	PlayerState:ForEachConnected(function(playerID, record)
		record.abilities.basic = record.abilities.basic or {}
		record.abilities.ultimate = record.abilities.ultimate or {}
		local guard = 0
		while #record.abilities.basic < BASIC_SLOTS and guard < 200 do
			guard = guard + 1
			local owned = OwnedList(record)
			local exclude = {}
			for _, a in ipairs(owned) do exclude[a] = true end
			local pick = self.abilityManager:RandomFrom(pools.regular, exclude)
			if not pick then break end
			local ok = self.abilityManager:IsCompatible(pick, owned, record.hero)
			if ok then table.insert(record.abilities.basic, pick) end
		end
		if #record.abilities.ultimate < 1 then
			local owned = OwnedList(record)
			local exclude = {}
			for _, a in ipairs(owned) do exclude[a] = true end
			local pick = self.abilityManager:RandomFrom(pools.ultimate, exclude)
			if pick then table.insert(record.abilities.ultimate, pick) end
		end
		self.abilityDone[playerID] = true
	end)

	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ability_draft_end", {})
	self.active = false
	local cb = self.onComplete
	self.onComplete = nil
	if cb then cb() end
end

function DraftManager:StartUltimateDraft(onComplete)
	print("[DraftManager] Ultimate draft - 6 choices, confirm to lock")
	self.phase = "ultimate"
	self.onComplete = onComplete
	self.finished = false
	self.timeLeft = ULTIMATE_DRAFT_TIME
	self.ultOffers = {}
	self.ultPicks = {}
	self.ultConfirmed = {}
	self.active = true

	local pools = self.abilityManager:GetPools()
	local source = pools.extraUltimate
	if not source or #source == 0 then source = pools.ultimate end

	PlayerState:ForEachConnected(function(playerID, record)
		record.draftState = "ULTIMATE_DRAFT"
		record.ultimateConfirmed = false
		local owned = OwnedList(record)
		local exclude = {}
		for _, a in ipairs(owned) do exclude[a] = true end
		local choices = self.abilityManager:Sample(source, SECOND_ULT_CHOICES, exclude)
		self.ultOffers[playerID] = choices
		self:SendUltOffers(playerID)
	end)

	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ult_draft_start", {
		time = ULTIMATE_DRAFT_TIME,
	})

	self.timer = Timers:CreateTimer(function()
		if self.finished or self.phase ~= "ultimate" then return nil end
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_ult_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:FinishUltimateDraft()
			return nil
		end
		return 1
	end)
end

function DraftManager:SendUltOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ult_offers", {
		choices = Join(self.ultOffers[playerID] or {}),
		selected = self.ultPicks[playerID] or "",
		confirmed = self.ultConfirmed[playerID] == true,
		time = self.timeLeft,
	})
end

function DraftManager:HandleUltPick(playerID, abilityName)
	if self.finished or self.phase ~= "ultimate" then return end
	if self.ultConfirmed[playerID] then return end
	if not abilityName then return end
	local offers = self.ultOffers[playerID] or {}
	local ok = false
	for _, a in ipairs(offers) do if a == abilityName then ok = true break end end
	if not ok then return end
	local record = PlayerState:Get(playerID)
	local owned = OwnedList(record)
	local compatible = self.abilityManager:IsCompatible(abilityName, owned, record and record.hero)
	if not compatible then return end
	self.ultPicks[playerID] = abilityName
	self:SendUltOffers(playerID)
end

function DraftManager:HandleUltConfirm(playerID)
	if self.finished or self.phase ~= "ultimate" then return end
	if self.ultConfirmed[playerID] then return end
	local pick = self.ultPicks[playerID]
	if not pick then return end
	local record = PlayerState:Get(playerID)
	if not record then return end
	record.abilities.ultimate = record.abilities.ultimate or {}
	local owned = OwnedList(record)
	local has = false
	for _, a in ipairs(owned) do if a == pick then has = true break end end
	if not has then
		table.insert(record.abilities.ultimate, pick)
	end
	self.ultConfirmed[playerID] = true
	record.ultimateConfirmed = true
	record.draftState = "ULTIMATE_LOCKED"
	self:SendUltOffers(playerID)
	print(string.format("[DraftManager] Player %d locked 2nd ult %s", playerID, pick))
	self:CheckUltDone()
end

function DraftManager:CheckUltDone()
	local pending = false
	PlayerState:ForEachConnected(function(playerID, _)
		if not self.ultConfirmed[playerID] then pending = true end
	end)
	if not pending then
		self:FinishUltimateDraft()
	end
end

function DraftManager:FinishUltimateDraft()
	if self.phase ~= "ultimate" then return end
	if self.finished then return end
	self.finished = true
	if self.timer then Timers:RemoveTimer(self.timer) self.timer = nil end

	local pools = self.abilityManager:GetPools()
	local source = pools.extraUltimate
	if not source or #source == 0 then source = pools.ultimate end

	PlayerState:ForEachConnected(function(playerID, record)
		if self.ultConfirmed[playerID] then return end
		local pick = self.ultPicks[playerID]
		if not pick then
			local owned = OwnedList(record)
			local exclude = {}
			for _, a in ipairs(owned) do exclude[a] = true end
			for _, c in ipairs(self.ultOffers[playerID] or {}) do
				if not exclude[c] then pick = c break end
			end
			if not pick then
				pick = self.abilityManager:RandomFrom(source, exclude)
			end
		end
		if pick then
			record.abilities.ultimate = record.abilities.ultimate or {}
			local has = false
			for _, a in ipairs(record.abilities.ultimate) do if a == pick then has = true break end end
			if not has then table.insert(record.abilities.ultimate, pick) end
		end
		self.ultConfirmed[playerID] = true
		record.ultimateConfirmed = true
	end)

	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ult_draft_end", {})
	self.active = false
	local cb = self.onComplete
	self.onComplete = nil
	if cb then cb() end
end

function DraftManager:GetHeroPick(playerID)
	return self.heroPicks[playerID]
end
