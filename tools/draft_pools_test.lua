-- Run from the repository root with a plain Lua interpreter.
package.path = "game/scripts/vscripts/?.lua;" .. package.path
function class()
	local cls = {}
	cls.__index = cls
	return setmetatable(cls, { __call = function(self)
		local instance = setmetatable({}, self)
		instance:constructor()
		return instance
	end })
end

function LoadKeyValues(path)
	local file = io.open("game/" .. path)
	if not file then return nil end
	local text = file:read("*a"):gsub("//[^\n]*", "")
	file:close()
	-- Preserve braces alongside quoted tokens (the repository uses simple KV).
	local tokens = {}
	local position = 1
	while position <= #text do
		local char = text:sub(position, position)
		if char == '"' then
			local ending = assert(text:find('"', position + 1, true))
			table.insert(tokens, text:sub(position + 1, ending - 1))
			position = ending + 1
		elseif char == "{" or char == "}" then
			table.insert(tokens, char)
			position = position + 1
		else position = position + 1 end
	end
	position = 1
	local function parse()
		local out = {}
		while tokens[position] and tokens[position] ~= "}" do
			local key = tokens[position]
			position = position + 1
			if tokens[position] == "{" then
				position = position + 1
				out[key] = parse()
			else
				out[key] = tokens[position]
				position = position + 1
			end
		end
		position = position + 1
		return out
	end
	return parse()
end

require("systems/hero_manager")
require("systems/ability_manager")
local random = require("systems/seeded_random")
local checks = 0
local function check(value, message)
	assert(value, message)
	checks = checks + 1
end
local function same(first, second)
	if type(first) ~= type(second) then return false end
	if type(first) ~= "table" then return first == second end
	for key, value in pairs(first) do if not same(value, second[key]) then return false end end
	for key in pairs(second) do if first[key] == nil then return false end end
	return true
end

random:Init(1)
check(random:Int(1, 2147483646) == 16807, "Park-Miller reference sequence")
check(random:Snapshot().draws == 1, "draw count")
for _, seed in ipairs({ "123", -123, 0, 2147483647, math.huge, -math.huge, {}, "bad" }) do
	random:Init(seed)
	local snapshot = random:Snapshot()
	check(snapshot.seed >= 1 and snapshot.seed < 2147483647, "normalized seed")
	check(random:Int(-10, 10) >= -10, "bounded sample")
end
random:Init(0 / 0)
check(random:Snapshot().seed == 1, "NaN fallback")
check(not pcall(function() random:Int(2, 1) end), "invalid range")

