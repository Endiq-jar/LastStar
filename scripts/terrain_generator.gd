extends Node3D
## A 10 km world, streamed around the player.
##
## The valley used to be one 900 m mesh with a rim of mountains at 300 m, which
## is a bowl: however far you walk, the wall is always just there. This is the
## same landscape at ten kilometres across, with the mountains moved out to 2.4 km
## and a sea bay in the south-east that the river runs into.
##
## Nothing about that scale is affordable as one mesh. 10 km at the old 3.1 m
## tessellation is ten million vertices, and one mesh that big can never be
## frustum-culled anyway. So the ground is drawn in three layers, all sampled from
## the same analytic height function:
##
##   near  96 m tiles, 4 m quads, a 480 m window around the player   (~29k tris)
##   mid   672 m tiles, 32 m quads, a 4.7 km window around the player (~43k tris)
##   far   one static shell over the whole map at 160 m cells          (~8k tris)
##
## The mid tiles leave a hole exactly the shape of the near window (both are
## aligned to 32 m, so the hole has clean edges) and the near tiles drop a skirt
## over their own edges so the coarse/fine seam cannot show sky through it. The
## far shell is sunk 10 m so it never z-fights with anything above it; from the
## valley floor it is only visible past the mid window, which is past the
## mountains.
##
## get_height_at() remains the single authority for the world's shape - physics,
## prop placement, grass and the culler all call it - so the three layers can
## never disagree about where the ground is.

## The whole map, metres across. The playable core is the middle half of it.
const WORLD_SIZE := 10000.0
const SEA_LEVEL := 1.2

## Shared world features (Game mirrors these for other scripts).
const LAKE_CENTER := Vector2(190.0, 210.0)
const LAKE_RADIUS := 105.0
## Standing water away from the lake and the sea: x, z, radius.
const PONDS := [
	Vector3(-360.0, 300.0, 34.0),
	Vector3(520.0, -260.0, 26.0),
	Vector3(-150.0, -520.0, 30.0),
	Vector3(760.0, 480.0, 40.0),
	Vector3(-640.0, -140.0, 22.0),
	Vector3(240.0, 640.0, 30.0),
]
## The river runs roughly north to south with a meander, from the mountains,
## past the lake, out through the south-east bay. Its depth is a flat bed just
## under the waterline, so it reads as a channel rather than a canyon.
## Half-width of the river channel. The carve is flat over the inner 45% of it
## and eases out over the rest, so this is the bank-to-bank reach.
const RIVER_REACH := 26.0

const NEAR_TILE := 96.0
const NEAR_QUADS := 24
## Tiles out from the player's tile: 2 gives a 5 x 5 window, 480 m across.
const NEAR_RING := 2
const MID_TILE := 672.0
const MID_QUADS := 21
const MID_RING := 3
const FAR_CELL := 160.0
const FAR_CELLS := 63
## How far the static shell is sunk below the analytic surface, so the streamed
## layers always win the depth test against it.
const FAR_SINK := 10.0
## Collision is a patch that follows the player rather than a shape covering the
## map: a concave shape over 10 km at this resolution is tens of millions of
## triangles, and none of it is anywhere the player is.
const COLLIDE_SPAN := 320.0
const COLLIDE_STEP := 8.0

## Extra high-frequency surface detail, metres. The analytic height function is
## smooth on purpose (collision and gameplay snapping have to agree with it), so
## the rendered vertices get a small bump of their own.
const SURFACE_DETAIL := 0.22
const NOISE_SEED := 20261109

## How far the player must walk before the layers are refreshed, and how many
## tiles may be built per frame so a refresh never shows as a hitch.
const MOVE_REFRESH := 48.0
const NEAR_BUILDS_PER_FRAME := 2
const MID_BUILDS_PER_FRAME := 1

var height_noise: FastNoiseLite
var ridge_noise: FastNoiseLite
var detail_noise: FastNoiseLite
## Small-scale surface bump. Deliberately SEPARATE from get_height_at(): the
## analytic height is the collision and gameplay authority, so adding this there
## would make every physics query disagree with the visual mesh. Only rendered
## vertices get it.
var surface_noise: FastNoiseLite

