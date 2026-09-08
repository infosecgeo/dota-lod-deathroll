-- The custom draft and presentation run in PRE_GAME, not native strategy.
require("libraries/timers")
require("systems/game_state")
require("systems/player_state")
local DraftRandom = require("systems/seeded_random")
require("systems/hero_manager")
require("systems/ability_manager")
require("systems/ban_manager")
require("systems/draft_manager")
require("systems/reroll_manager")
require("systems/respawn_manager")
require("systems/balance_manager")
require("systems/match_results")
require("systems/bot_manager")
require("mmr/client")

LinkLuaModifier("modifier_ai_lod_preparation", "modifiers/modifier_ai_lod_preparation", LUA_MODIFIER_MOTION_NONE)

AILODGameMode = AILODGameMode or class({})
local ENABLE_LOD_DRAFT = true
local FILL_EMPTY_WITH_BOTS = true
-- Native team-select countdown before FinishCustomGameSetup.
local SETUP_COUNTDOWN = 10
-- Custom LOD lobby countdown after PRE_GAME (ban draft gate).
local LOBBY_COUNTDOWN = 5
local LOBBY_AUTO_READY_AFTER = 8
local PREPARATION_TIMEOUT = 30
local STRATEGY_TIME = 15
local INTRODUCTION_TIME = 5
-- Placeholder body only. Native HERO_SELECTION must not random-pick real heroes
-- before BAN_HEROES; PreparePlayer replaces this with the drafted base.
local PLACEHOLDER_HERO = "npc_dota_hero_wisp"
-- Let ban/hero panels paint before bots commit instant picks.
local BOT_DRAFT_ACTION_DELAY = 2

function AILODGameMode:InitGameMode()
	self.enableLodDraft = ENABLE_LOD_DRAFT
	self.fillEmptyWithBots = FILL_EMPTY_WITH_BOTS
	self.flowStarted = false
	self.ended = false
	self.heldUnits = {}
	PlayerState:Init()
	GameState:Init(self)
	if IsInToolsMode() and Convars.RegisterConvar then
		Convars:RegisterConvar("ai_lod_seed", "0", "Deterministic draft seed (0 uses match/time)", 0)
	end
	local seed = IsInToolsMode() and Convars:GetInt("ai_lod_seed") or 0
	if not seed or seed == 0 then
		seed = tonumber(GameRules.GetMatchID and GameRules:GetMatchID()) or 0
		if seed == 0 then seed = math.floor(Time() * 1000) + 1 end
	end
	self.draftSeed = seed
	DraftRandom:Init(seed)
	self.heroManager = HeroManager()
	self.abilityManager = AbilityManager()
	self.abilityManager:Load()
	self.banManager = BanManager(self.heroManager)
	self.draftManager = DraftManager(self.heroManager, self.abilityManager)
	self.botManager = BotManager(self)
	self.rerollManager = RerollManager()
	self.respawnManager = RespawnManager(self.abilityManager, self.rerollManager)
	self.respawnManager.enabledDraft = ENABLE_LOD_DRAFT
	self.balanceManager = BalanceManager(self.abilityManager)
	self.balanceManager:Load()
	self.mmrClient = MMRClient()
	self.heroManager:LoadPool()
	self:SetupGameRules()
	self:RegisterStateHandlers()
	self:RegisterEvents()
	Timers:Start()
end

function AILODGameMode:SetupGameRules()
	GameRules:SetCustomGameTeamMaxPlayers(DOTA_TEAM_GOODGUYS, 5)
	GameRules:SetCustomGameTeamMaxPlayers(DOTA_TEAM_BADGUYS, 5)
	-- Server owns setup: assign players, fill bots, show countdown, then launch.
	if GameRules.SetCustomGameSetupTimeout then
		-- -1 keeps the panel open until we call FinishCustomGameSetup.
		GameRules:SetCustomGameSetupTimeout(-1)
	end
	if GameRules.EnableCustomGameSetupAutoLaunch then
		GameRules:EnableCustomGameSetupAutoLaunch(true)
	end
	GameRules:SetCustomGameSetupAutoLaunchDelay(SETUP_COUNTDOWN)
	if GameRules.SetCustomGameSetupRemainingTime then
		GameRules:SetCustomGameSetupRemainingTime(SETUP_COUNTDOWN)
	end
	-- Use 1s (not 0): some engine builds treat 0 as "wait forever" and never
	-- leave native hero selection when combined with ForceHero placeholders.
	GameRules:SetStrategyTime(self.enableLodDraft and 1 or 0)
	GameRules:SetShowcaseTime(self.enableLodDraft and 1 or 0)
	GameRules:SetPostGameTime(30)
	GameRules:SetTreeRegrowTime(60)
	GameRules:SetUseUniversalShopMode(true)
	GameRules:SetSameHeroSelectionEnabled(true)
	GameRules:SetHeroSelectionTime(self.enableLodDraft and 1 or 30)
	GameRules:SetHeroSelectPenaltyTime(self.enableLodDraft and 0 or 5)
	-- This clock is server-paused throughout readiness/drafting/kit creation.
	-- Only the bounded 15 + 5 second presentation consumes pregame time.
	GameRules:SetPreGameTime(120)
	local mode = GameRules:GetGameModeEntity()
	-- LOD owns the final base hero after BAN → draft. Force a shared placeholder
	-- so the engine cannot auto-assign real heroes (or bot picks) during the
	-- short native hero-selection window before PRE_GAME bans start.
	if self.enableLodDraft and mode.SetCustomGameForceHero then
		mode:SetCustomGameForceHero(PLACEHOLDER_HERO)
	end
	mode:SetRecommendedItemsDisabled(false)
	mode:SetBuybackEnabled(true)
	mode:SetPauseEnabled(false)
	mode:SetCustomHeroMaxLevel(30)
	mode:SetFogOfWarDisabled(false)
	mode:SetUnseenFogOfWarEnabled(true)
	if mode.SetFixedRespawnTime then mode:SetFixedRespawnTime(-1) end
	if mode.SetBotThinkingEnabled then mode:SetBotThinkingEnabled(true) end
	if mode.SetBotsInLateGame then mode:SetBotsInLateGame(true) end
	mode:SetExecuteOrderFilter(Dynamic_Wrap(AILODGameMode, "FilterOrder"), self)
	mode:SetDamageFilter(function() return not self.ended and GameState:Is(GameState.PLAYING) end, self)
