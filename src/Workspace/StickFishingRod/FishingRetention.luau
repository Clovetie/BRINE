--[[
	FishingRetention: which caught fish to clear.

	A caught fish stays in the world so it can be picked up, but nothing used to remove them:
	`Workspace.CaughtFish` and the server's `floaters` list only ever grew, and that list is
	walked on every Heartbeat, so each catch added permanent per-frame work and a live
	DragDetector (measured 2026-10-27: 2 casts -> 2 fish retained, 2 DragDetectors, no removal
	path anywhere in src/).

	The decision is pure so it can be tested without a server: the server gathers one entry per
	caught fish and this module says which to destroy. Three protections, in order of strength:

		* a fish a player is holding (drag) is never cleared;
		* a fish younger than `MinAge` is never cleared, which covers the one just caught and the
		  second or two it spends arcing to the player;
		* a fish within `CullNearPlayerDistance` of a player is never cleared, so nothing
		  disappears in front of someone -- the same rule the floating objects follow.

	Past `HardCeiling` the age protection is the only one that still holds: retention has to be
	bounded, and a ceiling that cannot be enforced is not a ceiling.

	Deliberately NOT keyed on os.clock(): that returns CPU seconds, which on a freshly started
	server is smaller than any age already stored, so the newest fish sorted as the oldest and
	was cleared first. CaughtAt is wall time (workspace:GetServerTimeNow()).
]]

local FishingRetention = {}

FishingRetention.Defaults = {
	MaxRetained = 24,
	MinAge = 20,
	CullNearPlayerDistance = 250,
	HardCeiling = 40,
}

--[[
	SelectClears(fish, config) -> { any }

	`fish` is a list of entries, oldest first is not required:
		{ model = Instance, caughtAt = number, held = boolean, distance = number }
	where `distance` is the fish's distance to the nearest player (math.huge if none).

	Returns the entries to destroy, oldest first. It only returns as many as needed to get back
	to `MaxRetained`, and never more than exist.
]]
function FishingRetention.SelectClears(fish, config): { any }
	local cfg = config or FishingRetention.Defaults
	local maxRetained = cfg.MaxRetained or FishingRetention.Defaults.MaxRetained
	local minAge = cfg.MinAge or FishingRetention.Defaults.MinAge
	local nearDistance = cfg.CullNearPlayerDistance or FishingRetention.Defaults.CullNearPlayerDistance
	local hardCeiling = cfg.HardCeiling or FishingRetention.Defaults.HardCeiling

	local total = #fish
	if total <= maxRetained then
		return {}
	end

	local overCeiling = total > hardCeiling
	local candidates = {}
	local newest = nil
	for _, entry in ipairs(fish) do
		if newest == nil or (entry.caughtAt or 0) > (newest.caughtAt or 0) then
			newest = entry
		end
	end

	for _, entry in ipairs(fish) do
		if not entry.held and entry ~= newest then
			local age = (entry.age ~= nil) and entry.age or nil
			local oldEnough = age == nil or age >= minAge
			if oldEnough then
				local close = (entry.distance or math.huge) <= nearDistance
				if not close or overCeiling then
					candidates[#candidates + 1] = entry
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		return (a.caughtAt or 0) < (b.caughtAt or 0)
	end)

	local clears = {}
	local excess = total - maxRetained
	for _, entry in ipairs(candidates) do
		if excess <= 0 then
			break
		end
		clears[#clears + 1] = entry
		excess -= 1
	end
	return clears
end

return FishingRetention
