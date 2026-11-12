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
## Instances per 26 m chunk. Near chunks were 3400 - about five tufts per square
## metre - drawn as 2.1 m quads, which left visible gaps between them and read as
## blotches of green on bare ground rather than a carpet. Roughly doubled to close
## that up. The far tiers stay cheap because each tuft there covers more screen
## area.
const BLADES_NEAR := 14000        ## instances in a chunk adjacent to the player
const BLADES_MID := 5200
const BLADES_FAR := 1500
const MAX_CHUNKS := 81            ## (2*5+1)^2, hard cap on live chunks
const SEA_MARGIN := 2.4           ## metres above water level where grass starts

## Two crossed quads per tuft, so a tuft has volume from every angle.
## Tuft footprint and height in metres. The height matters more than it looks:
## the player is 1.8 m tall and the camera sits 4.2 m back at 2 m up, so a 0.78 m
## blade with a 1.2 scale multiplier in the mid ring grew to roughly the
## character's chest and hid her completely. Meadow grass in this style sits
## around knee height.
const BLADE_W := 0.62
const BLADE_H := 0.56

signal chunk_built(count: int)

var _terrain: Node
var _player: Node3D
var _chunks: Dictionary = {}       ## Vector2i -> MultiMeshInstance3D
var _pending: Array[Vector2i] = []
var _blade_mesh: Mesh
var _material: ShaderMaterial
var _last_center := Vector2i(9999, 9999)
var _build_budget := 3             ## chunks built per frame, to avoid hitches
## Multiplies every tier's instance count. This is the real density control.
##
## set_density_scale() used to write _build_budget and nothing else, so the
## "density" setting only changed how many chunks were streamed per frame - the
## blade counts were identical at every tier. A phone that dropped to
## Performance therefore grew the same meadow as a desktop, which is exactly
## backwards, and the quality menu's promise was never wired to anything.
var _density := 1.0
var _enabled := true
## Diagnostics: why blades were rejected, so a density regression is explainable
## instead of a mystery number.
var _rej_water := 0
var _rej_height := 0
var _rej_slope := 0
var _tried := 0
var _tier_counts := {2600: 0, 1300: 0, 520: 0}


func setup(terrain: Node, player: Node3D) -> void:
	_terrain = terrain
	_player = player
	name = "GrassField"
	_build_resources()
	_refresh(true)


func _build_resources() -> void:
	# One textured quad per tuft, standing UPRIGHT. The blade cluster lives in the
	# texture's alpha channel, so a single plane draws a full tuft, and the shader
	# uses cull_disabled so the plane is visible from both faces.
	#
	# QuadMesh defaults to FACE_Z (upright). This was set to FACE_Y, which lays
	# the quad FLAT - so every tuft was a horizontal decal lying on the hillside
	# and the grass rendered as elongated blotches smeared across the ground.
	# That is the blotchy-patch artefact this file spent several revisions
	# chasing: it was never density or colour. Each instance gets a random yaw
	# (see _build_chunk), so the planes do not all face the same way.
	var quad := QuadMesh.new()
	# Roughly square in aspect: a tuft's silhouette is a fan of blades as tall as
	# it is wide, and a wide short quad read as a leaf on the ground rather than as
	# grass. (This was 3.4x the width for 1.15x the height, i.e. twice as wide as
	# tall.)
	quad.size = Vector2(BLADE_W * 1.15, BLADE_H * 1.30)
	quad.orientation = PlaneMesh.FACE_Z
	_blade_mesh = quad

	_material = ShaderMaterial.new()
	var shader := load("res://shaders/terrain/grass_sway.gdshader")
	if shader != null:
		_material.shader = shader
		var tex := load("res://icons/grass/tuft.png")
		if tex != null:
			_material.set_shader_parameter("blade_tex", tex)
		else:
			push_warning("LastStar: grass tuft texture missing - blades will be solid")
	else:
		push_warning("LastStar: grass shader missing - grass will look flat")