var _material: ShaderMaterial
var _body: StaticBody3D
var _far: MeshInstance3D
var _near: Dictionary = {}          ## Vector2i -> MeshInstance3D
var _mid: Dictionary = {}           ## Vector2i -> MeshInstance3D
var _pending_near: Array[Vector2i] = []
var _pending_mid: Array[Vector2i] = []
var _near_center := Vector2i(999999, 999999)
var _mid_center := Vector2i(999999, 999999)
var _built_at := Vector2(1e9, 1e9)
var _collide_at := Vector2(1e9, 1e9)
var _player: Node3D


func _ready() -> void:
	add_to_group("terrain")
	_setup_noise()
	_material = _terrain_material()
	_build_far_shell()

	_body = StaticBody3D.new()
	_body.name = "TerrainBody"
	_body.collision_layer = 1
	_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.name = "TerrainCollision"
	_body.add_child(shape)
	add_child(_body)
	_rebuild_collision(Vector2.ZERO)

	_refresh(Vector2.ZERO, true)

	# Mirror the world layout so other systems (water, enemies, HUD compass) agree
	# on it instead of each hard-coding a lake.
	Game.water_level = SEA_LEVEL
	Game.lake_center = LAKE_CENTER
	Game.lake_radius = LAKE_RADIUS
	Game.world_size = WORLD_SIZE


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

	surface_noise = FastNoiseLite.new()
	surface_noise.seed = NOISE_SEED + 41
	surface_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	surface_noise.frequency = 0.16
	surface_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	surface_noise.fractal_octaves = 3
	surface_noise.fractal_gain = 0.5


# --------------------------------------------------------------------------
# the world's shape
# --------------------------------------------------------------------------

## The river's centre line: a meander in x as a function of z. Cheap on purpose -
## every terrain sample runs this, and a polyline with a hundred segments would be
## a hundred distance tests per sample.
func river_x(z: float) -> float:
	return 150.0 * sin(z * 0.0016) + 80.0 * sin(z * 0.0041 + 1.1) + 60.0


## Pull a height down to a flat bed inside `radius`, with soft banks.
func _carve(h: float, dist: float, radius: float, bed: float) -> float:
	if dist >= radius:
		return h
	var w := 1.0 - smoothstep(radius * 0.45, radius, dist)
	return lerpf(h, bed, w)


## World height. Everything in the game that needs ground height calls this.
func get_height_at(x: float, z: float) -> float:
	var r := sqrt(x * x + z * z)
	var base := height_noise.get_noise_2d(x, z) * 46.0
	var ridge := absf(ridge_noise.get_noise_2d(x, z)) * 30.0
	var detail := detail_noise.get_noise_2d(x, z) * 3.0

	# Which side of the map the sea is on. +1 points south-east; the mountains
	# stand down on that side so the bay has an opening.
	var sea_side := 0.0
	if r > 0.5:
		sea_side = (x * 0.72 + z * 0.69) / r
	var sea_blend := smoothstep(-0.20, 0.60, sea_side)

	# Mountains at the edge of the world, 2.4-3.7 km out - far enough that the
	# valley reads as a landscape rather than a bowl.
	var mount := smoothstep(2400.0, 3700.0, r) * (110.0 + ridge * 1.6)
	mount *= 1.0 - 0.85 * sea_blend

	# A gently terraced meadow at spawn, so the opening view is not a hillside.
	var spawn_d := Vector2(x, z).length()
	var meadow := (1.0 - smoothstep(30.0, 130.0, spawn_d)) * 6.0

	var h := base * smoothstep(0.0, 24.0, r) + ridge * smoothstep(0.0, 40.0, r)
	h += detail + mount + meadow + SEA_LEVEL + 12.0

	# The sea itself: past the shoreline the land keeps falling away, so the coast
	# is wherever the noise happens to cross the waterline. Islands and cliffs come
	# out of that for free.
	var sea := smoothstep(1300.0, 2700.0, r) * sea_blend
	if sea > 0.0:
		h -= sea * 62.0

	# Standing water. All three are the same operation: a flat bed a little under
	# the waterline, soft banks, and the noise left alone outside them.
	h = _carve(h, Vector2(x, z).distance_to(LAKE_CENTER), LAKE_RADIUS, SEA_LEVEL - 4.5)
	for pond in PONDS:
		h = _carve(h, Vector2(x, z).distance_to(Vector2(pond.x, pond.y)), pond.z, SEA_LEVEL - 1.6)
	if absf(z) < 3400.0:
		h = _carve(h, absf(x - river_x(z)), RIVER_REACH, SEA_LEVEL - 2.6)
	return h


