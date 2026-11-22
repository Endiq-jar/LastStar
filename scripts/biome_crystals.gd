extends Node3D
## A small, streamed fantasy-region landmark layer. One MultiMesh per occupied
## chunk, no collision, no per-instance updates, and one build per frame.
const CHUNK := 48.0
const RADIUS := 3
var terrain: Node
var player: Node3D
var _center := Vector2i(99999, 99999)
var _chunks: Dictionary = {}
var _pending: Array[Vector2i] = []
var _mesh: CylinderMesh
var _material: StandardMaterial3D


func setup(ground: Node, actor: Node3D) -> void:
	terrain = ground
	player = actor
	_mesh = CylinderMesh.new()
	_mesh.top_radius = 0.0
	_mesh.bottom_radius = 0.7
	_mesh.height = 3.0
	_mesh.radial_segments = 5
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.48, 0.34, 0.74)
	_material.emission_enabled = true
	_material.emission = Color(0.12, 0.07, 0.21)
	_material.roughness = 0.45


func _process(_delta: float) -> void:
	if not is_instance_valid(player) or not is_instance_valid(terrain): return
	var p := player.global_position
	var center := Vector2i(floori(p.x / CHUNK), floori(p.z / CHUNK))
	if center != _center:
		_center = center
		_pending.clear()
		for key in _chunks.keys():
			if abs(key.x - center.x) > RADIUS or abs(key.y - center.y) > RADIUS:
				_chunks[key].queue_free()
				_chunks.erase(key)
		for z in range(-RADIUS, RADIUS + 1):
			for x in range(-RADIUS, RADIUS + 1):
				var key := center + Vector2i(x, z)
				if not _chunks.has(key): _pending.append(key)
	if not _pending.is_empty(): _build(_pending.pop_front())


func _build(key: Vector2i) -> void:
	var origin := Vector2(key.x * CHUNK, key.y * CHUNK)
	if terrain.biome_at(origin.x + CHUNK * 0.5, origin.y + CHUNK * 0.5) != "fantasy": return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var transforms: Array[Transform3D] = []
	for i in range(5):
		var x := origin.x + rng.randf_range(0, CHUNK)
		var z := origin.y + rng.randf_range(0, CHUNK)
		if terrain.is_underwater(x, z) or terrain.get_slope_at(x, z) > 0.55 or terrain.is_path(x, z): continue
		var h: float = terrain.surface_height_at(x, z)
		var scale := rng.randf_range(0.55, 1.7)
		var basis := Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(Vector3(scale, scale, scale))
		transforms.append(Transform3D(basis, Vector3(x, h + 1.5 * scale, z)))
	if transforms.is_empty(): return
	var mesh := MultiMesh.new()
	mesh.transform_format = MultiMesh.TRANSFORM_3D
	mesh.mesh = _mesh
	mesh.instance_count = transforms.size()
	for i in range(transforms.size()): mesh.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = mesh
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = 160.0
	add_child(node)
	_chunks[key] = node
