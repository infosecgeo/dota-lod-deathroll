-- gamemode.lua
-- AI-LOD core. Full LOD draft pipeline (Phases 3-12) enabled for V1.0.

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
local ENABLE_LOD_DRAFT = true

-- Fallback hero if selection fails (also used if force-hero path is needed).
local DEFAULT_HERO = "npc_dota_hero_axe"

function AILODGameMode:InitGameMode()
	print("[AI-LOD] InitGameMode (V1.0 LOD draft, ENABLE_LOD_DRAFT="
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

	GameRules:SetCustomGameSetupAutoLaunchDelay(5)
	GameRules:SetStrategyTime(0)
	GameRules:SetShowcaseTime(0)
	GameRules:SetPostGameTime(30)
	GameRules:SetTreeRegrowTime(60)
	GameRules:SetUseUniversalShopMode(true)
	GameRules:SetSameHeroSelectionEnabled(true)

	if self.enableLodDraft then
		-- LOD path: skip vanilla pick, draft owns hero choice.
		GameRules:SetHeroSelectionTime(0)
		GameRules:SetHeroSelectPenaltyTime(0)
		GameRules:SetPreGameTime(240)
	else
		GameRules:SetHeroSelectionTime(30)
		GameRules:SetHeroSelectPenaltyTime(5)
		GameRules:SetPreGameTime(10)
	end

	-- NOTE: Do not call mode:SetCustomGameForceHero(DEFAULT_HERO) here.
	-- Forcing a hero makes the engine auto-assign DEFAULT_HERO to every
	-- player as soon as PRE_GAME starts, bypassing the ban -> hero draft ->
	-- ability draft -> ultimate draft pipeline entirely (players would
	-- always spawn as Axe instead of going through the draft). The draft
	-- pipeline creates each player's hero explicitly via
	-- HeroManager:EnsureHeroForPlayer() in RunSpawnPhase once the draft
	-- completes, and the foundation (non-draft) path never needs a forced
	-- hero either since it relies on vanilla hero selection.
	local mode = GameRules:GetGameModeEntity()
	if mode then
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
			GameState:Transition(GameState.ULTIMATE_DRAFT)
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
		print("[AI-LOD] PLAYING — heroes should move, attack, cast, die, death-draft")
		CustomGameEventManager:Send_ServerToAllClients("ai_lod_playing", {})
		CustomGameEventManager:Send_ServerToAllClients("lod_battle_start", {})
	end)

	GameState:OnEnter(GameState.RESPAWN_DRAFT, function(payload)
		-- Global RESPAWN_DRAFT is reserved; death draft is per-player in PLAYING.
		print("[AI-LOD] RESPAWN_DRAFT global enter; returning to PLAYING")
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
	CustomGameEventManager:RegisterListener("ai_lod_pick_hero", function(_, event)
		gm:OnPickHero(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_reroll_hero", function(_, event)
		gm:OnRerollHero(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_pick_ability", function(_, event)
		gm:OnPickAbility(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_pick_ult", function(_, event)
		gm:OnPickUlt(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_confirm_ult", function(_, event)
		gm:OnConfirmUlt(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_death_slot", function(_, event)
		gm:OnDeathSlot(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_death_ability", function(_, event)
		gm:OnDeathAbility(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_death_reroll", function(_, event)
		gm:OnDeathReroll(event)
	end)
	CustomGameEventManager:RegisterListener("ai_lod_death_confirm", function(_, event)
		gm:OnDeathConfirm(event)
	end)

	-- Legacy event names (map onto new handlers)
	CustomGameEventManager:RegisterListener("lod_ban_ability", function(_, event)
		-- legacy banned abilities; ignore in hero-ban design
	end)
	CustomGameEventManager:RegisterListener("lod_pick_hero", function(_, event)
		gm:OnPickHero(event)
	end)
	CustomGameEventManager:RegisterListener("lod_pick_ability", function(_, event)
		gm:OnPickAbility(event)
	end)
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
		print("[AI-LOD] Foundation flow -> SPAWN -> PLAYING")
		GameState:Transition(GameState.SPAWN)
	end
end

function AILODGameMode:RunSpawnPhase()
	print("[AI-LOD] SPAWN phase")

	PlayerState:ForEachConnected(function(playerID, record)
		local preferred = record.hero or (self.draftManager and self.draftManager:GetHeroPick(playerID))
		local hero, heroName = self.heroManager:EnsureHeroForPlayer(playerID, preferred)
		if hero then
			print(string.format("[AI-LOD] Player %d ready with %s", playerID, tostring(heroName)))
			-- Apply drafted kit
			if self.enableLodDraft and record.abilities then
				local basics = record.abilities.basic or {}
				local ults = record.abilities.ultimate or {}
				self.abilityManager:ApplyKit(hero, basics, ults)
				local budgetOk = self.balanceManager:WithinBudget(
					(function()
						local all = {}
						for _, a in ipairs(basics) do table.insert(all, a) end
						for _, a in ipairs(ults) do table.insert(all, a) end
						return all
					end)()
				)
				print(string.format("[AI-LOD] Player %d kit budget ok=%s score=%s",
					playerID, tostring(budgetOk),
					tostring(self.balanceManager:Total(
						(function()
							local all = {}
							for _, a in ipairs(basics) do table.insert(all, a) end
							for _, a in ipairs(ults) do table.insert(all, a) end
							return all
						end)()
					))))
			end
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
	if not self.enableLodDraft then
		PlayerState:SetHero(playerID, hero:GetUnitName())
	end
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
		self.respawnManager:OnHeroSpawn(unit)
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

function AILODGameMode:OnPickHero(event)
	if not GameState:Is(GameState.HERO_DRAFT) then return end
	if type(event) ~= "table" then return end
	self.draftManager:HandleHeroPick(self:EventPlayerID(event), event.hero)
end

function AILODGameMode:OnRerollHero(event)
	if not GameState:Is(GameState.HERO_DRAFT) then return end
	if type(event) ~= "table" then return end
	self.draftManager:HandleHeroReroll(self:EventPlayerID(event), event.category)
end

function AILODGameMode:OnPickAbility(event)
	if not GameState:Is(GameState.ABILITY_DRAFT) then return end
	if type(event) ~= "table" then return end
	self.draftManager:HandleAbilityPick(self:EventPlayerID(event), event.ability)
end

function AILODGameMode:OnPickUlt(event)
	if not GameState:Is(GameState.ULTIMATE_DRAFT) then return end
	if type(event) ~= "table" then return end
	self.draftManager:HandleUltPick(self:EventPlayerID(event), event.ability)
end

function AILODGameMode:OnConfirmUlt(event)
	if not GameState:Is(GameState.ULTIMATE_DRAFT) then return end
	if type(event) ~= "table" then return end
	self.draftManager:HandleUltConfirm(self:EventPlayerID(event))
end

function AILODGameMode:OnDeathSlot(event)
	if type(event) ~= "table" then return end
	self.respawnManager:HandleDeathSelectSlot(self:EventPlayerID(event), event.slot or event.ability)
end

function AILODGameMode:OnDeathAbility(event)
	if type(event) ~= "table" then return end
	self.respawnManager:HandleDeathSelectAbility(self:EventPlayerID(event), event.ability)
end

function AILODGameMode:OnDeathReroll(event)
	if type(event) ~= "table" then return end
	self.respawnManager:HandleDeathReroll(self:EventPlayerID(event))
end

function AILODGameMode:OnDeathConfirm(event)
	if type(event) ~= "table" then return end
	self.respawnManager:HandleDeathConfirm(self:EventPlayerID(event))
end

-- Back-compat alias
LODDeathrollGameMode = AILODGameMode