## A rendered vertex position: the collision height plus the small-scale bump.
##
## Only the visual mesh uses this. Physics and the player resolve against
## get_height_at(), so the bump is cosmetic and can never desync a collision
## query - see surface_height_at() for how scattered props still land on it.
func _surface_point(x: float, z: float) -> Vector3:
	var bump := surface_noise.get_noise_2d(x, z) * SURFACE_DETAIL
	# Fade the bump out under the waterline so the beds stay smooth.
	if get_height_at(x, z) < SEA_LEVEL + 1.0:
		bump *= 0.0
	return Vector3(x, get_height_at(x, z) + bump, z)


## The height of the RENDERED surface at a point, i.e. the bumpy mesh the player
## is looking at - not the smooth analytic field the collision mesh uses.
##
## Defined on the near layer's 4 m grid, which is where anything placed by hand
## ends up standing. Reconstructed with the same four corner samples and the same
## diagonal split the near tiles use, so a prop placed with this sits exactly on
## the ground under the camera.
func surface_height_at(x: float, z: float) -> float:
	var step := NEAR_TILE / float(NEAR_QUADS)
	var gx := floorf(x / step)
	var gz := floorf(z / step)
	var x0 := gx * step
	var z0 := gz * step
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


## Steepness at a point, as a true gradient: metres of rise per metre of run.
func get_slope_at(x: float, z: float) -> float:
	const SAMPLE := 3.0
	var dx := get_height_at(x + 1.5, z) - get_height_at(x - 1.5, z)
	var dz := get_height_at(x, z + 1.5) - get_height_at(x, z - 1.5)
	return sqrt(dx * dx + dz * dz) / SAMPLE


func is_underwater(x: float, z: float) -> bool:
	return get_height_at(x, z) < SEA_LEVEL


## Turn an arbitrary point into one that is guaranteed to be above the ground.
func ground_point(x: float, z: float, clearance: float = 1.5) -> Vector3:
	return Vector3(x, surface_height_at(x, z) + clearance, z)


# --------------------------------------------------------------------------
# streaming
# --------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		var found := get_tree().get_first_node_in_group("player")
		if found is Node3D:
			_player = found as Node3D
	if _player != null:
		var p := _player.global_position
		if Vector2(p.x - _built_at.x, p.z - _built_at.y).length() > MOVE_REFRESH:
			_refresh(Vector2(p.x, p.z), false)
		if Vector2(p.x - _collide_at.x, p.z - _collide_at.y).length() > COLLIDE_SPAN * 0.25:
			_rebuild_collision(Vector2(p.x, p.z))
	_drain_queue()


func _refresh(pos: Vector2, immediate: bool) -> void:
	_built_at = pos
	var nc := Vector2i(floori(pos.x / NEAR_TILE), floori(pos.y / NEAR_TILE))
	if nc != _near_center:
		_near_center = nc
		_queue_near(nc)
		# The mid tiles carry a hole the shape of the near window, so moving the
		# window invalidates the few mid tiles it overlaps.
		_queue_mid_over_window()
	var mc := Vector2i(floori(pos.x / MID_TILE), floori(pos.y / MID_TILE))
	if mc != _mid_center:
		_mid_center = mc
		_queue_mid(mc)
	if immediate:
		while not _pending_near.is_empty():
			_build_near(_pending_near.pop_front())
		while not _pending_mid.is_empty():
			_build_mid(_pending_mid.pop_front())


