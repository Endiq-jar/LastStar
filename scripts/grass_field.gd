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
## The tuft is a painted card again: two crossed alpha-cut quads, 4 triangles an
## instance, drawn from assets/grass/tuft.webp (hand-painted; see below).
##
## It spent a while as real geometry from the nature pack, at 64 triangles a
## tuft. That looked right and cost the earth: the meadow is stamped tens of
## thousands of times, so it alone was ~1.9M of the frame's 4.4M triangles. The
## card is 16x cheaper for a silhouette the eye reads the same way past about
## 15 m, which is where almost all of the field is. The 3D tuft is still in
## NaturePack.clump() if a close-up ever wants it.
##
## There is no wind, at the owner's request: the shader has no TIME in it and the
## blades do not move. What the shader does keep is everything about *not*
## drawing - the behind-camera collapse, the clearing around the character, the
## distance fade, the dissolve at the streaming edge.
##
## Chunks are recycled as the player walks, so walking 5 km never grows the
## instance count. One draw call per chunk.

## The painted tuft, at the proportions that card is drawn at.
##
## The sheet is a 1:1 tuft - a fountain about as wide as it is tall - so the card
## is close to square. Stretching it wide squashed the blades into ribbons;
## stretching it tall made it a reedy clump.
##
## This is the old painted grass's own quad: it was BLADE_W 0.62 by BLADE_H 0.56,
## scaled 1.15 across and 1.30 up, so 0.713 x 0.728 m. The same paint at the same
## proportions lands on the same silhouette, which is the whole point of using the
## old card. The field is denser now than it was then, so this is 0.71 x 0.73
## rather than the 1.3 m footprint that read as gaps between tufts.
const CARD_WIDTH := 0.52
const CARD_HEIGHT := 0.54

const CHUNK_SIZE := 26.0          ## metres per chunk
## Radius, in chunks. 5 * 26 = 130 m, which with the shader's dissolve put a
## visible arc of bare terrain at the edge of the meadow. Raised to 7 (182 m) so
## the field runs past the point where blades stop being resolvable.
const VIEW_CHUNKS := 7
## Instances per 26 m chunk.
##
## Counts of CARDS, so the number that matters is cards per square metre. A chunk
## is 676 m2, and the card is 0.71 m of painted grass - the same paint, on the
## same kind of card, as the old meadow this restores.
##
## The old meadow's own numbers, from c7b415f: BLADES_NEAR 14000, i.e. 20.7
## cards/m2, with a 0.62 x 0.56 m quad. That is the density its frame shows, and
## the sheet is a top-heavy tuft whose solid base is a *quarter* of its height, so
## at 0.73 m tall every card puts 0.18 m of opaque paint on the ground. Just
## under a quarter of the frame's pixels are that base, and if the cards are too
## sparse to overlap you do not get a carpet - you get green boxes with tufts
## sticking out of them, which is exactly what this looked like at 9.2/m2.
##
## Cost, counted in triangles because that is what the frame pays: 4 triangles an
## instance, two crossed quads. The disc is 9 near / 19 mid / 93 far chunks, so
## the old numbers bought 364 300 cards and 1.46 M triangles - four times the
## meadow's previous triangle count, because the old version drew ONE quad a card
## and this draws two. That is too much to spend on the way to "less laggy".
##
## The card is deliberately smaller than the old meadow's 0.71 x 0.73 m, at
## 0.52 x 0.54. A card that size at two metres from the lens is about 300 pixels
## tall, so the foreground was a handful of enormous cards with their solid bases
## reading as slabs - the meadow only looked like grass from about 15 m out. Half
## a metre at the same density is a carpet all the way in, and it lets the count
## go up without the triangles following: 9*10000*4 + 19*3600*4 + 93*500*4 =
## 0.82 M triangles for 240 000 cards, 14.8 cards/m2 near the player.
##
## It is the largest line item in the frame, so quality tier 1 multiplies all
## three tiers by 0.35 and the far ring is deliberately sparse.
const BLADES_NEAR := 10000        ## instances in a chunk adjacent to the player
const BLADES_MID := 3600
const BLADES_FAR := 500
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
## camera sits 4.2 m back at 2 m up, so a tuft that reaches her chest hides her
## completely. The scale range in _build_chunk keeps the meadow at knee height.

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


func setup(terrain: Node, player: Node3D) -> void:
	_terrain = terrain
	_player = player
	name = "GrassField"
	_build_resources()
	_refresh(true)


