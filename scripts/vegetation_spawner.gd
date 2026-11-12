extends Node3D
## Genshin-ish vegetation scatter for mobile: stylized pine trees, round
## wind-swept broadleaf trees, glowing flowers, rocks and a MultiMesh grass
## carpet. All meshes are procedural and batched with MultiMesh where possible.

@export var terrain_path: NodePath

const VegPresets := preload("res://scripts/performance/vegetation_presets.gd")
const VegMeshes := preload("res://scripts/performance/vegetation_meshes.gd")

const TREE_COUNT := 170
const PINE_COUNT := 130
const ROCK_COUNT := 100
const FLOWER_COUNT := 300
const LOG_COUNT := 46
const PEBBLE_COUNT := 900
const SPREAD := 330.0

var _time := 0.0
var _player: Node3D
## Distance culling for the heavy scatter groups (see _process).
var _scatter_roots: Array[Node3D] = []
## StaticBody3D trunks, tracked separately: they are physics objects, not draw
## calls, and _rebuild() has to free them or every quality change leaks a whole
## forest of collision shapes.
var _collision_bodies: Array[Node3D] = []
var _cull_timer := 0.0
## Retained for the render-server distance cull set up in _add_multimesh.
const CULL_NEAR := 190.0
## Fraction of the scatter that is actually instantiated, set by the quality
## tier. The spawner used to build the full count and the tier then hid the whole
## node - see World.apply_quality, which no longer does that.
var _detail := 1.0


var _built := false


## Called by the quality tuner. Safe to call before OR after the scatter exists:
## the counts are only read inside _ready(), so a late call rebuilds the scatter
## at the new density rather than silently doing nothing. World.apply_quality()
## runs after _ready() has been queued, and relying on that ordering to be the
## right way round is exactly the kind of bug that only shows up on one device.
func set_detail_scale(scale: float) -> void:
	var next := clampf(scale, 0.1, 1.0)
	if is_equal_approx(next, _detail):
		return
	_detail = next
	if _built:
		_rebuild()


func _scaled(base: int) -> int:
	return maxi(1, int(round(float(base) * _detail)))


func _ready() -> void:
	await get_tree().process_frame
	var terrain := get_node_or_null(terrain_path)
	if terrain == null or not terrain.has_method("get_height_at"):
		push_warning("VegetationSpawner: terrain missing")
		return
	_spawn_round_trees(terrain)
	_spawn_pines(terrain)
	_spawn_rocks(terrain)
	_spawn_flowers(terrain)
	_spawn_fallen_logs(terrain)
	_spawn_pebbles(terrain)
	_built = true


## Drop every scatter root and build again at the current detail level. Only
## used when the quality tier changes after the world is already standing.
func _rebuild() -> void:
	for root in _scatter_roots:
		if is_instance_valid(root):
			root.queue_free()
	_scatter_roots.clear()
	for body in _collision_bodies:
		if is_instance_valid(body):
			body.queue_free()
	_collision_bodies.clear()
	var terrain := get_node_or_null(terrain_path)
	if terrain == null or not terrain.has_method("get_height_at"):
		return
	_spawn_round_trees(terrain)
	_spawn_pines(terrain)
	_spawn_rocks(terrain)
	_spawn_flowers(terrain)
	_spawn_fallen_logs(terrain)
	_spawn_pebbles(terrain)


func _toon(color: Color, rim: float = 0.3) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/character/anime_toon.gdshader")
	m.set_shader_parameter("albedo_color", color)
	m.set_shader_parameter("shadow_tint", Color(0.55, 0.62, 0.88))
	m.set_shader_parameter("rim_color", Color(1.0, 0.95, 0.8))
	m.set_shader_parameter("rim_strength", rim)
	m.set_shader_parameter("diffuse_energy", 1.0)
	return m


