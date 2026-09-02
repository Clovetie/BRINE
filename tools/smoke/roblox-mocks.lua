-- roblox-mocks.lua
-- Minimal headless Roblox environment for smoke-testing the BRINE
-- floating-object generator outside Studio. Loaded by tools/smoke-test.js
-- inside a Lua 5.3 VM (fengari); NOT part of the game itself.
--
-- NOTE: this file is written in the same stylized Luau subset as src/ and is
-- run through the same Luau->5.3 transform (generalized iteration, compound
-- assignment) by tools/smoke-test.js.

local PLANE_OFFSET_Y = 25

-- ----------------------------------------------------------------------------
-- Stdlib shims (Lua 5.3 <-> Luau differences)
-- ----------------------------------------------------------------------------
table.clone = function(t)
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = v
	end
	return copy
end
table.clear = function(t)
	for k in pairs(t) do
		t[k] = nil
	end
end
table.create = function()
	return {}
end
table.find = function(t, value)
	for i, x in ipairs(t) do
		if x == value then
			return i
		end
	end
	return nil
end
table.freeze = function(t)
	return t
end
math.atan2 = function(y, x)
	return math.atan(y, x)
end
math.clamp = function(x, lo, hi)
	return math.min(math.max(x, lo), hi)
end

-- ----------------------------------------------------------------------------
-- Virtual clock + task scheduler
-- ----------------------------------------------------------------------------
local CLOCK = 0
local sleepingThreads = {}

local task = {}
function task.spawn(fn, ...)
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error("task.spawn failed: " .. tostring(err), 0)
	end
end
function task.wait(seconds)
	local co = coroutine.running()
	table.insert(sleepingThreads, { thread = co, wakeAt = CLOCK + (seconds or 0.03) })
	return coroutine.yield()
end
task.defer = task.spawn

local function pumpThreads()
	local due = {}
	for i = #sleepingThreads, 1, -1 do
		if sleepingThreads[i].wakeAt <= CLOCK then
			table.insert(due, table.remove(sleepingThreads, i))
		end
	end
	for _, entry in ipairs(due) do
		local ok, err = coroutine.resume(entry.thread)
		if not ok then
			error("thread failed: " .. tostring(err), 0)
		end
	end
end

-- ----------------------------------------------------------------------------
-- Vector3
-- ----------------------------------------------------------------------------
local Vector3 = {}
Vector3.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
	elseif key == "Unit" then
		local m = math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
		if m == 0 then
			return Vector3.new()
		end
		local v = setmetatable({ X = self.X / m, Y = self.Y / m, Z = self.Z / m }, Vector3)
		return v
	end
	return Vector3[key]
end
Vector3.__add = function(a, b)
	return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z }, Vector3)
end
Vector3.__sub = function(a, b)
	return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }, Vector3)
end
Vector3.__mul = function(a, b)
	if type(a) == "number" then
		return setmetatable({ X = a * b.X, Y = a * b.Y, Z = a * b.Z }, Vector3)
	elseif type(b) == "number" then
		return setmetatable({ X = a.X * b, Y = a.Y * b, Z = a.Z * b }, Vector3)
	end
	return setmetatable({ X = a.X * b.X, Y = a.Y * b.Y, Z = a.Z * b.Z }, Vector3)
end
Vector3.__div = function(a, b)
	if type(b) == "number" then
		return setmetatable({ X = a.X / b, Y = a.Y / b, Z = a.Z / b }, Vector3)
	end
	return setmetatable({ X = a.X / b.X, Y = a.Y / b.Y, Z = a.Z / b.Z }, Vector3)
end
Vector3.__unm = function(a)
	return setmetatable({ X = -a.X, Y = -a.Y, Z = -a.Z }, Vector3)
end
Vector3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.__tostring = function(a)
	return string.format("(%.3f, %.3f, %.3f)", a.X, a.Y, a.Z)
end
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end
function Vector3.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
Vector3.zero = Vector3.new(0, 0, 0)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.one = Vector3.new(1, 1, 1)

-- ----------------------------------------------------------------------------
-- CFrame (full 3x3 rotation + translation)
-- ----------------------------------------------------------------------------
local CFrame = {}
CFrame.__index = function(self, key)
	if key == "Position" then
		return Vector3.new(self.p.X, self.p.Y, self.p.Z)
	elseif key == "LookVector" then
		return Vector3.new(-self.m[3], -self.m[6], -self.m[9])
	elseif key == "XVector" then
		return Vector3.new(self.m[1], self.m[4], self.m[7])
	elseif key == "YVector" then
		return Vector3.new(self.m[2], self.m[5], self.m[8])
	end
	return CFrame[key]