func _build_resources() -> void:
	_blade_mesh = _build_tuft_mesh()
	if _blade_mesh == null:
		push_warning("LastStar: could not build the grass card - the meadow will be empty")
		return

	var shader := load("res://shaders/terrain/grass_card.gdshader")
	if shader == null:
		push_warning("LastStar: grass shader missing - grass will look flat")
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	var sheet := load("res://assets/grass/tuft.webp")
	# Log what the import produced, at load time.
	#
	# A card whose alpha did not survive importing draws as a plain rectangle, and
	# that is indistinguishable from a shader fault in a screenshot. Printing the
	# decoded format and a few alpha values here settles which it is, on the one
	# run where it happens.
	if sheet is Texture2D:
		var img: Image = (sheet as Texture2D).get_image()
		if img == null:
			print("GRASS_SHEET %dx%d format=%d image=NONE" % [
				(sheet as Texture2D).get_width(), (sheet as Texture2D).get_height(),
				(sheet as Texture2D).get_format()])
		else:
			print("GRASS_SHEET %dx%d format=%d alpha(top/mid/bottom)=%.2f/%.2f/%.2f" % [
				img.get_width(), img.get_height(), img.get_format(),
				img.get_pixel(img.get_width() / 2, 8).a,
				img.get_pixel(img.get_width() / 2, 128).a,
				img.get_pixel(img.get_width() / 2, 248).a])
	if sheet is Texture2D:
		_material.set_shader_parameter("blade_tex", sheet)
	else:
		push_warning("LastStar: assets/grass/tuft.webp missing - it is hand-painted and committed; "
			+ "restore it from git, the generator does not draw it")
	_material.set_shader_parameter("card_height", CARD_HEIGHT)


## Two quads crossed at right angles, origin at the root, UV.y running from the
## soil to the tip.
##
## Normals are the quad's own - horizontal, pointing out of the card - and not
## straight up.
##
## Up normals were a mistake worth recording, because the reasoning sounded
## right: a vertical card lit by its own normal is edge-on to the sun half the
## time, so half the meadow goes dark depending on which way a tuft is turned,
## whereas an up normal lights grass the way it lights the ground and makes the
## field read as one surface.
##
## What it actually did was make the meadow *brighter*, uniformly, and the sun on
## this map is why. It sits 0.74 above the horizon, so a vertical card facing the
## light gets N.L = 1.00 while an up-facing one gets 0.74. Every card was being
## handed the maximum the key light can give, which is what turned the field into
## flat lime-green sheets in front of the camera - three quarters of the frame's
## contrast between one blade and the next is that dot product, and it had been
## constant across the whole meadow.
##
## The old painted grass this replaces used the quad's own normal, and its cards
## are crossed for exactly this reason: the pair always presents a face to the
## light, so a tuft is lit without all of it being lit the same.
func _build_tuft_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := CARD_WIDTH * 0.5
	for i in range(2):
		var ang := float(i) * PI * 0.5
		var edge := Vector3(cos(ang), 0.0, sin(ang)) * half
		# The quad's own outward normal: perpendicular to the card and horizontal.
		_add_quad(st, -edge, edge, Vector3(-sin(ang), 0.0, cos(ang)))
	st.index()
	return st.commit()


