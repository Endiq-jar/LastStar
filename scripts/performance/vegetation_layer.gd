extends Node3D
## A single batched vegetation layer: one MultiMeshInstance3D, one material.
##
## This is the machinery behind everything the brief asks for - grass, border
## grass, flowers, bushes, pebbles, rocks, leaves. Rather than one script per
## species, each species is a `VegetationLayer` configured with a mesh, a
## material, a density and a set of placement rules.
##
## Why MultiMesh and not nodes
## ---------------------------
## A MultiMesh is one draw call regardless of instance count. Ten thousand
## individual Node3D + MeshInstance3D pairs cost ten thousand draw submissions
## plus ten thousand nodes in the SceneTree, and the scene-tree half of that is
## what actually shows up as stutter, because it is rebuilt and traversed on the
## main thread every frame. This project already paid for that lesson: the
## scatter was ~1,600 MeshInstance3D and batching it took the valley's vegetation
## from ~1,600 draw calls to ~15.
##
## Chunking
## --------
## One MultiMesh spanning the whole map would never be frustum-culled, because
## its AABB always overlaps the view. So the layer is split into square chunks,
## each its own MultiMesh. Off-screen chunks are rejected by the renderer's
## frustum test before anything is submitted, and chunks far away can be dropped
## entirely with visibility_range.
##
## Density variation
## -----------------
## Placement is clustered, not uniform: a low-frequency noise field biases where
## instances land, so the meadow has thick and thin patches. Uniform random
## placement is the single most reliable way to make a field look synthetic.

const VegMeshes := preload("res://scripts/performance/vegetation_meshes.gd")

## World size of one chunk, in metres.
@export var chunk_size: float = 26.0
## How many chunks out from the anchor stay alive.
@export var chunk_radius: int = 5
## Instances per square metre inside a fully-dense chunk.
@export var density: float = 1.6
## Height range in metres for the placed card.
@export var min_height: float = 0.38
@export var max_height: float = 0.78
## Extra spacing kept clear around the character, so nothing clips the camera.
@export var player_clear: float = 0.55
## Reject if the ground is steeper than this (rise over run).
@export var max_slope: float = 0.55
@export var material: ShaderMaterial
@export var alpha_texture: Texture2D
## Which generated mesh to instance: "crossed" for foliage cards, "rock", "lobe".
@export var mesh_kind: String = "crossed"

var _terrain: Node
var _player: Node3D
var _chunks: Dictionary = {}
var _queued: Array[Vector2i] = []
var _center := Vector2i(999999, 999999)
## Per-frame budget for chunk construction. Building a whole ring in one frame is
## the classic cause of a multi-hundred-millisecond hitch when the player walks.
@export var chunks_per_frame: int = 1

var _mesh: Mesh = null
var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()
var _instances_built := 0
var _chunks_built := 0


func setup(terrain: Node, player: Node3D, seed_value: int = 1) -> void:
	_terrain = terrain
	_player = player
	_rng.seed = seed_value
	_mesh = VegMeshes.crossed() if mesh_kind == "crossed" else VegMeshes.rock()
	if mesh_kind == "lobe":
		_mesh = VegMeshes.lobe()
	_noise.seed = seed_value
	# Low frequency: patches roughly 40 m across, which is the scale at which a
	# real meadow varies as the ground changes.
	_noise.frequency = 0.022
	_noise.fractal_octaves = 2
	if material != null and alpha_texture != null:
		material.set_shader_parameter("albedo_texture", alpha_texture)
	_refresh_center()


func _process(_delta: float) -> void:
	if _player == null or _terrain == null:
		return
	_refresh_center()
	# Streaming budget: a few chunks per frame, never all of them at once.
	var built := 0
	while built < chunks_per_frame and not _queued.is_empty():
		var key: Vector2i = _queued.pop_front()
		if not _chunks.has(key):
			_build_chunk(key)
			built += 1


