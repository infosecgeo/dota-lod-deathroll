-- Hero draft (3x4, one reroll/category), three basics, initial ult, then extra ult.

DraftManager = DraftManager or class({})

local HERO_DRAFT_TIME = 30
local ABILITY_DRAFT_TIME = 30
local ULTIMATE_DRAFT_TIME = 20
local BUILD_CONFIRMATION_TIME = 15
local BASIC_SLOTS = 3
local ABILITY_OFFER_BASICS = 12
local ABILITY_OFFER_ULTS = 6
local SECOND_ULT_CHOICES = 6

local function Join(list)
	return table.concat(list or {}, ",")
end

local function Contains(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then return true end
	end
	return false
end

local function Copy(list)
	local result = {}
	for _, item in ipairs(list or {}) do table.insert(result, item) end
	return result
end

local function OwnedList(record)
	local owned = Copy(record.abilities.basic)
	for _, a in ipairs(record.abilities.ultimate) do table.insert(owned, a) end
	return owned
end

function DraftManager:constructor(heroManager, abilityManager)
	self.heroManager = heroManager
	self.abilityManager = abilityManager
	self.active = false
	self.finished = false
	self.timeLeft = 0
	self.participants = {}
	self.heroOffers = {}
	self.heroPicks = {}
	self.abilityOffers = {}
	self.abilityDone = {}
	self.ultOffers = {}
	self.ultPicks = {}
	self.ultConfirmed = {}
end

function DraftManager:Cancel()
	self.active = false
	self.finished = true
	self.onComplete = nil
	if self.timer then Timers:RemoveTimer(self.timer) self.timer = nil end
end

function DraftManager:BeginPhase(phase, duration, onComplete)
	self:Cancel()
	self.phase = phase
	self.phaseGeneration = (self.phaseGeneration or 0) + 1
	self.onComplete = onComplete
	self.finished = false
	self.active = true
	self.timeLeft = duration
	self.deadline = Time() + duration
	PlayerState:ForEachParticipant(function(playerID, _)
		self.participants[playerID] = true
	end)
end

function DraftManager:ForEachPlayer(callback)
	-- Keep phase participants even while disconnected so reconnects cannot skip a kit.
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if self.participants[playerID] then callback(playerID, PlayerState:Get(playerID)) end
	end
end

function DraftManager:AcceptAction(playerID, phase)
	local states = { hero = GameState.HERO_DRAFT, ability = GameState.ABILITY_DRAFT,
		initial = GameState.INITIAL_ULTIMATE, ultimate = GameState.ULTIMATE_DRAFT,
		build = GameState.BUILD_CONFIRMATION }
	return self.active and not self.finished and self.phase == phase
		and self.participants[playerID] == true and PlayerState:IsParticipant(playerID)
		and GameState:Is(states[phase]) and Time() < self.deadline
end

function DraftManager:Fail(reason)
	self:Cancel()
	if GameState.owner then GameState.owner:AbortPreparation(reason or "draft_pool_exhausted") end
end

function DraftManager:PublishRoster()
	if GameState.owner and GameState.owner.PublishRoster then GameState.owner:PublishRoster() end
end

function DraftManager:StartTimer(phase, event, finish)
	local generation = self.phaseGeneration
	self.timer = Timers:CreateTimer(function()
		if not self.active or self.finished or self.phase ~= phase or self.phaseGeneration ~= generation then return nil end
		self.timeLeft = math.max(0, math.ceil(self.deadline - Time()))
		CustomGameEventManager:Send_ServerToAllClients(event, { time = self.timeLeft })
		self:PublishRoster()
		if self.timeLeft <= 0 then
			local ok, reason = pcall(finish, self)
			if not ok then
				print("[DraftManager] Timeout failed: " .. tostring(reason))
				self:Fail("draft_timeout_failed")
				return nil
			end
			if not self.active or self.finished or self.phase ~= phase or self.phaseGeneration ~= generation then return nil end
			self:Fail("draft_timeout_recovery_failed")
			return nil
		end
		return 1
	end, false)
end

function DraftManager:CompletePhase(event)
	local cb = self.onComplete
	self:Cancel()
	CustomGameEventManager:Send_ServerToAllClients(event, {})
	if cb then cb() end
end

function DraftManager:SyncPlayer(playerID)
	if not self.active or self.finished or not self.participants[playerID] then return end
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local events = {
		hero = "ai_lod_hero_draft_start",
		ability = "ai_lod_ability_draft_start",
		ultimate = "ai_lod_ult_draft_start",
		initial = "ai_lod_initial_ult_draft_start",
		build = "ai_lod_build_confirmation",
	}
	if self.phase ~= "build" then
		CustomGameEventManager:Send_ServerToPlayer(player, events[self.phase], { time = self.timeLeft })
	end
	if self.phase == "hero" then
		self:SendHeroOffers(playerID)
		if self.heroPicks[playerID] then
			CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_hero_picked", {
				hero = self.heroPicks[playerID],
			})
		end
	elseif self.phase == "ability" then
		self:SendAbilityOffers(playerID)
	elseif self.phase == "ultimate" then
		self:SendUltOffers(playerID)
	elseif self.phase == "initial" then
		self:SendInitialUltOffers(playerID)
	elseif self.phase == "build" then
		self:SendBuild(playerID)
	end