end

function AILODGameMode:ScheduleBotDraftAction(expectedState, action)
	if not self.botManager or type(action) ~= "function" then return end
	local start = Time()
	Timers:CreateTimer(function()
		if self.ended or not GameState:Is(expectedState) then return nil end
		if Time() < start + BOT_DRAFT_ACTION_DELAY then return 0.1 end
		action(self.botManager)
		return nil
	end, false)
end

function AILODGameMode:RegisterStateHandlers()
	GameState:OnEnter(GameState.BAN, function()
		self.banManager:Start(function()
			if not self.ended and GameState:Is(GameState.BAN) then
				GameState:Transition(GameState.GENERATE_HERO_POOLS)
			end
		end)
		-- Bots ban only after the ban phase is live — never before, and never as a
		-- substitute for skipping BAN_HEROES into hero select.
		self:ScheduleBotDraftAction(GameState.BAN, function(bots)
			bots:AutoBan(self.banManager)
		end)
	end)
	GameState:OnEnter(GameState.GENERATE_HERO_POOLS, function()
		self.draftManager:GenerateHeroPools()
		GameState:Transition(GameState.HERO_DRAFT)
	end)
	GameState:OnEnter(GameState.HERO_DRAFT, function()
		self.draftManager:StartHeroDraft(function()
			if not self.ended and GameState:Is(GameState.HERO_DRAFT) then
				GameState:Transition(GameState.ABILITY_DRAFT)
			end
		end)
		self:ScheduleBotDraftAction(GameState.HERO_DRAFT, function(bots)
			bots:AutoHero(self.draftManager)
		end)
	end)
	GameState:OnEnter(GameState.ABILITY_DRAFT, function()
		self.draftManager:StartAbilityDraft(function()
			if not self.ended and GameState:Is(GameState.ABILITY_DRAFT) then
				GameState:Transition(GameState.INITIAL_ULTIMATE)
			end
		end)
		self:ScheduleBotDraftAction(GameState.ABILITY_DRAFT, function(bots)
			bots:AutoAbilities(self.draftManager)
		end)
	end)
	GameState:OnEnter(GameState.INITIAL_ULTIMATE, function()
		self.draftManager:StartInitialUltimate(function()
			if not self.ended and GameState:Is(GameState.INITIAL_ULTIMATE) then
				GameState:Transition(GameState.ULTIMATE_DRAFT)
			end
		end)
		self:ScheduleBotDraftAction(GameState.INITIAL_ULTIMATE, function(bots)
			bots:AutoInitialUlt(self.draftManager)
		end)
	end)
	GameState:OnEnter(GameState.ULTIMATE_DRAFT, function()
		self.draftManager:StartUltimateDraft(function()
			if not self.ended and GameState:Is(GameState.ULTIMATE_DRAFT) then
				GameState:Transition(GameState.BUILD_CONFIRMATION)
			end
		end)
		self:ScheduleBotDraftAction(GameState.ULTIMATE_DRAFT, function(bots)
			bots:AutoBonusUlt(self.draftManager)
		end)
	end)
	GameState:OnEnter(GameState.BUILD_CONFIRMATION, function()
		self.draftManager:StartBuildConfirmation(function()
			if not self.ended and GameState:Is(GameState.BUILD_CONFIRMATION) then
				GameState:Transition(GameState.ABILITY_VALIDATION)
			end
		end)
		self:ScheduleBotDraftAction(GameState.BUILD_CONFIRMATION, function(bots)
			bots:AutoBuild(self.draftManager)
		end)
	end)
	GameState:OnEnter(GameState.ABILITY_VALIDATION, function()
		local valid, changed = self.draftManager:ValidateAndRecover()
		if not valid then self:AbortPreparation("invalid_build")
		elseif changed then GameState:Transition(GameState.BUILD_CONFIRMATION)
		else self:PrepareHeroes() end
	end)
	GameState:OnEnter(GameState.STRATEGY, function() self:StartStrategy() end)
	GameState:OnEnter(GameState.INTRODUCTION, function() self:StartIntroduction() end)
	GameState:OnEnter(GameState.SPAWN, function() self:RunSpawnPhase() end)
	GameState:OnEnter(GameState.PLAYING, function()
		PlayerState:ForEachParticipant(function(_, record) record.draftState = "GAME" end)
		self:ReleaseWorld()
		GameRules:GetGameModeEntity():SetPauseEnabled(true)
		if self.botManager then self.botManager:ApplyHardDifficulty() end
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_playing", {})
		CustomGameEventManager:Send_ServerToAllClients("lod_battle_start", {})
		self:PublishRoster()
	end)
end

function AILODGameMode:RegisterEvents()
	ListenToGameEvent("game_rules_state_change", Dynamic_Wrap(AILODGameMode, "OnGameRulesStateChange"), self)
	ListenToGameEvent("npc_spawned", Dynamic_Wrap(AILODGameMode, "OnNPCSpawned"), self)
	ListenToGameEvent("entity_killed", Dynamic_Wrap(AILODGameMode, "OnEntityKilled"), self)
	ListenToGameEvent("dota_player_pick_hero", Dynamic_Wrap(AILODGameMode, "OnPlayerPickHero"), self)
	if IsInToolsMode() then
		ListenToGameEvent("player_chat", Dynamic_Wrap(AILODGameMode, "OnToolsChat"), self)
	end
	local handlers = {
		ai_lod_ban_hero = "OnBanHero",
		ai_lod_pick_hero = "OnPickHero",
		ai_lod_reroll_hero = "OnRerollHero",
		ai_lod_pick_ability = "OnPickAbility",
		ai_lod_pick_ult = "OnPickUlt",
		ai_lod_pick_initial_ult = "OnPickInitialUlt",
		ai_lod_confirm_build = "OnConfirmBuild",
		ai_lod_lobby_ready = "OnLobbyReady",
		ai_lod_confirm_ult = "OnConfirmUlt",
		ai_lod_death_slot = "OnDeathSlot",
		ai_lod_death_ability = "OnDeathAbility",
		ai_lod_death_reroll = "OnDeathReroll",
		ai_lod_death_confirm = "OnDeathConfirm",
		ai_lod_death_skip = "OnDeathSkip",
		ai_lod_client_ready = "OnClientReady",
		ai_lod_strategy_ready = "OnStrategyReady",
		ai_lod_strategy_lane = "OnStrategyLane",
		lod_pick_hero = "OnPickHero",
		lod_pick_ability = "OnPickAbility",
	}
	for eventName, method in pairs(handlers) do
		local handler = method
		CustomGameEventManager:RegisterListener(eventName, function(source, event)
			local playerID = self:EventPlayerID(source, event)
			if playerID == nil or type(event) ~= "table" then return end
			self[handler](self, playerID, event)
		end)
	end
