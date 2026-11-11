extends CharacterBody3D
## Wandering elemental slime (Genshin-style blob enemy).
##
## Squashy toon blob with an elemental core, an aggro hop toward the player,
## contact damage and the reaction "take_hit(power, element, dir)" API used by
## the player's melee/skill/burst.

const FX := preload("res://scripts/fx.gd")
const ELEMENT_COLORS := [
	Color(0.42, 0.92, 0.78),  # Anemo
	Color(1.0, 0.55, 0.32),   # Pyro
	Color(0.75, 0.56, 1.0),   # Electro
]

var max_hp := 150.0
var hp := 150.0
var element := 0
var home := Vector3.ZERO
var _player: Node3D
var _mesh_root: Node3D
var _core: MeshInstance3D
var _body_mat: ShaderMaterial
var _core_mat: StandardMaterial3D
var _time := 0.0
var _hop_timer := 0.0
var _attack_timer := 0.0
var _dead := false
var _spawn_pos := Vector3.ZERO
var _wander_target := Vector3.ZERO
var _wander_timer := 0.0
var _base_scale := 1.0


func _ready() -> void:
	add_to_group("enemy")
	collision_layer = 8
	collision_mask = 1 | 2
	_spawn_pos = global_position
	home = global_position
	_build()
	_player = get_tree().get_first_node_in_group("player")
	_wander_target = home
	_pick_wander()


func _build() -> void:
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.62
	col.shape = shape
	col.position.y = 0.62
	add_child(col)

	_mesh_root = Node3D.new()
	add_child(_mesh_root)

	# Radius 0.72 / height 1.1 made a 1.4 m wide opaque balloon - as wide as the
	# player is tall, and twice as wide as she is. From the third-person camera it
	# filled a third of the screen as a flat, fully saturated disc with a heavy
	# black rim. On screen that is indistinguishable from a UI bug, and it is the
	# most "this is a prototype" object in the player's view. A slime is a
	# knee-high blob.
	var body := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.40
	sphere.height = 0.64
	sphere.radial_segments = 16
	sphere.rings = 10
	body.mesh = sphere
	_body_mat = ShaderMaterial.new()
	_body_mat.shader = load("res://shaders/anime_toon.gdshader")
	_body_mat.set_shader_parameter("albedo_color", Color(0.62, 0.92, 0.86))
	_body_mat.set_shader_parameter("shadow_tint", Color(0.5, 0.6, 0.9))
	_body_mat.set_shader_parameter("rim_strength", 0.35)
	body.material_override = _body_mat
	body.position.y = 0.40
	_mesh_root.add_child(body)

	var outline := MeshInstance3D.new()
	var shell := SphereMesh.new()
	shell.radius = 0.412
	shell.height = 0.66
	shell.radial_segments = 16
	shell.rings = 10
	outline.mesh = shell
	var om := ShaderMaterial.new()
	om.shader = load("res://shaders/outline.gdshader")
	om.set_shader_parameter("outline_width", 0.011)
	om.set_shader_parameter("outline_color", Color(0.12, 0.12, 0.22, 1.0))
	outline.material_override = om
	outline.position.y = 0.40
	_mesh_root.add_child(outline)

	_core = MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.22
	core_mesh.height = 0.44
	core_mesh.radial_segments = 8
	_core.mesh = core_mesh
	_core_mat = StandardMaterial3D.new()
	_core_mat.emission_enabled = true
	_core_mat.emission_energy_multiplier = 2.6
	_core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core.material_override = _core_mat
	_core.position = Vector3(0, 0.42, -0.22)
	_mesh_root.add_child(_core)

	# Two glowing eyes.
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.062, 0.085)
		eye.mesh = quad
		var em := StandardMaterial3D.new()
		em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		em.albedo_color = Color(0.12, 0.10, 0.18)
		eye.material_override = em
		eye.position = Vector3(0.115 * side, 0.50, -0.365)
		_mesh_root.add_child(eye)

	var light := OmniLight3D.new()
	light.light_energy = 0.9
	light.omni_range = 3.0
	light.shadow_enabled = false
	light.light_color = ELEMENT_COLORS[element]
	light.position = Vector3(0, 0.5, 0)
	_mesh_root.add_child(light)
	_apply_element()


func _apply_element() -> void:
	var col: Color = ELEMENT_COLORS[element]
	# Milky, desaturated gel rather than the raw element hue. The body used to be
	# the element colour at full chroma with a 0.7 rim and a 0.9 spec, which on a
	# sphere this size is a solid saturated disc. Mixing most of the way to white
	# and leaving the saturated hue to the core, the eyes and the light is how the
	# reference creatures read.
	var gel := col.lerp(Color(0.88, 0.90, 0.92), 0.42)
	gel = gel.lerp(Color(1, 1, 1), 0.10)
	_body_mat.set_shader_parameter("albedo_color", gel)
	_core_mat.albedo_color = col
	_core_mat.emission = col