## Toon material carrying a texture.
##
## The plain _toon() sets only albedo_color, so a merged tree was a flat vertex
## colour whatever UVs it had. This variant multiplies the same toon ramp by a
## painted texture, and tints it, which is how the bark and the leaf sheets get
## onto the geometry.
func _toon_tex(color: Color, tex_path: String, rim: float = 0.3,
		uv_scale: Vector2 = Vector2.ONE) -> ShaderMaterial:
	var m := _toon(color, rim)
	var tex := _load_tex(tex_path)
	if tex != null:
		# The toon shader has no uv_scale uniform, so the scale is baked into the
		# merged UVs by the caller instead. Only the sampler is set here.
		m.set_shader_parameter("albedo_tex", tex)
	return m


func _load_tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		push_warning("LastStar vegetation: missing texture " + path)
		return null
	var t := load(path)
	return t as Texture2D if t is Texture2D else null


func _pick(terrain: Node, rng: RandomNumberGenerator, min_h: float, max_h: float, max_slope: float, count: int, avoid_lake: bool = true) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var attempts := 0
	while out.size() < count and attempts < count * 22:
		attempts += 1
		var x := rng.randf_range(-SPREAD, SPREAD)
		var z := rng.randf_range(-SPREAD, SPREAD)
		# Bumped surface, so trees and rocks sit in the visible ground rather
		# than hovering over it (see TerrainGenerator.surface_height_at).
		var h: float = terrain.surface_height_at(x, z) if terrain.has_method("surface_height_at") \
			else terrain.get_height_at(x, z)
		if h < min_h or h > max_h:
			continue
		# Reject actual water rather than a circle around the lake centre:
		# the old radius test (78 m) also covered the spawn glade, because the
		# player starts 66 m from the lake centre. That left the whole starting
		# area as bare dirt with no trees, flowers or rocks.
		if avoid_lake and terrain.is_underwater(x, z):
			continue
		if terrain.get_slope_at(x, z) > max_slope:
			continue
		out.append(Vector3(x, h, z))
	return out


## --- batching helpers ---------------------------------------------------
##
## Everything below used to build its own MeshInstance3D per prop, and most of
## them spun up a brand-new primitive mesh per instance as well. On the Oppo
## that cost roughly 1,600 independent draw calls of vegetation, several
## thousand unique ArrayMesh uploads at boot, and - worst of the three - a
## fresh ShaderMaterial per material slot. Godot keys its shader cache on the
## material, so a new ShaderMaterial means the toon shader is compiled again,
## and the stalls landed exactly on the first frames of play.
##
## The fix is to build each prop's geometry ONCE, merge the parts that share a
## material into a single surface, and draw the whole population with one
## MultiMeshInstance3D per material. A tree is then one draw call for all of the
## trunks in the valley, one for the canopy, regardless of how many trees there
## are. Nothing is hidden, thinned or downgraded - the same 170 trees, in the
## same places, at the same size.