end

function AILODGameMode:EventPlayerID(source, event)
	-- Prefer the authenticated sender. Dota may pass a player entity index or a playerID.
	if type(source) == "number" and source == math.floor(source) then
		if source > 0 then
			local entity = EntIndexToHScript(source)
			if entity and not entity:IsNull() and entity.GetPlayerID then
				local playerID = entity:GetPlayerID()
				if PlayerState:IsParticipant(playerID) and PlayerResource:GetPlayer(playerID) == entity then
					return playerID
				end
			end
		end
		if source >= 0 and source < DOTA_MAX_PLAYERS
			and PlayerState:IsParticipant(source) and PlayerResource:GetPlayer(source) then
			return source
		end
	end
	-- Some engine builds only stamp PlayerID on the payload.
	if type(event) == "table" then
		local fromEvent = tonumber(event.PlayerID or event.playerID or event.player_id)
		if fromEvent and PlayerState:IsParticipant(fromEvent) and PlayerResource:GetPlayer(fromEvent) then
			return fromEvent
		end
	end
	return nil
end

function AILODGameMode:OnGameRulesStateChange()
	local state = GameRules:State_Get()
	if state >= DOTA_GAMERULES_STATE_POST_GAME then
		self:FinishMatch()
		return
	end
	if self.ended then return end
	if state == DOTA_GAMERULES_STATE_CUSTOM_GAME_SETUP then
		self:StartCustomGameSetup()
	elseif self.enableLodDraft and (
			(DOTA_GAMERULES_STATE_HERO_SELECTION and state == DOTA_GAMERULES_STATE_HERO_SELECTION)
			or (DOTA_GAMERULES_STATE_STRATEGY_TIME and state == DOTA_GAMERULES_STATE_STRATEGY_TIME)
			or (DOTA_GAMERULES_STATE_TEAM_SHOWCASE and state == DOTA_GAMERULES_STATE_TEAM_SHOWCASE)
		) then
		-- Native selection is a short placeholder window when LOD draft is on.
		-- Do NOT PauseGame here: pausing freezes the engine clock and traps the
		-- match in HERO_SELECTION forever (blank map, no LOD lobby UI).
		-- Real bans/picks still wait until PRE_GAME via BeginMatchFlow.
		self.draftPause = false
		self:EnsureNativeSelectionAdvances(state)
	elseif state == DOTA_GAMERULES_STATE_PRE_GAME then
		self.draftPause = true
		PauseGame(true)
		-- No bot fill here: empty slots are detected and filled once the lobby
		-- countdown ends, immediately before the roster locks.
		self:BeginMatchFlow()
	elseif state == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
		if self.spawnReady and GameState:Is(GameState.SPAWN) then
			GameState:Transition(GameState.PLAYING)
		else
			-- Fail closed if another script unexpectedly advances the engine.
			PauseGame(true)
			print("[AI-LOD] Refusing engine start before final preparation")
			self:AbortPreparation("unexpected_engine_start")
		end
	end
end

function AILODGameMode:EnsureNativeSelectionAdvances(state)
	-- Force-hero + short selection should pass quickly. If the engine stalls
	-- (placeholder bots / econ inventory noise), keep clocks short and unpaused.
	if self.nativeAdvanceArmed or self.ended then return end
	self.nativeAdvanceArmed = true
	local openedAt = Time()
	Timers:CreateTimer(function()
		if self.ended then return end
		local now = GameRules:State_Get()
		if now == DOTA_GAMERULES_STATE_PRE_GAME
			or now == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS
			or (DOTA_GAMERULES_STATE_POST_GAME and now >= DOTA_GAMERULES_STATE_POST_GAME) then
			self.nativeAdvanceArmed = false
			return
		end
		local inNative = now == DOTA_GAMERULES_STATE_HERO_SELECTION
			or (DOTA_GAMERULES_STATE_STRATEGY_TIME and now == DOTA_GAMERULES_STATE_STRATEGY_TIME)
			or (DOTA_GAMERULES_STATE_TEAM_SHOWCASE and now == DOTA_GAMERULES_STATE_TEAM_SHOWCASE)
		if not inNative then
			self.nativeAdvanceArmed = false
			return
		end
		-- Never leave the match paused during native selection windows.
		if GameRules.IsGamePaused and GameRules:IsGamePaused() then
			PauseGame(false)
		end
		pcall(function() GameRules:SetHeroSelectionTime(1) end)
		pcall(function() GameRules:SetStrategyTime(1) end)
		pcall(function() GameRules:SetShowcaseTime(1) end)
		-- After several seconds still stuck, log once and keep retrying unpause.
		if Time() >= openedAt + 3 then
			print(string.format("[AI-LOD] Waiting on native state %s (expect PRE_GAME next)", tostring(now)))
			openedAt = Time()
		end
		return 0.5
	end, false)
end

