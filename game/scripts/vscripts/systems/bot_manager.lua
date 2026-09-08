-- Fill empty Radiant/Dire slots with hard AI bots and auto-complete their LOD draft.

BotManager = BotManager or class({})
local DraftRandom = require("systems/seeded_random")

local TEAM_SIZE = 5
local BOT_DIFFICULTY = "hard"
local NAME_PREFIX = {
	"Iron", "Shadow", "Crimson", "Azure", "Silent", "Storm", "Jade", "Grim",
	"Swift", "Hollow", "Golden", "Ashen", "Rogue", "Frost", "Solar", "Night",
}
local NAME_SUFFIX = {
	"Blade", "Ward", "Fang", "Spark", "Crest", "Warden", "Seer", "Reaver",
	"Hex", "Bolt", "Shade", "Flame", "Tide", "Crown", "Arrow", "Oath",
}

function BotManager:constructor(gameMode)
	self.gameMode = gameMode
	self.filled = false
	self.botNames = {}
	self.usedNames = {}
end

function BotManager:IsPlayableTeam(team)
	return team == DOTA_TEAM_GOODGUYS or team == DOTA_TEAM_BADGUYS
end

function BotManager:TeamCount(team)
	local count = 0
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) and PlayerResource:GetTeam(playerID) == team then
			count = count + 1
		end
	end
	return count
end

function BotManager:TeamsFull()
	return self:TeamCount(DOTA_TEAM_GOODGUYS) >= TEAM_SIZE
		and self:TeamCount(DOTA_TEAM_BADGUYS) >= TEAM_SIZE
end

function BotManager:AssignTeam(playerID, team)
	if playerID == nil or playerID < 0 or not self:IsPlayableTeam(team) then return false end
	if PlayerResource.SetCustomTeamAssignment then
		pcall(function() PlayerResource:SetCustomTeamAssignment(playerID, team) end)
	end
	local player = PlayerResource.GetPlayer and PlayerResource:GetPlayer(playerID)
	if player and not player:IsNull() and player.SetTeam then
		pcall(function() player:SetTeam(team) end)
	end
	return PlayerResource:GetTeam(playerID) == team
end

function BotManager:BalancedTeam()
	local radiant = self:TeamCount(DOTA_TEAM_GOODGUYS)
	local dire = self:TeamCount(DOTA_TEAM_BADGUYS)
	if radiant < TEAM_SIZE and (radiant <= dire or dire >= TEAM_SIZE) then
		return DOTA_TEAM_GOODGUYS
	end
	if dire < TEAM_SIZE then
		return DOTA_TEAM_BADGUYS
	end
	return nil
end

function BotManager:MarkBot(playerID, name, team)
	if name and name ~= "" then
		self.usedNames[name] = true
		self.botNames[playerID] = name
	end
	if PlayerResource.SetPlayerName and name and name ~= "" then
		pcall(function() PlayerResource:SetPlayerName(playerID, name) end)
	end
	if team then self:AssignTeam(playerID, team) end
	local record = PlayerState:Ensure(playerID)
	if record then
		record.isBot = true
		record.botName = name or record.botName or ("Bot " .. tostring(playerID))
		record.clientReady = true
		record.lobbyReady = true
		record.strategyReady = true
	end
end

function BotManager:AutoAssignUnassigned()
	local unassigned = {}
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then
			local team = PlayerResource:GetTeam(playerID)
			if not self:IsPlayableTeam(team) then
				table.insert(unassigned, playerID)
			end
		end
	end
	for _, playerID in ipairs(unassigned) do
		local team = self:BalancedTeam()
		if not team then break end
		if self:AssignTeam(playerID, team) then
			if PlayerResource.IsFakeClient and PlayerResource:IsFakeClient(playerID) then
				self:MarkBot(playerID, self.botNames[playerID] or self:RandomName(), team)
			end
			print(string.format("[BotManager] Auto-assigned player %d to team %d", playerID, team))
		end
	end
end