end

function DraftManager:GenerateHeroPools()
	self.heroOffers = {}
	PlayerState:ForEachParticipant(function(playerID, record)
		self.heroOffers[playerID] = self.heroManager:BuildPlayerOffers()
		record.heroPools = self.heroOffers[playerID]
		record.draftState = "GENERATE_HERO_POOLS"
	end)
end

function DraftManager:StartHeroDraft(onComplete)
	self.participants = {}
	self:BeginPhase("hero", HERO_DRAFT_TIME, onComplete)
	self.heroPicks = {}
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_draft_start", { time = self.timeLeft })
	self:ForEachPlayer(function(playerID, record)
		record.draftState = "SELECT_BASE_HERO"
		record.rerolls.heroCategory1 = 1
		record.rerolls.heroCategory2 = 1
		record.rerolls.heroCategory3 = 1
		self.heroOffers[playerID] = self.heroOffers[playerID] or self.heroManager:BuildPlayerOffers()
		record.heroPools = self.heroOffers[playerID]
		self:SendHeroOffers(playerID)
	end)
	self:StartTimer("hero", "ai_lod_hero_timer", self.FinishHeroDraft)
end

function DraftManager:SendHeroOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local o = self.heroOffers[playerID] or {}
	local record = PlayerState:Get(playerID)
	if not self.heroAbilityPreviews then
		local byHero = {}
		for name, definition in pairs(self.abilityManager.db or {}) do
			if type(definition.hero) == "string" and self.abilityManager:ValidateAbility(name) then
				byHero[definition.hero] = byHero[definition.hero] or {}
				table.insert(byHero[definition.hero], name)
			end
		end
		self.heroAbilityPreviews = {}
		for hero, abilities in pairs(byHero) do
			table.sort(abilities)
			self.heroAbilityPreviews[hero] = Join(abilities)
		end
	end
	local previews = {}
	for _, category in ipairs(self.heroManager:GetCategories()) do
		for _, hero in ipairs(o[category] or {}) do previews[hero] = self.heroAbilityPreviews[hero] or "" end
	end
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_hero_offers", {
		strength = Join(o.Strength),
		agility = Join(o.Agility),
		intelligence = Join(o.Intelligence),
		hero_abilities = previews,
		reroll_str = record and record.rerolls.heroCategory1 or 0,
		reroll_agi = record and record.rerolls.heroCategory2 or 0,
		reroll_int = record and record.rerolls.heroCategory3 or 0,
		selected = self.heroPicks[playerID] or "",
		locked = self.heroPicks[playerID] ~= nil,
		time = self.timeLeft,
	})
end

function DraftManager:CategoryKey(name)
	if type(name) ~= "string" then return nil end
	local n = string.lower(name)
	if n == "strength" or n == "str" or n == "poolc" or n == "1" then return "Strength", "heroCategory1" end
	if n == "agility" or n == "agi" or n == "poola" or n == "2" then return "Agility", "heroCategory2" end
	if n == "intelligence" or n == "int" or n == "poolb" or n == "3" then return "Intelligence", "heroCategory3" end
	return nil
end

