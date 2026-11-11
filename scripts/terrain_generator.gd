extends Node3D
## Stylized open-world terrain, Genshin-ish verticality.
##
## One big valley with a calmer "windrise" basin, rolling hills, a lake bowl to
## the south-east and a ring of tall ridges at the edge of the map. Uses a
## heightmap surface tool + trimesh collision, and exposes get_height_at() so
## props, enemies and the player can snap to the ground.

const TERRAIN_SIZE := 900.0
## 288, not 144.
##
## At 144 the mesh is 6.25 m per triangle. The third-person camera sits 3.9 m
## from the player, so a single triangle spans roughly 90 degrees of the view -
## the ground the player is standing on is two or three flat facets with hard
## straight edges. That is the whole reason the terrain read as glossy green
## plastic with a folded-paper horizon instead of a landscape: it was not a
## shading problem at all, the surface simply had no geometry in it near the
## camera.
##
## 288 gives 3.1 m triangles for 4x the vertex count (~166k), which is still a
## cheap static mesh on a phone and gives the near ground real form. Collision is
## built at half this resolution as before.
const RESOLUTION := 288
## Extra high-frequency surface detail, metres of displacement. The analytic
## height function is deliberately smooth (it has to be, so collision and gameplay
## snapping agree with it), which left the ground featureless however finely it
## was tessellated. This adds the small-scale undulation - the hummocks and dips
## a meadow actually has - without changing the macro shape.
const SURFACE_DETAIL := 0.22
const NOISE_SEED := 20261109
const SEA_LEVEL := 1.2

## Shared world constants (Game autoload mirrors these for other scripts).
const LAKE_CENTER := Vector2(190.0, 210.0)
const LAKE_RADIUS := 105.0

var height_noise: FastNoiseLite
var ridge_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var patch_noise: FastNoiseLite
## Small-scale surface bump. Kept SEPARATE from get_height_at() on purpose: the
## analytic height is the collision and gameplay authority, so adding this there
## would make every physics query disagree with the visual mesh by up to
## SURFACE_DETAIL. Only the rendered vertices get it.
var surface_noise: FastNoiseLite

var _mesh_instance: MeshInstance3D


func _ready() -> void:
	add_to_group("terrain")
	_setup_noise()
	_build()

	# Mirror the lake and water level into the global state so other systems
	# (water plane, enemies, HUD compass) agree on the world layout.
	Game.water_level = SEA_LEVEL
	Game.lake_center = LAKE_CENTER
	Game.lake_radius = LAKE_RADIUS


func _setup_noise() -> void:
	height_noise = FastNoiseLite.new()
	height_noise.seed = NOISE_SEED
	height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	height_noise.frequency = 0.0021
	height_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	height_noise.fractal_octaves = 5
	height_noise.fractal_gain = 0.48
	height_noise.fractal_lacunarity = 2.05

	ridge_noise = FastNoiseLite.new()
	ridge_noise.seed = NOISE_SEED + 91
	ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridge_noise.frequency = 0.0045
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge_noise.fractal_octaves = 4

	detail_noise = FastNoiseLite.new()
	detail_noise.seed = NOISE_SEED + 17
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.frequency = 0.018
	detail_noise.fractal_octaves = 4
	detail_noise.fractal_gain = 0.42

	patch_noise = FastNoiseLite.new()
	patch_noise.seed = NOISE_SEED + 5
	patch_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	patch_noise.frequency = 0.006

	# Two octaves at roughly 1.5 m and 6 m. Short enough to be invisible in the
	# collision mesh's best interest, long enough to break the facet edges up.
	surface_noise = FastNoiseLite.new()
	surface_noise.seed = NOISE_SEED + 41
	surface_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	surface_noise.frequency = 0.16
	surface_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	surface_noise.fractal_octaves = 3
	surface_noise.fractal_gain = 0.5


## A rendered vertex position: the collision height plus the small-scale bump.
##
## Only the visual mesh uses this. Physics and the player resolve against
## get_height_at(), so the bump is cosmetic and can never desync a collision
## query - see surface_height_at() for how scattered props still land on it.
func _surface_point(x: float, z: float) -> Vector3:
	var bump := surface_noise.get_noise_2d(x, z) * SURFACE_DETAIL
	# Fade the bump out under the waterline so the lake bed stays smooth.
	if get_height_at(x, z) < SEA_LEVEL + 1.0:
		bump *= 0.0
	return Vector3(x, get_height_at(x, z) + bump, z)