function AILODGameMode:StartCustomGameSetup()
	if self.setupStarted or self.ended then return end
	self.setupStarted = true
	self.setupOpenedAt = Time()
	self.setupStatus = "filling"
	print(string.format("[AI-LOD] Custom game setup: %ds countdown, bot fill enabled=%s",
		SETUP_COUNTDOWN, tostring(self.fillEmptyWithBots)))

	if GameRules.EnableCustomGameSetupAutoLaunch then
		GameRules:EnableCustomGameSetupAutoLaunch(true)
	end
	if GameRules.SetCustomGameSetupRemainingTime then
		GameRules:SetCustomGameSetupRemainingTime(SETUP_COUNTDOWN)
	end

	if self.fillEmptyWithBots and self.botManager then
		self.botManager:FillEmptySlots()
	end
	self:PublishRoster()

	Timers:CreateTimer(function()
		if self.ended then return end
		if GameRules:State_Get() ~= DOTA_GAMERULES_STATE_CUSTOM_GAME_SETUP then return end

		if self.fillEmptyWithBots and self.botManager then
			self.botManager:FillEmptySlots()
		end

		local remaining = math.max(0, math.ceil(SETUP_COUNTDOWN - (Time() - self.setupOpenedAt)))
		self.setupStatus = remaining > 0 and "countdown" or "launching"
		self.setupDeadline = self.setupOpenedAt + SETUP_COUNTDOWN
		if GameRules.SetCustomGameSetupRemainingTime then
			GameRules:SetCustomGameSetupRemainingTime(remaining)
		end
		self:PublishRoster()

		if remaining <= 0 then
			if GameRules.LockCustomGameSetupTeamAssignment then
				pcall(function() GameRules:LockCustomGameSetupTeamAssignment(true) end)
			end
			if GameRules.FinishCustomGameSetup then
				print("[AI-LOD] Finishing custom game setup after countdown")
				pcall(function() GameRules:FinishCustomGameSetup() end)
			end
			return
		end
		return 0.5
	end, false)
end

function AILODGameMode:BeginMatchFlow()
	if self.flowStarted or self.ended then return end
	self.flowStarted = true
	self:EnforcePlaceholderHeroes()
	self.lobbyOpenedAt = Time()
	-- Ensure the lobby UI has authoritative state even if the client missed Activate.
	CustomNetTables:SetTableValue("ai_lod_match", "state", {
		state = GameState:Get(), name = GameState:Name(),
	})
	self:PublishRoster()
	Timers:CreateTimer(function()
		if self.ended or not GameState:Is(GameState.LOBBY) then return end
		-- Connected humans start after a short grace period even if the UI never
		-- reported ready (so bot-filled lobbies are not stuck forever).
		if self.lobbyOpenedAt and Time() >= self.lobbyOpenedAt + LOBBY_AUTO_READY_AFTER then
			PlayerState:ForEachParticipant(function(playerID, record)
				if not PlayerState:IsBot(playerID) then
					record.clientReady = true
					record.lobbyReady = true
				end
			end)
		end
		local ready, signature = self:LobbyCanStart()
		if not ready or signature ~= self.lobbySignature then self.lobbyDeadline = nil end
		self.lobbySignature = signature
		if ready and not self.lobbyDeadline then self.lobbyDeadline = Time() + LOBBY_COUNTDOWN end
		self:PublishRoster()
		if ready and Time() >= self.lobbyDeadline then
			if IsInToolsMode() then
				local seed = Convars:GetInt("ai_lod_seed")
				if seed and seed ~= 0 then
					self.draftSeed = seed
					DraftRandom:Init(seed)
				end
			end
			-- Countdown ended: detect empty Radiant/Dire slots (late leavers,
			-- never-joined seats) and fill them with bots before the roster
			-- locks and BAN_HEROES begins.
			if self.fillEmptyWithBots and self.botManager then
				self.botManager:FillEmptySlots()
			end
			PlayerState:LockRoster()
			if self.enableLodDraft then
				GameState:Transition(GameState.BAN)
			else
				self:PrepareHeroes()
			end

			return
		end
		return 0.25
	end, false)
end

function AILODGameMode:LobbyCanStart()
	local count, humans, teams, ready, signature = 0, 0, {}, true, {}
	PlayerState:ForEachParticipant(function(playerID, record)
		local team = PlayerState:GetTeam(playerID)
		count = count + 1
		teams[team] = true
		table.insert(signature, tostring(playerID) .. ":" .. tostring(team))
		local bot = PlayerState:IsBot(playerID)
		if not bot then
			humans = humans + 1
			if not PlayerState:IsConnected(playerID) or not record.clientReady or not record.lobbyReady then
				ready = false
			end
		end
	end)
	-- With bot fill, one human is enough; bots complete both teams.
	self.requiredPlayers = 1
	local enough = humans >= 1 or (IsInToolsMode() and count >= 1)
	local bothTeams = teams[DOTA_TEAM_GOODGUYS] and teams[DOTA_TEAM_BADGUYS]
	if IsInToolsMode() and humans >= 1 then bothTeams = true end
	self.lobbyStatus = not enough and "waiting_for_players"
		or not bothTeams and "waiting_for_teams" or not ready and "waiting_for_ready" or "countdown"
	return enough and bothTeams and ready, table.concat(signature, ",")
end

function AILODGameMode:RosterPayload()
	local players, completed = {}, 0
	PlayerState:ForEachParticipant(function(playerID, record)
		local ready = record.buildConfirmed
		if GameState:Is(GameState.LOBBY) then ready = record.lobbyReady or PlayerState:IsBot(playerID)
		elseif GameState:Is(GameState.BAN) then ready = #record.bannedHeroes > 0
		elseif GameState:Is(GameState.HERO_DRAFT) then ready = record.hero ~= nil
		elseif GameState:Is(GameState.ABILITY_DRAFT) then ready = #record.abilities.basic == 3
		elseif GameState:Is(GameState.INITIAL_ULTIMATE) then ready = #record.abilities.ultimate >= 1
		elseif GameState:Is(GameState.ULTIMATE_DRAFT) then ready = record.ultimateConfirmed
		elseif GameState:Is(GameState.STRATEGY) then ready = record.strategyReady end
		if ready then completed = completed + 1 end
		table.insert(players, { player_id = playerID, team = PlayerState:GetTeam(playerID),
			hero = record.hero or "", ready = ready and 1 or 0, draft_state = record.draftState,
			basic_count = #record.abilities.basic, ultimate_count = #record.abilities.ultimate,
			connected = PlayerState:IsConnected(playerID) and 1 or 0,
			lane = record.lane or "",
			is_bot = PlayerState:IsBot(playerID) and 1 or 0,
			name = record.botName or "",
		})
	end)
	local inSetup = GameRules.State_Get and GameRules:State_Get() == DOTA_GAMERULES_STATE_CUSTOM_GAME_SETUP
	local deadline = inSetup and self.setupDeadline
		or GameState:Is(GameState.LOBBY) and self.lobbyDeadline
		or self.draftManager and self.draftManager.active and self.draftManager.deadline
		or GameState:Is(GameState.BAN) and self.banManager.deadline
		or self.presentationDeadline
	local status = GameState:Name()
	if inSetup then
		status = self.setupStatus or "countdown"
	elseif GameState:Is(GameState.LOBBY) then
		status = self.lobbyStatus or "waiting_for_players"
	end
	return { players = players, required_players = self.requiredPlayers or (IsInToolsMode() and 1 or 2),
		time = math.max(0, math.ceil((deadline or Time()) - Time())),
		status = status,
		phase = inSetup and "SETUP" or GameState:Name(), total = #players, completed = completed,
		locked = PlayerState.roster ~= nil,
		team_slots = 5, max_players = 10,
		banned = table.concat(self.heroManager and self.heroManager:GetBannedList() or {}, ","),
		setup_countdown = SETUP_COUNTDOWN,
		lobby_countdown = LOBBY_COUNTDOWN,
	}