function BotManager:RandomName()
	for _ = 1, 40 do
		local name = NAME_PREFIX[DraftRandom:Int(1, #NAME_PREFIX)]
			.. " "
			.. NAME_SUFFIX[DraftRandom:Int(1, #NAME_SUFFIX)]
		if not self.usedNames[name] then
			self.usedNames[name] = true
			return name
		end
	end
	return "Bot " .. tostring(DraftRandom:Int(100, 999))
end

function BotManager:ApplyHardDifficulty()
	local mode = GameRules:GetGameModeEntity()
	if mode and mode.SetBotThinkingEnabled then
		mode:SetBotThinkingEnabled(true)
	end
	if mode and mode.SetBotsInLateGame then
		mode:SetBotsInLateGame(true)
	end
	-- 0 passive … 3 hard … 4 unfair. Prefer hard.
	if Convars and Convars.SetInt then
		pcall(function() Convars:SetInt("dota_bot_difficulty", 3) end)
		pcall(function() Convars:SetInt("dota_bot_force_difficulty", 3) end)
	end
	if SendToServerConsole then
		pcall(function() SendToServerConsole("dota_bot_set_difficulty 3") end)
		pcall(function() SendToServerConsole("dota_bot_force_right_click_attack 0") end)
	end
	if Tutorial and Tutorial.SetBotDifficulty then
		pcall(function() Tutorial:SetBotDifficulty(3) end)
	end
end

function BotManager:HasFreePlayerSlot()
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if not PlayerResource:IsValidPlayerID(playerID) then return true end
	end
	return false
end

function BotManager:TryAddBot(team, name)
	if self:TeamCount(team) >= TEAM_SIZE or not self:HasFreePlayerSlot() then return nil end

	local before = {}
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID) then before[playerID] = true end
	end

	local addedID = nil
	if GameRules.AddBotPlayerWithEntityScript then
		local ok, result = pcall(function()
			-- Empty hero: LOD owns hero creation after the draft completes.
			-- false = add immediately so team assignment sticks during setup.
			return GameRules:AddBotPlayerWithEntityScript("", name, team, "", false)
		end)
		if ok and type(result) == "number" and result >= 0 and result < DOTA_MAX_PLAYERS then
			addedID = result
		end
	end

	if addedID == nil and Tutorial and Tutorial.AddBot then
		-- Fallback: engine bot join. Hero is replaced after draft.
		local radiant = team == DOTA_TEAM_GOODGUYS
		pcall(function()
			Tutorial:AddBot("npc_dota_hero_wisp", "mid", BOT_DIFFICULTY, radiant)
		end)
	end

	if addedID == nil then
		for playerID = 0, DOTA_MAX_PLAYERS - 1 do
			if PlayerResource:IsValidPlayerID(playerID) and not before[playerID] then
				addedID = playerID
				break
			end
		end
	end

	if addedID == nil or addedID < 0 or addedID >= DOTA_MAX_PLAYERS then return nil end
	if not PlayerResource:IsValidPlayerID(addedID) then return nil end

	self:MarkBot(addedID, name, team)
	if PlayerResource:GetTeam(addedID) ~= team then
		print(string.format("[BotManager] Bot %d failed team assign to %d", addedID, team))
		return nil
	end
	print(string.format("[BotManager] Filled slot %d on team %d as '%s'", addedID, team, name))
	return addedID
end

function BotManager:FillEmptySlots()
	if PlayerState.roster then return self.filled end
	if self.filled and self:TeamsFull() then return true end

	self:ApplyHardDifficulty()
	self:AutoAssignUnassigned()

	local added = 0
	for _, team in ipairs({ DOTA_TEAM_GOODGUYS, DOTA_TEAM_BADGUYS }) do
		local guard = 0
		while self:TeamCount(team) < TEAM_SIZE and guard < TEAM_SIZE do
			guard = guard + 1
			local name = self:RandomName()
			local id = self:TryAddBot(team, name)
			if id == nil then
				print(string.format("[BotManager] Could not fill team %d beyond %d players", team, self:TeamCount(team)))
				break
			end
			added = added + 1
		end
	end

	-- Reclaim any bots that still sit in the unassigned column of team select.
	self:AutoAssignUnassigned()
	self.filled = self:TeamsFull()
	print(string.format("[BotManager] Bot fill complete (+%d, full=%s). Radiant=%d Dire=%d",
		added, tostring(self.filled), self:TeamCount(DOTA_TEAM_GOODGUYS), self:TeamCount(DOTA_TEAM_BADGUYS)))
	return self.filled or added > 0
		or self:TeamCount(DOTA_TEAM_GOODGUYS) + self:TeamCount(DOTA_TEAM_BADGUYS) > 0
end

function BotManager:IsBot(playerID)
	if PlayerState:IsBot(playerID) then return true end
	local record = PlayerState.players and PlayerState.players[playerID]
	return record and record.isBot == true
end

function BotManager:ForEachBot(callback)
	PlayerState:ForEachParticipant(function(playerID, record)
		if self:IsBot(playerID) then callback(playerID, record) end
	end)
end

function BotManager:AutoBan(banManager)
	if not banManager or not banManager.active then return end
	local pool = banManager.heroManager and banManager.heroManager:LoadPool() or {}
	self:ForEachBot(function(playerID, _)
		if banManager.playerBanned[playerID] then return end
		local candidates = {}
		for _, hero in ipairs(pool) do
			if banManager.heroManager:IsAvailable(hero) then table.insert(candidates, hero) end
		end
		if #candidates == 0 then return end
		local hero = candidates[DraftRandom:Int(1, #candidates)]
		banManager:HandleBan(playerID, hero)
	end)
end

function BotManager:AutoHero(draftManager)
	if not draftManager or draftManager.phase ~= "hero" then return end
	self:ForEachBot(function(playerID, _)
		if draftManager.heroPicks[playerID] then return end
		local offers = draftManager.heroOffers[playerID] or {}
		local choices = {}
		for _, cat in ipairs(draftManager.heroManager:GetCategories()) do
			for _, hero in ipairs(offers[cat] or {}) do
				if draftManager:IsHeroOffered(playerID, hero) then table.insert(choices, hero) end
			end
		end
		if #choices == 0 then return end
		draftManager:HandleHeroPick(playerID, choices[DraftRandom:Int(1, #choices)])
	end)
end

function BotManager:AutoAbilities(draftManager)
	if not draftManager or draftManager.phase ~= "ability" then return end
	self:ForEachBot(function(playerID, record)
		if draftManager.abilityDone[playerID] then return end
		local offers = draftManager.abilityOffers[playerID]
		if not offers then return end
		local guard = 0
		while not draftManager.abilityDone[playerID] and guard < 8 do
			guard = guard + 1
			local basics = draftManager:Candidates(offers.basic, record, false)
			if #basics == 0 then break end
			draftManager:HandleAbilityPick(playerID, basics[DraftRandom:Int(1, #basics)])
		end
	end)
end

function BotManager:AutoInitialUlt(draftManager)
	if not draftManager or draftManager.phase ~= "initial" then return end
	self:ForEachBot(function(playerID, record)
		if #record.abilities.ultimate > 0 then return end
		local choices = draftManager.initialUltOffers[playerID] or {}
		if #choices == 0 then return end
		draftManager:HandleInitialUltPick(playerID, choices[DraftRandom:Int(1, #choices)])
	end)
end

function BotManager:AutoBonusUlt(draftManager)
	if not draftManager or draftManager.phase ~= "ultimate" then return end
	self:ForEachBot(function(playerID, _)
		if draftManager.ultConfirmed[playerID] then return end
		local choices = draftManager:Candidates(draftManager.ultOffers[playerID], PlayerState:Get(playerID), true)
		if #choices == 0 then return end
		local pick = choices[DraftRandom:Int(1, #choices)]
		draftManager:HandleUltPick(playerID, pick)
		draftManager:HandleUltConfirm(playerID)
	end)
end

function BotManager:AutoBuild(draftManager)
	if not draftManager or draftManager.phase ~= "build" then return end
	self:ForEachBot(function(playerID, record)
		if record.buildConfirmed then return end
		draftManager:HandleBuildConfirm(playerID)
	end)
end

function BotManager:AutoStrategy(gameMode)
	self:ForEachBot(function(playerID, record)
		record.strategyReady = true
		if record.lane == nil or record.lane == "" then
			local lanes = { "top", "mid", "bottom", "jungle" }
			record.lane = lanes[DraftRandom:Int(1, #lanes)]
		end
	end)
	if gameMode and gameMode.SendPreparation then gameMode:SendPreparation() end
	if gameMode and gameMode.PublishRoster then gameMode:PublishRoster() end
end