function DraftManager:HandleHeroReroll(playerID, categoryName)
	if not self:AcceptAction(playerID, "hero") then return end
	local offers = self.heroOffers[playerID]
	if not offers or self.heroPicks[playerID] then return end
	local cat, bucket = self:CategoryKey(categoryName)
	if not cat then return end
	local record = PlayerState:Get(playerID)
	if not record or (record.rerolls[bucket] or 0) <= 0 then return end
	local exclude = {}
	for _, h in ipairs(offers[cat] or {}) do exclude[h] = true end
	local hardExclude = {}
	for _, other in ipairs(self.heroManager:GetCategories()) do
		if other ~= cat then
			for _, hero in ipairs(offers[other] or {}) do hardExclude[hero] = true end
		end
	end
	local replacement = self.heroManager:SampleCategory(cat, 4, exclude, hardExclude)
	if #replacement == 0 then return end
	record.rerolls[bucket] = record.rerolls[bucket] - 1
	offers[cat] = replacement
	record.heroPools = offers
	self:SendHeroOffers(playerID)
end

function DraftManager:IsHeroOffered(playerID, heroName)
	if type(heroName) ~= "string" or not self.heroManager:IsValidHero(heroName)
		or not self.heroManager:IsAvailable(heroName) then return false end
	local offers = self.heroOffers[playerID] or {}
	for _, cat in ipairs(self.heroManager:GetCategories()) do
		if Contains(offers[cat], heroName) then return true end
	end
	return false
end

function DraftManager:LockHero(playerID, heroName)
	if not self.heroManager:TrySelect(heroName, playerID) then return false end
	self.heroPicks[playerID] = heroName
	PlayerState:SetHero(playerID, heroName)
	local record = PlayerState:Get(playerID)
	if record then record.draftState = "HERO_LOCKED" end
	self:SendHeroOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_hero_picked", { hero = heroName })
	end
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_hero_pick_public", {
		playerID = playerID, hero = heroName,
	})
	self:RefreshHeroOffers()
	self:PublishRoster()
	return true
end

function DraftManager:RefreshHeroOffers()
	self:ForEachPlayer(function(playerID, record)
		if self.heroPicks[playerID] then return end
		local offers = self.heroOffers[playerID] or {}
		for _, category in ipairs(self.heroManager:GetCategories()) do
			local available = {}
			for _, hero in ipairs(offers[category] or {}) do
				if self.heroManager:IsAvailable(hero) then table.insert(available, hero) end
			end
			if #available > 0 then
				offers[category] = available
			else
				local hardExclude = {}
				for _, other in ipairs(self.heroManager:GetCategories()) do
					if other ~= category then
						for _, hero in ipairs(offers[other] or {}) do hardExclude[hero] = true end
					end
				end
				offers[category] = self.heroManager:SampleCategory(category, 4, {}, hardExclude)
			end
		end
		self.heroOffers[playerID] = offers
		record.heroPools = offers
		self:SendHeroOffers(playerID)
	end)
end

function DraftManager:HandleHeroPick(playerID, heroName)
	if not self:AcceptAction(playerID, "hero") then return end
	if playerID == nil or self.heroPicks[playerID] then return end
	if not self:IsHeroOffered(playerID, heroName) then return end
	if not self:LockHero(playerID, heroName) then return end
	self:CheckHeroDone()
end

function DraftManager:CheckHeroDone()
	local pending = false
	self:ForEachPlayer(function(playerID, _)
		if not self.heroPicks[playerID] then pending = true end
	end)
	if not pending then self:FinishHeroDraft() end
end

function DraftManager:FinishHeroDraft()
	if not self.active or self.finished or self.phase ~= "hero" then return end
	local pending = false
	self:ForEachPlayer(function(playerID, record)
		if self.heroPicks[playerID] then return end
		local function offeredHero()
			for _, cat in ipairs(self.heroManager:GetCategories()) do
				for _, hero in ipairs((self.heroOffers[playerID] or {})[cat] or {}) do
					if self:IsHeroOffered(playerID, hero) then return hero end
				end
			end
		end
		local pick = offeredHero()
		if not pick then
			self.heroOffers[playerID] = self.heroManager:BuildPlayerOffers()
			record.heroPools = self.heroOffers[playerID]
			self:SendHeroOffers(playerID)
			pick = offeredHero()
		end
		if not pick or not self:LockHero(playerID, pick) then pending = true end
	end)
	if not pending then self:CompletePhase("ai_lod_hero_draft_end") else self:Fail("hero_pool_exhausted") end
end

function DraftManager:CanPick(record, abilityName, isUlt)
	if type(abilityName) ~= "string" then return false end
	if isUlt then
		if not self.abilityManager:IsUltimate(abilityName) then return false end
	elseif not self.abilityManager:IsRegular(abilityName) or self.abilityManager:IsUltimate(abilityName) then
		return false
	end
	local owned = OwnedList(record)
	if Contains(owned, abilityName) then return false end
	return self.abilityManager:IsAvailable(abilityName, record.playerID)
		and self.abilityManager:IsCompatible(abilityName, owned, record.hero, record.playerID)
