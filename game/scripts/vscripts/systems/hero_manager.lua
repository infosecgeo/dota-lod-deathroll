-- systems/hero_manager.lua
-- Full hero pool, bans, randomized 3x4 category offers, spawn helpers.

HeroManager = HeroManager or class({})
local DraftRandom = require("systems/seeded_random")

local CATEGORIES = { "Strength", "Agility", "Intelligence" }
local OFFERS_PER_CATEGORY = 4
local HERO_PREFIX = "npc_dota_hero_"

function HeroManager:constructor()
	self.pool = {}
	self.categories = {}
	self.banned = {}
	self.selected = {}
	self.loaded = false
end

function HeroManager:GetCategories()
	return CATEGORIES
end

function HeroManager:LoadPool()
	if self.loaded then
		return self.pool
	end

	local engine = LoadKeyValues("scripts/npc/herolist.txt")
	self.engineHeroes = (engine and (engine.herolist or engine.HeroList or engine)) or {}
	local kv = LoadKeyValues("scripts/config/heroes.kv")
	if not kv then
		kv = LoadKeyValues("scripts/npc/hero_categories.txt")
	end
	if kv and kv.CustomHeroList then
		kv = kv.CustomHeroList
	elseif kv and kv.Heroes then
		kv = kv.Heroes
	end

	local pool = {}
	local categories = {}
	for _, cat in ipairs(CATEGORIES) do
		categories[cat] = {}
	end

	local function addHero(name, enabled, category)
		if not (enabled == 1 or enabled == "1") then return end
		if type(name) ~= "string" or name == "" then return end
		if name:sub(1, #HERO_PREFIX) ~= HERO_PREFIX then return end
		if self.engineHeroes[name] ~= 1 and self.engineHeroes[name] ~= "1" then return end
		table.insert(pool, name)
		if category and categories[category] then
			table.insert(categories[category], name)
		end
	end

	if kv then
		for key, value in pairs(kv) do
			if type(value) == "table" then
				local cat = nil
				for _, c in ipairs(CATEGORIES) do
					if key == c then cat = c break end
				end
				if key == "PoolA" then cat = "Agility"
				elseif key == "PoolB" then cat = "Intelligence"
				elseif key == "PoolC" then cat = "Strength"
				end
				for hero, enabled in pairs(value) do
					addHero(hero, enabled, cat)
				end
			else
				addHero(key, value, nil)
			end
		end
	end

	local seen = {}
	local unique = {}
	for _, h in ipairs(pool) do
		if not seen[h] then
			seen[h] = true
			table.insert(unique, h)
		end
	end
	table.sort(unique)
	for _, cat in ipairs(CATEGORIES) do
		local cs, cu = {}, {}
		for _, h in ipairs(categories[cat] or {}) do
			if not cs[h] then cs[h] = true table.insert(cu, h) end
		end
		table.sort(cu)
		categories[cat] = cu
	end

	local anyCat = false
	for _, cat in ipairs(CATEGORIES) do
		if #(categories[cat] or {}) > 0 then anyCat = true break end
	end
	if not anyCat then
		for i, h in ipairs(unique) do
			local cat = CATEGORIES[((i - 1) % #CATEGORIES) + 1]
			table.insert(categories[cat], h)
		end
	end

	self.pool = unique
	self.categories = categories
	self.loaded = true
	print(string.format("[HeroManager] Loaded %d heroes (Str=%d Agi=%d Int=%d)",
		#unique,
		#(categories.Strength or {}),
		#(categories.Agility or {}),
		#(categories.Intelligence or {})))
	return unique
end

function HeroManager:GetCategoryHeroes(category)
	self:LoadPool()
	return self.categories[category] or {}
end

function HeroManager:GetAvailableInCategory(category)
	local out = {}
	for _, h in ipairs(self:GetCategoryHeroes(category)) do
		if self:IsAvailable(h) then
			table.insert(out, h)
		end
	end
	return out
end

function HeroManager:SampleCategory(category, count, excludeSet, hardExclude)
	self:LoadPool()
	count = count or OFFERS_PER_CATEGORY
	excludeSet = excludeSet or {}
	hardExclude = hardExclude or {}
	local offers, seen = {}, {}
	local function fill(source, previous)
		if #offers >= count then return end
		local candidates = {}
		for _, name in ipairs(source) do
			if not seen[name] and not hardExclude[name] and self:IsAvailable(name)
				and (excludeSet[name] == true) == previous then
				table.insert(candidates, name)
			end
		end
		table.sort(candidates)
		for i = #candidates, 2, -1 do
			local j = DraftRandom:Int(1, i)
			candidates[i], candidates[j] = candidates[j], candidates[i]
		end
		for _, name in ipairs(candidates) do
			if #offers >= count then break end
			seen[name] = true
			table.insert(offers, name)
		end
	end
	fill(self:GetCategoryHeroes(category), false)
	fill(self.pool, false)
	fill(self:GetCategoryHeroes(category), true)
	fill(self.pool, true)
	return offers
end

function HeroManager:BuildPlayerOffers(excludeHeroes)
	self:LoadPool()
	local offers = {}
	local exclude = {}
	if excludeHeroes then
		for _, h in ipairs(excludeHeroes) do exclude[h] = true end
	end
	local hardExclude = {}
	for _, cat in ipairs(CATEGORIES) do
		offers[cat] = self:SampleCategory(cat, OFFERS_PER_CATEGORY, exclude, hardExclude)
		for _, name in ipairs(offers[cat]) do hardExclude[name] = true end
	end
	return offers
end

function HeroManager:IsValidHero(heroName)
	for _, h in ipairs(self:LoadPool()) do
		if h == heroName then return true end
	end
	return false
end

function HeroManager:IsBanned(heroName)
	return self.banned[heroName] == true
end

function HeroManager:IsAvailable(heroName)
	return self:IsValidHero(heroName) and not self:IsBanned(heroName)
		and self.selected[heroName] == nil
end

function HeroManager:TrySelect(heroName, playerID)
	if type(playerID) ~= "number" or playerID < 0 or playerID == math.huge or playerID ~= math.floor(playerID)
		or not self:IsAvailable(heroName) then return false end
	for _, owner in pairs(self.selected) do
		if owner == playerID then return false end
	end
	self.selected[heroName] = playerID
	return true
end

function HeroManager:Ban(heroName, playerID)
	if not heroName or heroName == "" then
		return false, "empty"
	end
	if self.banned[heroName] then
		return false, "already_banned"
	end
	if not self:IsValidHero(heroName) then
		return false, "invalid"
	end
	if self.selected[heroName] ~= nil then return false, "already_selected" end
	self.banned[heroName] = true
	print(string.format("[HeroManager] Banned %s by player %s", heroName, tostring(playerID)))
	return true
end

function HeroManager:GetBannedList()
	local list = {}
	for h, _ in pairs(self.banned) do
		table.insert(list, h)
	end
	table.sort(list)
	return list
end

function HeroManager:GetDefaultHero()
	local pool = self:LoadPool()
	for _, h in ipairs(pool) do
		if self:IsAvailable(h) then
			return h
		end
	end
	return nil
end

function HeroManager:EnsureHeroForPlayer(playerID, preferredHero)
	local heroName = preferredHero
	if not heroName then
		for name, owner in pairs(self.selected) do
			if owner == playerID then heroName = name break end
		end
	end
	if not heroName or self.selected[heroName] ~= playerID
		or not self:IsValidHero(heroName) or self:IsBanned(heroName) then return nil, heroName end
	local hero = PlayerResource:GetSelectedHeroEntity(playerID)

	if hero and not hero:IsNull() then
		if hero:GetUnitName() ~= heroName then
			-- Placeholder → drafted base swap. Only legal while the preparation
			-- pause holds the world; a live mid-frame replace freezes clients.
			local gold = hero.GetGold and hero:GetGold() or 0
			local replaced = PlayerResource:ReplaceHeroWith(playerID, heroName, gold, 0)
			if replaced and not replaced:IsNull() then
				hero = replaced
			else
				return nil, heroName
			end
		else
			heroName = hero:GetUnitName()
		end
	else
		local player = PlayerResource:GetPlayer(playerID)
		if player then
			hero = CreateHeroForPlayer(heroName, player)
		else
			hero = PlayerResource:ReplaceHeroWith(playerID, heroName, 0, 0)
		end
	end

	if hero and not hero:IsNull() then
		hero:RemoveModifierByName("modifier_stunned")
		hero:RemoveModifierByName("modifier_fountain_invulnerability")
		if PlayerState then
			PlayerState:SetHero(playerID, hero:GetUnitName())
		end
	end

	return hero, heroName
end
