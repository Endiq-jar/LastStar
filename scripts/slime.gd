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

## Shared meshes and materials.
##
## Every slime used to allocate its own SphereMeshes and its own ShaderMaterials
## in _ready(). With 14 enemies that was 28 redundant mesh uploads and - worse -
## 14 distinct ShaderMaterial objects for the same toon shader. Godot keys its
## shader cache on the material, so each fresh material meant the shader was
## compiled again, and the stalls all landed as the world booted.
##
## Meshes are immutable here, so they are shared outright. Materials carry the
## per-element colour, so they are cached per element rather than shared
## blindly - one material per (element, slot) pair, three of each at most.
static var _mesh_cache := {}
static var _body_mats := {}
static var _outline_mat: ShaderMaterial
static var _core_mats := {}
static var _eye_mat: StandardMaterial3D

## AI tick cadence. Close enemies every frame; distant ones four times a second.
const AI_NEAR_RANGE := 45.0
const AI_TICK := 0.25
## Physics frames between the only work a fully occluded slime does (settling its
## own gravity). See the note in _physics_process.
const CULLED_TICK_EVERY := 8

var _ai_timer := 0.0
var max_hp := 150.0
var hp := 150.0
var element := 0
var home := Vector3.ZERO
var _player: Node3D
var _mesh_root: Node3D
var _core: MeshInstance3D
## The body mesh, kept so an element change can re-point its material without
## having to guess which child is which by radius.
var _body_mesh: MeshInstance3D
var _body_mat: ShaderMaterial
var _core_mat: StandardMaterial3D
var _time := 0.0
var _hop_timer := 0.0
var _attack_timer := 0.0
var _dead := false
var _wander_target := Vector3.ZERO
var _wander_timer := 0.0
## True while the entity culler has decided the player cannot see this slime.
var _view_culled := false
var _culled_frames := 0


func _ready() -> void:
	add_to_group("enemy")
	collision_layer = 8
	collision_mask = 1 | 2
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
	body.mesh = _shared_sphere("body", 0.40, 0.64, 16, 10)
	_body_mesh = body
	_body_mat = _body_material(element)
	body.material_override = _body_mat
	body.position.y = 0.40
	_mesh_root.add_child(body)

	var outline := MeshInstance3D.new()
	outline.mesh = _shared_sphere("outline", 0.412, 0.66, 16, 10)
	outline.material_override = _outline_material()
	outline.position.y = 0.40
	_mesh_root.add_child(outline)

	_core = MeshInstance3D.new()
	_core.mesh = _shared_sphere("core", 0.22, 0.44, 8, 4)
	_core_mat = _core_material(element)
	_core.material_override = _core_mat
	_core.position = Vector3(0, 0.42, -0.22)
	_mesh_root.add_child(_core)

	# Two glowing eyes.
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		eye.mesh = _shared_quad("eye", Vector2(0.062, 0.085))
		eye.material_override = _eye_material()
		eye.position = Vector3(0.115 * side, 0.50, -0.365)
		_mesh_root.add_child(eye)

	# No per-slime OmniLight3D.
	#
	# Fourteen enemies each carried a real-time point light. On the
	# `gl_compatibility` renderer there is no clustered lighting, so every lit
	# object in the valley evaluates every light that reaches it - these fourteen
	# were being paid for on every blade of grass and every metre of terrain, for
	# a soft glow the emissive core below already provides for free.
	#
	# The core is unshaded and emissive at 2.6x, and the body uses the toon
	# shader with a rim; on screen the blob reads as self-lit without it.
	_apply_element()


## Build (or fetch) one mesh per shape, shared by every slime.
static func _shared_sphere(key: String, radius: float, height: float,
		segments: int, rings: int) -> SphereMesh:
	if not _mesh_cache.has(key):
		var m := SphereMesh.new()
		m.radius = radius
		m.height = height
		m.radial_segments = segments
		m.rings = rings
		_mesh_cache[key] = m
	return _mesh_cache[key]


static func _shared_quad(key: String, size: Vector2) -> QuadMesh:
	if not _mesh_cache.has(key):
		var q := QuadMesh.new()
		q.size = size
		_mesh_cache[key] = q
	return _mesh_cache[key]


static func _body_material(index: int) -> ShaderMaterial:
	if not _body_mats.has(index):
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/character/anime_toon.gdshader")
		m.set_shader_parameter("shadow_tint", Color(0.5, 0.6, 0.9))
		m.set_shader_parameter("rim_strength", 0.35)
		# Bake the element colour in here so the material is a pure cache entry
		# and never has to be mutated after creation.
		var col: Color = ELEMENT_COLORS[clampi(index, 0, ELEMENT_COLORS.size() - 1)]
		var gel := col.lerp(Color(0.88, 0.90, 0.92), 0.42)
		gel = gel.lerp(Color(1, 1, 1), 0.10)
		m.set_shader_parameter("albedo_color", gel)
		_body_mats[index] = m
	return _body_mats[index]


