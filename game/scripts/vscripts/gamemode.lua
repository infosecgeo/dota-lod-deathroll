-- gamemode.lua
-- Core game mode logic for LOD Deathroll.

require("libraries/timers")
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

-- Placeholder hero while LOD draft UI runs (skips vanilla pick screen).
local FORCE_HERO = "npc_dota_hero_axe"

function LODDeathrollGameMode:InitGameMode()
	print("[LOD Deathroll] Initializing game mode")

	self.state = STATE_BAN_PHASE
	self.draftStarted = false
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

	-- Custom events: callback is (eventSourceIndex, eventData). Bind to instance methods.
	local gm = self
	CustomGameEventManager:RegisterListener("lod_ban_ability", function(_, event)
		gm:OnBanAbility(event)
	end)
	CustomGameEventManager:RegisterListener("lod_pick_hero", function(_, event)
		gm:OnPickHero(event)
	end)
	CustomGameEventManager:RegisterListener("lod_pick_ability", function(_, event)
		gm:OnPickAbility(event)
	end)
end

function LODDeathrollGameMode:SetupGameRules()
	GameRules:SetCustomGameTeamMaxPlayers(DOTA_TEAM_GOODGUYS, 5)
	GameRules:SetCustomGameTeamMaxPlayers(DOTA_TEAM_BADGUYS, 5)

	-- Skip vanilla hero pick — LOD category pick + ability draft is the real select.
	GameRules:SetCustomGameSetupAutoLaunchDelay(3)
	GameRules:SetHeroSelectionTime(0)
	GameRules:SetHeroSelectPenaltyTime(0)
	GameRules:SetStrategyTime(0)
	GameRules:SetShowcaseTime(0)
	-- Draft runs during pre-game (ban 30 + hero 45 + ability 60 ≈ 135s; buffer included).
	GameRules:SetPreGameTime(150)
	GameRules:SetPostGameTime(30)
	GameRules:SetTreeRegrowTime(60)
	GameRules:SetGoldPerTick(0)
	GameRules:SetGoldTickTime(0)
	GameRules:SetUseUniversalShopMode(true)
	GameRules:SetSameHeroSelectionEnabled(true)

	local mode = GameRules:GetGameModeEntity()
	if mode then
		-- Force a placeholder so the engine does not show normal hero picking.
		if mode.SetCustomGameForceHero then
			mode:SetCustomGameForceHero(FORCE_HERO)
		end
		mode:SetRecommendedItemsDisabled(false)
		mode:SetBuybackEnabled(true)
		mode:SetCustomHeroMaxLevel(30)
		mode:SetFogOfWarDisabled(false)
		mode:SetUnseenFogOfWarEnabled(true)
	end
end

function LODDeathrollGameMode:OnGameRulesStateChange()
	local state = GameRules:State_Get()
	-- Start LOD draft as soon as heroes exist (PRE_GAME), not after match clock.
	if state == DOTA_GAMERULES_STATE_PRE_GAME or state == DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
		self:StartDraft()
	end
end

function LODDeathrollGameMode:OnNPCSpawned(event)
	local unit = EntIndexToHScript(event.entindex)
	if not unit or not unit:IsRealHero() then return end
	if unit.bLODProcessed then return end

	-- During draft, strip placeholder abilities so players cannot fight yet.
	if self.state ~= STATE_BATTLE then
		self:StripHeroAbilities(unit)
		unit:AddNewModifier(unit, nil, "modifier_stunned", {})
	end
end

function LODDeathrollGameMode:OnEntityKilled(event)
	local killed = EntIndexToHScript(event.entindex_killed)
	if not killed or not killed:IsRealHero() then return end
	if self.state == STATE_BATTLE then
		self.deathroll:OnHeroDeath(killed)
	end
end

function LODDeathrollGameMode:StartDraft()
	if self.draftStarted then return end
	self.draftStarted = true
	print("[LOD Deathroll] Starting LOD draft phase (ban -> hero -> abilities)")
	self.state = STATE_BAN_PHASE
	Timers:Start()

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

function LODDeathrollGameMode:StripHeroAbilities(hero)
	if not hero or hero:IsNull() then return end
	local toRemove = {}
	for i = 0, hero:GetAbilityCount() - 1 do
		local ab = hero:GetAbilityByIndex(i)
		if ab then
			local name = ab:GetAbilityName()
			if name and name ~= "" and not string.find(name, "special_bonus") then
				table.insert(toRemove, name)
			end
		end
	end
	for _, name in ipairs(toRemove) do
		hero:RemoveAbility(name)
	end
end

function LODDeathrollGameMode:ApplyDraftedAbilities(hero, picks)
	if not hero or hero:IsNull() or not picks then return end
	self:StripHeroAbilities(hero)

	local order = {}
	for _, ability in ipairs(picks.regular or {}) do
		table.insert(order, ability)
	end
	if picks.ultimate then
		table.insert(order, picks.ultimate)
	end

	for _, abilityName in ipairs(order) do
		local ab = hero:AddAbility(abilityName)
		if ab then
			ab:SetLevel(1)
			ab:SetHidden(false)
		else
			print(string.format("[LOD Deathroll] Failed to add ability %s", tostring(abilityName)))
		end
	end
end

function LODDeathrollGameMode:StartBattle()
	print("[LOD Deathroll] Draft complete. Applying heroes and abilities.")
	self.state = STATE_BATTLE

	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			local heroName = self.heroSelect:GetPick(playerID) or "npc_dota_hero_axe"
			local picks = self.abilityDraft:GetPicks(playerID)

			local hero = PlayerResource:GetSelectedHeroEntity(playerID)
			if hero and hero:GetUnitName() ~= heroName then
				local gold = 0
				if hero.GetGold then gold = hero:GetGold() end
				local newHero = PlayerResource:ReplaceHeroWith(playerID, heroName, gold, 0)
				if newHero then
					hero = newHero
				end
			elseif not hero then
				local player = PlayerResource:GetPlayer(playerID)
				if player then
					hero = CreateHeroForPlayer(heroName, player)
				end
			end

			if hero then
				hero:RemoveModifierByName("modifier_stunned")
				self:ApplyDraftedAbilities(hero, picks)
				hero.bLODProcessed = true
				print(string.format("[LOD Deathroll] Player %d -> %s with drafted skills", playerID, heroName))
			end
		end
	end

	self.extraUlt:AssignExtraUltimates()
	CustomGameEventManager:Send_ServerToAllClients("lod_battle_start", {})
end

function LODDeathrollGameMode:EventPlayerID(event)
	if not event then return nil end
	if event.PlayerID ~= nil then return event.PlayerID end
	if event.player_id ~= nil then return event.player_id end
	return nil
end

function LODDeathrollGameMode:OnBanAbility(event)
	if self.state ~= STATE_BAN_PHASE then return end
	if type(event) ~= "table" then return end
	self.banPhase:HandleBan(self:EventPlayerID(event), event.ability)
end

function LODDeathrollGameMode:OnPickHero(event)
	if self.state ~= STATE_HERO_SELECT then return end
	if type(event) ~= "table" then return end
	-- Prefer explicit hero name; fall back to category for older clients.
	local hero = event.hero or event.category
	self.heroSelect:HandlePick(self:EventPlayerID(event), hero)
end

function LODDeathrollGameMode:OnPickAbility(event)
	if self.state ~= STATE_ABILITY_DRAFT then return end
	if type(event) ~= "table" then return end
	self.abilityDraft:HandlePick(self:EventPlayerID(event), event.ability)
end
