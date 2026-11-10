extends Node3D
## A carpet of grass over the entire valley.
##
## Grass "everywhere" cannot mean one MultiMesh with a million instances: the
## vertex cost alone would melt a Helio P95, and the GPU would rasterise blades
## behind the camera. Instead the world is cut into square chunks and only the
## chunks around the player are built, at a density that falls off with distance:
##
##   near  (0 - 26 m)   dense, full blade height, catches the light
##   mid   (26 - 70 m)  half density, slightly taller so bare ground never shows
##   far   (70 - 130 m) sparse, cheap - reads as distant meadow texture
##
## Chunks are recycled as the player walks, so walking 500 m never grows the
## instance count. Everything is one draw call per chunk.

const CHUNK_SIZE := 26.0          ## metres per chunk
const VIEW_CHUNKS := 5            ## radius, in chunks (5 * 26 = 130 m)
const BLADES_NEAR := 2600         ## instances in a chunk adjacent to the player
const BLADES_MID := 1300
const BLADES_FAR := 520
const MAX_CHUNKS := 81            ## (2*5+1)^2, hard cap on live chunks
const SEA_MARGIN := 2.4           ## metres above water level where grass starts

## Two crossed quads per tuft, so a tuft has volume from every angle.
const BLADE_W := 0.62
const BLADE_H := 0.78

signal chunk_built(count: int)

var _terrain: Node
var _player: Node3D
var _chunks: Dictionary = {}       ## Vector2i -> MultiMeshInstance3D
var _pending: Array[Vector2i] = []
var _blade_mesh: Mesh
var _material: ShaderMaterial
var _last_center := Vector2i(9999, 9999)
var _build_budget := 3             ## chunks built per frame, to avoid hitches
var _enabled := true


func setup(terrain: Node, player: Node3D) -> void:
	_terrain = terrain
	_player = player
	name = "GrassField"
	_build_resources()
	_refresh(true)


func _build_resources() -> void:
	# One tuft = three thin quads fanned around the vertical axis. Three is the
	# sweet spot: it fills the silhouette from any camera angle without the
	# overdraw of a full star of quads.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(3):
		var a := TAU * float(i) / 3.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var side := Vector3(-dir.z, 0.0, dir.x) * (BLADE_W * 0.5)
		var base := dir * 0.06
		var top := dir * 0.16 + Vector3(0.0, BLADE_H, 0.0)
		# Slight bend so the blade is not a flat rectangle.
		var mid_l := base - side + Vector3(0.0, BLADE_H * 0.45, 0.0)
		var mid_r := base + side + Vector3(0.0, BLADE_H * 0.45, 0.0)
		_tri(st, base - side, mid_l, mid_r)
		_tri(st, base - side, mid_r, base + side)
		_tri(st, mid_l, top, mid_r)
	st.index()
	_blade_mesh = st.commit()

	_material = ShaderMaterial.new()
	var shader := load("res://shaders/grass_sway.gdshader")
	if shader != null:
		_material.shader = shader
	else:
		push_warning("LastStar: grass shader missing - grass will look flat")


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(a)
	st.set_uv(Vector2(1.0, 0.45))
	st.add_vertex(b)
	st.set_uv(Vector2(0.0, 0.45))
	st.add_vertex(c)


func _process(_delta: float) -> void:
	if not _enabled or _player == null or _terrain == null:
		return
	var center := _chunk_of(_player.global_position)
	if center != _last_center:
		_last_center = center
		_queue_around(center)
	# Build a few chunks per frame so streaming never causes a visible hitch.
	var built := 0
	while built < _build_budget and not _pending.is_empty():
		var key: Vector2i = _pending.pop_front()
		if not _chunks.has(key):
			_build_chunk(key)
			built += 1


func _refresh(force: bool) -> void:
	if _player == null:
		return
	_last_center = _chunk_of(_player.global_position)
	_queue_around(_last_center)
	if force:
		# Fill the ring in one go at startup. It is ~70k instance transforms,
		# which is a few milliseconds of CPU - far better spent once than
		# spread over 30 frames that visibly pop chunks in.
		var guard := 0
		while not _pending.is_empty() and guard < MAX_CHUNKS * 2:
			_build_chunk(_pending.pop_front())
			guard += 1


func _chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CHUNK_SIZE), floori(p.z / CHUNK_SIZE))