local heroes = HeroManager()
check(#heroes:LoadPool() >= 100, "engine herolist intersection")
random:Init(42)
local offers = heroes:BuildPlayerOffers()
random:Init(42)
check(same(offers, heroes:BuildPlayerOffers()), "seeded reproducible offers")
local offered = {}
for _, category in ipairs(heroes:GetCategories()) do
	check(#offers[category] == 4, "four offers per category")
	for _, name in ipairs(offers[category]) do
		check(not offered[name] and heroes:IsAvailable(name), "valid unique offer")
		offered[name] = true
	end
	local reroll = heroes:SampleCategory(category, 4, offered)
	check(#reroll == 4, "four rerolls")
	for _, name in ipairs(reroll) do check(not offered[name], "fresh reroll") end
end
local selected = offers.Strength[1]
check(heroes:TrySelect(selected, 0), "reserve hero")
check(not heroes:TrySelect(selected, 1), "globally unique hero")
check(not heroes:TrySelect(offers.Strength[2], 0), "one hero per player")
check(not heroes:Ban(selected, 2), "selected hero cannot be banned")
check(heroes:EnsureHeroForPlayer(1, selected) == nil, "no unreserved hero creation")
local banned = offers.Agility[1]
check(heroes:Ban(banned, 1), "ban available hero")
check(not heroes:IsAvailable(banned), "banned unavailable")
heroes.categories.Strength = {}
local fallback = heroes:SampleCategory("Strength", 4, offered, { [offers.Intelligence[1]] = true })
check(#fallback == 4, "global shortage fallback")
for _, name in ipairs(fallback) do check(not offered[name] and heroes:IsAvailable(name), "safe fresh fallback") end
local first = heroes.pool[1]
local tiny = HeroManager()
tiny.loaded, tiny.pool, tiny.categories = true, { first, selected, banned },
	{ Strength = { first }, Agility = {}, Intelligence = {} }
tiny.banned[banned], tiny.selected[selected] = true, 0
check(same(tiny:SampleCategory("Strength", 4, { [first] = true }), { first }), "previous only after exhaustion")
check(#tiny:SampleCategory("Strength", 4, {}, { [first] = true }) == 0, "hard excludes never relaxed")
tiny.banned[first] = true
check(tiny:GetDefaultHero() == nil, "no banned/taken default")
local shared = HeroManager()
shared.loaded, shared.categories = true, { Strength = {}, Agility = {}, Intelligence = {} }
for index = 1, 12 do shared.pool[index] = heroes.pool[index] end
local globalOffers, globalSeen = shared:BuildPlayerOffers(), {}
for _, category in ipairs(shared:GetCategories()) do
	check(#globalOffers[category] == 4, "global fallback keeps 3x4 offers")
	for _, name in ipairs(globalOffers[category]) do
		check(not globalSeen[name], "no cross-category fallback duplicates")
		globalSeen[name] = true
	end
end

local abilities = AbilityManager()
local pools = abilities:GetPools()
check(#pools.regular >= 30 and #pools.ultimate >= 20, "ten-player pool capacity")
check(not abilities:ValidateAbility("not_a_real_ability"), "unknown ability rejected")
check(not abilities:ValidateAbility("invoker_invoke"), "blacklist applied")
for playerID = 0, 9 do
	local basics, ultimates = {}, {}
	for slot = 1, 3 do basics[slot] = pools.regular[playerID * 3 + slot] end
	for slot = 1, 2 do ultimates[slot] = pools.ultimate[playerID * 2 + slot] end
	check(abilities:CommitBuild(playerID, basics, ultimates), "atomic ten-player build")
	check(abilities:CommitBuild(playerID, basics, ultimates), "retained ownership")
end
local taken = pools.regular[1]
check(not abilities:IsAvailable(taken, 1) and abilities:IsAvailable(taken, 0), "owner-aware availability")
check(not abilities:Reserve(taken, 1), "cannot steal reservation")
check(not abilities:Release(taken, 1), "cannot release other owner")
local originalOwner = abilities.usedAbilities[taken]
check(not abilities:CommitBuild(0, { taken, pools.regular[4], pools.regular[3] },
	{ pools.ultimate[1], pools.ultimate[2] }), "conflicting build rejected")
check(abilities.usedAbilities[taken] == originalOwner, "failed commit preserves old owner")
check(abilities:CommitBuild(0, { pools.regular[31], pools.regular[2], pools.regular[3] },
	{ pools.ultimate[1], pools.ultimate[2] }), "successful replacement")
check(not abilities:CommitBuild(0, { [1] = pools.regular[31], [3] = pools.regular[3] },
	{ pools.ultimate[1], pools.ultimate[2] }), "sparse build rejected")
check(abilities:IsAvailable(taken), "successful commit releases previous")
local metadata = abilities:GetAbilityMetadata(taken)
check(metadata.type == "basic" and metadata.enabled == 1 and metadata.description:find(taken, 1, true), "metadata")
random:Init(91)
local sample = abilities:Sample({ pools.regular[40], pools.regular[39], pools.regular[39] }, 2)
random:Init(91)
check(same(sample, abilities:Sample({ pools.regular[39], pools.regular[40] }, 2)), "sorted unique ability sampling")

local function mockHero()
	local hero = { abilities = {}, modifiers = {}, removedModifiers = {}, playerID = 25 }
	function hero:IsNull() return false end
	function hero:IsAlive() return false end
	function hero:GetUnitName() return "npc_dota_hero_axe" end
	function hero:GetPlayerOwnerID() return self.playerID end
	function hero:HasScepter() return self.scepter == true end
	function hero:GetAbilityCount() return #self.abilities end
	function hero:GetAbilityByIndex(index) return self.abilities[index + 1] end
	function hero:FindAbilityByName(name)
		for _, ability in ipairs(self.abilities) do if ability.name == name then return ability end end
	end
	function hero:RemoveAbility(name)
		for index, ability in ipairs(self.abilities) do
			if ability.name == name then table.remove(self.abilities, index) return end
		end
	end
	function hero:RemoveModifierByName(name) self.removedModifiers[name] = true end
	function hero:FindAllModifiers() return self.modifiers end
	function hero:AddAbility(name)
		if name == self.failName then return nil end
		local ability = { name = name, level = 0, cooldown = 17, charges = 2, index = #self.abilities }
		function ability:IsNull() return false end
		function ability:GetAbilityName() return self.name end
		function ability:GetMaxLevel() return 4 end
		function ability:GetLevel() return self.level end
		function ability:SetLevel(level) self.level = level end
		function ability:IsHidden() return self.hidden == true end
		function ability:SetHidden(hidden) self.hidden = hidden end
		function ability:GetAbilityIndex() return self.index end
		function ability:SetAbilityIndex(index) self.index = index end
		function ability:GetIntrinsicModifierName() return "modifier_" .. self.name end
		table.insert(self.abilities, ability)
		if name == self.linkName then self:AddAbility("unexpected_internal") end
		return ability
	end
	return hero
end
local manager = AbilityManager()
manager.loaded = true
manager.upgrades = {}
for _, name in ipairs({ "a", "b", "c", "d", "e" }) do manager.db[name] = { type = "basic" } end
for _, name in ipairs({ "u", "v", "w" }) do manager.db[name] = { type = "ultimate" } end
manager.db.d.incompatible = "a"
check(not manager:IsCompatible("a", { "d" }, "npc_dota_hero_axe"), "symmetric incompatibility")
check(not manager:IsCompatible("d", { "a" }, "npc_dota_hero_axe"), "forward incompatibility")
manager.db.d.incompatible = nil
manager.db.d.requires = "a"
check(not manager:IsCompatible("d", {}, "npc_dota_hero_axe"), "required dependency")
check(manager:IsCompatible("d", { "a" }, "npc_dota_hero_axe"), "satisfied dependency")
manager.db.d.requires = nil
manager.db.d.hero_allowlist = "npc_dota_hero_lina"
check(not manager:IsCompatible("d", {}, "npc_dota_hero_axe"), "hero allowlist")
manager.db.d.hero_allowlist = nil
manager.db.d.hero_denylist = "npc_dota_hero_axe"
check(not manager:IsCompatible("d", {}, "npc_dota_hero_axe"), "hero denylist")
manager.db.d.hero_denylist = nil
manager.db.d.enabled = "0"
check(not manager:ValidateAbility("d"), "disabled entry")
manager.db.d.enabled = nil
manager.upgrades.e = { type = "basic", upgrade = "scepter", requires = "a" }
local hero = mockHero()
check(not manager:IsCompatible("e", { "a" }, hero:GetUnitName(), 25, hero), "required upgrade")
hero.scepter = true
check(manager:IsCompatible("e", { "a" }, hero:GetUnitName(), 25, hero), "owned upgrade")
hero:AddAbility("native_passive")
hero:AddAbility("special_bonus_native")
check(manager:ApplyKit(hero, { "a", "b", "c" }, { "u", "v" }), "apply initial kit")
check(not hero:FindAbilityByName("native_passive") and not hero:FindAbilityByName("special_bonus_native"), "strip native kit and talents")
check(hero.removedModifiers.modifier_native_passive, "strip native intrinsic")
check(manager:CommitBuild(25, { "a", "b", "c" }, { "u", "v" }), "commit initial kit")
check(manager:ValidateKit("npc_dota_hero_axe", { "a", "b", "c" }, { "u", "v" }, 25),
	"pre-spawn validation honors own reservations")
check(not manager:ValidateKit("npc_dota_hero_axe", { "a", "b", "c" }, { "u", "v" }, 26),
	"pre-spawn validation rejects other reservations")
check(manager:IsCompatible("d", { "a", "b" }, hero), "entity compatibility derives owner")
local unchanged = hero:FindAbilityByName("a")
unchanged:SetLevel(3)
hero.failName = "w"
check(not manager:ApplyDraftChanges(hero, { "a", "b", "c" }, { "u", "v" },
	{ "a", "b", "d" }, { "u", "w" }), "failed engine addition")
check(not hero:FindAbilityByName("d") and hero:FindAbilityByName("c"), "rollback staged spell")
check(manager.usedAbilities.c == 25 and manager.usedAbilities.d == nil, "rollback retains ownership")
hero.failName = nil
hero.linkName = "d"
check(not manager:ApplyDraftChanges(hero, { "a", "b", "c" }, { "u", "v" },
	{ "a", "b", "d" }, { "u", "v" }), "unexpected linked spell fails closed")
check(not hero:FindAbilityByName("unexpected_internal"), "linked rollback cleanup")
hero.linkName = nil
check(manager:ApplyDraftChanges(hero, { "a", "b", "c" }, { "u", "v" },
	{ "a", "b", "d" }, { "u", "v" }), "death replacement")
check(manager.usedAbilities.d == 25 and manager.usedAbilities.c == nil,
	"death replacement atomically commits ownership internally")
check(hero:FindAbilityByName("a") == unchanged and unchanged.level == 3
	and unchanged.cooldown == 17 and unchanged.charges == 2, "unchanged handle and state")
check(not hero:FindAbilityByName("c") and hero.removedModifiers.modifier_c, "old passive cleanup")
check(manager:CommitBuild(25, { "a", "b", "d" }, { "u", "v" }), "commit replacement")
check(manager:IsAvailable("c"), "death releases old reservation after success")
manager.pools.regular = { "c", "e" }
manager.db.c.incompatible = "a"
local deathPool = manager:GetDeathPool("basic", hero, { "a", "b", "d" }, { "u", "v" })
check(same(deathPool, { "e" }), "death pool shares compatibility and upgrade gates")
manager.db.a.hero = "npc_dota_hero_axe"
manager.db.b.hero = "npc_dota_hero_lina"
manager.db.d.hero = "npc_dota_hero_lion"
manager.db.u.hero = "npc_dota_hero_zuus"
manager.db.v.hero = "npc_dota_hero_axe"
local precacheCalls, completed = {}, 0
PrecacheUnitByNameAsync = function(name, callback, playerID)
	check(playerID == 25, "precache player context")
	table.insert(precacheCalls, { name = name, callback = callback })
end
local function cacheComplete(ok, reason)
	check(ok and reason == nil, "bounded precache succeeded")
	completed = completed + 1
end
manager:PrecacheBuild(hero:GetUnitName(), { "a", "b", "d" }, { "u", "v" }, 25, cacheComplete)
check(completed == 0 and #precacheCalls == 4, "wait for unique base and selected donors only")
manager:PrecacheBuild(hero:GetUnitName(), { "a", "b", "d" }, { "u", "v" }, 25, cacheComplete)
check(#precacheCalls == 4 and completed == 0, "share pending donor precaches")
for index = 2, #precacheCalls do
	check(precacheCalls[index - 1].name < precacheCalls[index].name, "sorted donor request order")
end
for index = #precacheCalls, 1, -1 do precacheCalls[index].callback() end
check(completed == 2, "complete each waiting build once")
precacheCalls[1].callback()
check(completed == 2, "ignore duplicate engine callback")
manager:PrecacheBuild(hero:GetUnitName(), { "a", "b", "e" }, { "u", "v" }, 25, cacheComplete)
check(completed == 3 and #precacheCalls == 4, "upgrade inherits cached parent donor")
PrecacheUnitByNameAsync = function() error("engine_precache_failed") end
local failed = false
manager:PrecacheBuild("npc_dota_hero_abaddon", { "a", "b", "d" }, { "u", "v" }, 25,
	function(ok) failed = not ok end)
check(failed and manager.precachedUnits.npc_dota_hero_abaddon == nil, "precache failure fails closed")
GetAbilityKeyValuesByName = function(name)
	if name == "a" then return { AbilityCooldown = "8 7 6 5", AbilityManaCost = "100" } end
	if name == "b" then return { AbilityBehavior = "DOTA_ABILITY_BEHAVIOR_HIDDEN" } end
	if name == "d" then return { AbilityBehavior = 3 } end
end
check(manager:ValidateAbility("a"), "installed engine definition")
check(not manager:ValidateAbility("b"), "hidden engine definition")
check(not manager:ValidateAbility("c"), "missing installed definition")
check(not manager:ValidateAbility("d"), "numeric hidden engine flag")
check(manager:GetAbilityMetadata("a").cooldown == "8 7 6 5", "engine tooltip metadata")
print(string.format("Draft pool checks passed: %d (curated capacity: %d basic, %d ultimate)",
	checks, #pools.regular, #pools.ultimate))
