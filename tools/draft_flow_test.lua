-- Run from the repository root: lua tools/draft_flow_test.lua
-- Real configured managers/state flow; Dota entities, events and wall clock are mocked.
package.path = "game/scripts/vscripts/?.lua;" .. package.path

function class(base)
	base.__index = base
	return setmetatable(base, { __call = function(cls, ...)
		local instance = setmetatable({}, cls)
		if instance.constructor then instance:constructor(...) end
		return instance
	end })
end

function LoadKeyValues(path)
	local file = io.open("game/" .. path)
	if not file then return nil end
	local text = file:read("*a"):gsub("//[^\n]*", "")
	file:close()
	local tokens, position = {}, 1
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

local checks = 0
local function check(value, message)
	assert(value, message)
	checks = checks + 1
end

DOTA_MAX_PLAYERS = 24
DOTA_TEAM_GOODGUYS, DOTA_TEAM_BADGUYS, DOTA_TEAM_NEUTRALS = 2, 3, 4
DOTA_CONNECTION_STATE_CONNECTED = 2
DOTA_GAMERULES_STATE_CUSTOM_GAME_SETUP = 6
DOTA_GAMERULES_STATE_PRE_GAME = 7
DOTA_GAMERULES_STATE_GAME_IN_PROGRESS = 8
DOTA_GAMERULES_STATE_POST_GAME = 9
LUA_MODIFIER_MOTION_NONE = 0

local clock, tools, configuredSeed, nativeState = 0, false, 0, 7
local teams, connected, players, entities, heroes, gold, fakeClients
local events, netTables, handlers, precaches, assetCallbacks, deferAssets
local nextBotID
function Time() return clock end
function IsInToolsMode() return tools end
function LinkLuaModifier() end
function ListenToGameEvent() end
function Dynamic_Wrap() return function() end end
function PauseGame() end
function EntIndexToHScript(index) return entities[index] end
Convars = { GetInt = function() return configuredSeed end, SetInt = function() end }
CustomNetTables = { SetTableValue = function(_, name, key, payload)
	check(name == "ai_lod_match", "flow must only write a declared nettable")
	netTables[key] = payload
end }
CustomGameEventManager = {
	Send_ServerToAllClients = function(_, name, payload) events[name] = payload end,
	Send_ServerToPlayer = function(_, player, name, payload)
		events[name] = payload
		player.events[name] = payload
	end,
	RegisterListener = function(_, name, callback) handlers[name] = callback end,
}
PlayerResource = {
	IsValidPlayerID = function(_, id) return teams[id] ~= nil end,
	GetTeam = function(_, id) return teams[id] end,
	GetConnectionState = function(_, id) return connected[id] and 2 or 0 end,
	IsFakeClient = function(_, id) return fakeClients[id] == true end,
	GetPlayer = function(_, id) return players[id] end,
	GetSelectedHeroEntity = function(_, id) return heroes[id] end,
	GetGold = function(_, id) return gold[id] or 0 end,
	SetCustomTeamAssignment = function(_, id, team) teams[id] = team end,
	SetPlayerName = function() end,
}
GameRules = {
	GetGameTime = function() return clock end,
	State_Get = function() return nativeState end,
	GetGameModeEntity = function() return {
		SetPauseEnabled = function() end,
		SetBotThinkingEnabled = function() end,
		SetBotsInLateGame = function() end,
	} end,
	ForceGameStart = function()
		nativeState = DOTA_GAMERULES_STATE_GAME_IN_PROGRESS
		GameState.owner:OnGameRulesStateChange()
	end,
	SetSafeToLeave = function() end,
	SetGameWinner = function(self, winner) self.winner = winner end,
	GetGameWinner = function(self) return self.winner end,
	EnableCustomGameSetupAutoLaunch = function() end,
	SetCustomGameSetupTimeout = function() end,
	SetCustomGameSetupAutoLaunchDelay = function() end,
	SetCustomGameSetupRemainingTime = function(_, seconds) GameRules.setupRemaining = seconds end,
	LockCustomGameSetupTeamAssignment = function(_, locked) GameRules.setupLocked = locked end,
	FinishCustomGameSetup = function()
		GameRules.setupFinished = true
		nativeState = DOTA_GAMERULES_STATE_PRE_GAME
		if GameState.owner then GameState.owner:OnGameRulesStateChange() end
	end,
	AddBotPlayerWithEntityScript = function(_, _hero, name, team)
		local id = nil
		for candidate = 0, DOTA_MAX_PLAYERS - 1 do
			if teams[candidate] == nil then id = candidate break end
		end
		if id == nil then return -1 end
		teams[id], connected[id], gold[id], fakeClients[id] = team, true, 600, true
		players[id] = {
			id = id, name = name, events = {},
			IsNull = function() return false end,
			GetPlayerID = function() return id end,
			SetTeam = function(_, nextTeam) teams[id] = nextTeam end,
		}
		entities[1000 + id] = players[id]
		return id
	end,
}
MatchResults = { Snapshot = function(_, winner) return { winner = winner } end }
Timers = {
	CreateTimer = function(self, callback)
		self.nextID = self.nextID + 1
		self.callbacks[self.nextID] = callback
		return self.nextID
	end,
	RemoveTimer = function(self, id) self.callbacks[id] = nil end,
	Stop = function(self) self.callbacks = {} end,
}
local function advance(seconds)
	for _ = 1, seconds do
		clock = clock + 1
		local ids = {}
		for id in pairs(Timers.callbacks) do table.insert(ids, id) end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local callback = Timers.callbacks[id]
			if callback and not callback() then Timers.callbacks[id] = nil end
		end
	end
