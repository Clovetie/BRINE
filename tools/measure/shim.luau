--!nocheck
-- Minimal Vector3 / Vector2 for running BRINE's ocean modules under the plain
-- Luau interpreter (.tools/bin/luau) with no Roblox engine.
-- Only the operations Gerstner/init.luau actually uses are implemented.

local V3 = {}
V3.__index = function(self, k)
	if k == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif k == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if m == 0 then
			return V3.new(0, 0, 0)
		end
		return V3.new(self.X / m, self.Y / m, self.Z / m)
	end
	return V3[k]
end
function V3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
end
V3.__add = function(a, b)
	return V3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3.__sub = function(a, b)
	return V3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__mul = function(a, b)
	if type(b) == "number" then
		return V3.new(a.X * b, a.Y * b, a.Z * b)
	elseif type(a) == "number" then
		return V3.new(a * b.X, a * b.Y, a * b.Z)
	end
	return V3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then
		return V3.new(a.X / b, a.Y / b, a.Z / b)
	end
	return V3.new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__unm = function(a)
	return V3.new(-a.X, -a.Y, -a.Z)
end
V3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3.__tostring = function(v)
	return string.format("(%.4f, %.4f, %.4f)", v.X, v.Y, v.Z)
end
function V3:Dot(o)
	return self.X * o.X + self.Y * o.Y + self.Z * o.Z
end
function V3:Cross(o)
	return V3.new(self.Y * o.Z - self.Z * o.Y, self.Z * o.X - self.X * o.Z, self.X * o.Y - self.Y * o.X)
end
V3.zero = V3.new(0, 0, 0)
V3.xAxis = V3.new(1, 0, 0)
V3.yAxis = V3.new(0, 1, 0)
V3.zAxis = V3.new(0, 0, 1)
Vector3 = V3

local V2 = {}
V2.__index = function(self, k)
	if k == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y)
	elseif k == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y)
		if m == 0 then
			return V2.new(0, 0)
		end
		return V2.new(self.X / m, self.Y / m)
	end
	return V2[k]
end
function V2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2)
end
V2.__add = function(a, b)
	return V2.new(a.X + b.X, a.Y + b.Y)
end
V2.__sub = function(a, b)
	return V2.new(a.X - b.X, a.Y - b.Y)
end
V2.__mul = function(a, b)
	if type(b) == "number" then
		return V2.new(a.X * b, a.Y * b)
	elseif type(a) == "number" then
		return V2.new(a * b.X, a * b.Y)
	end
	return V2.new(a.X * b.X, a.Y * b.Y)
end
V2.__div = function(a, b)
	if type(b) == "number" then
		return V2.new(a.X / b, a.Y / b)
	end
	return V2.new(a.X / b.X, a.Y / b.Y)
end
V2.zero = V2.new(0, 0)
Vector2 = V2

-- Luau's math.clamp / math.sign exist in the engine; the CLI has them, but be safe.
if not math.clamp then
	function math.clamp(x, lo, hi)
		return math.min(math.max(x, lo), hi)
	end
end
