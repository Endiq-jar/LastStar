extends Node3D
## Genshin-ish vegetation scatter for mobile: stylized pine trees, round
## wind-swept broadleaf trees, glowing flowers, rocks and a MultiMesh grass
## carpet. All meshes are procedural and batched with MultiMesh where possible.

@export var terrain_path: NodePath

const TREE_COUNT := 170
const PINE_COUNT := 130
const ROCK_COUNT := 100
const FLOWER_COUNT := 300
const GRASS_TUFT_COUNT := 2600
const SPREAD := 330.0

var _grass_meshes: Array[MultiMeshInstance3D] = []
var _time := 0.0
var _player: Node3D
## Distance culling for the heavy scatter groups (see _process).
var _scatter_roots: Array[Node3D] = []
var _cull_timer := 0.0
const CULL_NEAR := 190.0


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
	_spawn_grass(terrain)


func _toon(color: Color, rim: float = 0.3) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/anime_toon.gdshader")
	m.set_shader_parameter("albedo_color", color)
	m.set_shader_parameter("shadow_tint", Color(0.55, 0.62, 0.88))
	m.set_shader_parameter("rim_color", Color(1.0, 0.95, 0.8))
	m.set_shader_parameter("rim_strength", rim)
	m.set_shader_parameter("spec_energy", 0.18)
	m.set_shader_parameter("diffuse_energy", 1.0)
	return m


func _process(delta: float) -> void:
	## Cheap distance culling. Each tree/rock/flower is its own draw call, so on
	## a mid-range phone the far half of the valley is mostly wasted fill rate.
	## Hiding the instance groups the player has left behind keeps the frame
	## budget for what is actually on screen.
	_cull_timer -= delta
	if _cull_timer > 0.0:
		return
	_cull_timer = 0.5
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
	if _player == null:
		return
	var origin := _player.global_position
	for group in _scatter_roots:
		if group == null or not is_instance_valid(group):
			continue
		for item in group.get_children():
			if item is Node3D:
				var n := item as Node3D
				n.visible = n.global_position.distance_to(origin) < CULL_NEAR
	for mmi in _grass_meshes:
		if mmi != null and is_instance_valid(mmi):
			mmi.visible = _player.global_position.distance_to(mmi.global_position) < CULL_NEAR * 1.4


func _pick(terrain: Node, rng: RandomNumberGenerator, min_h: float, max_h: float, max_slope: float, count: int, avoid_lake: bool = true) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var attempts := 0
	while out.size() < count and attempts < count * 22:
		attempts += 1
		var x := rng.randf_range(-SPREAD, SPREAD)
		var z := rng.randf_range(-SPREAD, SPREAD)
		var h: float = terrain.get_height_at(x, z)
		if h < min_h or h > max_h:
			continue
		if avoid_lake and Vector2(x, z).distance_to(Game.lake_center) < Game.lake_radius * 0.85:
			continue
		if terrain.get_slope_at(x, z) > max_slope:
			continue
		out.append(Vector3(x, h, z))
	return out