end

function AILODGameMode:PublishRoster(player)
	local payload = self:RosterPayload()
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_roster", payload)
		if GameState:Is(GameState.LOBBY) then CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_lobby", payload) end
	else
		CustomNetTables:SetTableValue("ai_lod_match", "roster", payload)
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_roster", payload)
		if GameState:Is(GameState.LOBBY) then
			CustomNetTables:SetTableValue("ai_lod_match", "lobby", payload)
			CustomGameEventManager:Send_ServerToAllClients("ai_lod_lobby", payload)
		end
	end
end

function AILODGameMode:OnLobbyReady(playerID, event)
	if self.ended or not GameState:Is(GameState.LOBBY) or not PlayerState:IsParticipant(playerID) then return end
	PlayerState:Get(playerID).lobbyReady = event.ready ~= false and event.ready ~= 0 and event.ready ~= "0"
	self:LobbyCanStart()
	self:PublishRoster()
end

function AILODGameMode:HoldUnit(unit)
	if not unit or unit:IsNull() then return end
	if not unit.IsRealHero or not unit:IsRealHero() then return end
	local ok = pcall(function()
		unit:AddNewModifier(unit, nil, "modifier_ai_lod_preparation", {})
	end)
	if ok then
		self.heldUnits[unit:entindex()] = unit
	end
end

function AILODGameMode:ReleaseWorld()
	for _, unit in pairs(self.heldUnits) do
		if not unit:IsNull() then unit:RemoveModifierByName("modifier_ai_lod_preparation") end
	end
	self.heldUnits = {}
end

-- SetCustomGameForceHero only covers human clients; engine bots can still end
-- native selection holding a random real hero. Before the draft has produced a
-- validated build, every participant must sit on the shared placeholder so
-- nothing looks (or is) picked ahead of BAN_HEROES.
function AILODGameMode:EnforcePlaceholderHeroes()
	if not self.enableLodDraft or self.ended then return end
	if not GameState:In(GameState.LOBBY, GameState.BAN, GameState.GENERATE_HERO_POOLS,
		GameState.HERO_DRAFT, GameState.ABILITY_DRAFT, GameState.INITIAL_ULTIMATE,
		GameState.ULTIMATE_DRAFT, GameState.BUILD_CONFIRMATION) then return end
	-- ReplaceHeroWith on a live entity mid-frame freezes the client on the old
	-- hero; only strip while the PRE_GAME server pause holds the world.
	if GameRules.IsGamePaused and not GameRules:IsGamePaused() then return end
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			local record = PlayerState.players and PlayerState.players[playerID]
			local hero = PlayerResource:GetSelectedHeroEntity(playerID)
			if not (record and record.prepared)
				and hero and not hero:IsNull() and hero.IsRealHero and hero:IsRealHero()
				and hero:GetUnitName() ~= PLACEHOLDER_HERO then
				local gold = hero.GetGold and hero:GetGold() or 0
				local ok, replaced = pcall(function()
					return PlayerResource:ReplaceHeroWith(playerID, PLACEHOLDER_HERO, gold, 0)
				end)
				if ok and replaced and not replaced:IsNull() then
					self:HoldUnit(replaced)
					print(string.format("[AI-LOD] Stripped pre-draft hero %s from player %d back to placeholder",
						hero:GetUnitName(), playerID))
				else
					print(string.format("[AI-LOD] Failed to strip pre-draft hero %s from player %d",
						hero:GetUnitName(), playerID))
				end
			end
		end
	end
end

function AILODGameMode:PrepareHeroes()
	if self.preparing or self.ended then return end
	self.preparing = true
	local deadline = Time() + PREPARATION_TIMEOUT
	self.preparationDeadline = deadline
	Timers:CreateTimer(function()
		if self.ended then return end
		-- One broken slot must not end the match: past the timeout, unprepared
		-- participants fall back to a safe build instead of AbortPreparation.
		local timedOut = Time() >= deadline
		local complete = true
		PlayerState:ForEachParticipant(function(playerID, record)
			if record.prepared then return end
			if timedOut then
				local ok, prepared = pcall(self.FallbackPreparePlayer, self, playerID, record)
				if ok and prepared then return end
				if not ok then print("[AI-LOD] Fallback preparation failed: " .. tostring(prepared)) end
				complete = false
				return
			end
			local ok, prepared = pcall(self.PreparePlayer, self, playerID, record)
			if not ok or not prepared then
				complete = false
				if not ok then print("[AI-LOD] Hero preparation failed: " .. tostring(prepared)) end
			end
		end)
		if complete then
			self.preparing = false
			GameState:Transition(GameState.STRATEGY)
			return
		end
		if timedOut then
			self:AbortPreparation()
			return
		end
		return 1
	end, false)
end