func _refresh_center() -> void:
	var p := _player.global_position
	var c := Vector2i(floori(p.x / chunk_size), floori(p.z / chunk_size))
	if c == _center:
		return
	_center = c
	_queued.clear()
	# Queue nearest-first so the ground under the player fills in first.
	var wanted: Array[Vector2i] = []
	for dz in range(-chunk_radius, chunk_radius + 1):
		for dx in range(-chunk_radius, chunk_radius + 1):
			if Vector2(dx, dz).length() > float(chunk_radius) + 0.25:
				continue
			wanted.append(c + Vector2i(dx, dz))
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - c).length_squared() < (b - c).length_squared())
	_queued = wanted
	# Drop chunks that left the radius.
	for key in _chunks.keys():
		if abs(key.x - c.x) > chunk_radius + 1 or abs(key.y - c.y) > chunk_radius + 1:
			var node: Node3D = _chunks[key]
			if is_instance_valid(node):
				_instances_built -= int(node.get_meta("count", 0))
				node.queue_free()
			_chunks.erase(key)


func _build_chunk(key: Vector2i) -> void:
	var origin_x := float(key.x) * chunk_size
	var origin_z := float(key.y) * chunk_size

	var area := chunk_size * chunk_size
	var wanted := int(area * density)
	var transforms: Array[Transform3D] = []
	var customs: Array[Color] = []

	for i in range(wanted):
		var x := origin_x + _rng.randf() * chunk_size
		var z := origin_z + _rng.randf() * chunk_size

		# Density variation: a noise field thins the field in patches. Below the
		# threshold, skip - which is what produces natural clearings instead of
		# a uniform carpet.
		var field := _noise.get_noise_2d(x, z) * 0.5 + 0.5
		if _rng.randf() > field * 1.15:
			continue

		# Keep a small radius clear around the character. Done per instance at
		# build time rather than in the shader, so nothing is submitted at all.
		if _player != null:
			var d := Vector2(x - _player.global_position.x, z - _player.global_position.z).length()
			if d < player_clear:
				continue

		var h: float = _terrain.surface_height_at(x, z) if _terrain.has_method("surface_height_at") \
			else _terrain.get_height_at(x, z)
		if _terrain.has_method("is_underwater") and _terrain.is_underwater(x, z):
			continue
		if _terrain.get_slope_at(x, z) > max_slope:
			continue

		var s := _rng.randf_range(min_height, max_height)
		# Random yaw and a slight lean so the cards are not all perfectly upright
		# or perfectly square to each other.
		var basis := Basis(Vector3.UP, _rng.randf() * TAU)
		basis = basis.scaled(Vector3(s * _rng.randf_range(0.85, 1.15), s, s))
		# The crossed card's origin is at its ROOT, with the quad extending up
		# from y=0, so it is placed exactly on the ground - no half-height lift.
		# (A centred quad would need +s*0.5 here; getting this wrong puts every
		# tuft half a metre underground.)
		transforms.append(Transform3D(basis, Vector3(x, h, z)))
		# INSTANCE_CUSTOM.r is read by the shader as a per-instance tint.
		customs.append(Color(_rng.randf(), 0.0, 0.0, 0.0))

	if transforms.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Custom data is what lets the shader vary each instance without a second
	# draw call or a per-instance material.
	mm.use_custom_data = true
	mm.mesh = _mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_custom_data(i, customs[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Chunk_%d_%d" % [key.x, key.y]
	mmi.multimesh = mm
	if material != null:
		mmi.material_override = material
	# Grass does not cast shadows: at this density the shadow map cost dwarfs
	# the benefit, and the terrain's own shading carries the shape.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.set_meta("count", transforms.size())
	add_child(mmi)
	_chunks[key] = mmi
	_instances_built += transforms.size()
	_chunks_built += 1


## Census for the performance probe and the on-screen debug readout.
func census() -> Dictionary:
	return {
		"chunks": _chunks.size(),
		"instances": _instances_built,
		"built": _chunks_built,
		"pending": _queued.size(),
	}