func _process(_delta: float) -> void:
	if not _enabled or _player == null or _terrain == null:
		return
	# Push the camera position for the near-blade cull. The shader cannot read a
	# camera built-in in its vertex stage (those are fragment-only and using one
	# is a compile error that silently white-materials the whole field), so the
	# value comes from here.
	_push_view_params()
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
	# Taller further out hides the reduced density without turning the mid ring
	# into reeds.
	var height_scale := 1.0 + clampf(float(dist) * 0.045, 0.0, 0.22)
	count = maxi(1, int(round(float(count) * _density)))
	_tier_counts[count] = int(_tier_counts.get(count, 0)) + 1
	for i in range(count):
		_tried += 1
		var x := origin_x + rng.randf() * CHUNK_SIZE
		var z := origin_z + rng.randf() * CHUNK_SIZE
		# surface_height_at(), not get_height_at(): the grass has to sit on the
		# bumpy mesh the camera actually sees, not on the smooth analytic field
		# the collision uses. Those differ by up to the sagitta of a 3 m triangle,
		# which is exactly enough for a tuft to hover with air under it.
		var h: float = _terrain.surface_height_at(x, z) if _terrain.has_method("surface_height_at") \
			else _terrain.get_height_at(x, z)
		# Grass grows on gentle ground above the shoreline, not on cliffs,
		# not underwater and not on the high rock/snow bands.
		if h > 58.0:
			_rej_height += 1
			continue
		if _terrain.get_slope_at(x, z) > 0.52:
			_rej_slope += 1
			continue
		# Exclude actual water, not a circle around it. The old blanket
		# exclusion (lake_radius * 0.82 = 75 m from the lake centre) also
		# swallowed the spawn glade - the player starts 66 m from the centre,
		# so the entire meadow around them was silently rejected and the field
		# came out at a few thousand blades instead of tens of thousands.
		if _terrain.is_underwater(x, z):
			_rej_water += 1
			continue
		# Keep a small dry margin around the shoreline so blades do not poke
		# through the water surface.
		if h < SEA_MARGIN:
			_rej_water += 1
			continue
		var s := rng.randf_range(0.75, 1.45) * height_scale
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		# The quad is centred on its origin, so it has to be lifted by half its
		# height (times the instance scale) or the bottom half sinks into the
		# ground and the tuft reads as half a blade.
		made.append(Transform3D(basis, Vector3(x, h + BLADE_H * 1.30 * 0.5 * s - 0.06, z)))
	if made.is_empty():
		return
	multimesh.instance_count = made.size()
	for i in range(made.size()):
		multimesh.set_instance_transform(i, made[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Grass_%d_%d" % [key.x, key.y]
	mmi.multimesh = multimesh
	if _material != null:
		_push_view_params()
		mmi.material_override = _material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 150.0
	add_child(mmi)
	_chunks[key] = mmi
	chunk_built.emit(made.size())


func _push_view_params() -> void:
	## Hand the camera and character positions to the grass shader.
	##
	## Called from both _process and _build_chunk: chunks are built in a burst at
	## startup (fill-the-ring), and those builds happen before the first _process,
	## so relying on the per-frame push alone left the very first chunks drawing
	## with the default uniforms - grass growing through the character.
	if _material == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		_material.set_shader_parameter("cam_origin", cam.global_position)
	if _player != null:
		# The player node's origin is at her feet; lift the clearing centre to her
		# waist so the smoothstep removes grass around her body, not below it.
		_material.set_shader_parameter("player_origin", _player.global_position + Vector3(0, 0.9, 0))
		# 1.6 m carved a 3.2 m circle of bare ground around her feet, which is the
		# naked ring the character appears to be standing in the middle of. Only
		# the character of the clearing is needed - enough that blades do not grow
		# through her - and 0.95 m still leaves her boots and shins clear.
		_material.set_shader_parameter("player_clear", 0.95)


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


func diagnostics() -> String:
	return "tried=%d water=%d height=%d slope=%d tiers(near/mid/far)=%d/%d/%d" % [
		_tried, _rej_water, _rej_height, _rej_slope,
		int(_tier_counts.get(2600, 0)), int(_tier_counts.get(1300, 0)),
		int(_tier_counts.get(520, 0))]


func set_enabled(on: bool) -> void:
	_enabled = on
	visible = on
	if on and _player != null:
		_refresh(true)


func focus_at(point: Vector3) -> void:
	## Re-centre the field on an arbitrary point instead of the player.
	##
	## The field normally follows the player, which is right in play and wrong for
	## the beauty screenshot: that camera stands tens of metres away, outside the
	## ring, so its foreground has no grass at all. Rebuilding around the vantage
	## makes the screenshot show the world as it actually appears.
	if _terrain == null:
		return
	var center := _chunk_of(point)
	_last_center = center
	for key in _chunks.keys():
		var node: MultiMeshInstance3D = _chunks[key]
		if is_instance_valid(node):
			node.queue_free()
	_chunks.clear()
	_pending.clear()
	_queue_around(center)
	var guard := 0
	while not _pending.is_empty() and guard < MAX_CHUNKS * 2:
		_build_chunk(_pending.pop_front())
		guard += 1


func set_density_scale(scale: float) -> void:
	## Used by the quality tuner: 1.0 = full, 0.65 = Balanced, 0.35 = Performance.
	##
	## Only affects chunks built AFTER the call, so existing geometry is rebuilt
	## by dropping the ring and streaming it again - otherwise the player would
	## see the density change only once they had walked far enough to cycle every
	## chunk, which at 26 m chunks and 130 m of view is well over a minute.
	_build_budget = maxi(2, int(round(4.0 * scale)))
	visible = scale > 0.01
	if is_equal_approx(scale, _density):
		return
	_density = scale
	if _player != null:
		_last_center = Vector2i(9999, 9999)
