-- gamemode.lua
-- Core game mode logic for LOD Deathroll.

require("draft/ban_phase")
require("draft/hero_select")
require("draft/ability_draft")
require("draft/extra_ult")
require("deathroll")
require("mmr/client")

LODDeathrollGameMode = LODDeathrollGameMode or class({})

-- Game states
local STATE_BAN_PHASE = 1
local STATE_HERO_SELECT = 2
local STATE_ABILITY_DRAFT = 3
local STATE_BATTLE = 4

function LODDeathrollGameMode:InitGameMode()
	print("[LOD Deathroll] Initializing game mode")

	self.state = STATE_BAN_PHASE
	self.banPhase = BanPhase()
	self.heroSelect = HeroSelect()
	self.abilityDraft = AbilityDraft()
	self.extraUlt = ExtraUlt()
	self.deathroll = Deathroll()
	self.mmrClient = MMRClient()

	self:SetupGameRules()

	ListenToGameEvent("game_rules_state_change", Dynamic_Wrap(LODDeathrollGameMode, "OnGameRulesStateChange"), self)
	ListenToGameEvent("npc_spawned", Dynamic_Wrap(LODDeathrollGameMode, "OnNPCSpawned"), self)
	ListenToGameEvent("entity_killed", Dynamic_Wrap(LODDeathrollGameMode, "OnEntityKilled"), self)
	ListenToGameEvent("dota_game_state_change", Dynamic_Wrap(LODDeathrollGameMode, "OnGameStateChange"), self)

	CustomGameEventManager:RegisterListener("lod_ban_ability", Dynamic_Wrap(self, "OnBanAbility"))
	CustomGameEventManager:RegisterListener("lod_reroll_hero", Dynamic_Wrap(self, "OnRerollHero"))
	CustomGameEventManager:RegisterListener("lod_pick_hero", Dynamic_Wrap(self, "OnPickHero"))
	CustomGameEventManager:RegisterListener("lod_pick_ability", Dynamic_Wrap(self, "OnPickAbility"))
end

function LODDeathrollGameMode:SetupGameRules()
	-- Teams: 5v5 arcade layout
	GameRules:SetCustomGameTeamMaxPlayers(DOTA_TEAM_GOODGUYS, 5)
	GameRules:SetCustomGameTeamMaxPlayers(DOTA_TEAM_BADGUYS, 5)

	-- Allow a normal hero pick first (requires engine herolist.txt with "1" entries).
	-- Custom category draft still runs later for LOD flow / ability draft.
	GameRules:SetCustomGameSetupAutoLaunchDelay(3)
	GameRules:SetHeroSelectionTime(60)
	GameRules:SetHeroSelectPenaltyTime(0)
	GameRules:SetStrategyTime(10)
	GameRules:SetShowcaseTime(0)
	GameRules:SetPreGameTime(10)
	GameRules:SetPostGameTime(30)
	GameRules:SetTreeRegrowTime(60)
	GameRules:SetGoldPerTick(0)
	GameRules:SetGoldTickTime(0)
	GameRules:SetUseUniversalShopMode(true)
	GameRules:SetSameHeroSelectionEnabled(true)

	local mode = GameRules:GetGameModeEntity()
	if mode then
		mode:SetRecommendedItemsDisabled(false)
		mode:SetBuybackEnabled(true)
		mode:SetCustomHeroMaxLevel(30)
		mode:SetFogOfWarDisabled(false)
		mode:SetUnseenFogOfWarEnabled(true)
	end
end

function LODDeathrollGameMode:OnGameRulesStateChange()
	local state = GameRules:State_Get()
	if state == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
		self:StartDraft()
	end
end

function LODDeathrollGameMode:OnNPCSpawned(event)
	local unit = EntIndexToHScript(event.entindex)
	if not unit or not unit:IsRealHero() then return end
	if unit.bIsDrafted then return end
	unit.bIsDrafted = true
end

function LODDeathrollGameMode:OnEntityKilled(event)
	local killed = EntIndexToHScript(event.entindex_killed)
	if not killed or not killed:IsRealHero() then return end
	if self.state == STATE_BATTLE then
		self.deathroll:OnHeroDeath(killed)
	end
end

function LODDeathrollGameMode:OnGameStateChange() end

function LODDeathrollGameMode:StartDraft()
	print("[LOD Deathroll] Starting draft phase")
	self.banPhase:Start(function()
		self.state = STATE_HERO_SELECT
		self.heroSelect:Start(function()
			self.state = STATE_ABILITY_DRAFT
			self.abilityDraft:Start(function()
				self:StartBattle()
			end)
		end)
	end)
end

function LODDeathrollGameMode:StartBattle()
	print("[LOD Deathroll] Draft complete. Battle starting.")
	self.state = STATE_BATTLE
	self.extraUlt:AssignExtraUltimates()
	-- TODO: Spawn heroes, assign drafted abilities, teleport to arena
end

function LODDeathrollGameMode:OnBanAbility(event)
	if self.state ~= STATE_BAN_PHASE then return end
	self.banPhase:HandleBan(event.PlayerID, event.ability)
end

function LODDeathrollGameMode:OnRerollHero(event)
	if self.state ~= STATE_HERO_SELECT then return end
	self.heroSelect:HandleReroll(event.PlayerID)
end

function LODDeathrollGameMode:OnPickHero(event)
	if self.state ~= STATE_HERO_SELECT then return end
	self.heroSelect:HandlePick(event.PlayerID, event.category)
end

function LODDeathrollGameMode:OnPickAbility(event)
	if self.state ~= STATE_ABILITY_DRAFT then return end
	self.abilityDraft:HandlePick(event.PlayerID, event.ability)
end