-- Timeout fallback for a participant whose drafted build could not be installed
-- (precache/ReplaceHeroWith/engine failure). A random unlocked base plus a
-- globally free kit is better than abandoning the match for everyone.
function AILODGameMode:FallbackPreparePlayer(playerID, record)
	print(string.format("[AI-LOD] Preparation timeout: forcing fallback hero for player %d", playerID))
	-- Candidate order: the drafted hero first, then the player's category
	-- offers, then any unlocked pool hero. A failed install releases the
	-- selection so the next candidate can take the slot.
	local candidates, seen = {}, {}
	local function push(name)
		if type(name) == "string" and name ~= "" and not seen[name]
			and self.heroManager:IsValidHero(name) and not self.heroManager:IsBanned(name) then
			seen[name] = true
			table.insert(candidates, name)
		end
	end
	push(record.hero)
	for _, cat in ipairs(self.heroManager:GetCategories()) do
		for _, hero in ipairs((record.heroPools or {})[cat] or {}) do push(hero) end
	end
	for _, hero in ipairs(self.heroManager:LoadPool()) do push(hero) end

	local basics, ultimates = record.abilities.basic, record.abilities.ultimate
	if #basics ~= 3 or #ultimates ~= 2
		or not self.abilityManager:ValidateKit(record.hero, basics, ultimates, playerID) then
		basics = self.abilityManager:Sample(self.abilityManager:GetPools().regular, 3, {})
		ultimates = self.abilityManager:Sample(self.abilityManager:GetPools().ultimate, 2, {})
		if #basics ~= 3 or #ultimates ~= 2 then return false end
	end

	for _, name in ipairs(candidates) do
		local owner = self.heroManager.selected[name]
		if owner == nil or owner == playerID then
			self.heroManager.selected[name] = playerID
			local hero = self.heroManager:EnsureHeroForPlayer(playerID, name)
			if hero and not hero:IsNull() and hero:GetUnitName() == name
				and self.abilityManager:CommitBuild(playerID, basics, ultimates)
				and self.abilityManager:ApplyKit(hero, basics, ultimates) then
				if record.hero ~= name then print(string.format(
					"[AI-LOD] Fallback replaced unbuildable %s with %s for player %d",
					tostring(record.hero), name, playerID)) end
				record.hero = name
				record.abilities.basic = basics
				record.abilities.ultimate = ultimates
				record.buildConfirmed = true
				record.draftLocked = true
				record.confirmedBuild = { hero = name, basic = basics, ultimate = ultimates }
				self:HoldUnit(hero)
				record.prepared = true
				record.preparedHero = hero
				record.startingGold = PlayerResource.GetGold and PlayerResource:GetGold(playerID) or 0
				record.buildError = "preparation_fallback"
				hero.bAILODReady = true
				PlayerState:SetHero(playerID, name)
				return true
			end
			if self.heroManager.selected[name] == playerID then self.heroManager.selected[name] = nil end
		end
	end
	return false
end

function AILODGameMode:PreparePlayer(playerID, record)
	if self.ended or (self.preparationDeadline and Time() >= self.preparationDeadline) then return false end
	if self.enableLodDraft and (not record.buildConfirmed or not record.draftLocked
		or not self.draftManager:ValidateBuild(playerID, record)) then return false end
	if self.enableLodDraft then
		local buildKey = record.hero .. "|" .. table.concat(record.abilities.basic, ",")
			.. "|" .. table.concat(record.abilities.ultimate, ",")
		if record.precacheBuildKey ~= buildKey then
			record.precacheBuildKey = buildKey
			record.precacheToken = (record.precacheToken or 0) + 1
			record.precacheStarted, record.precacheReady, record.precacheError = false, false, nil
		end
	end
	if self.enableLodDraft and not record.precacheReady then
		if not record.precacheStarted then
			record.precacheStarted = true
			local token = record.precacheToken
			self.abilityManager:PrecacheBuild(record.hero, record.abilities.basic, record.abilities.ultimate, playerID,
				function(ok, reason)
					if self.ended or not GameState:Is(GameState.ABILITY_VALIDATION)
						or record.precacheToken ~= token
						or (self.preparationDeadline and Time() >= self.preparationDeadline) then return end
					record.precacheReady = ok
					record.precacheError = reason
				end)
		end
		if not record.precacheReady then return false end
	end
	local preferred = record.hero or self.draftManager:GetHeroPick(playerID)
	local hero = self.heroManager:EnsureHeroForPlayer(playerID, preferred)
	if not hero or hero:IsNull() or (preferred and hero:GetUnitName() ~= preferred) then return false end
	self:HoldUnit(hero)
	if self.enableLodDraft and not self.abilityManager:ApplyKit(hero, record.abilities.basic, record.abilities.ultimate) then
		return false
	end
	record.prepared = true
	record.preparedHero = hero
	record.startingGold = PlayerResource.GetGold and PlayerResource:GetGold(playerID) or 0
	hero.bAILODReady = true
	return true
end

function AILODGameMode:AbortPreparation(reason)
	if self.ended or self.preparationError then return end
	self.preparationError = reason or "hero_preparation_failed"
	print("[AI-LOD] Aborting setup: could not prepare every participant")
	GameRules:SetSafeToLeave(true)
	PauseGame(false)
	-- A broken setup awards neither playing team; use engine postgame, not a
	-- permanent server pause or a match started with incomplete heroes.
	GameRules:SetGameWinner(DOTA_TEAM_NEUTRALS)
	self:FinishMatch()
end

function AILODGameMode:PreparationPayload()
	local players, ready = {}, {}
	PlayerState:ForEachParticipant(function(playerID, record)
		ready[tostring(playerID)] = record.strategyReady and 1 or 0
		table.insert(players, {
			player_id = playerID,
			team = PlayerState:GetTeam(playerID),
			hero = record.hero or "",
			ready = record.strategyReady and 1 or 0,
			lane = record.lane or "",
			basic = table.concat(record.abilities.basic, ","),
			ultimate = table.concat(record.abilities.ultimate, ","),
			abilities = {
				basic = table.concat(record.abilities.basic, ","),
				ultimate = table.concat(record.abilities.ultimate, ","),
			},
			starting_gold = record.startingGold or (PlayerResource.GetGold and PlayerResource:GetGold(playerID)) or 0,
			gold = PlayerResource.GetGold and PlayerResource:GetGold(playerID) or 0,
		})
	end)
	return {
		phase = GameState:Name(),
		time = math.max(0, math.ceil((self.presentationDeadline or Time()) - Time())),
		ready = ready,
		players = players,
	}
end

function AILODGameMode:SendPreparation(player)
	local payload = self:PreparationPayload()
	if player then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_preparation", payload)
	else
		CustomNetTables:SetTableValue("ai_lod_match", "preparation", payload)
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_preparation", payload)
	end
end

