-- gamemode.lua
-- AI-LOD core. V0.1 = empty playable custom game + state machine.
-- LOD draft phases are wired but disabled until later milestones.

require("libraries/timers")
require("systems/game_state")
require("systems/player_state")
require("systems/hero_manager")
require("systems/ability_manager")
require("systems/ban_manager")
require("systems/draft_manager")
require("systems/reroll_manager")
require("systems/respawn_manager")
require("systems/balance_manager")
require("mmr/client")

AILODGameMode = AILODGameMode or class({})

-- ---------------------------------------------------------------------------
-- Feature flags
-- ---------------------------------------------------------------------------
-- V0.1 milestone: launch → lobby → start → spawn → move/attack/abilities →
-- die → respawn. No LOD draft yet.
local ENABLE_LOD_DRAFT = false

-- Fallback hero if selection fails (also used if force-hero path is needed).
local DEFAULT_HERO = "npc_dota_hero_axe"

function AILODGameMode:InitGameMode()
	print("[AI-LOD] InitGameMode (V0.1 foundation, ENABLE_LOD_DRAFT="
		.. tostring(ENABLE_LOD_DRAFT) .. ")")

	self.enableLodDraft = ENABLE_LOD_DRAFT
	self.flowStarted = false

	PlayerState:Init()
	GameState:Init(self)

	self.heroManager = HeroManager()
	self.abilityManager = AbilityManager()
	self.abilityManager:Load()
	self.banManager = BanManager(self.heroManager)
	self.draftManager = DraftManager(self.heroManager, self.abilityManager)
	self.rerollManager = RerollManager()
	self.respawnManager = RespawnManager()
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

	GameRules:SetCustomGameSetupAutoLaunchDelay(5)
	GameRules:SetStrategyTime(0)
	GameRules:SetShowcaseTime(0)
	GameRules:SetPostGameTime(30)
	GameRules:SetTreeRegrowTime(60)
	GameRules:SetUseUniversalShopMode(true)
	GameRules:SetSameHeroSelectionEnabled(true)

	if self.enableLodDraft then
		-- Future LOD path: skip vanilla pick, draft owns hero choice.
		GameRules:SetHeroSelectionTime(0)
		GameRules:SetHeroSelectPenaltyTime(0)
		GameRules:SetPreGameTime(180)
	else
		-- V0.1: normal hero pick from herolist, then play.
		GameRules:SetHeroSelectionTime(30)
		GameRules:SetHeroSelectPenaltyTime(5)
		GameRules:SetPreGameTime(10)
	end

	local mode = GameRules:GetGameModeEntity()
	if mode then
		if self.enableLodDraft and mode.SetCustomGameForceHero then
			mode:SetCustomGameForceHero(DEFAULT_HERO)
		end
		mode:SetRecommendedItemsDisabled(false)
		mode:SetBuybackEnabled(true)
		mode:SetCustomHeroMaxLevel(30)
		mode:SetFogOfWarDisabled(false)
		mode:SetUnseenFogOfWarEnabled(true)
		if mode.SetFixedRespawnTime then
			mode:SetFixedRespawnTime(-1)
		end
	end
end

function AILODGameMode:RegisterStateHandlers()
	GameState:OnEnter(GameState.BAN, function()
		self.banManager:Start(function()
			GameState:Transition(GameState.HERO_DRAFT)
		end)
	end)

	GameState:OnEnter(GameState.HERO_DRAFT, function()
		self.draftManager:StartHeroDraft(function()
			GameState:Transition(GameState.ABILITY_DRAFT)
		end)
	end)

	GameState:OnEnter(GameState.ABILITY_DRAFT, function()
		self.draftManager:StartAbilityDraft(function()
			GameState:Transition(GameState.SPAWN)
		end)
	end)

	GameState:OnEnter(GameState.ULTIMATE_DRAFT, function()
		self.draftManager:StartUltimateDraft(function()
			GameState:Transition(GameState.SPAWN)
		end)
	end)

	GameState:OnEnter(GameState.SPAWN, function()
		self:RunSpawnPhase()
	end)

	GameState:OnEnter(GameState.PLAYING, function()
		print("[AI-LOD] PLAYING — heroes should move, attack, cast, die, respawn")
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_playing", {})
	end)

	GameState:OnEnter(GameState.RESPAWN_DRAFT, function(payload)
		print("[AI-LOD] RESPAWN_DRAFT reserved; returning to PLAYING")
		GameState:Transition(GameState.PLAYING)
	end)

	GameState:OnEnter(GameState.GAME_OVER, function()
		print("[AI-LOD] GAME_OVER")
	end)
end