func _queue_near(center: Vector2i) -> void:
	_pending_near.clear()
	for dz in range(-NEAR_RING, NEAR_RING + 1):
		for dx in range(-NEAR_RING, NEAR_RING + 1):
			var key := center + Vector2i(dx, dz)
			if not _near.has(key):
				_pending_near.append(key)
	for key in _near.keys():
		var d: Vector2i = key - center
		if absi(d.x) > NEAR_RING or absi(d.y) > NEAR_RING:
			var node: MeshInstance3D = _near[key]
			if is_instance_valid(node):
				node.queue_free()
			_near.erase(key)


func _queue_mid(center: Vector2i) -> void:
	_pending_mid.clear()
	for dz in range(-MID_RING, MID_RING + 1):
		for dx in range(-MID_RING, MID_RING + 1):
			var key := center + Vector2i(dx, dz)
			if not _mid.has(key):
				_pending_mid.append(key)
	for key in _mid.keys():
		var d: Vector2i = key - center
		if absi(d.x) > MID_RING or absi(d.y) > MID_RING:
			var node: MeshInstance3D = _mid[key]
			if is_instance_valid(node):
				node.queue_free()
			_mid.erase(key)


## Mid tiles overlapped by the near window have to be rebuilt when the window
## moves: their hole is cut to its exact edge.
func _queue_mid_over_window() -> void:
	var half := (float(NEAR_RING) + 0.5) * NEAR_TILE
	var lo := Vector2(float(_near_center.x) * NEAR_TILE - half, float(_near_center.y) * NEAR_TILE - half)
	var hi := lo + Vector2(half * 2.0, half * 2.0)
	var mlo := Vector2i(floori(lo.x / MID_TILE), floori(lo.y / MID_TILE))
	var mhi := Vector2i(floori(hi.x / MID_TILE), floori(hi.y / MID_TILE))
	for mz in range(mlo.y, mhi.y + 1):
		for mx in range(mlo.x, mhi.x + 1):
			var key := Vector2i(mx, mz)
			if not _mid.has(key):
				continue
			var node: MeshInstance3D = _mid[key]
			if is_instance_valid(node):
				node.queue_free()
			_mid.erase(key)
			if absi(mx - _mid_center.x) <= MID_RING and absi(mz - _mid_center.y) <= MID_RING:
				_pending_mid.append(key)


func _drain_queue() -> void:
	var built := 0
	while built < NEAR_BUILDS_PER_FRAME and not _pending_near.is_empty():
		_build_near(_pending_near.pop_front())
		built += 1
	built = 0
	while built < MID_BUILDS_PER_FRAME and not _pending_mid.is_empty():
		_build_mid(_pending_mid.pop_front())
		built += 1


# --------------------------------------------------------------------------
# mesh building
# --------------------------------------------------------------------------

## Half-width of the hole the near window cuts in the mid layer.
func _near_window_half() -> float:
	return (float(NEAR_RING) + 0.5) * NEAR_TILE


func _build_near(key: Vector2i) -> void:
	if _near.has(key):
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := NEAR_TILE / float(NEAR_QUADS)
	var x0 := float(key.x) * NEAR_TILE
	var z0 := float(key.y) * NEAR_TILE
	var pts := PackedVector3Array()
	pts.resize((NEAR_QUADS + 1) * (NEAR_QUADS + 1))
	for gz in range(NEAR_QUADS + 1):
		for gx in range(NEAR_QUADS + 1):
			pts[gz * (NEAR_QUADS + 1) + gx] = _surface_point(x0 + gx * step, z0 + gz * step)
	var row := NEAR_QUADS + 1
	for gz in range(NEAR_QUADS):
		for gx in range(NEAR_QUADS):
			var p00 := pts[gz * row + gx]
			var p10 := pts[gz * row + gx + 1]
			var p01 := pts[(gz + 1) * row + gx]
			var p11 := pts[(gz + 1) * row + gx + 1]
			# Winding: Godot computes a triangle normal as (p1-p3) x (p1-p2), so
			# (p00,p01,p10) produced a DOWNWARD normal - an invisible, inside-out
			# surface. Counter-clockwise from above is the correct order.
			for v in [p00, p10, p01, p10, p11, p01]:
				st.set_uv(Vector2(v.x, v.z) * 0.02)
				st.add_vertex(v)
	# Skirts: a wall dropping 6 m from each edge, so the 4 m near mesh and the
	# 32 m mid mesh cannot show a sliver of sky at the seam between them.
	_add_skirts(st, pts, row, x0, z0, step)
	st.generate_normals()

	var mi := MeshInstance3D.new()
	mi.name = "Near_%d_%d" % [key.x, key.y]
	mi.mesh = st.commit()
	mi.material_override = _material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	_near[key] = mi


