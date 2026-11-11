extends RefCounted
## The configured vegetation species for Last Star.
##
## Centralised so the world builds the same set everywhere: grass, border grass,
## flowers, bushes, pebbles and rocks, each with its own texture, density and
## placement rules. Keeping this in one place means the art direction is a
## single file to tune rather than a scatter of magic numbers in the world.

const FoliageShader := preload("res://assets/shaders/vegetation/foliage_anime.gdshader")

const TEX_GRASS := "res://assets/environment/grass/grass.png"
const TEX_BORDER := "res://assets/environment/grass/border_grass.png"
const TEX_FLOWERS := "res://assets/environment/flowers/flowers.png"
const TEX_LEAF := "res://assets/environment/leaves/leaf.png"
const TEX_BUSH := "res://assets/environment/bushes/bush.png"
const TEX_ROCKS := "res://assets/environment/rocks/rocks.png"
const TEX_PEBBLES := "res://assets/environment/pebbles/pebbels.png"

## One shared material per species. Materials are shared deliberately: a
## ShaderMaterial per layer would recompile the shader, which is the stall that
## batching was meant to remove in the first place.
const _materials: Dictionary = {}


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
static func species() -> Array:
	return [
		{"name": "grass", "tex": TEX_GRASS, "density": 1.9, "hmin": 0.40, "hmax": 0.82,
			"wind": 0.22, "tint": Color(1.0, 1.0, 1.0), "slope": 0.55, "mesh": "crossed"},
		{"name": "border_grass", "tex": TEX_BORDER, "density": 0.55, "hmin": 0.55, "hmax": 1.05,
			"wind": 0.16, "tint": Color(0.92, 1.0, 0.90), "slope": 0.42, "mesh": "crossed"},
		{"name": "flowers", "tex": TEX_FLOWERS, "density": 0.16, "hmin": 0.28, "hmax": 0.46,
			"wind": 0.30, "tint": Color(1.0, 1.0, 1.0), "slope": 0.38, "mesh": "crossed"},
		{"name": "bush", "tex": TEX_BUSH, "density": 0.035, "hmin": 0.85, "hmax": 1.60,
			"wind": 0.08, "tint": Color(1.0, 1.0, 1.0), "slope": 0.45, "mesh": "crossed"},
		{"name": "leaves", "tex": TEX_LEAF, "density": 0.12, "hmin": 0.18, "hmax": 0.30,
			"wind": 0.34, "tint": Color(1.0, 1.0, 1.0), "slope": 0.40, "mesh": "crossed"},
		{"name": "pebbles", "tex": TEX_PEBBLES, "density": 0.22, "hmin": 0.12, "hmax": 0.26,
			"wind": 0.0, "tint": Color(1.0, 1.0, 1.0), "slope": 0.70, "mesh": "crossed"},
	]