function AILODGameMode:RegisterEvents()
	ListenToGameEvent("game_rules_state_change", Dynamic_Wrap(AILODGameMode, "OnGameRulesStateChange"), self)
	ListenToGameEvent("npc_spawned", Dynamic_Wrap(AILODGameMode, "OnNPCSpawned"), self)
	ListenToGameEvent("entity_killed", Dynamic_Wrap(AILODGameMode, "OnEntityKilled"), self)
	ListenToGameEvent("dota_player_pick_hero", Dynamic_Wrap(AILODGameMode, "OnPlayerPickHero"), self)

	local gm = self
	CustomGameEventManager:RegisterListener("ai_lod_ban_hero", function(_, event)
		gm:OnBanHero(event)
	end)
	-- Old UI events are ignored so stale clients cannot desync V0.1.
	CustomGameEventManager:RegisterListener("lod_ban_ability", function() end)
	CustomGameEventManager:RegisterListener("lod_pick_hero", function() end)
	CustomGameEventManager:RegisterListener("lod_pick_ability", function() end)
end

function AILODGameMode:OnGameRulesStateChange()
	local state = GameRules:State_Get()

	if state == DOTA_GAMERULES_STATE_HERO_SELECTION then
		print("[AI-LOD] Engine state: HERO_SELECTION")
		GameState.current = GameState.WAITING
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_state", {
			state = GameState.WAITING,
			name = "WAITING",
		})
	end

	if state == DOTA_GAMERULES_STATE_PRE_GAME then
		print("[AI-LOD] Engine state: PRE_GAME")
		self:BeginMatchFlow()
	end

	if state == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
		print("[AI-LOD] Engine state: GAME_IN_PROGRESS")
		if GameState:Is(GameState.WAITING) or GameState:Is(GameState.SPAWN) then
			self:BeginMatchFlow()
		end
		if GameState:Is(GameState.SPAWN) then
			GameState:Transition(GameState.PLAYING)
		end
	end

	if state == DOTA_GAMERULES_STATE_POST_GAME then
		if GameState:CanTransition(GameState.GAME_OVER) then
			GameState:Transition(GameState.GAME_OVER)
		else
			-- Force terminal state if mid-flow
			GameState.current = GameState.GAME_OVER
		end
	end
end

function AILODGameMode:BeginMatchFlow()
	if self.flowStarted then
		return
	end
	self.flowStarted = true
	Timers:Start()

	if self.enableLodDraft then
		print("[AI-LOD] Starting LOD draft flow")
		GameState:Transition(GameState.BAN)
	else
		print("[AI-LOD] V0.1 foundation flow → SPAWN → PLAYING")
		GameState:Transition(GameState.SPAWN)
	end
end

function AILODGameMode:RunSpawnPhase()
	print("[AI-LOD] SPAWN phase")

	PlayerState:ForEachConnected(function(playerID, record)
		local preferred = record.hero
		local hero, heroName = self.heroManager:EnsureHeroForPlayer(playerID, preferred)
		if hero then
			print(string.format("[AI-LOD] Player %d ready with %s", playerID, tostring(heroName)))
			hero:RemoveModifierByName("modifier_stunned")
			hero.bAILODReady = true
		else
			print(string.format("[AI-LOD] WARNING: no hero for player %d", playerID))
		end
	end)

	local engineState = GameRules:State_Get()
	if engineState == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
		GameState:Transition(GameState.PLAYING)
	else
		Timers:CreateTimer(function()
			if GameState:Is(GameState.SPAWN) then
				GameState:Transition(GameState.PLAYING)
			end
			return nil
		end)
	end
end

function AILODGameMode:OnPlayerPickHero(event)
	local hero = EntIndexToHScript(event.heroindex)
	if not hero or hero:IsNull() then return end
	local playerID = hero:GetPlayerOwnerID()
	if not PlayerResource:IsValidPlayerID(playerID) then return end
	PlayerState:SetHero(playerID, hero:GetUnitName())
	print(string.format("[AI-LOD] Pick recorded player %d -> %s", playerID, hero:GetUnitName()))
end

function AILODGameMode:OnNPCSpawned(event)
	local unit = EntIndexToHScript(event.entindex)
	if not unit or unit:IsNull() or not unit:IsRealHero() then return end

	if not self.enableLodDraft then
		unit:RemoveModifierByName("modifier_stunned")
		self.respawnManager:OnHeroSpawn(unit)
		return
	end

	if not GameState:Is(GameState.PLAYING) and not GameState:Is(GameState.SPAWN) then
		if not unit.bAILODReady then
			unit:AddNewModifier(unit, nil, "modifier_stunned", {})
		end
	else
		unit:RemoveModifierByName("modifier_stunned")
	end
end

function AILODGameMode:OnEntityKilled(event)
	local killed = EntIndexToHScript(event.entindex_killed)
	if not killed or killed:IsNull() or not killed:IsRealHero() then return end
	if GameState:Is(GameState.PLAYING) then
		self.respawnManager:OnHeroDeath(killed)
	end
end

function AILODGameMode:EventPlayerID(event)
	if not event then return nil end
	if event.PlayerID ~= nil then return event.PlayerID end
	if event.player_id ~= nil then return event.player_id end
	return nil
end

function AILODGameMode:OnBanHero(event)
	if not GameState:Is(GameState.BAN) then return end
	if type(event) ~= "table" then return end
	self.banManager:HandleBan(self:EventPlayerID(event), event.hero)
end

-- Back-compat alias
LODDeathrollGameMode = AILODGameMode