end

function PrecacheUnitByNameAsync(name, callback)
	table.insert(precaches, name)
	if deferAssets then table.insert(assetCallbacks, callback) else callback() end
end
function CreateHeroForPlayer(name, player)
	local hero = { name = name, owner = player.id, abilities = {}, inventory = {} }
	function hero:IsNull() return false end
	function hero:GetUnitName() return self.name end
	function hero:GetPlayerOwnerID() return self.owner end
	function hero:GetGold() return gold[self.owner] end
	function hero:entindex() return 2000 + self.owner end
	function hero:AddNewModifier() end
	function hero:RemoveModifierByName() end
	function hero:Stop() end
	function hero:GetAbilityCount() return #self.abilities end
	function hero:GetAbilityByIndex(index) return self.abilities[index + 1] end
	function hero:FindAbilityByName(abilityName)
		for _, ability in ipairs(self.abilities) do
			if ability.name == abilityName then return ability end
		end
	end
	function hero:AddAbility(abilityName)
		local ability = { name = abilityName }
		function ability:IsNull() return false end
		function ability:IsHidden() return false end
		function ability:GetAbilityName() return self.name end
		function ability:GetMaxLevel() return 4 end
		function ability:SetLevel(level) self.level = level end
		function ability:SetHidden() end
		function ability:SetAbilityIndex(index) self.index = index end
		table.insert(self.abilities, ability)
		return ability
	end
	heroes[player.id] = hero
	return hero
end

for _, name in ipairs({
	"libraries/timers", "systems/reroll_manager", "systems/respawn_manager",
	"systems/balance_manager", "systems/match_results", "mmr/client",
}) do package.loaded[name] = {} end
require("gamemode")
local random = require("systems/seeded_random")

local function addPlayer(id, team, bot)
	teams[id], connected[id], gold[id] = team, true, 600
	fakeClients[id] = bot == true
	players[id] = {
		id = id, events = {},
		IsNull = function() return false end,
		GetPlayerID = function() return id end,
		SetTeam = function(_, nextTeam) teams[id] = nextTeam end,
	}
	entities[1000 + id] = players[id]