end
CFrame.__tostring = function(a)
	return "CFrame" .. tostring(a.p)
end
local function cfFromMatrix(p, m)
	return setmetatable({ p = p, m = m }, CFrame)
end
local function matrixMul(a, b)
	local out = {}
	for col = 0, 2 do
		for row = 0, 2 do
			out[col * 3 + row + 1] = a[1 * row + 1] * b[col * 3 + 1]
				+ a[2 * row + 1] * b[col * 3 + 2]
				+ a[3 * row + 1] * b[col * 3 + 3]
		end
	end
	return out
end
local function cfInverse(a)
	local m = a.m
	local px = -(m[1] * a.p.X + m[2] * a.p.Y + m[3] * a.p.Z)
	local py = -(m[4] * a.p.X + m[5] * a.p.Y + m[6] * a.p.Z)
	local pz = -(m[7] * a.p.X + m[8] * a.p.Y + m[9] * a.p.Z)
	return cfFromMatrix(
		Vector3.new(px, py, pz),
		{ m[1], m[4], m[7], m[2], m[5], m[8], m[3], m[6], m[9] }
	)
end
CFrame.__mul = function(a, b)
	return cfFromMatrix(
		Vector3.new(
			a.p.X + a.m[1] * b.p.X + a.m[2] * b.p.Y + a.m[3] * b.p.Z,
			a.p.Y + a.m[4] * b.p.X + a.m[5] * b.p.Y + a.m[6] * b.p.Z,
			a.p.Z + a.m[7] * b.p.X + a.m[8] * b.p.Y + a.m[9] * b.p.Z
		),
		matrixMul(a.m, b.m)
	)