func _spawn_round_trees(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 771
	var spots := _pick(terrain, rng, 3.0, 78.0, 0.85, TREE_COUNT)

	var trunk_mat := _toon(Color(0.42, 0.29, 0.22))
	var leaf_mats := [
		_toon(Color(0.36, 0.66, 0.32), 0.45),
		_toon(Color(0.46, 0.76, 0.36), 0.45),
		_toon(Color(0.30, 0.58, 0.34), 0.45),
	]
	var root := Node3D.new()
	root.name = "Broadleaf"
	add_child(root)
	_scatter_roots.append(root)

	for i in range(spots.size()):
		var tree := Node3D.new()
		tree.position = spots[i]
		var s := rng.randf_range(0.8, 1.6)
		tree.scale = Vector3.ONE * s
		tree.rotation.y = rng.randf() * TAU
		root.add_child(tree)

		var trunk := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.16
		cylinder.bottom_radius = 0.3
		cylinder.height = 3.2
		cylinder.radial_segments = 8
		trunk.mesh = cylinder
		trunk.material_override = trunk_mat
		trunk.position.y = 1.6
		tree.add_child(trunk)

		var leaf_mat: Material = leaf_mats[i % leaf_mats.size()]
		for b in range(3):
			var crown := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			var r := 1.5 - b * 0.3
			sphere.radius = r
			sphere.height = r * 1.55
			sphere.radial_segments = 10
			sphere.rings = 6
			crown.mesh = sphere
			crown.material_override = leaf_mat
			crown.position = Vector3(rng.randf_range(-0.4, 0.4), 3.3 + b * 0.85, rng.randf_range(-0.4, 0.4))
			tree.add_child(crown)

		# Trunk collision so the player can't run through the big ones.
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
		tree.add_child(body)


func _spawn_pines(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 992
	var spots := _pick(terrain, rng, 10.0, 135.0, 1.1, PINE_COUNT)
	var trunk_mat := _toon(Color(0.36, 0.26, 0.2))
	var pine_mats := [
		_toon(Color(0.22, 0.48, 0.32), 0.35),
		_toon(Color(0.28, 0.56, 0.38), 0.35),
	]
	var root := Node3D.new()
	root.name = "Pines"
	add_child(root)
	_scatter_roots.append(root)

	for i in range(spots.size()):
		var pine := Node3D.new()
		pine.position = spots[i]
		var s := rng.randf_range(0.9, 1.7)
		pine.scale = Vector3(s, s * rng.randf_range(1.0, 1.5), s)
		pine.rotation.y = rng.randf() * TAU
		root.add_child(pine)

		var trunk := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.1
		cylinder.bottom_radius = 0.24
		cylinder.height = 2.6
		cylinder.radial_segments = 7
		trunk.mesh = cylinder
		trunk.material_override = trunk_mat
		trunk.position.y = 1.3
		pine.add_child(trunk)

		var mat: Material = pine_mats[i % pine_mats.size()]
		for layer in range(4):
			var cone := MeshInstance3D.new()
			var prism := CylinderMesh.new()
			prism.top_radius = 0.0
			prism.bottom_radius = 1.5 - layer * 0.28
			prism.height = 1.5 - layer * 0.18
			prism.radial_segments = 8
			cone.mesh = prism
			cone.material_override = mat
			cone.position.y = 2.2 + layer * 0.78
			pine.add_child(cone)


func _spawn_rocks(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 313
	var spots := _pick(terrain, rng, 0.6, 140.0, 1.6, ROCK_COUNT, false)
	var mat := _toon(Color(0.62, 0.62, 0.68), 0.35)
	var root := Node3D.new()
	root.name = "Rocks"
	add_child(root)
	_scatter_roots.append(root)
	for p in spots:
		var rock := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = rng.randf_range(0.5, 1.8)
		sphere.height = sphere.radius * rng.randf_range(1.0, 1.6)
		sphere.radial_segments = 7
		sphere.rings = 4
		rock.mesh = sphere
		rock.material_override = mat
		rock.position = p + Vector3(0, sphere.radius * 0.35, 0)
		rock.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3))
		rock.scale = Vector3(1.0, rng.randf_range(0.6, 1.0), 1.0)
		root.add_child(rock)


func _spawn_flowers(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var spots := _pick(terrain, rng, 2.0, 60.0, 0.7, FLOWER_COUNT)
	var colors := [
		Color(0.55, 0.85, 1.0),
		Color(1.0, 0.78, 0.9),
		Color(1.0, 0.95, 0.6),
		Color(0.75, 0.6, 1.0),
	]
	var root := Node3D.new()
	root.name = "Flowers"
	add_child(root)
	_scatter_roots.append(root)
	for i in range(spots.size()):
		var flower := Node3D.new()
		flower.position = spots[i]
		var col: Color = colors[i % colors.size()]
		var stem := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.015
		cyl.bottom_radius = 0.02
		cyl.height = 0.3
		cyl.radial_segments = 4
		stem.mesh = cyl
		stem.material_override = _toon(Color(0.35, 0.6, 0.32))
		stem.position.y = 0.15
		flower.add_child(stem)
		var bloom := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.09
		s.height = 0.12
		s.radial_segments = 6
		s.rings = 3
		bloom.mesh = s
		var bm := StandardMaterial3D.new()
		bm.albedo_color = col
		bm.emission_enabled = true
		bm.emission = col
		bm.emission_energy_multiplier = 0.9
		bloom.material_override = bm
		bloom.position.y = 0.32
		flower.add_child(bloom)
		root.add_child(flower)


func _spawn_grass(terrain: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 555
	var spots := _pick(terrain, rng, 2.2, 55.0, 0.55, GRASS_TUFT_COUNT)
	if spots.is_empty():
		return

	var blade := QuadMesh.new()
	blade.size = Vector2(0.55, 0.7)
	blade.orientation = PlaneMesh.FACE_Y
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/grass_sway.gdshader")
	mat.set_shader_parameter("grass_color", Color(0.42, 0.72, 0.34))
	mat.set_shader_parameter("grass_tip", Color(0.72, 0.92, 0.45))

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = blade
	multimesh.instance_count = spots.size()
	for i in range(spots.size()):
		var p: Vector3 = spots[i]
		var s := rng.randf_range(0.7, 1.5)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		multimesh.set_instance_transform(i, Transform3D(basis, p + Vector3(0, 0.33 * s, 0)))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GrassCarpet"
	mmi.multimesh = multimesh
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_grass_meshes.append(mmi)