end

function DraftManager:Candidates(source, record, isUlt)
	local result, seen = {}, {}
	for _, ability in ipairs(source or {}) do
		if not seen[ability] and self:CanPick(record, ability, isUlt) then
			seen[ability] = true
			table.insert(result, ability)
		end
	end
	return result
end

function DraftManager:ExtraSource()
	local pools = self.abilityManager:GetPools()
	local source = Copy(pools.extraUltimate)
	for _, ability in ipairs(pools.ultimate or {}) do
		if not Contains(source, ability) then table.insert(source, ability) end
	end
	return source
end

function DraftManager:GlobalAbilityOffers(record, preferred)
	local pools = self.abilityManager:GetPools()
	local basics = Copy(preferred and preferred.basic)
	local ultimates = Copy(preferred and preferred.ultimate)
	for _, ability in ipairs(pools.regular or {}) do table.insert(basics, ability) end
	for _, ability in ipairs(pools.ultimate or {}) do table.insert(ultimates, ability) end
	return {
		basic = self:Candidates(basics, record, false),
		ultimate = self:Candidates(ultimates, record, true),
	}
end

function DraftManager:FindAbilityCompletion(record, offers)
	local working = {
		playerID = record.playerID,
		hero = record.hero,
		abilities = { basic = Copy(record.abilities.basic), ultimate = Copy(record.abilities.ultimate) },
	}
	if #working.abilities.basic > BASIC_SLOTS or #working.abilities.ultimate > 1 then return nil end
	local extraSource = self:ExtraSource()
	if #self:Candidates(offers.basic, working, false) < BASIC_SLOTS - #working.abilities.basic then return nil end
	local extra = self:Candidates(extraSource, working, true)
	if #extra == 0 then return nil end
	if #working.abilities.ultimate == 0 then
		local hasPair = false
		for _, initial in ipairs(self:Candidates(offers.ultimate, working, true)) do
			for _, second in ipairs(extra) do
				if initial ~= second then hasPair = true break end
			end
			if hasPair then break end
		end
		if not hasPair then return nil end
	end
	local remaining = 10000
	local function search(first)
		remaining = remaining - 1
		if remaining <= 0 then return false end
		local basics = working.abilities.basic
		if #basics < BASIC_SLOTS then
			for i = first, #(offers.basic or {}) do
				local ability = offers.basic[i]
				if self:CanPick(working, ability, false) then
					table.insert(basics, ability)
					if search(i + 1) then return true end
					table.remove(basics)
				end
			end
			return false
		end
		if #working.abilities.ultimate == 0 then
			for _, ability in ipairs(offers.ultimate or {}) do
				if self:CanPick(working, ability, true) then
					table.insert(working.abilities.ultimate, ability)
					if #self:Candidates(extraSource, working, true) > 0 then return true end
					table.remove(working.abilities.ultimate)
				end
			end
			return false
		end
		return #self:Candidates(extraSource, working, true) > 0
	end
	if search(1) then return working.abilities end
	return nil
end

function DraftManager:EnsureAbilityOffers(playerID, record)
	local offers = self.abilityOffers[playerID] or { basic = {}, ultimate = {} }
	self.abilityOffers[playerID] = offers
	local completion = self:FindAbilityCompletion(record, offers)
	if completion then return completion end
	local global = self:GlobalAbilityOffers(record, offers)
	completion = self:FindAbilityCompletion(record, { basic = offers.basic, ultimate = global.ultimate })
		or self:FindAbilityCompletion(record, { basic = global.basic, ultimate = offers.ultimate })
		or self:FindAbilityCompletion(record, global)
	if not completion then return nil end
	-- Repair only an unfinishable offer; valid current offers always take precedence.
	for _, kind in ipairs({ "basic", "ultimate" }) do
		for _, ability in ipairs(completion[kind]) do
			if not Contains(offers[kind], ability) and not Contains(record.abilities[kind], ability) then
				table.insert(offers[kind], ability)
			end
		end
	end
	self:SendAbilityOffers(playerID)
	return completion
end

