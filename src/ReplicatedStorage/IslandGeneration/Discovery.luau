--!nonstrict
--!optimize 2

-- ROADMAP 4.3: premade island discovery. Builds the biome catalog from
-- ServerStorage.<PremadeIslandsRoot> and reads each island's radius and Center.
-- Pure over ServerStorage/Config: it holds no generator state.

local ServerStorage = game:GetService("ServerStorage")

local Config = require(script.Parent.IslandConfig)

local Discovery = {}

-- Catalog / discovery ----------------------------------------------------------

-- Collects every premade island Model under `folder`, recursing through nested
-- folders of any depth. We deliberately do NOT descend into Models: a model's
-- children are island components (e.g. a dock/ruin submodel), not separate
-- island templates.
local function collectTemplates(folder: Instance, out: { Model })
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			table.insert(out, child)
		elseif child:IsA("Folder") then
			collectTemplates(child, out)
		end
		-- Ignore any other instance type (stray Parts, StringValues, ...).
	end
end

-- Builds the biome catalog from ServerStorage.Islands.
--   * Each Folder directly under the root = a biome (its Name).
--   * Models directly under the root = Config.DefaultBiome (edge case).
--   * Biomes with no island Models are skipped (edge case).
--   * Optional weights come from Config.BiomeWeights; weight <= 0 removes it.
local function buildCatalog()
	local root = ServerStorage:FindFirstChild(Config.PremadeIslandsRoot)
	if not root then
		return {}
	end

	local entries = {}

	-- Loose Models directly under the root.
	local rootModels = {}
	for _, child in root:GetChildren() do
		if child:IsA("Model") then
			table.insert(rootModels, child)
		end
	end
	if #rootModels > 0 then
		local name = Config.DefaultBiome
		entries[name] = {
			name = name,
			weight = Config.BiomeWeights[name] or Config.DEFAULT_WEIGHT,
			templates = rootModels,
		}
	end

	-- Biome folders.
	for _, child in root:GetChildren() do
		if child:IsA("Folder") then
			local templates = {}
			collectTemplates(child, templates)
			if #templates > 0 then
				local name = child.Name
				entries[name] = {
					name = name,
					weight = Config.BiomeWeights[name] or Config.DEFAULT_WEIGHT,
					templates = templates,
				}
			end
		end
	end

	local catalog = {}
	for _, entry in entries do
		if entry.weight > 0 then
			table.insert(catalog, entry)
		end
	end
	return catalog
end

-- Island contract helpers ------------------------------------------------------

-- Radius for a premade island model: Radius IntValue first, then the XZ
-- bounding-box half (matching ZoneManager's own fallback), then DefaultRadius.
local function modelRadius(model: Model): number
	local radiusInst = model:FindFirstChild(Config.RadiusValueName)
	if radiusInst and radiusInst:IsA("IntValue") and radiusInst.Value > 0 then
		return radiusInst.Value
	end
	local extents = model:GetExtentsSize() * Vector3.new(1, 0, 1)
	local bboxRadius = extents.Magnitude / 2
	if bboxRadius > 1 then
		return bboxRadius
	end
	return Config.DefaultRadius
end

-- Returns the island's Center BasePart, creating a contract-compliant one at the
-- model's bounding-box center if the template has none. The returned part is the
-- model's PrimaryPart.
local function ensureCenter(model: Model): BasePart
	local center = model:FindFirstChild(Config.CenterPartName)
	if center and center:IsA("BasePart") then
		center.Anchored = true
		center.CanCollide = false
		model.PrimaryPart = center
		return center
	end

	local cf = model:GetBoundingBox() -- returns (CFrame, Vector3); we want the center CFrame
	local part = Instance.new("Part")
	part.Name = Config.CenterPartName
	part.Size = Config.CenterPartSize
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Position = cf.Position
	part.Parent = model
	model.PrimaryPart = part
	return part
end

Discovery.buildCatalog = buildCatalog
Discovery.modelRadius = modelRadius
Discovery.ensureCenter = ensureCenter

return Discovery
