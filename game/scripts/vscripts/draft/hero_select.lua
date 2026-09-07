-- LEGACY (not required by V0.1). Kept for reference until systems/* fully replace this.
-- hero_select.lua
-- Phase 2: category-based hero select.
-- 3 categories × 4 heroes each; players pick one hero from the pool.

HeroSelect = HeroSelect or class({})

local SELECT_TIME = 45 -- seconds
local CATEGORIES = { "Strength", "Agility", "Intelligence" }

function HeroSelect:constructor()
	self.offers = {} -- playerID -> { category -> { heroName, ... } }
	self.picks = {} -- playerID -> heroName
	self.onComplete = nil
	self.pools = nil -- cached category -> hero list
end

function HeroSelect:LoadPools()
	if self.pools then return self.pools end

	local heroKV = LoadKeyValues("scripts/npc/hero_categories.txt")
	if heroKV and heroKV.CustomHeroList then
		heroKV = heroKV.CustomHeroList
	end

	local pools = {}
	for _, category in ipairs(CATEGORIES) do
		local heroes = {}
		local pool = heroKV and heroKV[category] or {}
		for hero, enabled in pairs(pool) do
			if enabled == 1 or enabled == "1" then
				table.insert(heroes, hero)
			end
		end
		table.sort(heroes)
		pools[category] = heroes
		if #heroes == 0 then
			print(string.format("[HeroSelect] WARNING: empty pool for category %s", category))
		else
			print(string.format("[HeroSelect] %s pool: %d heroes", category, #heroes))
		end
	end
	self.pools = pools
	return pools
end

function HeroSelect:Start(onComplete)
	print("[HeroSelect] Starting category hero select (3x4 pool)")
	self.onComplete = onComplete
	self.timeLeft = SELECT_TIME
	self.finished = false

	local pools = self:LoadPools()

	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) and PlayerResource:GetConnectionState(playerID) ~= DOTA_CONNECTION_STATE_ABANDONED then
			self.offers[playerID] = pools
			self:SendOffers(playerID)
		end
	end

	self.timer = Timers:CreateTimer(function()
		if self.finished then return nil end
		self.timeLeft = self.timeLeft - 1
		CustomGameEventManager:Send_ServerToAllClients("lod_hero_timer", { time = self.timeLeft })
		if self.timeLeft <= 0 then
			self:Finish()
			return nil
		end
		return 1
	end)
end

function HeroSelect:SendOffers(playerID)
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	local o = self.offers[playerID] or self:LoadPools()

	local function join(list)
		if not list then return "" end
		return table.concat(list, ",")
	end

	CustomGameEventManager:Send_ServerToPlayer(player, "lod_hero_offers", {
		strength = join(o.Strength),
		agility = join(o.Agility),
		intelligence = join(o.Intelligence),
		time = self.timeLeft,
	})
end

function HeroSelect:HandlePick(playerID, heroName)
	if self.finished then return end
	if self.picks[playerID] then return end
	if not heroName or heroName == "" then return end

	local pools = self:LoadPools()
	local resolved = heroName
	if pools[heroName] and pools[heroName][1] then
		resolved = pools[heroName][1]
	end

	local valid = false
	for _, category in ipairs(CATEGORIES) do
		for _, hero in ipairs(pools[category] or {}) do
			if hero == resolved then
				valid = true
				break
			end
		end
		if valid then break end
	end
	if not valid then
		print(string.format("[HeroSelect] Rejected invalid pick %s from player %d", tostring(heroName), playerID))
		return
	end

	self.picks[playerID] = resolved
	print(string.format("[HeroSelect] Player %d picked %s", playerID, resolved))

	local player = PlayerResource:GetPlayer(playerID)
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "lod_hero_picked", { hero = resolved })
	end

	self:CheckDone()
end

function HeroSelect:CheckDone()
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID)
			and PlayerResource:GetConnectionState(playerID) ~= DOTA_CONNECTION_STATE_ABANDONED
			and not self.picks[playerID] then
			return
		end
	end
	self:Finish()
end

function HeroSelect:Finish()
	if self.finished then return end
	self.finished = true
	if self.timer then Timers:RemoveTimer(self.timer) end

	local pools = self:LoadPools()
	local fallback = nil
	for _, category in ipairs(CATEGORIES) do
		if pools[category] and pools[category][1] then
			fallback = pools[category][1]
			break
		end
	end

	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) and not self.picks[playerID] then
			self.picks[playerID] = fallback or "npc_dota_hero_axe"
			print(string.format("[HeroSelect] Auto-assigned %s to player %d", self.picks[playerID], playerID))
		end
	end

	CustomGameEventManager:Send_ServerToAllClients("lod_hero_phase_end", {})
	if self.onComplete then self.onComplete() end
end

function HeroSelect:GetPick(playerID)
	return self.picks[playerID]
end