function DraftManager:StartAbilityDraft(onComplete)
	self:BeginPhase("ability", ABILITY_DRAFT_TIME, onComplete)
	self.abilityOffers = {}
	self.abilityDone = {}
	self.abilityManager:Load()
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ability_draft_start", { time = self.timeLeft })
	self:ForEachPlayer(function(playerID, record)
		record.draftState = "ABILITY_DRAFT"
		record.abilities.basic = {}
		record.abilities.ultimate = {}
		record.draftLocked = false
		local pools = self:GlobalAbilityOffers(record)
		self.abilityOffers[playerID] = {
			basic = self.abilityManager:Sample(pools.basic, ABILITY_OFFER_BASICS, {}),
			ultimate = self.abilityManager:Sample(pools.ultimate, ABILITY_OFFER_ULTS, {}),
		}
		self:EnsureAbilityOffers(playerID, record)
		self:SendAbilityOffers(playerID)
	end)
	self:StartTimer("ability", "ai_lod_ability_timer", self.FinishAbilityDraft)
end

function DraftManager:SendAbilityOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local o = self.abilityOffers[playerID] or {}
	local record = PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ability_offers", {
		basic = Join(o.basic),
		ultimate = "",
		picked_basic = Join(record and record.abilities.basic),
		picked_ultimate = Join(record and record.abilities.ultimate),
		locked = self.abilityDone[playerID] == true,
		basic_locked = record ~= nil and #record.abilities.basic >= BASIC_SLOTS,
		ultimate_locked = true,
		time = self.timeLeft,
	})
end

function DraftManager:HandleAbilityPick(playerID, abilityName)
	if not self:AcceptAction(playerID, "ability") then return end
	if playerID == nil or self.abilityDone[playerID] then return end
	local record = PlayerState:Get(playerID)
	local offers = self.abilityOffers[playerID]
	if not record or not offers then return end
	if not Contains(offers.basic, abilityName) or #record.abilities.basic >= BASIC_SLOTS then return end
	if not self:CanPick(record, abilityName, false) then self:RefreshAbilityOffers() return end

	local target = record.abilities.basic
	table.insert(target, abilityName)
	if not self:FindAbilityCompletion(record, offers)
		and not self:FindAbilityCompletion(record, self:GlobalAbilityOffers(record, offers)) then
		table.remove(target)
		return
	end
	if not self.abilityManager:Reserve(abilityName, playerID) then table.remove(target) return end
	if #record.abilities.basic == BASIC_SLOTS then
		self.abilityDone[playerID] = true
		record.draftState = "ABILITY_LOCKED"
	end
	self:EnsureAbilityOffers(playerID, record)
	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ability_picked", {
			ability = abilityName,
			regularCount = #record.abilities.basic,
			hasUltimate = #record.abilities.ultimate > 0,
			isUltimate = false,
		})
	end
	self:SendAbilityOffers(playerID)
	self:RefreshAbilityOffers()
	self:PublishRoster()
	self:CheckAbilityDone()
end

function DraftManager:CheckAbilityDone()
	local pending = false
	self:ForEachPlayer(function(playerID, _)
		if not self.abilityDone[playerID] then pending = true end
	end)
	if not pending then self:FinishAbilityDraft() end
end

function DraftManager:FinishAbilityDraft()
	if not self.active or self.finished or self.phase ~= "ability" then return end
	local pending = false
	self:ForEachPlayer(function(playerID, record)
		if self.abilityDone[playerID] then return end
		local completion = self:EnsureAbilityOffers(playerID, record)
		if not completion then pending = true return end
		for _, ability in ipairs(completion.basic) do
			if not Contains(record.abilities.basic, ability) then
				if not self.abilityManager:Reserve(ability, playerID) then pending = true return end
				table.insert(record.abilities.basic, ability)
			end
		end
		self.abilityDone[playerID] = true
		record.draftState = "ABILITY_LOCKED"
		self:SendAbilityOffers(playerID)
	end)
	if not pending then self:CompletePhase("ai_lod_ability_draft_end") else self:Fail("basic_pool_exhausted") end
end

function DraftManager:RefreshAbilityOffers()
	self:ForEachPlayer(function(playerID, record)
		if self.phase == "ability" and not self.abilityDone[playerID] then
			local offers = self.abilityOffers[playerID] or {}
			offers.basic = self:Candidates(offers.basic, record, false)
			offers.ultimate = self:Candidates(offers.ultimate, record, true)
			self.abilityOffers[playerID] = offers
			self:EnsureAbilityOffers(playerID, record)
			self:SendAbilityOffers(playerID)
		elseif self.phase == "initial" and #record.abilities.ultimate == 0 then
			self:EnsureInitialUltOffers(playerID, record)
			self:SendInitialUltOffers(playerID)
		elseif self.phase == "ultimate" and not self.ultConfirmed[playerID] then
			self.ultOffers[playerID] = self:Candidates(self.ultOffers[playerID], record, true)
			self:EnsureUltOffers(playerID, record)
			if not Contains(self.ultOffers[playerID], self.ultPicks[playerID]) then self.ultPicks[playerID] = nil end
			self:SendUltOffers(playerID)
		end
	end)
