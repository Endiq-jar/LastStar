extends RefCounted
## The configured vegetation species for Last Star.
##
## Centralised so the world builds the same set everywhere: border grass,
## flowers, bushes, plants, pebbles and boulders, each naming one model from the
## Quaternius Ultimate Stylized Nature Pack (see scripts/nature_pack.gd) plus its
## density, scale range and placement rules. Keeping this in one place means the
## art direction is a single file to tune rather than a scatter of magic numbers
## in the world.
##
## There are no textures here any more. Every species used to name a png - a
## painted tuft, a flower atlas, a seamless rock tile - and the layer drew it
## onto a crossed card or a generated blob. The pack's models are real geometry
## with their colour in their materials, so a species now names a model and the
## rest is scale and density.

const Nature := preload("res://scripts/nature_pack.gd")


static func material_for(spec: Dictionary) -> ShaderMaterial:
	return Nature.material(str(spec["model"]), float(spec["wind"]), spec["tint"])


static func model_of(spec: Dictionary) -> ArrayMesh:
	return Nature.mesh_of(str(spec["model"]))


## Species table.
##
## `density` is instances per square metre, `hmin`/`hmax` are the uniform scale
## range applied to the model (NOT a height in metres - the pack's models are
## authored at their own sizes, from a 0.4 m tuft to a 3.6 m birch, so a scale is
## the only honest way to ask for "a 6 m tree"), `wind` the sway strength, `tint`
## the multiplier over the baked vertex colours, and `radius` the streaming
## radius in chunks of 26 m.
##
## The ranges were re-tuned against the pack's own model sizes after the first
## build: a bush at 1.3-2.6 on a 1.24 m bush is a three-metre dome, and three of
## those in a meadow read as boulders rather than undergrowth. Measured heights
## live in NaturePack.height_of(); every range below is chosen so the species
## lands in the same hierarchy the hand-drawn props had - flowers at the ankle,
## ferns at the knee, bushes at the hip, boulders above the head.
##
## `radius` is per species on purpose. Every layer used to stream the same 130 m
## ring, which means a pebble 120 m away - where it covers a couple of pixels -
## cost exactly as much as a flower at the player's feet. The measured frame on
## the CI runner had 782 draw calls and 495 multimeshes for this, most of them
## objects too small to see.
##
## Detail belongs close. The meadow's grass is the world's ground cover and
## streams furthest; flowers and pebbles only have to hold up where the camera
## can resolve them.
static func species() -> Array:
	return [
		# Border grass is a detail layer now, not ground cover.
		#
		# At 0.55/m2 across a 104 m radius that is ~18 000 instances of a 64
		# triangle tuft - 1.2 M triangles, a quarter of the whole frame - spent
		# re-covering ground the painted carpet already covers twice as densely.
		# It also *fights* the carpet visually: the pack's tuft is a bright
		# saturated green sprig and the carpet is a soft pale one, so the meadow
		# came out as acid-green shrubs standing in pale grass. A tenth of the
		# density keeps the ragged field edge it was added for.
		{"name": "border_grass", "model": "grass_2", "density": 0.055,
			"hmin": 0.60, "hmax": 1.05, "wind": 0.24, "tint": Color(0.88, 0.96, 0.88),
			"slope": 0.42, "radius": 3},
		{"name": "flowers", "model": "flowers", "density": 0.14,
			"hmin": 0.35, "hmax": 0.70, "wind": 0.20, "tint": Color(1.0, 1.0, 1.0),
			"slope": 0.38, "radius": 3},
		# Bushes are accents, not ground cover.
		#
		# At 0.030/m2 over a 104 m radius that is ~1000 bushes inside a single
		# view, all of them the same 1.24 m model at a similar scale, and the
		# meadow stops being a meadow: the frame the probe captured is a hedge
		# with grass in the gaps. A third of the count and a wider scale range
		# reads as scrub scattered through grassland, which is what the hillside
		# is supposed to be.
		{"name": "bush", "model": "bush_1", "density": 0.010,
			"hmin": 0.55, "hmax": 1.45, "wind": 0.10, "tint": Color(1.0, 1.0, 1.0),
			"slope": 0.45, "radius": 3, "casts_shadow": true},
		{"name": "plants", "model": "plant_3", "density": 0.070,
			"hmin": 0.55, "hmax": 1.10, "wind": 0.16, "tint": Color(1.0, 1.02, 0.98),
			"slope": 0.40, "radius": 3},
		{"name": "ferns", "model": "plant_1", "density": 0.050,
			"hmin": 0.90, "hmax": 1.60, "wind": 0.18, "tint": Color(1.04, 1.02, 0.96),
			"slope": 0.50, "radius": 2},
		{"name": "pebbles", "model": "rock_1", "density": 0.24,
			"hmin": 0.20, "hmax": 0.50, "wind": 0.0, "tint": Color(0.62, 0.64, 0.68),
			"slope": 0.70, "radius": 2},
		# Boulders. Absent entirely before this: the only stones in the world were
		# 12-26 cm pebbles and the ruin architecture, so the meadow had no
		# mid-scale rock at all and read as a bare carpet. 1.5-3.0 on a 0.78 m
		# rock puts them between the player's chest and twice her height,
		# which is the size that shapes a hillside's silhouette.
		# Tinted well below the pack's own Rock. The palette colour is converted
		# for a lit surface, and the foliage shader then adds a shadow fill to
		# every fragment - on a pale grey that lands at near-white, which against
		# a green meadow reads as a painted slab rather than as stone. 0.62 puts
		# the lit faces in the same value band as the terrain's rock band.
		{"name": "rocks", "model": "rock_4", "density": 0.010,
			"hmin": 1.50, "hmax": 3.00, "wind": 0.0, "tint": Color(0.62, 0.64, 0.68),
			"slope": 0.85, "radius": 2},
	]
