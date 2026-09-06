-- hero_select.lua
-- Phase 2: category-based hero select with rerolls.
-- Each player is offered one hero per category and may reroll a limited number of times.

HeroSelect = HeroSelect or class({})

local MAX_REROLLS = 2
local SELECT_TIME = 45 -- seconds
local CATEGORIES = { "Strength", "Agility", "Intelligence", "Universal" }

function HeroSelect:constructor()
	self.offers = {} -- playerID -> { category -> heroName }
	self.rerollsLeft = {} -- playerID -> int
	self.picks = {} -- playerID -> heroName
	self.onComplete = nil
end

function HeroSelect:Start(onComplete)
	print("[HeroSelect] Starting category hero select")
	self.onComplete = onComplete
	self.timeLeft = SELECT_TIME

	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			self.rerollsLeft[playerID] = MAX_REROLLS
			self.offers[playerID] = self:RollOffers()
			self:SendOffers(playerID)
		end
	end

	self.timer = Timers:CreateTimer(function()
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("lod_hero_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:Finish()
			return nil
		end
		return 1
	end)
end

function HeroSelect:RollOffers()
	local heroKV = LoadKeyValues("scripts/npc/herolist.txt")
	local offers = {}
	for _, category in ipairs(CATEGORIES) do
		local pool = heroKV and heroKV[category] or {}
		local heroes = {}
		for hero, _ in pairs(pool) do
			table.insert(heroes, hero)
		end
		if #heroes > 0 then
			offers[category] = heroes[RandomInt(1, #heroes)]
		end
	end
	return offers
end

function HeroSelect:SendOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local o = self.offers[playerID] or {}
	CustomGameEventManager:Send_ServerToPlayer(player, "lod_hero_offers", {
		strength = o.Strength or "",
		agility = o.Agility or "",
		intelligence = o.Intelligence or "",
		universal = o.Universal or "",
		rerolls = self.rerollsLeft[playerID],
		time = self.timeLeft,
	})
end

function HeroSelect:HandleReroll(playerID)
	if not self.rerollsLeft[playerID] or self.rerollsLeft[playerID] <= 0 then return end
	if self.picks[playerID] then return end
	self.rerollsLeft[playerID] = self.rerollsLeft[playerID] - 1
	self.offers[playerID] = self:RollOffers()
	self:SendOffers(playerID)
end

function HeroSelect:HandlePick(playerID, category)
	local offer = self.offers[playerID]
	if not offer or not offer[category] then return end
	self.picks[playerID] = offer[category]
	print(string.format("[HeroSelect] Player %d picked %s (%s)", playerID, offer[category], category))
	self:CheckDone()
end

function HeroSelect:CheckDone()
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) and not self.picks[playerID] then
			return
		end
	end
	self:Finish()
end

function HeroSelect:Finish()
	if self.timer then Timers:RemoveTimer(self.timer) end
	-- Assign random hero from remaining offers for players who did not pick
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) and not self.picks[playerID] then
			local o = self.offers[playerID]
			if o then
				for _, hero in pairs(o) do
					self.picks[playerID] = hero
					break
				end
			end
		end
	end
	CustomGameEventManager:Send_ServerToAllClients("lod_hero_phase_end", {})
	if self.onComplete then self.onComplete() end
end

function HeroSelect:GetPick(playerID)
	return self.picks[playerID]
end