end

function DraftManager:EnsureInitialUltOffers(playerID, record)
	local choices = self:Candidates((self.abilityOffers[playerID] or {}).ultimate, record, true)
	local valid = {}
	local function add(source)
		for _, ability in ipairs(source) do
			if not Contains(valid, ability) then
				table.insert(record.abilities.ultimate, ability)
				local hasBonus = #self:Candidates(self:ExtraSource(), record, true) > 0
				table.remove(record.abilities.ultimate)
				if hasBonus then table.insert(valid, ability) end
			end
		end
	end
	add(choices)
	if #valid == 0 then add(self:Candidates(self.abilityManager:GetPools().ultimate, record, true)) end
	self.initialUltOffers[playerID] = valid
end

function DraftManager:StartInitialUltimate(onComplete)
	self:BeginPhase("initial", ULTIMATE_DRAFT_TIME, onComplete)
	self.initialUltOffers = {}
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_initial_ult_draft_start", { time = self.timeLeft })
	self:ForEachPlayer(function(playerID, record)
		record.draftState = "INITIAL_ULTIMATE"
		self:EnsureInitialUltOffers(playerID, record)
		self:SendInitialUltOffers(playerID)
	end)
	self:StartTimer("initial", "ai_lod_initial_ult_timer", self.FinishInitialUltimate)
end

function DraftManager:SendInitialUltOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local record = PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_initial_ult_offers", {
		choices = Join(self.initialUltOffers[playerID]), selected = record.abilities.ultimate[1] or "",
		locked = #record.abilities.ultimate > 0, picked_basic = Join(record.abilities.basic),
		picked_ultimate = Join(record.abilities.ultimate), time = self.timeLeft,
	})
end

function DraftManager:LockInitialUltimate(playerID, record, ability)
	if #record.abilities.basic ~= BASIC_SLOTS or #record.abilities.ultimate ~= 0
		or not Contains(self.initialUltOffers[playerID], ability) or not self:CanPick(record, ability, true) then return false end
	if not self.abilityManager:Reserve(ability, playerID) then return false end
	table.insert(record.abilities.ultimate, ability)
	record.draftState = "INITIAL_ULTIMATE_LOCKED"
	self:SendInitialUltOffers(playerID)
	self:RefreshAbilityOffers()
	self:PublishRoster()
	return true
end

function DraftManager:HandleInitialUltPick(playerID, ability)
	if not self:AcceptAction(playerID, "initial") then return end
	local record = PlayerState:Get(playerID)
	if not self:LockInitialUltimate(playerID, record, ability) then return end
	local complete = true
	self:ForEachPlayer(function(_, p) if #p.abilities.ultimate ~= 1 then complete = false end end)
	if complete then self:FinishInitialUltimate() end
end

function DraftManager:FinishInitialUltimate()
	local pending = false
	self:ForEachPlayer(function(playerID, record)
		if #record.abilities.ultimate == 1 then return end
		self:EnsureInitialUltOffers(playerID, record)
		local ability = self.initialUltOffers[playerID][1]
		if not ability or not self:LockInitialUltimate(playerID, record, ability) then pending = true end
	end)
	if pending then self:Fail("initial_ultimate_pool_exhausted")
	else self:CompletePhase("ai_lod_initial_ult_draft_end") end
end

function DraftManager:EnsureUltOffers(playerID, record)
	local offers = self.ultOffers[playerID] or {}
	if #self:Candidates(offers, record, true) > 0 then return end
	-- This is pool-error recovery, not a player-requested extra-ultimate reroll.
	self.ultOffers[playerID] = self.abilityManager:Sample(
		self:Candidates(self:ExtraSource(), record, true), SECOND_ULT_CHOICES, {})
	self:SendUltOffers(playerID)
end

function DraftManager:StartUltimateDraft(onComplete)
	self:BeginPhase("ultimate", ULTIMATE_DRAFT_TIME, onComplete)
	self.ultOffers = {}
	self.ultPicks = {}
	self.ultConfirmed = {}
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_ult_draft_start", { time = self.timeLeft })
	self:ForEachPlayer(function(playerID, record)
		record.draftState = "BONUS_ULTIMATE_DRAFT"
		record.ultimateConfirmed = false
		local pools = self.abilityManager:GetPools()
		local source = self:Candidates(pools.extraUltimate, record, true)
		if #source < SECOND_ULT_CHOICES then source = self:Candidates(self:ExtraSource(), record, true) end
		self.ultOffers[playerID] = self.abilityManager:Sample(source, SECOND_ULT_CHOICES, {})
		self:SendUltOffers(playerID)
	end)
	self:StartTimer("ultimate", "ai_lod_ult_timer", self.FinishUltimateDraft)
end

function DraftManager:SendUltOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local record = PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_ult_offers", {
		choices = Join(self.ultOffers[playerID]),
		selected = self.ultPicks[playerID] or "",
		confirmed = self.ultConfirmed[playerID] == true,
		locked = self.ultConfirmed[playerID] == true,
		picked_basic = Join(record and record.abilities.basic),
		picked_ultimate = Join(record and record.abilities.ultimate),
		time = self.timeLeft,
	})