## Four walls, one per edge, hanging below the tile.
func _add_skirts(st: SurfaceTool, pts: PackedVector3Array, row: int, x0: float, z0: float, step: float) -> void:
	const DROP := 6.0
	for side in range(4):
		for i in range(NEAR_QUADS):
			var a := Vector3.ZERO
			var b := Vector3.ZERO
			match side:
				0:
					a = pts[i]
					b = pts[i + 1]
				1:
					a = pts[(row - 1) * row + i]
					b = pts[(row - 1) * row + i + 1]
				2:
					a = pts[i * row]
					b = pts[(i + 1) * row]
				_:
					a = pts[i * row + row - 1]
					b = pts[(i + 1) * row + row - 1]
			var down := Vector3(0.0, -DROP, 0.0)
			for v in [a, b, b + down, a, b + down, a + down]:
				st.set_uv(Vector2(v.x, v.z) * 0.02)
				st.add_vertex(v)


func _build_mid(key: Vector2i) -> void:
	if _mid.has(key):
		return
	var step := MID_TILE / float(MID_QUADS)
	var x0 := float(key.x) * MID_TILE
	var z0 := float(key.y) * MID_TILE
	# The near window's footprint, in world space, so quads under it are left out.
	var half := _near_window_half()
	var wlo := Vector2(float(_near_center.x) * NEAR_TILE - half, float(_near_center.y) * NEAR_TILE - half)
	var whi := wlo + Vector2(half * 2.0, half * 2.0)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	for gz in range(MID_QUADS):
		for gx in range(MID_QUADS):
			var cx := x0 + (gx + 0.5) * step
			var cz := z0 + (gz + 0.5) * step
			if cx > wlo.x and cx < whi.x and cz > wlo.y and cz < whi.y:
				continue
			var p00 := _surface_point(x0 + gx * step, z0 + gz * step)
			var p10 := _surface_point(x0 + (gx + 1) * step, z0 + gz * step)
			var p01 := _surface_point(x0 + gx * step, z0 + (gz + 1) * step)
			var p11 := _surface_point(x0 + (gx + 1) * step, z0 + (gz + 1) * step)
			for v in [p00, p10, p01, p10, p11, p01]:
				st.set_uv(Vector2(v.x, v.z) * 0.02)
				st.add_vertex(v)
			quads += 1
	if quads == 0:
		return
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Mid_%d_%d" % [key.x, key.y]
	mi.mesh = st.commit()
	mi.material_override = _material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_mid[key] = mi


## One static shell over the whole map. Coarse enough to be a rounding error in
## the triangle budget and always behind everything the streamed layers draw.
func _build_far_shell() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := FAR_CELL * float(FAR_CELLS) * 0.5
	for gz in range(FAR_CELLS):
		for gx in range(FAR_CELLS):
			var x0 := -half + gx * FAR_CELL
			var z0 := -half + gz * FAR_CELL
			var x1 := x0 + FAR_CELL
			var z1 := z0 + FAR_CELL
			var p00 := Vector3(x0, get_height_at(x0, z0) - FAR_SINK, z0)
			var p10 := Vector3(x1, get_height_at(x1, z0) - FAR_SINK, z0)
			var p01 := Vector3(x0, get_height_at(x0, z1) - FAR_SINK, z1)
			var p11 := Vector3(x1, get_height_at(x1, z1) - FAR_SINK, z1)
			for v in [p00, p10, p01, p10, p11, p01]:
				st.set_uv(Vector2(v.x, v.z) * 0.02)
				st.add_vertex(v)
	st.generate_normals()
	_far = MeshInstance3D.new()
	_far.name = "FarShell"
	_far.mesh = st.commit()
	_far.material_override = _material
	_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_far)