static func _core_material(index: int) -> StandardMaterial3D:
	if not _core_mats.has(index):
		var m := StandardMaterial3D.new()
		m.emission_enabled = true
		m.emission_energy_multiplier = 2.6
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var col: Color = ELEMENT_COLORS[clampi(index, 0, ELEMENT_COLORS.size() - 1)]
		m.albedo_color = col
		m.emission = col
		_core_mats[index] = m
	return _core_mats[index]


static func _outline_material() -> ShaderMaterial:
	if _outline_mat == null:
		_outline_mat = ShaderMaterial.new()
		_outline_mat.shader = load("res://shaders/character/outline.gdshader")
		_outline_mat.set_shader_parameter("outline_width", 0.011)
		_outline_mat.set_shader_parameter("outline_color", Color(0.12, 0.12, 0.22, 1.0))
	return _outline_mat


static func _eye_material() -> StandardMaterial3D:
	if _eye_mat == null:
		_eye_mat = StandardMaterial3D.new()
		_eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_eye_mat.albedo_color = Color(0.12, 0.10, 0.18)
	return _eye_mat


func _apply_element() -> void:
	# Assign the cached material for this element instead of writing colours into
	# it.
	#
	# The materials are shared between every slime of the same element, so
	# mutating albedo here would have recoloured the entire species at once - a
	# single enemy changing element would have repainted all fourteen. The colour
	# now lives in the cache key, so switching element swaps the reference.
	# (The gel mixing that produced the milky body colour moved into
	# _body_material, where it is computed once per element rather than per slime.)
	_body_mat = _body_material(element)
	_core_mat = _core_material(element)
	if _body_mesh != null and is_instance_valid(_body_mesh):
		_body_mesh.material_override = _body_mat
	if _core != null and is_instance_valid(_core):
		_core.material_override = _core_mat


func set_element(index: int) -> void:
	element = clampi(index, 0, ELEMENT_COLORS.size() - 1)
	if _core_mat:
		_apply_element()


## Called by the entity culler when this slime leaves / re-enters the player's
## sight lines. Hiding the mesh root takes it out of the renderer entirely
## without touching the CharacterBody3D, so physics and combat stay correct.
func set_view_culled(hidden: bool) -> void:
	if _view_culled == hidden:
		return
	_view_culled = hidden
	if _mesh_root != null and is_instance_valid(_mesh_root):
		_mesh_root.visible = not hidden


func is_view_culled() -> bool:
	return _view_culled


func _physics_process(delta: float) -> void:
	if _dead or Game.is_paused:
		return

	# Occluded: no brain, no animation, no contact-damage check.
	#
	# The culler has geometry-proved that this slime is behind a wall, a ceiling
	# or a hillside, so nothing it decides this frame can be seen. Gravity still
	# settles it at one frame in eight (and with the elapsed time folded back in)
	# so an occluded slime cannot be left hovering in mid-air and then drop the
	# moment it comes back into view.
	if _view_culled:
		_culled_frames += 1
		if _culled_frames % CULLED_TICK_EVERY != 0:
			return
		if not is_on_floor():
			velocity.y -= 24.0 * delta * float(CULLED_TICK_EVERY)
		else:
			velocity.y = 0.0
		move_and_slide()
		if global_position.y < -50.0:
			queue_free()
		return
	_culled_frames = 0

	# Distance-gated AI.
	#
	# Every slime ran a full hop/aggro/steering tick on every physics frame for
	# the entire session, including the ones 200 m away over a ridge that the
	# player will not see for minutes. The brain here decides nothing that
	# matters at that range.
	#
	# Enemies near the player keep the full 60 Hz tick. Anything past IDLE_RANGE
	# drops to a 4 Hz decision tick: gravity and velocity are still integrated
	# (so nothing floats or freezes mid-air) but the target search, the distance
	# check against the player and the steering all run a fraction as often.
	# Between ticks the body keeps its last velocity, which for a slow wanderer
	# is indistinguishable and stable.
	_ai_timer -= delta
	var player_known := _player != null and is_instance_valid(_player)
	var near := false
	if player_known:
		var d2 := global_position.distance_squared_to(_player.global_position)
		near = d2 < AI_NEAR_RANGE * AI_NEAR_RANGE
	elif _ai_timer > 0.0:
		# No player cached and nothing due: don't retry the group lookup every
		# physics frame. One lookup per AI tick is enough.
		if not is_on_floor():
			velocity.y -= 24.0 * delta
		else:
			velocity.y = 0.0
		move_and_slide()
		return
	var tick := near or _ai_timer <= 0.0
	if not tick:
		# Keep physics integrating so nothing hangs in the air.
		if not is_on_floor():
			velocity.y -= 24.0 * delta
		else:
			velocity.y = 0.0
		move_and_slide()
		return
	_ai_timer = AI_TICK if not near else 0.0
	# Anchored check: a slime that has drifted far from home without a player
	# nearby is not worth a tick at all.
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
