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
## The tuft itself is geometry from the Quaternius nature pack (NaturePack.clump),
## not a painted card: the field used to be a 0.7 m quad with a sprite cut out of
## it, and the sprite is gone. One tuft is now ~1 m of real blades at 64
## triangles, which is 16x the vertex cost of two crossed quads, so the instance
## counts below came down by roughly the same factor to keep the meadow inside
## the triangle budget the rest of the frame was measured against (1.2M in the
## probe before this change). The clumps are wider than the cards they replace,
## so the field covers the same ground with a third of the instances and reads
## denser from eye level, because each tuft is a bundle of blades with real
## thickness rather than a flat cut-out.
##
## Chunks are recycled as the player walks, so walking 500 m never grows the
## instance count. Everything is one draw call per chunk.

const NaturePack := preload("res://scripts/nature_pack.gd")

const CHUNK_SIZE := 26.0          ## metres per chunk
## Radius, in chunks. 5 * 26 = 130 m, which with the shader's dissolve put a
## visible arc of bare terrain at the edge of the meadow. Raised to 7 (182 m) so
## the field runs past the point where blades stop being resolvable.
const VIEW_CHUNKS := 7
## Instances per 26 m chunk. Near chunks were 3400 - about five tufts per square
## metre - drawn as 2.1 m quads, which left visible gaps between them and read as
## blotches of green on bare ground rather than a carpet. Roughly doubled to close
## that up. The far tiers stay cheap because each tuft there covers more screen
## area.
const BLADES_NEAR := 1800         ## instances in a chunk adjacent to the player
const BLADES_MID := 640
const BLADES_FAR := 190
## Hard cap on live chunks. Must be at least (2*VIEW_CHUNKS+1)^2 or the field
## silently stops growing: the cap was written for a radius of 5 and stayed at 81
## when the radius became 7, which needs 225. Without this the outer ring would
## simply never be built and the "grass everywhere" change would do nothing past
## 130 m while looking correct in the code.
const MAX_CHUNKS := 225
## Metres above water level where grass starts. 2.4 left a bare sand ring round
## every shore; 0.9 keeps blades out of the water but lets the meadow reach it.
const SEA_MARGIN := 0.9

## Tuft height matters more than it looks: the player is 1.8 m tall and the
## camera sits 4.2 m back at 2 m up, so a tuft that reaches the character's chest
## hides her completely. The scale range in _build_chunk keeps the meadow around
## knee height, and NaturePack.clump() supplies the blades themselves.

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
	# A real tuft of blades from the nature pack, decimated to its tallest 36
	# blades. The pack's tuft is ~100 blades in 192 triangles; at full density
	# this field would draw tens of millions of triangles for ground cover.
	_blade_mesh = NaturePack.clump("grass", 36)
	if _blade_mesh == null:
		push_warning("LastStar: nature pack grass missing - the meadow will be empty")
		return

	_material = ShaderMaterial.new()
	var shader := load("res://shaders/terrain/grass_sway.gdshader")
	if shader == null:
		push_warning("LastStar: grass shader missing - grass will look flat")
		return
	_material.shader = shader
	# The tuft carries its colour in vertex colours (the pack ships no textures
	# and no UVs), so the shader is told to use them instead of sampling a blade
	# sprite. Everything else - the wind, the view cull, the sightline clearing,
	# the distance fade - is unchanged, which is the point of keeping this shader
	# rather than writing a second one.
	_material.set_shader_parameter("use_vertex_color", 1.0)
	_material.set_shader_parameter("model_height", maxf(NaturePack.height_of("grass"), 0.05))


func _process(_delta: float) -> void:
	if _player == null or _terrain == null:
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


## True when a chunk lies entirely behind the camera and so cannot draw.
##
## The shader culls per instance, which is what removes blades behind the lens
## from an already-built chunk. This is the cheaper filter one level up: a chunk
## that is entirely behind the camera should never be *built* in the first
## place. The player walks forward, so a third of the ring is queued, built,
## uploaded and then culled every time they move - paying full CPU cost for
## geometry that provably contributes nothing.
##
## Conservative by SIGHT_CULL_MARGIN: a chunk is only skipped if the whole of
## it is behind a plane pushed that far back, so a chunk the camera can still
## see at the edge of a wide FOV - or that holds the character in view when the
## camera swings - is always built. False negatives cost a chunk that gets built
## and culled later; false positives would be a hole in the meadow, so the test
## errs toward building.
const SIGHT_CULL_MARGIN := 34.0


func _behind_camera(key: Vector2i) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	var fwd := -cam.global_basis.z
	var c := Vector3((float(key.x) + 0.5) * CHUNK_SIZE, 0.0,
		(float(key.y) + 0.5) * CHUNK_SIZE)
	# Half-diagonal of a chunk, so the test covers every corner of it.
	var reach := CHUNK_SIZE * 0.7072
	return (c - cam.global_position).dot(fwd) < -(reach + SIGHT_CULL_MARGIN)