func set_element(index: int) -> void:
	element = clampi(index, 0, ELEMENT_COLORS.size() - 1)
	if _core_mat:
		_apply_element()


func _physics_process(delta: float) -> void:
	if _dead or Game.is_paused:
		return
	_time += delta
	_hop_timer -= delta
	_attack_timer = maxf(0.0, _attack_timer - delta)

	if not is_on_floor():
		velocity.y -= 24.0 * delta
	else:
		velocity.y = 0.0

	var target := _wander_target
	var speed := 2.4
	if _player and is_instance_valid(_player):
		var d := global_position.distance_to(_player.global_position)
		if d < 20.0 and d > 1.2:
			target = _player.global_position
			speed = 3.6
			if _hop_timer <= 0.0 and is_on_floor():
				_hop_timer = randf_range(0.8, 1.4)
				velocity.y = 5.5
		elif _hop_timer <= 0.0 and is_on_floor():
			_hop_timer = randf_range(2.0, 3.6)
			velocity.y = 3.4
	else:
		_player = get_tree().get_first_node_in_group("player")

	var dir := Vector3(target.x - global_position.x, 0.0, target.z - global_position.z)
	if dir.length() > 0.6:
		dir = dir.normalized()
		velocity.x = move_toward(velocity.x, dir.x * speed, 14.0 * delta)
		velocity.z = move_toward(velocity.z, dir.z * speed, 14.0 * delta)
		_mesh_root.rotation.y = lerp_angle(_mesh_root.rotation.y, atan2(-dir.x, -dir.z), 8.0 * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_pick_wander()

	move_and_slide()

	# Squash & stretch bounce animation.
	var bounce := absf(sin(_time * 4.2)) * 0.10
	_mesh_root.scale = Vector3(1.0 + bounce * 0.6, 1.0 - bounce * 0.5, 1.0 + bounce * 0.6)
	_core.position.y = 0.62 + sin(_time * 3.1) * 0.05

	# Contact damage.
	if _player and is_instance_valid(_player) and _attack_timer <= 0.0:
		if global_position.distance_to(_player.global_position) < 1.5:
			_attack_timer = 1.1
			if _player.has_method("take_damage"):
				_player.take_damage(38.0, global_position)
				FX.hit_flash(get_parent(), _player.global_position + Vector3(0, 1.0, 0), ELEMENT_COLORS[element])

	# Fell out of the world.
	if global_position.y < -50.0:
		queue_free()


func _pick_wander() -> void:
	var a := randf() * TAU
	var r := randf_range(4.0, 14.0)
	_wander_target = home + Vector3(cos(a) * r, 0.0, sin(a) * r)
	_wander_timer = randf_range(3.0, 6.0)


func take_hit(power: float, hit_element: int, dir: Vector3) -> void:
	if _dead:
		return
	# Elemental reactions: same element = resisted, different = empowered.
	var mult := 1.0
	if hit_element == element:
		mult = 0.55
	elif (hit_element == 0 and element == 1) or (hit_element == 1 and element == 0):
		mult = 1.6  # swirl-like reaction
	elif hit_element != element:
		mult = 1.25
	var dmg := power * mult
	hp -= dmg

	FX.elemental_damage_number(get_parent(), global_position + Vector3(0, 1.4, 0), dmg, ELEMENT_COLORS[hit_element])
	FX.hit_flash(get_parent(), global_position + Vector3(0, 0.8, 0), ELEMENT_COLORS[hit_element])
	Game.add_energy(5.0)

	if dir.length() > 0.01:
		velocity += dir.normalized() * 5.0 + Vector3(0, 3.0, 0)

	var tw := create_tween()
	tw.tween_property(_mesh_root, "scale", Vector3(1.35, 0.7, 1.35), 0.08)
	tw.tween_property(_mesh_root, "scale", Vector3.ONE, 0.16)

	if hp <= 0.0:
		_die()


func _die() -> void:
	_dead = true
	Game.register_slime()
	FX.ring_burst(get_parent(), global_position + Vector3(0, 0.6, 0), ELEMENT_COLORS[element], 3.2)
	for i in range(8):
		FX.sparkle(get_parent(), global_position + Vector3(0, 0.7, 0), ELEMENT_COLORS[element], 1.6)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_mesh_root, "scale", Vector3.ZERO, 0.35)
	tw.tween_property(_mesh_root, "rotation:y", _mesh_root.rotation.y + TAU, 0.35)
	tw.chain().tween_callback(queue_free)
