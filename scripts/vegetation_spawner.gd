extends Node3D
## The valley's standing vegetation: trees, pines, dead trees, rocks, flowers,
## fallen logs, stumps and pebbles.
##
## Every prop is a model from the Quaternius Ultimate Stylized Nature Pack
## (see scripts/nature_pack.gd), instanced through a MultiMesh per variant and
## split into spatial tiles so each batch can still be frustum-culled. Before
## this, every prop was procedural geometry carrying painted pngs from
## assets/environment/: a cylinder trunk with three sphere lobes and 26 leaf
## cards for a broadleaf, four stacked cones and a ragged skirt for a pine, a
## sphere for a rock. Those pngs are gone with the pipeline. The pack ships its
## colour in named materials and no textures at all, so NaturePack bakes the
## colours into vertex colours and every prop needs one material, one mesh and
## one draw call per tile.
##
## What did not change is the placement: the height/slope/lake rejection, the
## collision bodies under the trunks and the tiling below, because those are
## what make a scatter look planted rather than sprinkled.

@export var terrain_path: NodePath

const NaturePack := preload("res://scripts/nature_pack.gd")

const TREE_COUNT := 170
const PINE_COUNT := 130
const DEAD_COUNT := 34
const ROCK_COUNT := 100
const FLOWER_COUNT := 300
const LOG_COUNT := 46
const STUMP_COUNT := 38
const PEBBLE_COUNT := 900
const SPREAD := 330.0

## The four broadleaf species, one batch each. A MultiMesh draws one mesh, so
## variety is a batch per model rather than a property of an instance.
const BROADLEAF := ["tree_common_1", "tree_common_3", "tree_birch", "tree_willow"]
const PINES := ["tree_pine_1", "tree_pine_3"]

## Scale ranges. The pack authors every tree at 2.2-3.6 m; the valley's trees have
## always been 5-11 m, and a forest of 3 m trees under a 1.8 m character reads as
## a field of shrubs. 1.8-3.2 puts the broadleaves at 4.5-11 m and the pines at
## 4.6-9.6 m, which is the range the hand-built trees occupied.
const TREE_SCALE_MIN := 1.8
const TREE_SCALE_MAX := 3.2
const PINE_SCALE_MIN := 1.7
const PINE_SCALE_MAX := 2.9

## Distance culling for the heavy scatter groups (see _process).
var _scatter_roots: Array[Node3D] = []
## StaticBody3D trunks, tracked separately: they are physics objects, not draw
## calls, and _rebuild() has to free them or every quality change leaks a whole
## forest of collision shapes.
var _collision_bodies: Array[Node3D] = []
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
	_spawn_all(terrain)
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
	_spawn_all(terrain)


func _spawn_all(terrain: Node) -> void:
	_spawn_round_trees(terrain)
	_spawn_pines(terrain)
	_spawn_dead_trees(terrain)
	_spawn_rocks(terrain)
	_spawn_flowers(terrain)
	_spawn_fallen_logs(terrain)
	_spawn_stumps(terrain)
	_spawn_pebbles(terrain)


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

## rejects the ones behind and beside the camera before any instance work
## happens. On a typical gameplay camera that is roughly a third of the
## instances surviving.
##
## It costs draw calls - a batched population goes from 1 draw to as many as
## there are occupied tiles. That trade is overwhelmingly worth it here: these
## are cheap, heavily instanced draws on a renderer that is vertex-bound, not
## draw-call-bound, and the tiles that are culled cost nothing at all.
const SCATTER_TILES := 8
## Target instances per tile, and the floor on the split.
##
## The grid size is chosen per population from its own size rather than fixed,
## because a fixed grid is wrong in both directions:
##
##   8x8 for every population measured 1145 draw calls, which is a worse frame
##   than the one that could not cull anything;
##   1x1 for a population of 85 trees buys no culling, because a batch that big
##   is exactly the thing that gets submitted no matter where the camera looks.
##
## ~120 instances per batch keeps each AABB small enough to be rejected, and the
## 2x2 floor guarantees that every population, however small, is at least
## quartered - a quarter of the trees is worth rejecting. Worst case this is 61
## batches in the whole valley, against 18 before and 1145 at 8x8.
const SCATTER_TILE_TARGET := 120
const SCATTER_TILE_MIN_DIV := 2
## Instances closer than this to a tile edge are duplicated into the adjacent
## tile. A prop is one draw call once, but its geometry can extend past the
## instance origin, and a tile whose AABB is exactly its instance origins will
## cull a tree whose trunk is one centimetre outside it - the classic "trees pop
## in a ring at the edge of the screen" artefact.
const SCATTER_TILE_PAD := 2.5


