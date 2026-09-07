-- Minimal Timers library for LOD Deathroll (Think-based).
-- API: Timers:CreateTimer(fn) -> id; Timers:RemoveTimer(id)

if Timers == nil then
	Timers = {}
end

Timers.timers = Timers.timers or {}
Timers.nextId = Timers.nextId or 1
Timers.started = Timers.started or false

local THINK_NAME = "LODDeathrollTimers"
local TICK = 0.03

function Timers:Start()
	if self.started or self.stopped then return end
	self.started = true
	local mode = GameRules:GetGameModeEntity()
	if not mode then
		print("[Timers] WARNING: GameModeEntity missing; retrying")
		self.started = false
		return
	end
	mode:SetContextThink(THINK_NAME, function()
		return Timers:Think()
	end, TICK)
end

function Timers:Think()
	if self.stopped then return nil end
	local now = GameRules:GetGameTime()
	local realNow = Time()
	local pending = {}
	for id, timer in pairs(self.timers) do
		pending[id] = timer
	end
	for id, t in pairs(pending) do
		local clock = t.useGameTime and now or realNow
		if self.timers[id] == t
			and (not t.useGameTime or not GameRules:IsGamePaused()) and t.endTime <= clock then
			local status, nextDelay = pcall(t.callback)
			if self.stopped then return nil end
			if self.timers[id] ~= t then
				-- A callback may cancel itself or all timers.
			elseif not status then
				print("[Timers] Error in timer " .. tostring(id) .. ": " .. tostring(nextDelay))
				self.timers[id] = nil
			elseif type(nextDelay) == "number" and nextDelay > 0 then
				t.endTime = clock + nextDelay
			else
				self.timers[id] = nil
			end
		end
	end
	return TICK
end

-- Pass false for presentation timers that must run during the server's draft pause.
function Timers:CreateTimer(callback, useGameTime)
	if self.stopped then return nil end
	self:Start()
	local id = self.nextId
	self.nextId = self.nextId + 1
	useGameTime = useGameTime ~= false
	local now = useGameTime and GameRules:GetGameTime() or Time()
	self.timers[id] = {
		endTime = now,
		callback = callback,
		useGameTime = useGameTime,
	}
	return id
end

function Timers:Stop()
	self.stopped = true
	self.timers = {}
end

function Timers:RemoveTimer(id)
	if id then
		self.timers[id] = nil
	end
end
