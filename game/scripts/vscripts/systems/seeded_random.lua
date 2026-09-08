-- A private Park-Miller stream; never changes the engine/global RNG.
local DraftRandom = { seed = 1, state = 1, draws = 0 }
local MODULUS = 2147483647

function DraftRandom:Init(seed)
	local value = (type(seed) == "number" or type(seed) == "string") and tonumber(seed) or nil
	if not value or value ~= value or value == math.huge or value == -math.huge then
		value = 1
	end
	value = math.floor(value) % MODULUS
	if value == 0 then value = 1 end
	self.seed, self.state, self.draws = value, value, 0
	return self:Snapshot()
end

function DraftRandom:Int(minimum, maximum)
	assert(type(minimum) == "number" and type(maximum) == "number"
		and minimum == math.floor(minimum) and maximum == math.floor(maximum)
		and minimum > -math.huge and maximum < math.huge and minimum <= maximum,
		"DraftRandom:Int requires finite integer bounds")
	local width = maximum - minimum + 1
	assert(width <= MODULUS - 1, "DraftRandom:Int range too large")
	-- Rejection sampling avoids modulo bias. Products stay exactly representable.
	local limit = (MODULUS - 1) - ((MODULUS - 1) % width)
	local sample
	repeat
		self.state = (self.state * 16807) % MODULUS
		self.draws = self.draws + 1
		sample = self.state - 1
	until sample < limit
	return minimum + (sample % width)
end

function DraftRandom:Snapshot()
	return { seed = self.seed, state = self.state, draws = self.draws }
end

return DraftRandom