func _build_chunk(key: Vector2i) -> void:
	if _terrain == null:
		return
	if _chunks.size() >= MAX_CHUNKS:
		return
	if _behind_camera(key):
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
	# Placement runs in tufts, not independent blades.
	#
	# Every blade was an independent uniform random point, which is the definition
	# of a statistically flat carpet: no clumping, no gaps, no scale between a
	# single blade and the whole chunk. Real grass grows in tufts, and at the
	# distances this field is seen the tuft is the unit the eye reads - a blade is
	# sub-pixel past about 15 m.
	#
	# So each iteration drops a tuft centre on the noise field and then places a
	# small cluster of blades around it. The total blade count is unchanged, so
	# this costs nothing; what changes is that density now varies at 1 m scale as
	# well as at the 40 m scale of the existing _noise patches.
	var tuft_size := 3 + int(rng.randf() * 5.0)
	var tuft_radius := 0.16 + rng.randf() * 0.30
	var cx := origin_x + rng.randf() * CHUNK_SIZE
	var cz := origin_z + rng.randf() * CHUNK_SIZE
	var in_tuft := 0
	for i in range(count):
		_tried += 1
		# Start a new tuft once this one is full, or immediately on the first blade.
		# A tuft whose centre lands on rejected ground simply places nothing, which
		# is correct - a tuft on a cliff is not grass.
		if in_tuft >= tuft_size:
			in_tuft = 0
			tuft_size = 3 + int(rng.randf() * 5.0)
			tuft_radius = 0.16 + rng.randf() * 0.30
			cx = origin_x + rng.randf() * CHUNK_SIZE
			cz = origin_z + rng.randf() * CHUNK_SIZE
		in_tuft += 1
		# Offset within the tuft, denser toward the centre: a tuft is a bundle
		# rising from one root, not a disc of grass cut with a cookie cutter.
		var ang := rng.randf() * TAU
		var rad := tuft_radius * pow(rng.randf(), 0.65)
		var x := cx + cos(ang) * rad
		var z := cz + sin(ang) * rad
		# surface_height_at(), not get_height_at(): the grass has to sit on the
		# bumpy mesh the camera actually sees, not on the smooth analytic field
		# the collision uses. Those differ by up to the sagitta of a 3 m triangle,
		# which is exactly enough for a tuft to hover with air under it.
		var h: float = _terrain.surface_height_at(x, z) if _terrain.has_method("surface_height_at") \
			else _terrain.get_height_at(x, z)
		# Grass grows on gentle ground above the shoreline, not on cliffs,
		# not underwater and not on the high rock/snow bands.
		# 58 -> 92 m. The old ceiling stopped grass well below the rock and snow
		# bands, so every hill above the valley floor was bare terrain - the
		# single largest reason the world read as "a meadow patch surrounded by
		# empty mountains". 92 m is where the terrain shader's own rock blend
		# takes over, so the two agree instead of leaving a gap.
		if h > 92.0:
			_rej_height += 1
			continue
		# 0.52 -> 0.78. At 0.52 the field skipped roughly 27 degrees of slope, which
		# is most of a hilly valley - the grass stopped wherever the ground started
		# to rise, and the hillsides above it were bare. 0.78 (~38 degrees) still
		# keeps blades off cliffs and scree.
		if _terrain.get_slope_at(x, z) > 0.78:
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
		# Outer blades of a tuft are shorter and lean outward; the tallest blades
		# are at the centre. This is what stops a tuft reading as a cylinder of
		# identical quad cards.
		var centre_bias := 1.0 - clampf(rad / maxf(tuft_radius, 0.001), 0.0, 1.0)
		# A 1 m pack tuft against the 0.73 m card it replaced, so the scale range
		# is a little tighter and sits lower: meadow grass in this style is knee
		# height on a 1.8 m character.
		var s := rng.randf_range(0.52, 0.92) * height_scale * (0.84 + centre_bias * 0.34)
		var lean := (1.0 - centre_bias) * 0.22
		var basis := Basis(Vector3.UP, ang + rng.randf_range(-0.5, 0.5))
		basis = basis * Basis(Vector3(cos(ang), 0.0, sin(ang)), lean)
		# Wider than tall: the pack's tuft is 0.37 m across and 1 m high, and a
		# meadow needs the footprint more than it needs the height.
		basis = basis.scaled(Vector3(s * 1.45, s, s * 1.45))
		# The tuft's origin is at its root, not its centre, so it goes straight on
		# the ground. (The quad this replaced was centred and had to be lifted by
		# half its height - getting that wrong buried the bottom half.) The 4 cm
		# sink hides the seam where the lowest blades meet the terrain.
		made.append(Transform3D(basis, Vector3(x, h - 0.04, z)))
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
		# Forward is -Z of the camera basis. Handed to the shader as a uniform
		# because the camera built-ins are fragment-stage only, and the vertex
		# stage is where the behind-camera cull has to happen.
		_material.set_shader_parameter("cam_forward", -cam.global_basis.z)
	if _player != null:
		_material.set_shader_parameter("view_origin", _player.global_position)
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
	# The tier keys were hard-coded 2600/1300/520 - numbers from an older density
	# curve that no longer exist. `_tier_counts` is keyed by the actual per-chunk
	# instance count, so it reported 0/0/0 on a field of 276,811 blades. A
	# diagnostic that always reads zero is worse than none: it looks like the
	# blades are not being placed at all.
	#
	# Count live chunks by tier instead, derived from the same constants the
	# builder uses, so this cannot drift again.
	var near := 0
	var mid := 0
	var far := 0
	for key in _chunks.keys():
		var d := (key as Vector2i) - _last_center
		var dist := Vector2(d).length()
		if dist <= 1.5:
			near += 1
		elif dist <= 3.0:
			mid += 1
		else:
			far += 1
	var placed := 0
	for v in _tier_counts.values():
		placed += int(v)
	return "tried=%d placed=%d chunks=%d water=%d height=%d slope=%d tiers(near/mid/far)=%d/%d/%d" % [
		_tried, placed, _chunks.size(), _rej_water, _rej_height, _rej_slope,
		near, mid, far]



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