## The height of the RENDERED surface at a point, i.e. the bumpy mesh the player
## is looking at - not the smooth analytic field the collision mesh uses.
##
## This distinction matters and used to be invisible: get_height_at() is a smooth
## function, but the mesh renders it as bilinear triangles between vertices a
## few metres apart. The two agree only at the vertices. Halfway along an edge
## the straight line between two samples sits below the curve, so every scattered
## prop placed with get_height_at() was hovering above the visible ground by up
## to the sagitta of a 3 m triangle - grass tufts floating in mid-air with air
## under them, which reads as props scattered over a photograph rather than
## growing out of soil. It is also why the ground looked bare right where the
## player was standing.
##
## Reconstructed here with the same four corner samples and the same diagonal
## split the mesh builder uses, so it matches the rendered surface exactly.
func surface_height_at(x: float, z: float) -> float:
	var step := TERRAIN_SIZE / float(RESOLUTION)
	var half := TERRAIN_SIZE * 0.5
	var gx := floorf((x + half) / step)
	var gz := floorf((z + half) / step)
	var x0 := -half + gx * step
	var z0 := -half + gz * step
	var x1 := x0 + step
	var z1 := z0 + step
	var fx := clampf((x - x0) / step, 0.0, 1.0)
	var fz := clampf((z - z0) / step, 0.0, 1.0)
	var h00 := get_height_at(x0, z0)
	var h10 := get_height_at(x1, z0)
	var h01 := get_height_at(x0, z1)
	var h11 := get_height_at(x1, z1)
	# Triangles are (p00,p10,p01) and (p10,p11,p01): the split runs from the
	# p10 corner to the p01 corner, so fx + fz < 1 is the first triangle.
	var h := 0.0
	if fx + fz <= 1.0:
		h = h00 + (h10 - h00) * fx + (h01 - h00) * fz
	else:
		h = h11 + (h01 - h11) * (1.0 - fx) + (h10 - h11) * (1.0 - fz)
	if h < SEA_LEVEL + 1.0:
		return h
	return h + surface_noise.get_noise_2d(x, z) * SURFACE_DETAIL


## World height. Everything in the game that needs ground height calls this.
func get_height_at(x: float, z: float) -> float:
	var base := height_noise.get_noise_2d(x, z) * 46.0
	var ridge := absf(ridge_noise.get_noise_2d(x, z)) * 30.0
	var detail := detail_noise.get_noise_2d(x, z) * 3.0

	# Radial rim: high ridges at the edge of the playable valley.
	var r := sqrt(x * x + z * z)
	var rim := smoothstep(300.0, 460.0, r) * (95.0 + ridge * 1.4)

	# Lake bowl: carve down toward water level around the lake center.
	var lake_d := Vector2(x, z).distance_to(LAKE_CENTER)
	var lake := (1.0 - smoothstep(LAKE_RADIUS * 0.35, LAKE_RADIUS * 1.35, lake_d)) * 52.0

	# A gently terraced "windrise" meadow near spawn for the starting area.
	var spawn_d := Vector2(x, z).length()
	var meadow := (1.0 - smoothstep(30.0, 130.0, spawn_d)) * 6.0

	var h := base * smoothstep(0.0, 24.0, r) + ridge * smoothstep(0.0, 40.0, r) + detail + rim + meadow - lake
	return h + SEA_LEVEL + 12.0


## Steepness at a point, as a true gradient: metres of rise per metre of run.
##
## This used to return the raw height difference across a 3 m sample without
## dividing by the distance, so it reported metres rather than a ratio. Every
## caller compares it against a value like 0.52 meaning "52% grade", so the
## units mismatch rejected ~94% of the whole map: the grass carpet came out at
## 5% of its intended density and trees avoided perfectly flat meadows.
func get_slope_at(x: float, z: float) -> float:
	const SAMPLE := 3.0
	var dx := get_height_at(x + 1.5, z) - get_height_at(x - 1.5, z)
	var dz := get_height_at(x, z + 1.5) - get_height_at(x, z - 1.5)
	return sqrt(dx * dx + dz * dz) / SAMPLE


func is_underwater(x: float, z: float) -> bool:
	return get_height_at(x, z) < SEA_LEVEL


## Load a terrain texture, falling back to procedural noise if the file is
## missing so the world still builds in a stripped checkout.
func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var t := load(path)
		if t is Texture2D:
			return t as Texture2D
	push_warning("LastStar: missing terrain texture " + path)
	return _make_noise_tex(101, 0.055, 512)


func _make_noise_tex(seed_v: int, freq: float, size: int, as_normal: bool = false, bump: float = 8.0) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.seed = seed_v
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 5
	n.fractal_gain = 0.5
	var t := NoiseTexture2D.new()
	t.noise = n
	t.width = size
	t.height = size
	t.seamless = true
	t.generate_mipmaps = true
	if as_normal:
		t.as_normal_map = true
		t.bump_strength = bump
	return t


