export type VertexKey = {
	VertexId: number,
	ColorId: number,
	UVId: number,

	UV: Vector2,
	Position: Vector3,

	Lerping: boolean,
	CurrentFrame: number,

	GoalPosition: Vector3,
	LastPosition: Vector3,

	AlphaTransparency: number,
	CurrentColor: Color3,
	QUALITY_LEVEL: number,

	-- // Caches of what is actually IN THE MESH, and the world-position epoch they were computed
	-- // for. `ShoreT` is the cached shore transparency (a function of world position only), and
	-- // `ColorBucket` is the quantised height band whose colour was last written. Both may only
	-- // advance when the corresponding write happens, or the mesh silently keeps a stale value.
	ShoreT: number?,
	ColorBucket: number?,
}
export type ChunkKey = {
	Rendering: boolean,
	ISLAND: {number | any} | nil,
	ZONE: {number | any} | nil,
}

export type Computations = { {Vector3 | Color3 | number | Vector2 | nil} }

return {}