end

function DraftManager:HandleUltPick(playerID, abilityName)
	if not self:AcceptAction(playerID, "ultimate") then return end
	if playerID == nil or self.ultConfirmed[playerID] then return end
	if not Contains(self.ultOffers[playerID], abilityName) then return end
	local record = PlayerState:Get(playerID)
	if not record or #record.abilities.basic ~= BASIC_SLOTS or #record.abilities.ultimate ~= 1 then return end
	if not self:CanPick(record, abilityName, true) then return end
	self.ultPicks[playerID] = abilityName
	self:SendUltOffers(playerID)
end

function DraftManager:LockUltimate(playerID, record, pick)
	if #record.abilities.basic ~= BASIC_SLOTS or #record.abilities.ultimate ~= 1 then return false end
	if not Contains(self.ultOffers[playerID], pick) or not self:CanPick(record, pick, true) then return false end
	if not self.abilityManager:Reserve(pick, playerID) then return false end
	table.insert(record.abilities.ultimate, pick)
	self.ultPicks[playerID] = pick
	self.ultConfirmed[playerID] = true
	record.ultimateConfirmed = true
	record.draftState = "ULTIMATE_LOCKED"
	self:SendUltOffers(playerID)
	self:RefreshAbilityOffers()
	self:PublishRoster()
	return true
end

function DraftManager:HandleUltConfirm(playerID)
	if not self:AcceptAction(playerID, "ultimate") then return end
	if playerID == nil or self.ultConfirmed[playerID] then return end
	local record = PlayerState:Get(playerID)
	local pick = self.ultPicks[playerID]
	if not record or not pick then return end
	if self:LockUltimate(playerID, record, pick) then self:CheckUltDone() end
end

function DraftManager:CheckUltDone()
	local pending = false
	self:ForEachPlayer(function(playerID, _)
		if not self.ultConfirmed[playerID] then pending = true end
	end)
	if not pending then self:FinishUltimateDraft() end
end

function DraftManager:FinishUltimateDraft()
	if not self.active or self.finished or self.phase ~= "ultimate" then return end
	local pending = false
	self:ForEachPlayer(function(playerID, record)
		if self.ultConfirmed[playerID] then
			if #record.abilities.basic ~= BASIC_SLOTS or #record.abilities.ultimate ~= 2 then pending = true end
			return
		end
		if #record.abilities.basic ~= BASIC_SLOTS or #record.abilities.ultimate ~= 1 then
			pending = true
			return
		end
		self:EnsureUltOffers(playerID, record)
		local pick = self.ultPicks[playerID]
		if not Contains(self.ultOffers[playerID], pick) or not self:CanPick(record, pick, true) then
			pick = self:Candidates(self.ultOffers[playerID], record, true)[1]
		end
		if not pick or not self:LockUltimate(playerID, record, pick) then pending = true end
	end)
	if not pending then self:CompletePhase("ai_lod_ult_draft_end") else self:Fail("bonus_ultimate_pool_exhausted") end
end

function DraftManager:GetHeroPick(playerID)
	return self.heroPicks[playerID]
end