func _queue_around(center: Vector2i) -> void:
	_pending.clear()
	for dz in range(-VIEW_CHUNKS, VIEW_CHUNKS + 1):
		for dx in range(-VIEW_CHUNKS, VIEW_CHUNKS + 1):
			var key := center + Vector2i(dx, dz)
			# Circular view so corners do not double the work.
			if Vector2(dx, dz).length() > float(VIEW_CHUNKS) + 0.25:
				continue
			if not _chunks.has(key):
				_pending.append(key)
	# Drop chunks that fell out of range. Anything still queued stays queued.
	for key in _chunks.keys():
		var d: Vector2i = key - center
		if Vector2(d).length() > float(VIEW_CHUNKS) + 1.5:
			var node: MultiMeshInstance3D = _chunks[key]
			if is_instance_valid(node):
				node.queue_free()
			_chunks.erase(key)


func _build_chunk(key: Vector2i) -> void:
	if _terrain == null:
		return
	if _chunks.size() >= MAX_CHUNKS:
		return
	# Distance is measured from where the player is *now*: chunks are queued in
	# batches and the player keeps moving while they are built.
	var center := _chunk_of(_player.global_position) if _player != null else _last_center
	var d := key - center
	var dist := Vector2(d).length()
	var count := BLADES_FAR
	if dist <= 1.5:
		count = BLADES_NEAR
	elif dist <= 3.0:
		count = BLADES_MID

	var rng := RandomNumberGenerator.new()
	# Deterministic per chunk: the meadow looks the same every time you return.
	rng.seed = hash(Vector2i(key.x * 73856093, key.y * 19349663))

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _blade_mesh
	var xform := Transform3D()
	# Fill first into an array, then set instance_count once: shrinking a live
	# MultiMesh is cheap, growing it reallocates the buffer.
	var made: Array[Transform3D] = []
	var origin_x := float(key.x) * CHUNK_SIZE
	var origin_z := float(key.y) * CHUNK_SIZE
	# Taller blades further away hide the reduced density.
	var height_scale := 1.0 + clampf(float(dist) * 0.06, 0.0, 0.35)
	for i in range(count):
		var x := origin_x + rng.randf() * CHUNK_SIZE
		var z := origin_z + rng.randf() * CHUNK_SIZE
		var h: float = _terrain.get_height_at(x, z)
		# Grass grows on gentle ground above the shoreline, not on cliffs,
		# not underwater and not on the high rock/snow bands.
		if h > 58.0:
			continue
		if _terrain.get_slope_at(x, z) > 0.52:
			continue
		# Exclude actual water, not a circle around it. The old blanket
		# exclusion (lake_radius * 0.82 = 75 m from the lake centre) also
		# swallowed the spawn glade - the player starts 66 m from the centre,
		# so the entire meadow around them was silently rejected and the field
		# came out at a few thousand blades instead of tens of thousands.
		if _terrain.is_underwater(x, z):
			continue
		# Keep a small dry margin around the shoreline so blades do not poke
		# through the water surface.
		if h < SEA_MARGIN:
			continue
		var s := rng.randf_range(0.75, 1.45) * height_scale
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		made.append(Transform3D(basis, Vector3(x, h - 0.05, z)))
	if made.is_empty():
		return
	multimesh.instance_count = made.size()
	for i in range(made.size()):
		multimesh.set_instance_transform(i, made[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Grass_%d_%d" % [key.x, key.y]
	mmi.multimesh = multimesh
	if _material != null:
		mmi.material_override = _material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 150.0
	add_child(mmi)
	_chunks[key] = mmi
	chunk_built.emit(made.size())


## Total live blades, for the performance tuner and the probe.
func blade_count() -> int:
	var total := 0
	for key in _chunks:
		var node: MultiMeshInstance3D = _chunks[key]
		if is_instance_valid(node) and node.multimesh != null:
			total += node.multimesh.instance_count
	return total


func chunk_count() -> int:
	return _chunks.size()


func set_enabled(on: bool) -> void:
	_enabled = on
	visible = on
	if on and _player != null:
		_refresh(true)


func set_density_scale(scale: float) -> void:
	## Used by the quality tuner: 1.0 = full, 0.5 = half the blades.
	_build_budget = maxi(1, int(round(4.0 * scale)))
	visible = scale > 0.01
