--!strict

--[[
	Placeholder for the ocean SurfaceAppearance.

	The source for this module was NOT supplied with the rest of the BRINE
	scripts, so this file exists only to keep the hierarchy intact:

		ReplicatedStorage.Gerstner.Appearance

	`Serial/Setup` clones this instance and parents it onto every plane it
	builds:

		local Appearance = ReplicatedStorage.Gerstner.Appearance:Clone()
		Appearance.Parent = Plane

	Drop the real asset here. Note that `Setup` uses it as a mesh material,
	so in the shipped BRINE this is expected to be a SurfaceAppearance
	(PBR ocean normal / roughness / metalness maps) rather than a
	ModuleScript -- the hierarchy spec lists it as `[MS]`, so it has been
	left as one until confirmed.
]]

warn('[BRINE] ReplicatedStorage.Gerstner.Appearance is a placeholder. Supply the real ocean appearance asset.')

return {}