function DraftManager:StartBuildConfirmation(onComplete)
	self:BeginPhase("build", BUILD_CONFIRMATION_TIME, onComplete)
	self:ForEachPlayer(function(playerID, record)
		record.draftState = record.buildConfirmed and "BUILD_LOCKED" or "BUILD_CONFIRMATION"
		record.draftLocked = record.buildConfirmed == true
		self:SendBuild(playerID)
	end)
	self:StartTimer("build", "ai_lod_build_timer", self.FinishBuildConfirmation)
end

function DraftManager:SendBuild(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local record = PlayerState:Get(playerID)
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_build_confirmation", {
		hero = record.hero or "", basic = Join(record.abilities.basic), ultimate = Join(record.abilities.ultimate),
		locked = record.buildConfirmed == true, time = self.timeLeft, error = record.buildError or "",
	})
end

function DraftManager:LockBuild(playerID, record)
	if not self.abilityManager:CommitBuild(playerID, record.abilities.basic, record.abilities.ultimate) then return false end
	record.buildConfirmed = true
	record.draftLocked = true
	record.confirmedBuild = { hero = record.hero, basic = Copy(record.abilities.basic), ultimate = Copy(record.abilities.ultimate) }
	record.draftState = "BUILD_LOCKED"
	self:SendBuild(playerID)
	self:PublishRoster()
	return true
end

function DraftManager:HandleBuildConfirm(playerID)
	if not self:AcceptAction(playerID, "build") then return end
	local record = PlayerState:Get(playerID)
	if record.buildConfirmed or not self:LockBuild(playerID, record) then return end
	local pending = false
	self:ForEachPlayer(function(_, p) if not p.buildConfirmed then pending = true end end)
	if not pending then self:FinishBuildConfirmation() end
end

function DraftManager:FinishBuildConfirmation()
	local pending = false
	self:ForEachPlayer(function(playerID, record)
		if not record.buildConfirmed and not self:LockBuild(playerID, record) then pending = true end
	end)
	-- Validation owns bounded repair, including a build that became unavailable.
	if pending then
		self:ForEachPlayer(function(_, record) if not record.buildConfirmed then record.buildError = "reservation_conflict" end end)
	end
	self:CompletePhase("ai_lod_build_confirmation_end")
end

function DraftManager:ValidateBuild(playerID, record)
	if not self.heroManager:IsValidHero(record.hero) or self.heroManager:IsBanned(record.hero)
		or self.heroManager.selected[record.hero] ~= playerID then return false, "invalid_hero" end
	local snapshot = record.confirmedBuild
	if record.buildConfirmed and (not snapshot or snapshot.hero ~= record.hero
		or Join(snapshot.basic) ~= Join(record.abilities.basic)
		or Join(snapshot.ultimate) ~= Join(record.abilities.ultimate)) then return false, "build_changed" end
	local ok, reason = self.abilityManager:ValidateKit(record.hero, record.abilities.basic, record.abilities.ultimate, playerID)
	if not ok then return false, reason end
	if not self.abilityManager:CommitBuild(playerID, record.abilities.basic, record.abilities.ultimate) then
		return false, "reservation_conflict"
	end
	return true
end

function DraftManager:ValidateAndRecover()
	self.validationPasses = (self.validationPasses or 0) + 1
	if self.validationPasses > 3 then return false, false end
	local valid, changed = true, false
	self:ForEachPlayer(function(playerID, record)
		record.draftState = "ABILITY_VALIDATION"
		local ok, reason = self:ValidateBuild(playerID, record)
		if ok then
			record.buildError = nil
			if not record.buildConfirmed then changed = true end
			return
		end
		record.buildError = reason or "invalid_build"
		record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
		if record.recoveryAttempts > 2 or reason == "invalid_hero" then valid = false return end
		-- Keep other players' reservations intact; replace only the affected build.
		local replacement = { playerID = playerID, hero = record.hero, abilities = { basic = {}, ultimate = {} } }
		local completion = self:FindAbilityCompletion(replacement, self:GlobalAbilityOffers(replacement))
		if not completion then valid = false return end
		replacement.abilities = completion
		local bonus = self:Candidates(self:ExtraSource(), replacement, true)[1]
		if not bonus then valid = false return end
		table.insert(completion.ultimate, bonus)
		local check = self.abilityManager:ValidateKit(record.hero, completion.basic, completion.ultimate, playerID)
		if not check or not self.abilityManager:CommitBuild(playerID, completion.basic, completion.ultimate) then
			valid = false
			return
		end
		record.abilities = completion
		record.buildConfirmed, record.draftLocked = false, false
		record.confirmedBuild = nil
		changed = true
	end)
	self:PublishRoster()
	return valid, changed
end