func _terrain_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/terrain_anime.gdshader")
	# Painterly noise textures stand in for hand-painted layers. They are
	# procedural so the project stays asset-light and fully MIT-safe.
	# Hand-painted, seamlessly tiling textures (textures/terrain/*.png), sampled
	# triplanar by the shader. These replace the procedural noise that made
	# every surface read as grey static up close.
	m.set_shader_parameter("meadow_tex", _load_tex("res://textures/terrain/meadow.png"))
	m.set_shader_parameter("rock_tex", _load_tex("res://textures/terrain/rock.png"))
	m.set_shader_parameter("sand_tex", _load_tex("res://textures/terrain/sand.png"))
	m.set_shader_parameter("macro_tex", _load_tex("res://textures/terrain/macro.png"))
	m.set_shader_parameter("water_level", SEA_LEVEL)
	m.set_shader_parameter("rock_height", 96.0)
	m.set_shader_parameter("snow_height", 128.0)
	# The paint was sampled at 0.055, i.e. one 18 m repeat: the entire hillside
	# between the player and the horizon carried barely one tile of texture, which
	# is why it read as flat colour. 0.13 gives a 7.7 m repeat - close enough that
	# the brush grain is legible on the ground the player is standing on, which is
	# the only place it needs to be.
	m.set_shader_parameter("uv_scale", 0.13)
	m.set_shader_parameter("macro_scale", 0.0045)
	return m


func _build() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step := TERRAIN_SIZE / float(RESOLUTION)
	var half := TERRAIN_SIZE * 0.5

	for z in range(RESOLUTION):
		for x in range(RESOLUTION):
			var wx0 := -half + x * step
			var wz0 := -half + z * step
			var wx1 := wx0 + step
			var wz1 := wz0 + step

			var p00 := _surface_point(wx0, wz0)
			var p10 := _surface_point(wx1, wz0)
			var p01 := _surface_point(wx0, wz1)
			var p11 := _surface_point(wx1, wz1)

			# Winding matters: Godot computes a triangle normal as
			# (p1-p3) x (p1-p2), so (p00,p01,p10) produced a DOWNWARD normal.
			# That inverted the surface (backface-culled = invisible terrain,
			# lit from underneath = "world upside down"). Counter-clockwise
			# when viewed from above is the correct order.
			for v in [p00, p10, p01, p10, p11, p01]:
				st.set_uv(Vector2(v.x, v.z) * 0.02)
				st.add_vertex(v)

	st.generate_normals()
	st.generate_tangents()

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "TerrainMesh"
	_mesh_instance.mesh = st.commit()
	_mesh_instance.material_override = _terrain_material()
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)

	# Collision is built from a half-resolution grid: the visual mesh stays
	# crisp while the physics triangles drop 4x (important on mobile).
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = _build_collision_shape()
	body.add_child(col)
	add_child(body)


func _build_collision_shape() -> ConcavePolygonShape3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := TERRAIN_SIZE / float(RESOLUTION) * 2.0
	var half := TERRAIN_SIZE * 0.5
	var n := RESOLUTION / 2
	for z in range(n):
		for x in range(n):
			var x0 := -half + x * step
			var z0 := -half + z * step
			var x1 := x0 + step
			var z1 := z0 + step
			var p00 := Vector3(x0, get_height_at(x0, z0), z0)
			var p10 := Vector3(x1, get_height_at(x1, z0), z0)
			var p01 := Vector3(x0, get_height_at(x0, z1), z1)
			var p11 := Vector3(x1, get_height_at(x1, z1), z1)
			# Same winding rule as the visual mesh above - see the comment
			# there. Inverted triangles made the ground unmovable for physics.
			for v in [p00, p10, p01, p10, p11, p01]:
				st.add_vertex(v)
	var mesh := st.commit()
	var shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	# Belt and braces: one-sided concave collision silently lets bodies fall
	# straight through if a triangle is ever wound the wrong way. That is a
	# catastrophic bug and completely invisible in the editor, so pay the small
	# cost of two-sided collision and make it structurally impossible.
	shape.set_backface_collision_enabled(true)
	return shape


## Turn an arbitrary point into one that is guaranteed to be above the ground.
## The physics engine needs room between a body and the surface it starts on
## (the body is not allowed to spawn intersecting), so callers add their own
## clearance on top of this.
func ground_point(x: float, z: float, clearance: float = 1.5) -> Vector3:
	return Vector3(x, get_height_at(x, z) + clearance, z)


## Cheap nearest-vertex lookup used by props/particles that must not spike the
## CPU (get_height_at is analytic and therefore exact).
func get_normal_approx(x: float, z: float) -> Vector3:
	var h := get_height_at(x, z)
	var hx := get_height_at(x + 1.0, z)
	var hz := get_height_at(x, z + 1.0)
	return Vector3(h - hx, 1.0, h - hz).normalized()