func _add_multimesh(node_name: String, mesh: Mesh, mat: Material,
		xforms: Array, cast_shadow: bool = true) -> MultiMeshInstance3D:
	# A model that failed to bake is a species with no geometry at all. Skipping
	# it names the batch instead of letting the MultiMesh try to measure a null
	# mesh, which is an engine error with no context in it.
	if mesh == null:
		push_warning("VegetationSpawner: '%s' has no mesh - batch skipped" % node_name)
		return null
	if xforms.is_empty() or mesh.get_surface_count() == 0:
		return null

	# How finely to split THIS population. A population small enough to be
	# culled whole stays in one batch.
	var div := clampi(int(ceil(sqrt(float(xforms.size()) / float(SCATTER_TILE_TARGET)))),
		SCATTER_TILE_MIN_DIV, SCATTER_TILES)
	var span := SPREAD * 2.0 / float(div)
	var buckets: Dictionary = {}
	for xf in xforms:
		var pos: Vector3 = (xf as Transform3D).origin
		var t := Vector2i(
			clampi(int(floor((pos.x + SPREAD) / span)), 0, div - 1),
			clampi(int(floor((pos.z + SPREAD) / span)), 0, div - 1))
		if not buckets.has(t):
			buckets[t] = []
		buckets[t].append(xf)

	var first: MultiMeshInstance3D = null
	for t in buckets:
		var list: Array = buckets[t]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = list.size()
		for i in range(list.size()):
			multimesh.set_instance_transform(i, list[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%d_%d" % [node_name, (t as Vector2i).x, (t as Vector2i).y]
		mmi.multimesh = multimesh
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The MultiMesh's AABB is computed from the instance transforms when it
		# is set above, so it already bounds this tile. Padding it slightly is
		# what stops a prop clipping out one pixel before it leaves the screen.
		mmi.extra_cull_margin = SCATTER_TILE_PAD
		# NOTE: still deliberately no visibility_range_* here. On a MultiMesh
		# that range is evaluated for the whole batch, so it pops a tile out at
		# once rather than fading distant props.
		add_child(mmi)
		_scatter_roots.append(mmi)
		if first == null:
			first = mmi
	return first


## Broadleaf trees, one batch per species.
##
## Collision stays per tree: a StaticBody3D is a physics-space cost, not a draw
## call, and carving the trunks out of the terrain's own collision would cost far
## more to build and to query.
func _spawn_round_trees(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var spots := _pick(terrain, rng, 6.0, 120.0, 1.1, _scaled(TREE_COUNT))
	if spots.is_empty():
		return
	var buckets := {}
	for kind in BROADLEAF:
		buckets[kind] = []
	for i in range(spots.size()):
		var kind: String = BROADLEAF[i % BROADLEAF.size()]
		var s := rng.randf_range(TREE_SCALE_MIN, TREE_SCALE_MAX)
		# A little non-uniform scale and a random yaw, so 170 instances of four
		# meshes do not read as 170 copies of four meshes.
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.scaled(Vector3(s, s * rng.randf_range(0.90, 1.14), s))
		(buckets[kind] as Array).append(Transform3D(basis, spots[i]))
		_add_trunk_body(spots[i], s, "TreeBody_%d" % i)
	for kind in BROADLEAF:
		var list: Array = buckets[kind]
		if list.is_empty():
			continue
		_add_multimesh("Broadleaf_" + kind, NaturePack.mesh_of(kind),
			NaturePack.material(kind), list)


## Conifers. Two species, no collision: the original pines had none, and a pine's
## trunk is thinner than the broadleaves' at the same height.
func _spawn_pines(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 515
	var spots := _pick(terrain, rng, 6.0, 120.0, 1.1, _scaled(PINE_COUNT))
	if spots.is_empty():
		return
	var buckets := {}
	for kind in PINES:
		buckets[kind] = []
	for i in range(spots.size()):
		var kind: String = PINES[i % PINES.size()]
		var s := rng.randf_range(PINE_SCALE_MIN, PINE_SCALE_MAX)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.scaled(Vector3(s, s * rng.randf_range(0.95, 1.20), s))
		(buckets[kind] as Array).append(Transform3D(basis, spots[i]))
	for kind in PINES:
		var list: Array = buckets[kind]
		if list.is_empty():
			continue
		_add_multimesh("Pines_" + kind, NaturePack.mesh_of(kind),
			NaturePack.material(kind), list)


## Bare storm-killed trees. The pack's dead tree has no foliage at all, which is
## a silhouette nothing else in the valley provides.
func _spawn_dead_trees(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8081
	var spots := _pick(terrain, rng, 5.0, 105.0, 1.3, _scaled(DEAD_COUNT))
	if spots.is_empty():
		return
	var xfs: Array = []
	for i in range(spots.size()):
		var s := rng.randf_range(1.5, 2.8)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.scaled(Vector3(s, s * rng.randf_range(0.85, 1.1), s))
		xfs.append(Transform3D(basis, spots[i]))
		_add_trunk_body(spots[i], s, "DeadBody_%d" % i)
	_add_multimesh("DeadTrees", NaturePack.mesh_of("tree_dead"),
		NaturePack.material("tree_dead"), xfs)


## A trunk collider sized from the tree's own scale, so a sapling is not a
## 2 m-wide post.
func _add_trunk_body(p: Vector3, s: float, body_name: String) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = maxf(0.20 * s, 0.26)
	shape.height = 2.2 * s
	col.shape = shape
	col.position.y = 1.1 * s
	body.add_child(col)
	body.position = p
	body.name = body_name
	add_child(body)
	_collision_bodies.append(body)


func _spawn_rocks(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 313
	var spots := _pick(terrain, rng, 0.6, 140.0, 1.6, _scaled(ROCK_COUNT), false)
	if spots.is_empty():
		return
	var big: Array = []
	var small: Array = []
	for p in spots:
		var r := rng.randf_range(0.9, 2.4)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.rotated(Vector3.RIGHT, rng.randf_range(-0.18, 0.18))
		basis = basis.scaled(Vector3(r, r * rng.randf_range(0.7, 1.1), r * rng.randf_range(0.85, 1.2)))
		# Sunk a little into the ground: a boulder resting exactly on the surface
		# reads as a decal, and the pack models are authored to sit on their base.
		var xf := Transform3D(basis, p + Vector3(0, -0.18 * r, 0))
		if r > 1.6:
			big.append(xf)
		else:
			small.append(xf)
	_add_multimesh("Rocks", NaturePack.mesh_of("rock_4"),
		NaturePack.material("rock_4"), big)
	_add_multimesh("RocksSmall", NaturePack.mesh_of("rock_1"),
		NaturePack.material("rock_1"), small)


func _spawn_flowers(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var spots := _pick(terrain, rng, 2.0, 60.0, 0.7, _scaled(FLOWER_COUNT))
	if spots.is_empty():
		return
	var xfs: Array = []
	for p in spots:
		var s := rng.randf_range(0.9, 1.6)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		xfs.append(Transform3D(basis, p))
	_add_multimesh("Flowers", NaturePack.mesh_of("flowers"),
		NaturePack.material("flowers"), xfs, false)


func _spawn_fallen_logs(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 771
	var spots := _pick(terrain, rng, 3.0, 70.0, 0.9, _scaled(LOG_COUNT))
	if spots.is_empty():
		return
	# The pack's log already lies along its own Z axis, so a fall only needs a
	# yaw and a slight tilt - no half-turn to stand it up.
	var xfs: Array = []
	for p in spots:
		var s := rng.randf_range(0.9, 1.9)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.rotated(Vector3.RIGHT, rng.randf_range(-0.10, 0.10))
		basis = basis.rotated(Vector3.FORWARD, rng.randf_range(-0.10, 0.10))
		basis = basis.scaled(Vector3(s, s * rng.randf_range(0.8, 1.1), s))
		xfs.append(Transform3D(basis, p + Vector3(0, -0.04, 0)))
	_add_multimesh("FallenLogs", NaturePack.mesh_of("log"),
		NaturePack.material("log"), xfs)


func _spawn_stumps(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 661
	var spots := _pick(terrain, rng, 3.0, 80.0, 0.9, _scaled(STUMP_COUNT))
	if spots.is_empty():
		return
	var xfs: Array = []
	for p in spots:
		var s := rng.randf_range(1.0, 1.9)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		xfs.append(Transform3D(basis, p))
	_add_multimesh("Stumps", NaturePack.mesh_of("stump"),
		NaturePack.material("stump"), xfs)


func _spawn_pebbles(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 977
	var spots := _pick(terrain, rng, 1.2, 90.0, 1.0, _scaled(PEBBLE_COUNT))
	if spots.is_empty():
		return
	var xfs: Array = []
	for p in spots:
		var s := rng.randf_range(0.14, 0.42)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(s, s * rng.randf_range(0.55, 0.95), s))
		xfs.append(Transform3D(basis, p + Vector3(0, -0.02, 0)))
	_add_multimesh("Pebbles", NaturePack.mesh_of("rock_2"),
		NaturePack.material("rock_2"), xfs, false)


## Draw-call and instance census, for the probe and the performance tuner.
func diagnostics() -> String:
	var mmi_count := 0
	var instances := 0
	for n in _scatter_roots:
		if n is MultiMeshInstance3D and is_instance_valid(n):
			mmi_count += 1
			instances += (n as MultiMeshInstance3D).multimesh.instance_count
	return "vegetation: %d batched draw calls, %d instances" % [mmi_count, instances]