end
local function setup(count)
	clock, tools, configuredSeed, nativeState = 0, false, 0, 7
	teams, connected, players, entities, heroes, gold, fakeClients = {}, {}, {}, {}, {}, {}, {}
	events, netTables, handlers, precaches, assetCallbacks = {}, {}, {}, {}, {}
	deferAssets, GameRules.winner, nextBotID = false, nil, 20
	GameRules.setupRemaining, GameRules.setupLocked, GameRules.setupFinished = nil, nil, false
	Timers.callbacks, Timers.nextID = {}, 0
	for id = 0, count - 1 do addPlayer(id, id < 5 and 2 or 3) end
	local owner = AILODGameMode()
	owner.enableLodDraft, owner.fillEmptyWithBots, owner.heldUnits = true, false, {}
	PlayerState:Init()
	GameState:Init(owner)
	owner.heroManager, owner.abilityManager = HeroManager(), AbilityManager()
	owner.heroManager:LoadPool()
	owner.abilityManager:Load()
	owner.banManager = BanManager(owner.heroManager)
	owner.draftManager = DraftManager(owner.heroManager, owner.abilityManager)
	owner.botManager = BotManager(owner)
	owner.respawnManager = { SyncPlayer = function() end, CancelAll = function() end }
	owner:RegisterStateHandlers()
	owner:RegisterEvents()
	PlayerState:ForEachParticipant(function(_, record) record.clientReady, record.lobbyReady = true, true end)
	local countHandlers = 0
	for _, listeners in pairs(GameState.listeners) do
		check(#listeners == 1, "one handler per state")
		countHandlers = countHandlers + 1
	end
	check(countHandlers == 12, "all handlers registered before any phase")
	return owner
end
local function signature()
	local out = {}
	PlayerState:ForEachParticipant(function(_, record)
		table.insert(out, record.hero or "")
		table.insert(out, table.concat(record.abilities.basic, ","))
		table.insert(out, table.concat(record.abilities.ultimate, ","))
	end)
	return table.concat(out, "|")
end
local function phase(state, message) check(GameState:Is(state), message or GameState:Name(state)) end

local owner = setup(0)
check(not owner:LobbyCanStart(), "empty public lobby denied")
tools = true
check(not owner:LobbyCanStart(), "empty tools lobby denied")
addPlayer(0, 2)
PlayerState:Get(0).clientReady, PlayerState:Get(0).lobbyReady = true, true
check(owner:LobbyCanStart(), "tools solo allowed")
tools = false
check(not owner:LobbyCanStart(), "public solo without opposite team denied")
addPlayer(1, 2)
PlayerState:Get(1).clientReady, PlayerState:Get(1).lobbyReady = true, true
check(not owner:LobbyCanStart(), "public missing team denied")
teams[1] = 3
check(owner:LobbyCanStart(), "public minimum and both teams allowed")
PlayerState:LockRoster()
teams[1] = nil
addPlayer(2, 3)
check(PlayerState:IsParticipant(1) and PlayerState:GetTeam(1) == 3, "disconnected frozen slot retained")
check(not PlayerState:IsParticipant(2), "late entrant excluded")

-- Bot fill tops both teams to 5 and auto-drafts random kits on hard AI slots.
owner = setup(1)
owner.fillEmptyWithBots = true
fakeClients[0] = false
PlayerState:Get(0).clientReady, PlayerState:Get(0).lobbyReady = true, true
check(owner.botManager:FillEmptySlots(), "bot fill runs")
check(owner.botManager:TeamCount(DOTA_TEAM_GOODGUYS) == 5, "radiant filled to 5")
check(owner.botManager:TeamCount(DOTA_TEAM_BADGUYS) == 5, "dire filled to 5")
local botSeen = false
PlayerState:ForEachParticipant(function(id, record)
	if id ~= 0 then
		botSeen = botSeen or PlayerState:IsBot(id)
		check(record.lobbyReady and record.clientReady, "bots are lobby-ready")
		check(type(record.botName) == "string" and record.botName ~= "", "bots receive random names")
	end
end)
check(botSeen, "fake clients registered as bots")
check(owner:LobbyCanStart(), "one human plus bot-filled teams can start")

-- Unassigned humans/bots are pulled onto balanced playable teams before fill.
owner = setup(0)
owner.fillEmptyWithBots = true
addPlayer(0, 0) -- unassigned human host
addPlayer(1, 0, true) -- unassigned bot stuck in team-select column
fakeClients[0] = false
check(owner.botManager:FillEmptySlots(), "fill after auto-assign")
check(PlayerResource:GetTeam(0) == DOTA_TEAM_GOODGUYS or PlayerResource:GetTeam(0) == DOTA_TEAM_BADGUYS,
	"unassigned human auto-assigned")
check(PlayerResource:GetTeam(1) == DOTA_TEAM_GOODGUYS or PlayerResource:GetTeam(1) == DOTA_TEAM_BADGUYS,
	"unassigned bot auto-assigned")
check(owner.botManager:TeamCount(DOTA_TEAM_GOODGUYS) == 5, "radiant full after reclaim")
check(owner.botManager:TeamCount(DOTA_TEAM_BADGUYS) == 5, "dire full after reclaim")

-- Native team-select countdown finishes setup then starts LOD lobby countdown.
owner = setup(1)
owner.fillEmptyWithBots = true
fakeClients[0] = false
PlayerState:Get(0).clientReady, PlayerState:Get(0).lobbyReady = false, false
nativeState = DOTA_GAMERULES_STATE_CUSTOM_GAME_SETUP
owner:OnGameRulesStateChange()
check(owner.setupStarted, "custom game setup loop armed")
advance(1)
check(owner.botManager:TeamsFull(), "setup loop fills empty slots")
check(type(GameRules.setupRemaining) == "number" and GameRules.setupRemaining <= 10, "setup countdown published")
advance(10)
check(GameRules.setupFinished == true, "setup countdown finishes custom game setup")
check(nativeState == DOTA_GAMERULES_STATE_PRE_GAME, "engine advanced to pre-game")
check(owner.flowStarted, "LOD lobby flow starts after setup")
advance(8)
check(PlayerState:Get(0).lobbyReady == true and PlayerState:Get(0).clientReady == true,
	"lobby auto-ready without UI after grace")
advance(5)
phase(GameState.BAN, "lobby countdown starts the ban phase")
owner.botManager:AutoBan(owner.banManager)
PlayerState:ForEachParticipant(function(id, record)
	if PlayerState:IsBot(id) then check(#record.bannedHeroes > 0, "bots ban immediately") end
end)
owner.banManager:Finish()
phase(GameState.HERO_DRAFT)
owner.botManager:AutoHero(owner.draftManager)
PlayerState:ForEachParticipant(function(id, record)
	if PlayerState:IsBot(id) then check(record.hero ~= nil, "bots pick random heroes") end
end)
-- Human still open so phase stays active; finish via timeout path later in lifecycle tests.
owner.draftManager:Cancel()
GameState.current = GameState.LOBBY

local function lifecycle(seed, repair)
	local mode = setup(10)
	local draft = mode.draftManager
	random:Init(999)
	random:Int(1, 100)
	tools = true
	mode:BeginMatchFlow()
	advance(2)
	PlayerState:Get(0).lobbyReady = false
	advance(1)
	check(mode.lobbyDeadline == nil, "unready resets countdown")
	PlayerState:Get(0).lobbyReady = true
	configuredSeed = seed
	advance(6)
	phase(GameState.BAN)
	check(random:Snapshot().seed == seed and random:Snapshot().draws == 0, "lobby seed read before offers")
	addPlayer(12, 2)
	check(not PlayerState:IsParticipant(12), "new slot cannot enter frozen draft")
	connected[9] = false
	advance(50)
	phase(GameState.HERO_DRAFT)
	mode:OnClientReady(0)
	local offer = players[0].events.ai_lod_hero_offers
	local preview = offer.hero_abilities[draft.heroOffers[0].Strength[1]]
	check(type(preview) == "string" and preview ~= "", "native ability preview CSV")
	check(netTables.roster.banned ~= "", "bans persist after BAN")
	check(not draft:AcceptAction(12, "hero"), "nonparticipant draft rejection")
	advance(30)
	phase(GameState.ABILITY_DRAFT)
	draft:HandleAbilityPick(0, draft.abilityOffers[0].ultimate[1])
	check(#PlayerState:Get(0).abilities.ultimate == 0, "basic phase cannot pick an ultimate")
	advance(30)
	phase(GameState.INITIAL_ULTIMATE)
	PlayerState:ForEachParticipant(function(_, record)
		check(#record.abilities.basic == 3 and #record.abilities.ultimate == 0, "basic timeout picks only basics")
	end)
	mode:OnClientReady(0)
	check(players[0].events.ai_lod_initial_ult_offers ~= nil, "initial ultimate reconnect snapshot")
	advance(20)
	phase(GameState.ULTIMATE_DRAFT)
	advance(20)
	phase(GameState.BUILD_CONFIRMATION)
	local original = signature()
	local seen = {}
	PlayerState:ForEachParticipant(function(id, record)
		for _, list in ipairs({ record.abilities.basic, record.abilities.ultimate }) do
			for _, ability in ipairs(list) do
				check(not seen[ability], "ten-player global uniqueness")
				seen[ability] = id
			end
		end
		check(mode.abilityManager:ValidateKit(record.hero, record.abilities.basic, record.abilities.ultimate, id),
			"own reservations accepted by actual manager")
	end)
	local invalid
	if repair then
		invalid = PlayerState:Get(0).abilities.basic[1]
		mode.abilityManager.db[invalid].enabled = false
	end
	advance(15)
	if repair then
		phase(GameState.BUILD_CONFIRMATION, "invalid build returns to confirmation")
		check(not PlayerState:Get(0).buildConfirmed, "affected build unlocked")
		check(PlayerState:Get(1).buildConfirmed, "unaffected confirmation preserved")
		check(mode.abilityManager.usedAbilities[invalid] == nil, "invalid reservation released")
		advance(15)
	end
	advance(1)
	phase(GameState.STRATEGY)
	check(#precaches > 0 and #precaches <= 60, "only final bases and selected donors precached")
	local saved = {}
	PlayerState:ForEachParticipant(function(id, record)
		saved[id] = record.preparedHero
		check(record.prepared and #saved[id].abilities == 5, "every real manager kit prepared")
	end)
	table.insert(saved[0].inventory, "item_branches")
	gold[0] = 450
	handlers.ai_lod_strategy_lane(1000, { lane = "top", PlayerID = 1 })
	check(PlayerState:Get(0).lane == "top" and PlayerState:Get(1).lane == "", "lane uses authenticated source")
	handlers.ai_lod_strategy_lane(1012, { lane = "jungle" })
	entities[9999] = { IsNull = function() return false end, GetPlayerID = function() return 0 end }
	handlers.ai_lod_strategy_lane(9999, { lane = "jungle" })
	handlers.ai_lod_strategy_lane(1000, { lane = "invalid" })
	check(PlayerState:Get(0).lane == "top", "invalid lane and late entrant rejected")
	mode:OnClientReady(0)
	local row = players[0].events.ai_lod_preparation.players[1]
	check(row.basic ~= "" and row.ultimate ~= "" and row.abilities.basic == row.basic, "strategy reconnect kit CSV")
	check(row.starting_gold == 600 and row.gold == 450 and row.lane == "top", "gold and lane snapshot")
	advance(15)
	phase(GameState.INTRODUCTION)
	handlers.ai_lod_strategy_lane(1000, { lane = "mid" })
	check(PlayerState:Get(0).lane == "top", "lane rejected outside strategy")
	advance(5)
	phase(GameState.PLAYING)
	PlayerState:ForEachParticipant(function(id, record)
		check(record.preparedHero == saved[id], "prepared entity preserved through game start")
	end)
	check(saved[0].inventory[1] == "item_branches", "strategy purchases preserved")
	local sequence = {}
	for _, entry in ipairs(GameState.history) do table.insert(sequence, GameState:Name(entry.to)) end
	if not repair then
		check(table.concat(sequence, ",") ==
			"BAN_HEROES,GENERATE_HERO_POOLS,SELECT_BASE_HERO,ABILITY_DRAFT,INITIAL_ULTIMATE," ..
			"BONUS_ULTIMATE_DRAFT,BUILD_CONFIRMATION,ABILITY_VALIDATION,STRATEGY_TIME,INTRODUCTION,GAME_START,GAME",
			"complete canonical phase order")
	end
	for _, listeners in pairs(GameState.listeners) do check(#listeners == 1, "no nested handler accumulation") end
	GameRules.winner = DOTA_TEAM_GOODGUYS
	mode:FinishMatch()
	phase(GameState.GAME_END)
	check(next(Timers.callbacks) == nil, "match end cancels timers")
	return original
end

local replay = lifecycle(12345, true)
check(replay == lifecycle(12345, false), "same seed, roster and events reproduce all draft selections")
check(replay ~= lifecycle(54321, false), "different seed changes draft selections")

owner = setup(2)
teams[1] = 3
PlayerState:LockRoster()
GameState.current = GameState.HERO_DRAFT
owner.draftManager:GenerateHeroPools()
owner.draftManager:StartHeroDraft(function() end)
owner.draftManager:HandleHeroReroll(0, "strength")
check(PlayerState:Get(0).rerolls.heroCategory1 == 0, "legitimate category reroll consumes one budget")
local afterReroll = random:Snapshot().draws
owner.draftManager:HandleHeroReroll(0, "strength")
check(random:Snapshot().draws == afterReroll, "exhausted reroll cannot consume randomness")
local visible = {}
for _, category in ipairs(owner.heroManager:GetCategories()) do
	for _, hero in ipairs(owner.draftManager.heroOffers[0][category]) do
		check(not visible[hero], "reroll retains cross-category uniqueness")
		visible[hero] = true
	end
end
local picked = owner.draftManager.heroOffers[0].Strength[1]
owner.draftManager:HandleHeroPick(0, picked)
owner.draftManager:HandleHeroPick(1, picked)
check(owner.draftManager.heroPicks[1] == nil, "conflicting hero selection rejected")
clock = owner.draftManager.deadline
check(not owner.draftManager:AcceptAction(1, "hero"), "exact deadline rejects player action")
owner.draftManager:Cancel()
owner.heroManager.selected = {}
for _, hero in ipairs(owner.heroManager:LoadPool()) do owner.heroManager.banned[hero] = true end
owner.draftManager.heroOffers = {}
owner.draftManager:StartHeroDraft(function() error("empty pool must not advance") end)
advance(30)
phase(GameState.GAME_END)
check(owner.preparationError == "hero_pool_exhausted", "exhausted pool fails closed, not stuck at zero")

owner = setup(1)
PlayerState:LockRoster()
GameState.current = GameState.ABILITY_DRAFT
local base = owner.heroManager:LoadPool()[1]
owner.heroManager:TrySelect(base, 0)
PlayerState:SetHero(0, base)
owner.abilityManager.pools.regular = {}
owner.draftManager:StartAbilityDraft(function() error("empty abilities must not advance") end)
advance(30)
phase(GameState.GAME_END)
check(owner.preparationError == "basic_pool_exhausted", "impossible basic pool has bounded termination")

owner = setup(1)
PlayerState:LockRoster()
GameState.current = GameState.ABILITY_VALIDATION
local record = PlayerState:Get(0)
record.hero = owner.heroManager:LoadPool()[1]
record.abilities.basic = { "a", "b", "c" }
record.abilities.ultimate = { "u", "v" }
record.buildConfirmed, record.draftLocked = true, true
owner.draftManager.ValidateBuild = function() return true end
local callbacks, applies = {}, 0
owner.abilityManager.PrecacheBuild = function(_, _, _, _, _, callback) table.insert(callbacks, callback) end
owner.abilityManager.ApplyKit = function() applies = applies + 1 return true end
owner.preparationDeadline = 30
check(not owner:PreparePlayer(0, record) and applies == 0, "pending assets block entity installation")
record.abilities.basic[1] = "replacement"
check(not owner:PreparePlayer(0, record) and #callbacks == 2, "changed build requests new precache")
callbacks[1](true)
check(not record.precacheReady, "stale build precache callback ignored")
clock = 30
callbacks[2](true)
check(not record.precacheReady and not owner:PreparePlayer(0, record), "exact-deadline completion rejected")
owner.draftManager.validationPasses = 3
check(not owner.draftManager:ValidateAndRecover(), "validation recovery pass budget is bounded")

owner = setup(1)
GameState.current = GameState.ABILITY_VALIDATION
owner.PreparePlayer = function() return false end
owner:PrepareHeroes()
advance(30)
phase(GameState.GAME_END)
check(owner.preparationError == "hero_preparation_failed", "engine preparation failure is bounded and fail closed")

print(string.format("draft_flow_test.lua: %d assertions passed", checks))