function AILODGameMode:StartStrategy()
	self.draftPause = false
	self.presentationDeadline = Time() + STRATEGY_TIME
	PlayerState:ForEachParticipant(function(playerID, record)
		record.strategyReady = PlayerState:IsBot(playerID)
		record.draftState = "STRATEGY_TIME"
	end)
	if self.botManager then self.botManager:AutoStrategy(self) end
	-- The final entity and kit now exist; unpause permits manual shop transactions.
	PauseGame(false)
	self:SendPreparation()
	self:PublishRoster()
	Timers:CreateTimer(function()
		if self.ended or not GameState:Is(GameState.STRATEGY) then return end
		local ready = true
		PlayerState:ForEachConnected(function(playerID, record)
			if PlayerState:IsBot(playerID) then return end
			if not record.strategyReady then ready = false end
		end)
		if ready or Time() >= self.presentationDeadline then
			GameState:Transition(GameState.INTRODUCTION)
			return
		end
		self:SendPreparation()
		return 0.25
	end, false)
end

function AILODGameMode:StartIntroduction()
	PlayerState:ForEachParticipant(function(_, record) record.draftState = "INTRODUCTION" end)
	self.presentationDeadline = Time() + INTRODUCTION_TIME
	self:SendPreparation()
	Timers:CreateTimer(function()
		if self.ended or not GameState:Is(GameState.INTRODUCTION) then return end
		if Time() >= self.presentationDeadline then
			GameState:Transition(GameState.SPAWN)
			return
		end
		self:SendPreparation()
		return 0.25
	end, false)
end

function AILODGameMode:RunSpawnPhase()
	if self.ended then return end
	local complete = true
	PlayerState:ForEachParticipant(function(_, record)
		local hero = record.preparedHero
		if not record.prepared or not hero or hero:IsNull() then complete = false end
	end)
	if not complete then
		print("[AI-LOD] Cannot start: a prepared hero is missing")
		self:AbortPreparation()
		return
	end
	-- Do not replace heroes or reapply kits here: strategy inventory must survive.
	-- One-time sweep so a stuck draft pause can never carry into gameplay.
	PauseGame(false)
	self.spawnReady = true
	PlayerState:ForEachParticipant(function(_, record) record.draftState = "GAME_START" end)
	self.presentationDeadline = Time()
	self:SendPreparation()
	if GameRules:State_Get() == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
		GameState:Transition(GameState.PLAYING)
		PauseGame(false)
	else
		GameRules:ForceGameStart()
	end
end

function AILODGameMode:OnClientReady(playerID)
	local record = PlayerState:Get(playerID)
	record.clientReady = true
	local player = PlayerResource:GetPlayer(playerID)
	if not player then return end
	CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_state", { state = GameState:Get(), name = GameState:Name() })
	self:PublishRoster(player)
	if self.results then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_results", self.results)
		return
	end
	if GameState:Is(GameState.BAN) then
		self.banManager:SyncPlayer(playerID)
	elseif GameState:In(GameState.HERO_DRAFT, GameState.ABILITY_DRAFT, GameState.INITIAL_ULTIMATE,
		GameState.ULTIMATE_DRAFT, GameState.BUILD_CONFIRMATION) then
		self.draftManager:SyncPlayer(playerID)
	elseif GameState:Is(GameState.ABILITY_VALIDATION) then
		self.draftManager:SendBuild(playerID)
	elseif GameState:In(GameState.STRATEGY, GameState.INTRODUCTION, GameState.SPAWN) then
		self:SendPreparation(player)
	elseif GameState:Is(GameState.PLAYING) then
		CustomGameEventManager:Send_ServerToPlayer(player, "ai_lod_playing", {})
		self.respawnManager:SyncPlayer(playerID)
	end
end

function AILODGameMode:OnStrategyReady(playerID)
	if self.ended or not PlayerState:IsParticipant(playerID) or not GameState:Is(GameState.STRATEGY)
		or Time() >= self.presentationDeadline then return end
	PlayerState:Get(playerID).strategyReady = true
	self:SendPreparation()
	self:PublishRoster()
end

function AILODGameMode:OnStrategyLane(playerID, event)
	if self.ended or not GameState:Is(GameState.STRATEGY) or not PlayerState:IsParticipant(playerID)
		or not self.presentationDeadline or Time() >= self.presentationDeadline then return end
	local lane = event.lane
	if lane ~= "top" and lane ~= "mid" and lane ~= "bottom" and lane ~= "jungle" then return end
	PlayerState:Get(playerID).lane = lane
	self:SendPreparation()
	self:PublishRoster()
end

function AILODGameMode:FilterOrder(order)
	if self.ended then return false end
	local playerID = order.issuer_player_id_const
	if GameState:Is(GameState.PLAYING) then
		if order.order_type == DOTA_UNIT_ORDER_BUYBACK then
			local record = PlayerState.players[playerID]
			return not (record and record.respawnPending)
		end
		return true
	end
	if not GameState:Is(GameState.STRATEGY) or not PlayerState:IsParticipant(playerID) then return false end
	local kind = order.order_type
	return kind == DOTA_UNIT_ORDER_PURCHASE_ITEM
		or kind == DOTA_UNIT_ORDER_SELL_ITEM
		or kind == DOTA_UNIT_ORDER_DISASSEMBLE_ITEM
		or kind == DOTA_UNIT_ORDER_MOVE_ITEM
		or kind == DOTA_UNIT_ORDER_SET_ITEM_COMBINE_LOCK
end

function AILODGameMode:OnPlayerPickHero(event)
	local hero = EntIndexToHScript(event.heroindex)
	if not hero or hero:IsNull() or self.ended then return end
	if not self.enableLodDraft then PlayerState:SetHero(hero:GetPlayerOwnerID(), hero:GetUnitName()) end
	if not GameState:Is(GameState.PLAYING) and hero.IsRealHero and hero:IsRealHero() then
		self:HoldUnit(hero)
	end
end

function AILODGameMode:OnNPCSpawned(event)
	local unit = EntIndexToHScript(event.entindex)
	if not unit or unit:IsNull() or self.ended then return end
	if not unit.IsRealHero or not unit:IsRealHero() then return end
	if not GameState:Is(GameState.PLAYING) then
		self:HoldUnit(unit)
		if self.enableLodDraft and unit:GetUnitName() ~= PLACEHOLDER_HERO then
			-- Engine-randomed bot heroes can spawn after PRE_GAME begins. Defer the
			-- sweep one tick; EnforcePlaceholderHeroes ignores drafted/prepared heroes.
			Timers:CreateTimer(function() self:EnforcePlaceholderHeroes() end, false)
		end
	else
		self.respawnManager:OnHeroSpawn(unit)
	end