end
function CFrame.new(x, y, z)
	if type(x) == "table" then
		return cfFromMatrix(Vector3.new(x.X, x.Y, x.Z), { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
	end
	return cfFromMatrix(Vector3.new(x or 0, y or 0, z or 0), { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
end
function CFrame.Angles(rx, ry, rz)
	local cx, sx = math.cos(rx), math.sin(rx)
	local cy, sy = math.cos(ry), math.sin(ry)
	local cz, sz = math.cos(rz), math.sin(rz)
	local rxm = { 1, 0, 0, 0, cx, sx, 0, -sx, cx }
	local rym = { cy, 0, -sy, 0, 1, 0, sy, 0, cy }
	local rzm = { cz, sz, 0, -sz, cz, 0, 0, 0, 1 }
	return cfFromMatrix(Vector3.new(), matrixMul(matrixMul(rxm, rym), rzm))
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
CFrame.fromEulerAnglesYXZ = CFrame.Angles
function CFrame:ToObjectSpace(other)
	return cfInverse(self) * other
end
function CFrame:Inverse()
	return cfInverse(self)
end
CFrame.identity = CFrame.new()

-- ----------------------------------------------------------------------------
-- Random
-- ----------------------------------------------------------------------------
local Random = {}
Random.__index = Random
local seedCounter = 0
function Random.new(seed)
	seedCounter += 1
	local state = math.floor(math.abs((seed or seedCounter) * 9301 + 49297)) % 233280
	if state <= 0 then
		state += 233280
	end
	return setmetatable({ _state = state }, Random)
end
function Random:NextNumber(min, max)
	self._state = (self._state * 9301 + 49297) % 233280
	local unit = self._state / 233280
	if min == nil then
		return unit
	elseif max == nil then
		return unit * min
	end
	return min + unit * (max - min)
end
function Random:NextInteger(min, max)
	self._state = (self._state * 9301 + 49297) % 233280
	local span = max - min
	if span <= 0 then
		return min
	end
	return min + math.floor((self._state / 233280) * (span + 1))
end

-- ----------------------------------------------------------------------------
-- Enum (autovivifying)
-- ----------------------------------------------------------------------------
local Enum = setmetatable({}, {
	__index = function(t, k)
		local category = setmetatable({}, {
			__index = function(tt, kk)
				local item = { EnumType = k, Name = kk }
				rawset(tt, kk, item)
				return item
			end,
		})
		rawset(t, k, category)
		return category
	end,
})

-- ----------------------------------------------------------------------------
-- Signals
-- ----------------------------------------------------------------------------
local function newSignal(name)
	local handlers = {}
	local signal = { _name = name }
	function signal:Connect(fn)
		local conn = { Connected = true }
		function conn:Disconnect()
			conn.Connected = false
			for i, h in ipairs(handlers) do
				if h.fn == fn and h.conn == conn then
					table.remove(handlers, i)
					break
				end
			end
		end
		table.insert(handlers, { fn = fn, conn = conn })
		return conn
	end
	function signal:Once(fn)
		local conn
		conn = signal:Connect(function(...)
			conn:Disconnect()
			fn(...)
		end)
		return conn
	end
	function signal:Fire(...)
		for _, h in ipairs(table.clone(handlers)) do
			h.fn(...)
		end
	end
	return signal
end

-- ----------------------------------------------------------------------------
-- Instances
-- ----------------------------------------------------------------------------
local SIGNAL_NAMES = {
	Destroying = true,
	AncestryChanged = true,
	ChildAdded = true,
	ChildRemoved = true,
}

local ALL_INSTANCES = {}
local InstanceMT = {}

InstanceMT.__index = function(self, key)
	if SIGNAL_NAMES[key] then
		local signals = rawget(self, "_signals")
		local sig = signals[key]
		if not sig then
			sig = newSignal(key)
			signals[key] = sig
		end
		return sig
	end
	if key == "Position" then
		local cframe = rawget(self, "CFrame")
		if cframe then
			return cframe.Position
		end
		return nil
	end
	if key == "WorldPosition" and self.ClassName == "Attachment" then
		local parent = rawget(self, "Parent")
		local cframe = rawget(self, "CFrame") or CFrame.identity
		if parent and parent.CFrame then
			return (parent.CFrame * cframe).Position
		end
		return cframe.Position
	end
	local kids = rawget(self, "_children")
	if kids then
		for _, child in ipairs(kids) do
			if child.Name == key then
				return child
			end
		end
	end
	return InstanceMT[key]
end

InstanceMT.__newindex = function(self, key, value)
	if key == "Parent" then
		local old = rawget(self, "Parent")
		if old then
			local oldKids = rawget(old, "_children")
			for i, c in ipairs(oldKids) do
				if c == self then
					table.remove(oldKids, i)
					break
				end
			end
		end
		rawset(self, "Parent", value)
		if value ~= nil then
			table.insert(rawget(value, "_children"), self)
		end
	else
		rawset(self, key, value)
	end
end

local function newInstance(className, name)
	local inst = {
		ClassName = className,
		Name = name or className,
		_children = {},
		_attrs = {},
		_tags = {},
		_signals = {},
	}
	setmetatable(inst, InstanceMT)
	table.insert(ALL_INSTANCES, inst)
	return inst
end

function InstanceMT:IsA(className)
	if self.ClassName == className then
		return true
	end
	if className == "BasePart" then
		return self.ClassName == "Part" or self.ClassName == "MeshPart"
	end
	if className == "BodyMover" then
		return self.ClassName == "BodyPosition" or self.ClassName == "BodyVelocity"
	end
	return false
end
function InstanceMT:IsAncestorOf(other)
	local node = rawget(other, "Parent")
	while node do
		if node == self then
			return true
		end
		node = rawget(node, "Parent")
	end
	return false
end
function InstanceMT:IsDescendantOf(other)
	return other:IsAncestorOf(self)
end
function InstanceMT:GetFullName()
	local parts = {}
	local node = self
	while node do
		table.insert(parts, 1, node.Name)
		node = rawget(node, "Parent")
	end
	return table.concat(parts, ".")
end
function InstanceMT:GetChildren()
	return table.clone(rawget(self, "_children"))
end
function InstanceMT:GetDescendants()
	local out = {}
	local function walk(inst)
		for _, child in ipairs(rawget(inst, "_children")) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end
function InstanceMT:FindFirstChild(name, recursive)
	for _, child in ipairs(rawget(self, "_children")) do
		if child.Name == name then
			return child
		end
	end
	if recursive then
		for _, desc in ipairs(self:GetDescendants()) do
			if desc.Name == name then
				return desc
			end
		end
	end
	return nil
end
function InstanceMT:FindFirstChildOfClass(className)
	for _, child in ipairs(rawget(self, "_children")) do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end
function InstanceMT:FindFirstChildWhichIsA(className, recursive)
	for _, child in ipairs(rawget(self, "_children")) do
		if child:IsA(className) then
			return child
		end
	end
	if recursive then
		for _, desc in ipairs(self:GetDescendants()) do
			if desc:IsA(className) then
				return desc
			end
		end
	end
	return nil
end
function InstanceMT:WaitForChild(name)
	return self:FindFirstChild(name)
end
function InstanceMT:GetAttribute(name)
	return rawget(self, "_attrs")[name]
end
function InstanceMT:SetAttribute(name, value)
	rawget(self, "_attrs")[name] = value
end
function InstanceMT:Destroy()
	rawget(self, "_signals").Destroying:Fire(self)
	local parent = rawget(self, "Parent")
	if parent then
		local kids = rawget(parent, "_children")
		for i, c in ipairs(kids) do
			if c == self then
				table.remove(kids, i)
				break
			end
		end
	end
	rawset(self, "Parent", nil)
	rawset(self, "_destroyed", true)
end

local CLONE_PROPS = {
	"Size",
	"CFrame",
	"Anchored",
	"CanCollide",
	"CanTouch",
	"CanQuery",
	"PrimaryPart",
	"RootPriority",
	"AssemblyMass",
	"CollisionGroup",
	"Transparency",
	"Health",
	"Value",
}

local function cloneDeep(inst, map)
	local copy = newInstance(inst.ClassName, inst.Name)
	map[inst] = copy
	for _, key in ipairs(CLONE_PROPS) do
		if key ~= "PrimaryPart" then
			local v = rawget(inst, key)
			if v ~= nil then
				rawset(copy, key, v)
			end
		end
	end
	for k, v in pairs(rawget(inst, "_attrs")) do
		rawget(copy, "_attrs")[k] = v
	end
	for k in pairs(rawget(inst, "_tags")) do
		rawget(copy, "_tags")[k] = true
	end
	for _, child in ipairs(rawget(inst, "_children")) do
		local childCopy = cloneDeep(child, map)
		childCopy.Parent = copy
	end
	return copy
end

function InstanceMT:Clone()
	local map = {}
	local copy = cloneDeep(self, map)
	-- Roblox remaps PrimaryPart to the CLONE's part; do the same.
	local primary = rawget(self, "PrimaryPart")
	if primary and map[primary] then
		rawset(copy, "PrimaryPart", map[primary])
	end
	return copy
end

-- Model helpers ---------------------------------------------------------------
function InstanceMT:GetExtentsSize()
	local minV, maxV
	for _, desc in ipairs(self:GetDescendants()) do
		if desc:IsA("BasePart") then
			local p = desc.CFrame.Position
			local s = desc.Size
			local lo = Vector3.new(p.X - s.X / 2, p.Y - s.Y / 2, p.Z - s.Z / 2)
			local hi = Vector3.new(p.X + s.X / 2, p.Y + s.Y / 2, p.Z + s.Z / 2)
			if not minV then
				minV, maxV = lo, hi
			else
				minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
				maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
			end
		end
	end
	if not minV then
		return Vector3.new(1, 1, 1)
	end
	return maxV - minV
end
function InstanceMT:GetBoundingBox()
	local minV, maxV
	for _, desc in ipairs(self:GetDescendants()) do
		if desc:IsA("BasePart") then
			local p = desc.CFrame.Position
			local s = desc.Size
			local lo = Vector3.new(p.X - s.X / 2, p.Y - s.Y / 2, p.Z - s.Z / 2)
			local hi = Vector3.new(p.X + s.X / 2, p.Y + s.Y / 2, p.Z + s.Z / 2)
			if not minV then
				minV, maxV = lo, hi
			else
				minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
				maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
			end
		end
	end
	if not minV then
		return CFrame.new(), Vector3.new(1, 1, 1)
	end
	local size = maxV - minV
	local center = (minV + maxV) / 2
	return CFrame.new(center.X, center.Y, center.Z), size
end
function InstanceMT:GetPivot()
	local pivot = rawget(self, "_pivot")
	if pivot then
		return pivot
	end
	return (self:GetBoundingBox())
end
function InstanceMT:PivotTo(cframe)
	local old = rawget(self, "_pivot")
	if not old then
		old = (self:GetBoundingBox())
	end
	rawset(self, "_pivot", cframe)
	-- Real PivotTo moves every descendant part; the mock must too, or
	-- hull.Position (used for LOD distances) would stay at the origin.
	local delta = cframe * old:Inverse()
	for _, desc in ipairs(self:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CFrame = delta * desc.CFrame
		end
	end
end

-- BasePart helpers ------------------------------------------------------------
function InstanceMT:CanSetNetworkOwnership()
	return not rawget(self, "_destroyed")
end
function InstanceMT:SetNetworkOwner() end

-- ----------------------------------------------------------------------------
-- Services
-- ----------------------------------------------------------------------------
local Workspace = newInstance("Workspace", "Workspace")
Workspace.Gravity = 196.2
Workspace._obstacleHits = {}
function Workspace:GetPartBoundsInRadius()
	return Workspace._obstacleHits
end
function Workspace:GetServerTimeNow()
	return CLOCK
end
Workspace.CurrentCamera = newInstance("Camera", "CurrentCamera")

local RunService = newInstance("RunService", "RunService")
RunService.PostSimulation = newSignal("PostSimulation")
RunService.Heartbeat = RunService.PostSimulation
function RunService:IsServer()
	return true
end

local ReplicatedStorage = newInstance("ReplicatedStorage", "ReplicatedStorage")
local ServerStorage = newInstance("ServerStorage", "ServerStorage")
local Players = newInstance("Players", "Players")
Players._players = {}
function Players:GetPlayers()
	return table.clone(Players._players)
end
Players.PlayerRemoving = newSignal("PlayerRemoving")

local CollectionService = newInstance("CollectionService", "CollectionService")
function CollectionService:HasTag(inst, tag)
	return rawget(inst, "_tags")[tag] == true
end
function CollectionService:AddTag(inst, tag)
	rawget(inst, "_tags")[tag] = true
end
function CollectionService:RemoveTag(inst, tag)
	rawget(inst, "_tags")[tag] = nil
end
function CollectionService:GetTagged(tag)
	local out = {}
	for _, inst in ipairs(ALL_INSTANCES) do
		if not rawget(inst, "_destroyed") and rawget(inst, "_tags")[tag] then
			table.insert(out, inst)
		end
	end
	return out
end
function CollectionService:GetTags(inst)
	local out = {}
	for k in pairs(rawget(inst, "_tags")) do
		table.insert(out, k)
	end
	return out
end

local services = {
	Workspace = Workspace,
	RunService = RunService,
	ReplicatedStorage = ReplicatedStorage,
	ServerStorage = ServerStorage,
	Players = Players,
	CollectionService = CollectionService,
}
local game = { _services = services }
function game:GetService(name)
	return services[name] or error("no mock service: " .. name, 2)
end

-- ----------------------------------------------------------------------------
-- Logging (JS collects these after the run)
-- ----------------------------------------------------------------------------
LOG = { n = 0 }
local function logLine(level, ...)
	local parts = {}
	for i = 1, select("#", ...) do
		table.insert(parts, tostring(select(i, ...)))
	end
	LOG.n += 1
	LOG[LOG.n] = level .. "|" .. table.concat(parts, " ")
end

print = function(...)
	logLine("print", ...)
end
warn = function(...)
	logLine("warn", ...)
end

_G.Vector3 = Vector3
_G.CFrame = CFrame
_G.task = task
_G.Random = Random
_G.Enum = Enum
_G.Instance = { new = newInstance }
_G.game = game
_G.workspace = Workspace
_G.OverlapParams = {
	new = function()
		return { FilterType = nil, FilterDescendantsInstances = {}, MaxParts = 0, RespectCanCollide = false }
	end,
}
_G.TweenInfo = { new = function()
	return {}
end }

function typeof(x)
	if type(x) == "table" then
		local mt = getmetatable(x)
		if mt == Vector3 then
			return "Vector3"
		elseif mt == CFrame then
			return "CFrame"
		elseif mt == Random then
			return "Random"
		end
	end
	return type(x)
end

-- ----------------------------------------------------------------------------
-- Pump: advance virtual time
-- ----------------------------------------------------------------------------
local function pumpFrames(seconds, frameStep)
	frameStep = frameStep or 0.1
	local target = CLOCK + seconds
	while CLOCK < target do
		CLOCK = math.min(CLOCK + frameStep, target)
		pumpThreads()
		RunService.PostSimulation:Fire(frameStep)
	end
end

MOCKS = {
	PLANE_OFFSET_Y = PLANE_OFFSET_Y,
	pumpFrames = pumpFrames,
	newInstance = newInstance,
	Vector3 = Vector3,
	CFrame = CFrame,
	Workspace = Workspace,
	ReplicatedStorage = ReplicatedStorage,
	ServerStorage = ServerStorage,
	Players = Players,
	RunService = RunService,
	CollectionService = CollectionService,
}
