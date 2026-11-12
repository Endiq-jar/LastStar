extends RefCounted
## The configured vegetation species for Last Star.
##
## Centralised so the world builds the same set everywhere: grass, border grass,
## flowers, bushes, pebbles and rocks, each with its own texture, density and
## placement rules. Keeping this in one place means the art direction is a
## single file to tune rather than a scatter of magic numbers in the world.

const FoliageShader := preload("res://shaders/vegetation/foliage_anime.gdshader")

const TEX_GRASS := "res://assets/environment/grass/grass.png"
const TEX_BORDER := "res://assets/environment/grass/border_grass.png"
const TEX_FLOWERS := "res://assets/environment/flowers/flowers.png"
const TEX_LEAF := "res://assets/environment/leaves/leaf.png"
const TEX_BUSH := "res://assets/environment/bushes/bush.png"
# The rocks.png and pebbels.png atlases are alpha-cutout sprite sheets: chunks of
# transparent black between the painted stones. Sampling one on solid geometry
# smears dark gaps across the surface and a cutout test would punch holes in the
# rock wherever the sheet is transparent. This is a separate seamless albedo built
# from the terrain's own rock paint, for use as a surface texture rather than as a
# billboard sheet.
const TEX_ROCK_SURFACE := "res://assets/environment/rocks/r_tex_rocks.png"
const TEX_ROCKS := TEX_ROCK_SURFACE

## One shared material per species. Materials are shared deliberately: a
## ShaderMaterial per layer would recompile the shader, which is the stall that
## batching was meant to remove in the first place.
# static var, not const - see the note in vegetation_meshes.gd.
static var _materials: Dictionary = {}


static func material_for(species: String, wind_strength: float, tint: Color) -> ShaderMaterial:
	var key := "%s_%.2f_%s" % [species, wind_strength, tint.to_html()]
	if _materials.has(key):
		return _materials[key]
	var mat := ShaderMaterial.new()
	mat.shader = FoliageShader
	mat.set_shader_parameter("base_tint", tint)
	mat.set_shader_parameter("wind_strength", wind_strength)
	mat.set_shader_parameter("tint_variation", 0.14)
	_materials[key] = mat
	return mat


static func texture(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


## Species table. `density` is instances per square metre, `hmin`/`hmax` the
## height range, `wind` the sway strength and `tint` the overall colour.
##
## `radius` is the streaming radius in metres, in chunks of 5, and it is per
## species on purpose. Every layer used to stream the same 130 m ring, which
## means a pebble 120 m away - where it covers a couple of pixels - cost exactly
## as much as a blade of grass at the player's feet. The measured frame on the
## CI runner had 782 draw calls and 495 multimeshes for this, most of them
## objects too small to see.
##
## Detail belongs close. Grass carries the meadow out to the horizon because it
## is what the ground reads as; flowers and pebbles only have to hold up where
## the camera can resolve them, and their absence at 60 m is invisible because
## grass is in front of them anyway.
##
## Radii in chunks (chunk_size 26 m): 5 = 130 m, 3 = 78 m, 2 = 52 m.
static func species() -> Array:
	return [
		{"name": "grass", "tex": TEX_GRASS, "density": 1.9, "hmin": 0.40, "hmax": 0.82,
			"wind": 0.22, "tint": Color(1.0, 1.0, 1.0), "slope": 0.55, "mesh": "crossed",
			"radius": 5},
		{"name": "border_grass", "tex": TEX_BORDER, "density": 0.55, "hmin": 0.55, "hmax": 1.05,
			"wind": 0.16, "tint": Color(0.92, 1.0, 0.90), "slope": 0.42, "mesh": "crossed",
			"radius": 4},
		{"name": "flowers", "tex": TEX_FLOWERS, "density": 0.16,
			"wind": 0.30, "tint": Color(1.0, 1.0, 1.0), "slope": 0.38, "mesh": "flower",
			# Cluster meshes carry their own metric height, so the layer's
			# hmin/hmax acts as a *scale*, not a size. 0.28-0.46 on top of a
			# 0.42 m cluster made flowers under 2 cm tall - they rendered as the
			# pale specks visible in the meadow and nothing else. Near 1.0 the
			# authored height survives.
			"hmin": 1.15, "hmax": 1.70, "radius": 3},
		{"name": "bush", "tex": TEX_BUSH, "density": 0.035,
			"wind": 0.08, "tint": Color(1.0, 1.0, 1.0), "slope": 0.45, "mesh": "bush",
			"hmin": 1.60, "hmax": 2.70, "radius": 4},
		{"name": "leaves", "tex": TEX_LEAF, "density": 0.12,
			"wind": 0.34, "tint": Color(1.0, 1.0, 1.0), "slope": 0.40, "mesh": "leaf",
			"hmin": 1.10, "hmax": 1.80, "radius": 2},
		{"name": "pebbles", "tex": TEX_ROCK_SURFACE, "density": 0.26, "hmin": 0.30, "hmax": 0.62,
			"wind": 0.0, "tint": Color(1.0, 1.0, 1.0), "slope": 0.70, "mesh": "rock",
			"radius": 2},
		# Boulders. Absent entirely before this: the only stones in the world were
		# 12-26 cm pebbles and the ruin architecture, so the meadow had no mid-scale
		# rock at all and read as a bare carpet. 1.6-3.1 m puts them at roughly the
		# player's height to twice it, which is the size that actually shapes a
		# hillside's silhouette.
		{"name": "rocks", "tex": TEX_ROCKS, "density": 0.010, "hmin": 1.6, "hmax": 3.1,
			"wind": 0.0, "tint": Color(1.0, 1.0, 1.0), "slope": 0.85, "mesh": "boulder",
			"radius": 3},
	]