end

function AILODGameMode:OnEntityKilled(event)
	local killed = EntIndexToHScript(event.entindex_killed)
	if not killed or killed:IsNull() or self.ended then return end
	local name = killed:GetUnitName()
	if name == "npc_dota_goodguys_fort" then self.ancientWinner = DOTA_TEAM_BADGUYS end
	if name == "npc_dota_badguys_fort" then self.ancientWinner = DOTA_TEAM_GOODGUYS end
	if killed:IsRealHero() and GameState:Is(GameState.PLAYING) then self.respawnManager:OnHeroDeath(killed) end
end

function AILODGameMode:FinishMatch()
	if self.ended then return end
	self.ended = true
	self.draftPause = false
	self.banManager:Cancel()
	self.draftManager:Cancel()
	self.respawnManager:CancelAll()
	Timers:Stop()
	PlayerState:ForEachParticipant(function(playerID)
		local hero = PlayerResource:GetSelectedHeroEntity(playerID)
		if hero and not hero:IsNull() then hero:Stop() end
	end)
	GameState:Transition(GameState.GAME_OVER)
	GameState:Lock()
	self:ReleaseWorld()
	PauseGame(false)
	local winner = GameRules.GetGameWinner and GameRules:GetGameWinner() or self.ancientWinner
	if winner == nil then
		local radiant = Entities:FindByName(nil, "dota_goodguys_fort")
		local dire = Entities:FindByName(nil, "dota_badguys_fort")
		if radiant and not radiant:IsAlive() then winner = DOTA_TEAM_BADGUYS end
		if dire and not dire:IsAlive() then winner = DOTA_TEAM_GOODGUYS end
	end
	if winner ~= DOTA_TEAM_GOODGUYS and winner ~= DOTA_TEAM_BADGUYS then winner = self.ancientWinner or -1 end
	self.results = MatchResults:Snapshot(winner)
	if self.preparationError then self.results.error = self.preparationError end
	CustomNetTables:SetTableValue("ai_lod_match", "results", self.results)
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_results", self.results)
end

function AILODGameMode:OnBanHero(playerID, event)
	if not self.ended and GameState:Is(GameState.BAN) then self.banManager:HandleBan(playerID, event.hero) end
end
function AILODGameMode:OnPickHero(playerID, event)
	if not self.ended and GameState:Is(GameState.HERO_DRAFT) then self.draftManager:HandleHeroPick(playerID, event.hero) end
end
function AILODGameMode:OnRerollHero(playerID, event)
	if not self.ended and GameState:Is(GameState.HERO_DRAFT) then self.draftManager:HandleHeroReroll(playerID, event.category) end
end
function AILODGameMode:OnPickAbility(playerID, event)
	if not self.ended and GameState:Is(GameState.ABILITY_DRAFT) then self.draftManager:HandleAbilityPick(playerID, event.ability) end
end
function AILODGameMode:OnPickUlt(playerID, event)
	if not self.ended and GameState:Is(GameState.ULTIMATE_DRAFT) then self.draftManager:HandleUltPick(playerID, event.ability) end
end
function AILODGameMode:OnPickInitialUlt(playerID, event)
	if not self.ended and GameState:Is(GameState.INITIAL_ULTIMATE) then self.draftManager:HandleInitialUltPick(playerID, event.ability) end
end
function AILODGameMode:OnConfirmBuild(playerID)
	if not self.ended and GameState:Is(GameState.BUILD_CONFIRMATION) then self.draftManager:HandleBuildConfirm(playerID) end
end
function AILODGameMode:OnConfirmUlt(playerID)
	if not self.ended and GameState:Is(GameState.ULTIMATE_DRAFT) then self.draftManager:HandleUltConfirm(playerID) end
end
function AILODGameMode:OnDeathSlot(playerID, event)
	if not self.ended and GameState:Is(GameState.PLAYING) then self.respawnManager:HandleDeathSelectSlot(playerID, event.slot, event.draft_id) end
end
function AILODGameMode:OnDeathAbility(playerID, event)
	if not self.ended and GameState:Is(GameState.PLAYING) then self.respawnManager:HandleDeathSelectAbility(playerID, event.ability, event.draft_id) end
end
function AILODGameMode:OnDeathReroll(playerID, event)
	if not self.ended and GameState:Is(GameState.PLAYING) then self.respawnManager:HandleDeathReroll(playerID, event.draft_id) end
end
function AILODGameMode:OnDeathConfirm(playerID, event)
	if not self.ended and GameState:Is(GameState.PLAYING) then self.respawnManager:HandleDeathConfirm(playerID, event.draft_id) end
end
function AILODGameMode:OnDeathSkip(playerID, event)
	if not self.ended and GameState:Is(GameState.PLAYING) then self.respawnManager:HandleDeathSkip(playerID, event.draft_id) end
end

function AILODGameMode:OnToolsChat(event)
	if not IsInToolsMode() or type(event.text) ~= "string" then return end
	local command = event.text:match("^(%S+)")
	if command ~= "!state" and command ~= "!draft" and command ~= "!reroll" and command ~= "!hero" then return end
	local playerID = tonumber(event.playerid or event.PlayerID)
	if not PlayerState:IsParticipant(playerID) then return end
	local record = PlayerState:Get(playerID)
	print(string.format("[AI-LOD tools] %s player=%d state=%s hero=%s basics=%s ultimates=%s seed=%s rerolls=%d/%d/%d",
		command, playerID, GameState:Name(), record.hero or "", table.concat(record.abilities.basic, ","),
		table.concat(record.abilities.ultimate, ","), tostring(self.draftSeed),
		record.rerolls.heroCategory1, record.rerolls.heroCategory2, record.rerolls.heroCategory3))
	-- Debug commands are read-only; normal UI requests retain their phase/budget checks.
	self:PublishRoster(PlayerResource:GetPlayer(playerID))
end

LODDeathrollGameMode = AILODGameMode