## A concave collision patch around the player, rebuilt as they walk. Physics only
## ever touches the ground within a few hundred metres of them, so the rest of a
## 10 km map does not need collision at all.
func _rebuild_collision(at: Vector2) -> void:
	if _body == null:
		return
	var snap := COLLIDE_STEP * 4.0
	var cx := snappedf(at.x, snap)
	var cz := snappedf(at.y, snap)
	_collide_at = Vector2(cx, cz)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := COLLIDE_SPAN * 0.5
	var n := int(COLLIDE_SPAN / COLLIDE_STEP)
	for gz in range(n):
		for gx in range(n):
			var x0 := cx - half + gx * COLLIDE_STEP
			var z0 := cz - half + gz * COLLIDE_STEP
			var x1 := x0 + COLLIDE_STEP
			var z1 := z0 + COLLIDE_STEP
			var p00 := Vector3(x0, get_height_at(x0, z0), z0)
			var p10 := Vector3(x1, get_height_at(x1, z0), z0)
			var p01 := Vector3(x0, get_height_at(x0, z1), z1)
			var p11 := Vector3(x1, get_height_at(x1, z1), z1)
			for v in [p00, p10, p01, p10, p11, p01]:
				st.add_vertex(v)
	var mesh := st.commit()
	var shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	# One-sided concave collision silently lets bodies fall straight through a
	# triangle wound the wrong way - catastrophic and invisible in the editor, so
	# pay the small cost of two-sided collision.
	shape.set_backface_collision_enabled(true)
	for child in _body.get_children():
		if child is CollisionShape3D:
			(child as CollisionShape3D).shape = shape
			return
	var col := CollisionShape3D.new()
	col.name = "TerrainCollision"
	col.shape = shape
	_body.add_child(col)


# --------------------------------------------------------------------------
# material and diagnostics
# --------------------------------------------------------------------------

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
	m.shader = load("res://shaders/terrain/terrain_anime.gdshader")
	m.set_shader_parameter("meadow_tex", _load_tex("res://textures/terrain/meadow.png"))
	m.set_shader_parameter("rock_tex", _load_tex("res://textures/terrain/rock.png"))
	m.set_shader_parameter("sand_tex", _load_tex("res://textures/terrain/sand.png"))
	m.set_shader_parameter("macro_tex", _load_tex("res://textures/terrain/macro.png"))
	m.set_shader_parameter("water_level", SEA_LEVEL)
	# The mountains reach ~210 m now, not the old rim's ~130, so the rock and snow
	# bands move up with them or every peak would come out entirely white.
	m.set_shader_parameter("rock_height", 90.0)
	m.set_shader_parameter("snow_height", 150.0)
	m.set_shader_parameter("uv_scale", 0.13)
	m.set_shader_parameter("macro_scale", 0.0045)
	return m


## Counts for the probe: what is actually in the scene, not what was intended.
func census() -> String:
	var near_tris := 0
	for key in _near:
		var node: MeshInstance3D = _near[key]
		if is_instance_valid(node) and node.mesh != null:
			near_tris += (node.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var mid_tris := 0
	for key in _mid:
		var node: MeshInstance3D = _mid[key]
		if is_instance_valid(node) and node.mesh != null:
			mid_tris += (node.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return "near=%d tiles/%d tris mid=%d tiles/%d tris far=%dm cells near_window=%.0fm" % [
		_near.size(), near_tris, _mid.size(), mid_tris,
		int(FAR_CELL), _near_window_half() * 2.0]
