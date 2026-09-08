-- Run with Lua from any directory; no Dota runtime or third-party test framework.
local directory = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = directory .. "../?.lua;" .. package.path

function class()
	local prototype = {}
	prototype.__index = prototype
	return setmetatable(prototype, {
		__call = function(self, ...)
			local object = setmetatable({}, self)
			object:constructor(...)
			return object
		end,
	})
end

local now, paused, playing = 0, false, true
function Time() return now end
GameRules = {
	GetGameTime = function() return now end,
	IsGamePaused = function() return paused end,
	GetGameModeEntity = function() return { SetContextThink = function() end } end,
}
GameState = { PLAYING = 6, Is = function() return playing end }
require("libraries/timers")
require("systems/respawn_manager")

local hero, record, manager, abilities, events
PlayerResource = {
	IsValidPlayerID = function(_, id) return id == 0 end,
	GetSelectedHeroEntity = function() return hero end,
	GetPlayer = function() return {} end,
}
PlayerState = {
	Get = function() return record end,
	IncDeath = function() record.deathCount = record.deathCount + 1 end,
	ResetRespawnRerolls = function() record.rerolls.respawn = 3 end,
}
CustomGameEventManager = {
	Send_ServerToPlayer = function(_, _, event, payload)
		events[event] = payload
	end,
}

local function reset(respawnTime)
	now, paused, playing = 0, false, true
	Timers.timers, Timers.nextId, Timers.stopped = {}, 1, false
	record = {
		abilities = { basic = { "a", "b", "c" }, ultimate = { "u", "v" } },
		rerolls = { respawn = 3 }, deathCount = 0,
	}
	hero = {
		alive = false,
		IsNull = function() return false end,
		IsRealHero = function() return true end,
		IsAlive = function(self) return self.alive end,
		GetPlayerOwnerID = function() return 0 end,
		GetTimeUntilRespawn = function() return respawnTime or 40 end,
		SetTimeUntilRespawn = function() error("Death drafting must not change respawn time") end,
	}
	events = {}
	abilities = {
		taken = {}, applyCount = 0, commitCount = 0,
		GetDeathPool = function(_, kind)
			return kind == "basic" and { "d", "e" } or { "w", "x" }
		end,
		IsAvailable = function(self, name) return not self.taken[name] end,
		Sample = function(_, source, count, excluded)
			local out = {}
			for _, name in ipairs(source) do
				if not excluded[name] and #out < count then table.insert(out, name) end
			end
			return out
		end,
		ApplyDraftChanges = function(self)
			self.applyCount = self.applyCount + 1
			return not self.fail, "invalid_kit"
		end,
		CommitBuild = function(self)
			self.commitCount = self.commitCount + 1
			return true
		end,
	}
	manager = RespawnManager(abilities)
	manager:OnHeroDeath(hero)
	return manager.pending[0]
end

local function stage(name)
	local session = manager.pending[0]
	manager:HandleDeathSelectSlot(0, "a", session.draftId)
	manager:HandleDeathSelectAbility(0, name or "d", session.draftId)
	return session
end

local session = reset(7)
assert(session.expiresAt == 7, "Draft ends no later than normal respawn")
stage()
manager:HandleDeathSkip(0, session.draftId)
assert(not manager.pending[0] and not record.respawnPending)
assert(record.abilities.basic[1] == "a" and abilities.applyCount == 0)
assert(events.ai_lod_death_end.skipped, "Skip must discard staged edits")
manager:HandleDeathConfirm(0, session.draftId)
assert(abilities.applyCount == 0, "Closed draft cannot be confirmed")

session = reset()
stage()
now = 25
Timers:Think()
assert(not manager.pending[0] and record.abilities.basic[1] == "a")
assert(events.ai_lod_death_end.timed_out and abilities.applyCount == 0)

session = reset()
manager:HandleDeathConfirm(0, session.draftId)
assert(abilities.applyCount == 0, "Keeping unchanged kit must not reapply abilities")

session = reset()
stage("w")
assert(session.candidate.basic[1] == "a", "Ultimate cannot replace basic slot")
stage()
manager:HandleDeathConfirm(0, session.draftId)
assert(record.abilities.basic[1] == "d" and abilities.applyCount == 1)
assert(abilities.commitCount == 1)
manager:HandleDeathConfirm(0, session.draftId)
assert(abilities.applyCount == 1, "Repeated confirmation is idempotent")

session = reset()
stage()
abilities.taken.d = true
manager:HandleDeathConfirm(0, session.draftId)
assert(manager.pending[0] and session.error == "ability_taken")
assert(abilities.applyCount == 0 and record.abilities.basic[1] == "a")

session = reset()
stage()
abilities.fail = true
manager:HandleDeathConfirm(0, session.draftId)
assert(manager.pending[0] and session.error == "invalid_kit")
assert(record.abilities.basic[1] == "a" and abilities.commitCount == 0)

session = reset()
local oldToken = session.draftId
stage()
manager:HandleDeathReroll(0, oldToken)
assert(record.rerolls.respawn == 2 and session.candidate.basic[1] == "a")
manager:HandleDeathConfirm(0, oldToken)
manager:HandleDeathSkip(0, oldToken)
assert(manager.pending[0], "Old offer tokens cannot confirm or skip newer offers")
manager:HandleDeathReroll(0, session.draftId)
manager:HandleDeathReroll(0, session.draftId)
local finalToken = session.draftId
manager:HandleDeathReroll(0, finalToken)
assert(record.rerolls.respawn == 0 and session.draftId == finalToken)
manager:HandleDeathSkip(0, finalToken)
assert(not manager.pending[0], "Skip stays available at zero rerolls")

session = reset()
stage()
hero.alive = true
manager:OnHeroSpawn(hero)
assert(not manager.pending[0] and abilities.applyCount == 0)
assert(record.abilities.basic[1] == "a", "Respawn preserves the original kit")

session = reset()
stage()
manager:SyncPlayer(0)
assert(events.ai_lod_death_draft.pending_basic == "d,b,c")
assert(events.ai_lod_death_draft.draft_id == session.draftId)
playing = false
manager:CancelAll()
assert(not manager.pending[0] and abilities.applyCount == 0)

reset()
Timers.timers, Timers.nextId = {}, 1
local order = {}
for i = 1, 12 do
	local index = i
	Timers:CreateTimer(function() table.insert(order, index) end, false)
end
paused = true
Timers:CreateTimer(function() error("Game-time timer executed during pause") end)
Timers:Think()
for i = 1, 12 do assert(order[i] == i, "Callbacks must have stable creation order") end
print("Death draft and timer regression checks passed")