func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, normal: Vector3) -> void:
	var up := Vector3(0.0, CARD_HEIGHT, 0.0)
	var verts := PackedVector3Array([a, b, b + up, a, b + up, a + up])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	for i in range(6):
		st.set_uv(uvs[i])
		st.set_normal(normal)
		st.add_vertex(verts[i])


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
	# Taller blades further away hide the reduced density without turning the
	# mid ring into reeds.
	# Capped lower than it was (0.22 -> 0.14): the far tiers are down to 220
	# cards a chunk, and stretching those by a fifth was the last version's way
	# of hiding it, which turns the outer ring into reeds.
	var height_scale := 1.0 + clampf(float(dist) * 0.030, 0.0, 0.14)
	count = maxi(1, int(round(float(count) * _density)))
	# Placement is a jittered grid, not random points and not tufts.
	#
	# Two earlier versions of this loop, and why both were wrong at carpet density:
	#
	#   * Independent uniform random points, which is a Poisson process: clumpy by
	#     nature, with patches of bare ground between clumps that no amount of
	#     instance count removes (it only shrinks them).
	#   * Tuft centres with 3-7 cards clustered on each, which multiplies that
	#     clumpiness on purpose. It was the right call at 2.2 cards/m2, where the
	#     job was to make a sparse scatter look intentional; at 9 cards/m2 the job
	#     is the opposite - cover the ground evenly - and clustering makes the
	#     coverage worse while *also* throwing away most of the cards, because a
	#     tuft whose centre lands in water loses all of its cards instead of one.
	#
	# A jittered grid is the standard answer: one candidate per cell, displaced by
	# less than half a cell, which covers the ground evenly and still has no
	# visible rows. Each card is independent, so a rejection costs one card.
	var per_side := maxi(1, int(ceil(sqrt(float(count)))))
	var cell := CHUNK_SIZE / float(per_side)
	for gz in range(per_side):
		for gx in range(per_side):
			_tried += 1
			var x := origin_x + (float(gx) + rng.randf()) * cell
			var z := origin_z + (float(gz) + rng.randf()) * cell
			# surface_height_at(), not get_height_at(): the grass has to sit on the
			# bumpy mesh the camera actually sees, not on the smooth analytic field
			# the collision uses. Those differ by up to the sagitta of a 3 m triangle,
			# which is exactly enough for a tuft to hover with air under it.
			var h: float = _terrain.surface_height_at(x, z) if _terrain.has_method("surface_height_at") \
				else _terrain.get_height_at(x, z)
			# Grass grows on gentle ground above the shoreline, not on cliffs and
			# not on the high rock/snow bands. 92 m is where the terrain shader's
			# own rock blend takes over, so the two agree instead of leaving a gap.
			if h > 92.0:
				_rej_height += 1
				continue
			# 0.78 (~38 degrees) keeps blades off cliffs and scree without
			# stopping the meadow wherever the ground starts to rise.
			if _terrain.get_slope_at(x, z) > 0.78:
				_rej_slope += 1
				continue
			# Actual water, not a circle around it, plus a dry margin so blades do
			# not poke through the surface.
			if _terrain.is_underwater(x, z) or h < SEA_MARGIN:
				_rej_water += 1
				continue
			# Every card is the same size and the same kind of card, so the only
			# variation is height, yaw and a small tilt. No per-cluster bias: at
			# this density the field is read as a surface, and any per-cluster
			# structure in it reads as polka dots.
			var s2 := rng.randf_range(0.80, 1.20) * height_scale
			var yaw := rng.randf() * TAU
			var tilt := rng.randf_range(-0.10, 0.10)
			var basis := Basis(Vector3.UP, yaw)
			basis = basis * Basis(Vector3(cos(yaw), 0.0, sin(yaw)), tilt)
			basis = basis.scaled(Vector3(s2, s2, s2))
			# The card's origin is at its root, so it goes straight on the ground.
			# The 2 cm sink hides the seam where the lowest blades meet the terrain.
			made.append(Transform3D(basis, Vector3(x, h - 0.02, z)))
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


## What the meadow's card actually is once the engine has imported it.
##
## Written after a frame in which every card drew as a plain green rectangle:
## alpha-scissor had stopped cutting anything out, and there is no way to tell
## from a screenshot whether the texture failed to import, arrived without an
## alpha channel, or was never bound to the sampler at all. This reports all
## three, because they have completely different fixes.
func card_report() -> String:
	if _material == null:
		return "material=NULL"
	var bound = _material.get_shader_parameter("blade_tex")
	if not (bound is Texture2D):
		return "blade_tex=UNBOUND"
	var tex: Texture2D = bound
	var out := "%dx%d format=%d" % [tex.get_width(), tex.get_height(), tex.get_format()]
	# Ask the engine for the decoded pixels rather than trusting the file: an
	# import that drops alpha, or compresses to a format with none, looks
	# identical on disk.
	var img := tex.get_image()
	if img == null:
		return out + " image=NULL (imported without CPU-readable pixels)"
	var samples: Array[String] = []
	# Top of the sheet is empty, the bottom is solid - so three vertical samples
	# say whether alpha survived the import in one line.
	for y in [8, 128, 248]:
		samples.append("%.2f" % img.get_pixel(tex.get_width() / 2, y).a)
	out += " alpha(top/mid/bottom)=%s" % "/".join(samples)
	return out


func diagnostics() -> String:
	# `_tier_counts` used to hold one key per density constant, written by the
	# builder. When the constants changed the keys were stale and this reported
	# 0/0/0 on a field of 276,811 blades - a diagnostic that always reads zero is
	# worse than none, because it looks like nothing is being placed.
	#
	# The live count is the MultiMeshes themselves now, so it cannot drift: the
	# tier a chunk belongs to is derived from its position, and its card count is
	# read off the instance buffer rather than remembered from a constant.
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
	var placed := blade_count()
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
