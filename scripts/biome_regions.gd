extends RefCounted
## Cosmetic, deterministic regions. Heights, paths, water and saved locations are
## unchanged. The spawn meadow lies outside every region's outer radius.
## x/z/radius vectors are also passed to the terrain shader as uniforms.
const SNOW := Vector3(-800, -930, 360)
const SAVANNA := Vector3(1020, -740, 410)
const TAIGA := Vector3(-1450, -650, 360)
const TIDAL := Vector3(760, 480, 300)
const FANTASY := Vector3(-720, 280, 340)
const REGIONS := {"snow": SNOW, "savanna": SAVANNA, "taiga": TAIGA, "tidal": TIDAL, "fantasy": FANTASY}


static func weight(point: Vector2, region: Vector3) -> float:
	var d2 := point.distance_squared_to(Vector2(region.x, region.y))
	var r2 := region.z * region.z
	return 1.0 - smoothstep(r2 * 0.49, r2, d2)


static func biome_at(point: Vector2) -> String:
	var best := 0.2
	var name := "meadow"
	for key in REGIONS:
		var w := weight(point, REGIONS[key])
		if w > best:
			best = w
			name = key
	return name