## Append `src`'s triangles into `arrays`, transformed by `xform`.
##
## Surfaces are accumulated by hand rather than with SurfaceTool because this
## also has to carry vertex normals through the transform; SurfaceTool would
## flatten the trees' shading to whatever winding the tool happened to produce.
func _append_arrays(arrays: Array, src: Array, xform: Transform3D) -> void:
	var verts: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = src[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX] if src[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var base := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var normal_basis := xform.basis.inverse().transposed()
	for v in verts:
		arrays[Mesh.ARRAY_VERTEX].append(xform * v)
	for n in norms:
		arrays[Mesh.ARRAY_NORMAL].append((normal_basis * n).normalized())
	# A normalised basis keeps the shape correct but can flip winding when the
	# transform has a negative determinant, so the order is fixed up here.
	# UVs. A source with none gets a planar projection so the bark grain still
	# appears on it rather than collapsing to texel (0,0).
	var uvs: PackedVector2Array = src[Mesh.ARRAY_TEX_UV] if src[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	if uvs.size() == verts.size():
		for uv in uvs:
			arrays[Mesh.ARRAY_TEX_UV].append(uv)
	else:
		for v in verts:
			var wv := xform * v
			arrays[Mesh.ARRAY_TEX_UV].append(Vector2(wv.x * 0.35, wv.y * 0.22))
	var flip := xform.basis.determinant() < 0.0
	if idx.is_empty():
		# Non-indexed source: emit sequential indices.
		for i in range(verts.size()):
			arrays[Mesh.ARRAY_INDEX].append(base + i)
	else:
		for i in range(0, idx.size(), 3):
			if flip:
				arrays[Mesh.ARRAY_INDEX].append(base + idx[i])
				arrays[Mesh.ARRAY_INDEX].append(base + idx[i + 2])
				arrays[Mesh.ARRAY_INDEX].append(base + idx[i + 1])
			else:
				arrays[Mesh.ARRAY_INDEX].append(base + idx[i])
				arrays[Mesh.ARRAY_INDEX].append(base + idx[i + 1])
				arrays[Mesh.ARRAY_INDEX].append(base + idx[i + 2])


func _new_arrays() -> Array:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	a[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	# UVs were never carried through the merge, so no texture could ever survive
	# it - trunk.png and leaf.png existed in assets/ and were loaded by nothing.
	# Every tree in the valley was a flat vertex colour because of this one
	# missing line, not because the textures were bad.
	a[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
	a[Mesh.ARRAY_INDEX] = PackedInt32Array()
	return a


func _arrays_to_mesh(arrays: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		return mesh
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Draw one MultiMesh for a whole population of props.
##
## `xforms` are already-posed instance transforms in world space. The material
## is shared across every instance, which is what makes this one draw call.
func _add_multimesh(node_name: String, mesh: Mesh, mat: Material,
		xforms: Array, cast_shadow: bool = true) -> MultiMeshInstance3D:
	if xforms.is_empty() or mesh.get_surface_count() == 0:
		return null
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = xforms.size()
	for i in range(xforms.size()):
		multimesh.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = multimesh
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# NOTE: deliberately no visibility_range_* here.
	#
	# On a MultiMeshInstance3D that range is evaluated for the batch, not for
	# each instance, so setting it would pop the entire forest out of the frame
	# at once instead of fading distant trees. The per-instance distance test
	# this replaces was a script loop over every prop four times a second, which
	# is the part that actually had to go; Godot's own frustum cull already
	# discards the instances behind the camera, and a batched batch is cheap
	# enough to submit whole.
	add_child(mmi)
	_scatter_roots.append(mmi)
	return mmi


## Build a merged mesh from a list of [mesh, local_transform] parts that all use
## the same material.
func _merge_parts(parts: Array) -> ArrayMesh:
	var arrays := _new_arrays()
	for part in parts:
		var m: Mesh = part[0]
		var xf: Transform3D = part[1]
		if m == null or m.get_surface_count() == 0:
			continue
		var src := m.surface_get_arrays(0)
		_append_arrays(arrays, src, xf)
	return _arrays_to_mesh(arrays)


## A low-poly cylinder, built once and reused. Primitive meshes used to be
## constructed inside the spawn loops, so a valley of 170 trees allocated 170
## separate CylinderMesh resources that were never shared.
func _make_cylinder(top_r: float, bot_r: float, height: float, sides: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top_r
	c.bottom_radius = bot_r
	c.height = height
	c.radial_segments = sides
	c.rings = 1
	return c


func _make_sphere(radius: float, height_ratio: float, segments: int, rings: int) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0 * height_ratio
	s.radial_segments = segments
	s.rings = rings
	return s


## Cards hung around the rim of each cone layer, for pines.
##
## Positioned to sit just under the widest part of each cone, angled downward and
## outward - the silhouette of a real conifer is a ragged skirt, not a cone.
func _pine_skirts() -> Array:
	var parts: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 4409
	for layer in range(4):
		var cone_r := 1.5 - layer * 0.28
		var y := 2.2 + layer * 0.78
		var ring := 7 + layer
		for i in range(ring):
			var ang := TAU * float(i) / float(ring) + rng.randf_range(-0.3, 0.3)
			var r := cone_r * rng.randf_range(0.80, 1.06)
			var pos := Vector3(cos(ang) * r, y - rng.randf_range(0.0, 0.22), sin(ang) * r)
			var card := _make_card(rng.randf_range(0.40, 0.70))
			# Facing outward and down.
			var outward := Vector3(cos(ang), 0.0, sin(ang))
			var n := (outward * 0.6 - Vector3.UP * 0.45).normalized()
			var right := Vector3.UP.cross(n).normalized()
			var b := Basis(right, n, right.cross(n).normalized())
			b = b * Basis(Vector3.RIGHT, rng.randf_range(-0.5, 0.5))
			parts.append([card, Transform3D(b, pos)])
	return parts


## A shell of leaf cards around an ellipsoid crown.
##
## Each card is a quad, placed on the crown surface and turned to face outward and
## slightly upward - leaves grow toward the light, and cards aligned to the
## normal alone read as spikes. The offsets are jittered so the crown has a ragged
## edge rather than the clean rim of a sphere.
func _leaf_shell(count: int, radius: float, height: float, centre_y: float) -> Array:
	var parts: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 8123
	for i in range(count):
		# Fibonacci sphere: even coverage with no clumping, unlike random angles.
		var t := (float(i) + 0.5) / float(count)
		var phi := acos(1.0 - 2.0 * t)
		var theta := PI * (1.0 + sqrt(5.0)) * float(i)
		var dir := Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
		# Flattened upward: the crown is taller than it is wide.
		var pos := Vector3(dir.x * radius, dir.y * height * 0.55, dir.z * radius) \
			+ Vector3(0.0, centre_y, 0.0)
		# Skip the underside. Cards there are never seen, and they double the
		# overdraw of the whole forest.
		if pos.y < centre_y - height * 0.30:
			continue
		var card := _make_card(rng.randf_range(0.55, 0.95))
		# Face outward, tilted up by a random amount so the shell is not a sphere.
		var up := Vector3.UP
		var outward := dir.normalized()
		if absf(outward.dot(up)) > 0.98:
			outward = Vector3.RIGHT
		var right := up.cross(outward).normalized()
		var fwd := right.cross(up).normalized()
		# Bias the facing toward the sky and jitter the roll.
		var n := (outward * 0.7 + Vector3.UP * rng.randf_range(0.25, 0.7)).normalized()
		var b := Basis(right, n, right.cross(n).normalized())
		b = Basis(Vector3.UP, rng.randf_range(-0.6, 0.6)) * b
		b = b * Basis(Vector3.RIGHT, rng.randf_range(-0.4, 0.4))
		parts.append([card, Transform3D(b, pos)])
	return parts


## One unit leaf card, centred on its origin, carrying a slice of the leaf sheet.
##
## The leaf texture is a horizontal strip of five different leaves. Each card
## samples its own fifth, so a crown shows a mix of leaf shapes instead of 26
## copies of the same one. That is the whole point of the strip, and a UV of 0..1
## across it would have shown all five squashed onto every card.
func _make_card(size: float, slice_index: int = -1) -> Mesh:
	var idx := slice_index
	if idx < 0:
		idx = randi() % 5
	var u0 := float(idx) / 5.0
	var u1 := float(idx + 1) / 5.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := size
	var w := size * 0.8
	var quad := [
		[Vector3(-w * 0.5, -h * 0.5, 0), Vector2(u0, 1)],
		[Vector3(w * 0.5, -h * 0.5, 0), Vector2(u1, 1)],
		[Vector3(w * 0.5, h * 0.5, 0), Vector2(u1, 0)],
		[Vector3(-w * 0.5, h * 0.5, 0), Vector2(u0, 0)],
	]
	var order := [0, 1, 2, 0, 2, 3]
	for o in order:
		st.set_normal(Vector3(0, 0, 1))
		st.set_uv(quad[o][1])
		st.add_vertex(quad[o][0])
	return st.commit()


func _spawn_round_trees(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 771
	var spots := _pick(terrain, rng, 3.0, 78.0, 0.85, _scaled(TREE_COUNT))
	if spots.is_empty():
		return

	# Three parts, three materials, three draw calls for the entire forest:
	# trunks, and each of the two canopy tints.
	var trunk_mesh := _merge_parts([
		[_make_cylinder(0.16, 0.3, 3.2, 8), Transform3D(Basis(), Vector3(0, 1.6, 0))],
	])
	# Canopy: a core of three lobes, wrapped in leaf cards.
	#
	# It used to be three bare spheres. A sphere with a flat colour is the single
	# most recognisable placeholder in a stylised game - it has no silhouette
	# break, no leaf shapes, and no texture, so a forest of them reads as green
	# balls on sticks. The lobes stay, because they give the crown its mass and
	# its shadow; the cards provide the outline and the leaves.
	var lobes := [
		[_make_sphere(1.5, 1.55 * 0.5, 8, 5), Transform3D(Basis(), Vector3(0, 3.3, 0))],
		[_make_sphere(1.2, 1.55 * 0.5, 8, 5), Transform3D(Basis(), Vector3(0, 4.15, 0))],
		[_make_sphere(0.9, 1.55 * 0.5, 8, 5), Transform3D(Basis(), Vector3(0, 5.0, 0))],
	]
	var canopy_a := _merge_parts(lobes)
	# A slightly lighter tint gets its own batch rather than a per-tree material.
	var canopy_b := canopy_a

	# The leaf-card shell. Built once and instanced on every tree.
	#
	# Cards are placed on the surface of an ellipsoid and turned to face outward,
	# which is what makes the crown read as a cluster of leaves from any angle
	# instead of as a solid lump with a texture wrapped round it. 26 cards is
	# enough to break the silhouette; more just costs overdraw at the distances
	# these trees are seen.
	var leaf_cards := _merge_parts(_leaf_shell(26, 1.55, 2.05, 3.95))

	var trunk_xf: Array = []
	var leaf_a_xf: Array = []
	var leaf_b_xf: Array = []
	var card_a_xf: Array = []
	var card_b_xf: Array = []

	for i in range(spots.size()):
		var s := rng.randf_range(0.8, 1.6)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s)
		var xf := Transform3D(basis, spots[i])
		trunk_xf.append(xf)
		if i % 2 == 0:
			leaf_a_xf.append(xf)
			card_a_xf.append(xf)
		else:
			leaf_b_xf.append(xf)
			card_b_xf.append(xf)

		# Trunk collision so the player can't run through the big ones. These are
		# still individual bodies - a StaticBody3D per tree is a physics-space
		# cost, not a draw call, and carving the trunks out of the terrain's
		# collision would cost far more to build and to query.
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var col := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = 0.32 * s
		shape.height = 3.2 * s
		col.shape = shape
		col.position.y = 1.6 * s
		body.add_child(col)
		body.position = spots[i]
		body.name = "TreeBody_%d" % i
		add_child(body)
		_collision_bodies.append(body)

	# Textures, finally. trunks sample the bark, canopies a leaf tile. Before
	# this every one of these was a flat albedo_color and the two painted
	# textures in assets/ were loaded by nothing at all.
	_add_multimesh("BroadleafTrunks", trunk_mesh,
		_toon_tex(Color(0.72, 0.62, 0.55), "res://assets/environment/trees/trunk.png", 0.28), trunk_xf)
	_add_multimesh("BroadleafCanopyA", canopy_a,
		_toon_tex(Color(0.40, 0.72, 0.34), "res://assets/environment/leaves/leaf.png", 0.45), leaf_a_xf)
	_add_multimesh("BroadleafCanopyB", canopy_b,
		_toon_tex(Color(0.50, 0.82, 0.38), "res://assets/environment/leaves/leaf.png", 0.45), leaf_b_xf)
	# The card shell is alpha-cut, so it needs the foliage shader rather than the
	# opaque toon one.
	var card_mat := VegPresets.material_for("leaves", 0.30, Color(0.84, 1.0, 0.80))
	card_mat.set_shader_parameter("albedo_texture", _load_tex("res://assets/environment/leaves/leaf.png"))
	_add_multimesh("BroadleafCardsA", leaf_cards, card_mat, card_a_xf, false)
	_add_multimesh("BroadleafCardsB", leaf_cards, card_mat, card_b_xf, false)


func _spawn_pines(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 515
	var spots := _pick(terrain, rng, 6.0, 120.0, 1.1, _scaled(PINE_COUNT))
	if spots.is_empty():
		return

	var trunk_mesh := _merge_parts([
		[_make_cylinder(0.1, 0.24, 2.6, 7), Transform3D(Basis(), Vector3(0, 1.3, 0))],
	])
	# Four stacked cones, merged into one surface.
	var cone_parts: Array = []
	for layer in range(4):
		cone_parts.append([
			_make_cylinder(0.0, 1.5 - layer * 0.28, 1.5 - layer * 0.18, 8),
			Transform3D(Basis(), Vector3(0, 2.2 + layer * 0.78, 0)),
		])
	var cone_mesh := _merge_parts(cone_parts)

	var trunk_xf: Array = []
	var cone_a_xf: Array = []
	var cone_b_xf: Array = []
	for i in range(spots.size()):
		var s := rng.randf_range(0.9, 1.7)
		var sy := s * rng.randf_range(1.0, 1.5)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, sy, s))
		var xf := Transform3D(basis, spots[i])
		trunk_xf.append(xf)
		if i % 2 == 0:
			cone_a_xf.append(xf)
		else:
			cone_b_xf.append(xf)

	# Bark texture on the trunks, and a ragged skirt of cards around each cone
	# layer. A pine of smooth cones is a Christmas-tree icon; the cards break the
	# straight cone rim, which is the only thing that reads as needles at range.
	var skirt := _merge_parts(_pine_skirts())
	var skirt_a_xf: Array = []
	var skirt_b_xf: Array = []
	for i in range(cone_a_xf.size()):
		skirt_a_xf.append(cone_a_xf[i])
	for i in range(cone_b_xf.size()):
		skirt_b_xf.append(cone_b_xf[i])

	_add_multimesh("PineTrunks", trunk_mesh,
		_toon_tex(Color(0.78, 0.66, 0.56), "res://assets/environment/trees/trunk_stripped.png", 0.26), trunk_xf)
	_add_multimesh("PineConesA", cone_mesh,
		_toon_tex(Color(0.52, 0.86, 0.58), "res://assets/environment/leaves/leaf.png", 0.4), cone_a_xf)
	_add_multimesh("PineConesB", cone_mesh,
		_toon_tex(Color(0.60, 0.94, 0.62), "res://assets/environment/leaves/leaf.png", 0.4), cone_b_xf)
	var needle_mat := VegPresets.material_for("border_grass", 0.18, Color(0.78, 1.0, 0.76))
	needle_mat.set_shader_parameter("albedo_texture", _load_tex("res://assets/environment/leaves/leaf.png"))
	_add_multimesh("PineSkirtsA", skirt, needle_mat, skirt_a_xf, false)
	_add_multimesh("PineSkirtsB", skirt, needle_mat, skirt_b_xf, false)


func _spawn_rocks(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 313
	var spots := _pick(terrain, rng, 0.6, 140.0, 1.6, _scaled(ROCK_COUNT), false)
	if spots.is_empty():
		return
	# One rock mesh, one material, one draw call for every boulder in the valley.
	var rock_mesh := _merge_parts([
		[_make_sphere(1.0, 1.3, 7, 4), Transform3D(Basis(), Vector3(0, 0.35, 0))],
	])
	var xfs: Array = []
	for p in spots:
		var r := rng.randf_range(0.5, 1.8)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.rotated(Vector3.RIGHT, rng.randf_range(-0.3, 0.3))
		basis = basis.rotated(Vector3.FORWARD, rng.randf_range(-0.3, 0.3))
		basis = basis.scaled(Vector3(r, r * rng.randf_range(0.6, 1.0), r))
		xfs.append(Transform3D(basis, p))
	_add_multimesh("Rocks", rock_mesh, _toon(Color(0.62, 0.62, 0.68), 0.35), xfs)


func _spawn_flowers(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var spots := _pick(terrain, rng, 2.0, 60.0, 0.7, _scaled(FLOWER_COUNT))
	if spots.is_empty():
		return
	# One mesh holding stem + bloom, batched per colour. Four draw calls total
	# instead of 300 flowers x 2 meshes plus a fresh emissive StandardMaterial
	# for every single bloom.
	var flower_mesh := _merge_parts([
		[_make_cylinder(0.015, 0.02, 0.3, 4), Transform3D(Basis(), Vector3(0, 0.15, 0))],
		[_make_sphere(0.09, 0.12 / 0.18, 6, 3), Transform3D(Basis(), Vector3(0, 0.32, 0))],
	])
	var colors := [
		Color(0.55, 0.85, 1.0),
		Color(1.0, 0.78, 0.9),
		Color(1.0, 0.95, 0.6),
		Color(0.75, 0.6, 1.0),
	]
	var buckets: Array = []
	for c in colors:
		buckets.append([])
	for i in range(spots.size()):
		var s := rng.randf_range(0.8, 1.4)
		var xf := Transform3D(
			Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), spots[i])
		buckets[i % colors.size()].append(xf)
	for c in range(colors.size()):
		_add_multimesh("Flowers_%d" % c, flower_mesh, _toon(colors[c], 0.5),
			buckets[c], false)


func _spawn_fallen_logs(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 771
	var spots := _pick(terrain, rng, 3.0, 70.0, 0.9, _scaled(LOG_COUNT))
	if spots.is_empty():
		return
	# Logs were 2-3 meshes each with a randomised length and radius, which meant
	# a unique CylinderMesh per log. A unit cylinder scaled per instance gives
	# the same variety for one draw call.
	var log_mesh := _merge_parts([
		[_make_cylinder(1.0, 1.0, 1.0, 8), Transform3D()],
	])
	var xfs: Array = []
	for p in spots:
		var log_len := rng.randf_range(2.6, 6.5)
		var log_r := rng.randf_range(0.18, 0.34)
		var yaw := rng.randf() * TAU
		var tilt := rng.randf_range(-0.12, 0.12)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, PI * 0.5 + tilt)
		basis = basis.scaled(Vector3(log_r, log_len, log_r))
		xfs.append(Transform3D(basis, p + Vector3(0, log_r * 0.85, 0)))
	_add_multimesh("FallenLogs", log_mesh,
		_toon_tex(Color(0.86, 0.74, 0.62), "res://assets/environment/wood/wood.png", 0.18), xfs)


func _spawn_pebbles(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 977
	var spots := _pick(terrain, rng, 1.2, 90.0, 1.0, _scaled(PEBBLE_COUNT))
	if spots.is_empty():
		return
	var pebble_mesh := _merge_parts([
		[_make_sphere(0.16, 0.22 / 0.32, 6, 3), Transform3D()],
	])
	var xfs: Array = []
	for p in spots:
		var s := rng.randf_range(0.5, 1.6)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(s, s * rng.randf_range(0.5, 0.9), s))
		xfs.append(Transform3D(b, p + Vector3(0, 0.04 * s, 0)))
	_add_multimesh("Pebbles", pebble_mesh,
		_toon(Color(0.58, 0.57, 0.56), 0.25), xfs, false)


## Draw-call and instance census, for the probe and the performance tuner.
func diagnostics() -> String:
	var mmi_count := 0
	var instances := 0
	for n in _scatter_roots:
		if n is MultiMeshInstance3D and is_instance_valid(n):
			mmi_count += 1
			instances += (n as MultiMeshInstance3D).multimesh.instance_count
	return "vegetation: %d batched draw calls, %d instances" % [mmi_count, instances]
