extends CharacterBody3D
## Two-phase guardian using Quaternius CC0 animated creature models.
## Visible ground telegraphs, deliberate recovery windows and a distinct second
## pattern make this a readable encounter rather than a contact-damage sponge.
signal defeated
const KEEPER := preload("res://assets/creatures/Ninja.gltf")
const DEMON := preload("res://assets/creatures/Demon.gltf")
const DRAGON := preload("res://assets/creatures/Dragon_Evolved.gltf")
const BLUE_DEMON := preload("res://assets/creatures/BlueDemon.gltf")
var is_vault := false
var is_dragon := false
var is_keeper := false
var custom_name := ""
var difficulty_scale := 1.0
# Story guardians can favour one readable technique; default keeps old fights.
var attack_profile := ""
var _radius := 2.6
const LINE_LENGTH := 12.0
const LINE_HALF_WIDTH := 1.0
const RING_INNER := 2.2
const RING_OUTER := 5.0
var _attack_kind := "circle"
var _line_origin := Vector3.ZERO
var _line_direction := Vector3.FORWARD
var _visual: Node3D
var _animation: AnimationPlayer
var _attack_number := 0
var max_hp := 1100.0
var hp := 1100.0
var phase := 1
var _player: Node3D
var _timer := 2.5
var _state := "rest"
var _target := Vector3.ZERO
var _warning: MeshInstance3D
var _label: Label3D
var _dead := false


func _ready() -> void:
	add_to_group("enemy")
	collision_layer = 8
	collision_mask = 1
	_player = get_tree().get_first_node_in_group("player") as Node3D
	if is_keeper:
		max_hp = 4500.0
	elif is_dragon:
		max_hp = 1800.0
	elif is_vault:
		max_hp = 1550.0
	max_hp *= clampf(difficulty_scale, 1.0, 1.5)
	hp = max_hp
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.7
	shape.height = 2.0
	collider.shape = shape
	collider.position.y = 1.0
	add_child(collider)
	_visual = (KEEPER if is_keeper else (DRAGON if is_dragon else (BLUE_DEMON if is_vault else DEMON))).instantiate() as Node3D
	_visual.scale = Vector3.ONE * (0.72 if is_dragon else 0.68)
	add_child(_visual)
	_animation = _visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_play_animation("Flying_Idle" if is_dragon else "Idle")
	_label = Label3D.new()
	_label.position.y = 2.7
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 48
	_label.pixel_size = 0.006
	_label.outline_size = 8
	add_child(_label)
	_update_label()
	_warning = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 2.6
	disc.bottom_radius = 2.6
	disc.height = 0.03
	disc.radial_segments = 32
	_warning.mesh = disc
	var warning_material := StandardMaterial3D.new()
	warning_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	warning_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	warning_material.albedo_color = Color(1.0, 0.18, 0.12, 0.48)
	_warning.material_override = warning_material
	_warning.visible = false
	get_parent().add_child.call_deferred(_warning)


func _physics_process(delta: float) -> void:
	if _dead or Game.is_paused or not is_instance_valid(_player):
		return
	_timer -= delta
	if _state == "rest":
		var toward := _player.global_position - global_position
		toward.y = 0
		if toward.length() > 3.0:
			velocity = toward.normalized() * (2.0 if phase == 1 else 2.6)
			_visual.rotation.y = lerp_angle(_visual.rotation.y, atan2(toward.x, toward.z), 6.0 * delta)
			_play_animation("Fast_Flying" if is_dragon else "Walk")
			move_and_slide()
		else:
			_play_animation("Flying_Idle" if is_dragon else "Idle")
		if _timer <= 0.0 and _can_target(15.0):
			_state = "warning"
			_timer = 1.6 if phase == 1 else (1.0 if is_keeper and phase >= 3 else (1.15 if is_vault else 1.25))
			_attack_number += 1
			var targeted := phase == 1 or ((is_vault or is_dragon or is_keeper) and _attack_number % 2 == 0)
			_attack_kind = _choose_attack(_attack_number, phase)
			_radius = 3.8 if is_keeper and phase >= 3 and not targeted else (3.4 if is_dragon and phase >= 2 and not targeted else 2.6)
			_play_animation("Headbutt" if is_dragon else "Punch")
			_warning.scale = Vector3.ONE
			if _attack_kind == "line":
				_line_origin = global_position
				_line_direction = _player.global_position - _line_origin
				_line_direction.y = 0
				if _line_direction.length_squared() < 0.01: _line_direction = Vector3.FORWARD
				_line_direction = _line_direction.normalized()
				_target = _line_origin + _line_direction * LINE_LENGTH * 0.5
				_target.y = global_position.y + 0.08
				var stripe := BoxMesh.new()
				stripe.size = Vector3(LINE_HALF_WIDTH * 2.0, 0.04, LINE_LENGTH)
				_warning.mesh = stripe
				_warning.rotation.y = atan2(_line_direction.x, _line_direction.z)
				_timer = 1.25 if is_keeper and phase >= 4 else 1.45 # Readable committed wind-up.
				Game.toast.emit("%s: star slash — dodge sideways!" % _boss_name())
			elif _attack_kind == "ring":
				# A flat annulus leaves safe space inside and outside its visible band.
				_target = global_position + Vector3(0, 0.08, 0)
				var ring := TorusMesh.new()
				ring.outer_radius = RING_OUTER
				ring.inner_radius = RING_INNER
				ring.rings = 32
				ring.ring_segments = 8
				_warning.mesh = ring
				_warning.scale.y = 0.03
				_warning.rotation.y = 0.0
				_timer = 1.5
				Game.toast.emit("%s: eclipse ring — move inside or beyond the ring!" % _boss_name())
			else:
				var disc := CylinderMesh.new()
				disc.top_radius = _radius
				disc.bottom_radius = _radius
				disc.height = 0.03
				disc.radial_segments = 32
				_warning.mesh = disc
				_warning.rotation.y = 0.0
				_target = _player.global_position if targeted else global_position
				_target.y = global_position.y + 0.08
				Game.toast.emit("%s: %s — dodge the red circle!" % [_boss_name(), "strike" if targeted else "shockwave"])
			if is_instance_valid(_warning):
				_warning.global_position = _target
				_warning.visible = true
	elif _timer <= 0.0:
		if is_instance_valid(_warning): _warning.visible = false
		var delta_pos := _player.global_position - _target
		delta_pos.y = 0
		var hit := delta_pos.length() < _radius
		if _attack_kind == "ring":
			hit = delta_pos.length() >= RING_INNER and delta_pos.length() <= RING_OUTER
		elif _attack_kind == "line":
			var offset := _player.global_position - _line_origin
			offset.y = 0
			var along := offset.dot(_line_direction)
			var across := absf(offset.x * _line_direction.z - offset.z * _line_direction.x)
			hit = along >= 0.0 and along <= LINE_LENGTH and across < LINE_HALF_WIDTH
		if hit and absf(_player.global_position.y - _target.y) < 2.5:
			_player.call("take_damage", Game.max_hp() * (0.22 if phase == 1 else 0.28), global_position)
		_state = "rest"
		_timer = 2.4 if phase == 1 else (1.45 if is_keeper and phase >= 4 else 1.8)



func _choose_attack(number: int, current_phase: int) -> String:
	if current_phase < 2: return "circle"
	match attack_profile:
		"slash":
			if number % 2 == 0: return "line"
			if number % 3 == 0: return "ring"
		"ring":
			if number % 2 == 0: return "ring"
			if number % 3 == 0: return "line"
		"circle":
			if number % 4 == 0: return "ring"
			if number % 5 == 0: return "line"
		_:
			if number % 3 == 0: return "line"
			if number % 4 == 0: return "ring"
	return "circle"


func take_hit(power: float, _element: int, _direction: Vector3) -> void:
	if _dead: return
	hp = maxf(0.0, hp - maxf(power, 0.0))
	var next_phase := 1
	if is_keeper:
		if hp <= max_hp * 0.25: next_phase = 4
		elif hp <= max_hp * 0.5: next_phase = 3
		elif hp <= max_hp * 0.75: next_phase = 2
	elif hp <= max_hp * 0.5:
		next_phase = 2
	if next_phase > phase:
		phase = next_phase
		Game.toast.emit("%s phase %d: watch the strike patterns!" % [_boss_name(), phase])
	_update_label()
	if hp <= 0.0:
		_dead = true
		if is_instance_valid(_warning): _warning.queue_free()
		defeated.emit()
		queue_free()


func take_combined_hit(power: float, first: int, _second: int, direction: Vector3) -> void:
	take_hit(power, first, direction)


func _update_label() -> void:
	_label.text = "%s · Phase %d\n%d / %d" % [_boss_name(), phase, int(hp), int(max_hp)]


func _play_animation(part: String) -> void:
	if _animation == null:
		return
	for name in _animation.get_animation_list():
		if str(name).to_lower().ends_with(part.to_lower()):
			if _animation.current_animation != name or not _animation.is_playing():
				_animation.play(name)
			return


func _exit_tree() -> void:
	if is_instance_valid(_warning): _warning.queue_free()


func _boss_name() -> String:
	if not custom_name.is_empty(): return custom_name
	if is_keeper: return "The Keeper"
	if is_dragon: return "Suncrest Dragon"
	return "Vault Sentinel" if is_vault else "Hollow Warden"


func _can_target(reach: float) -> bool:
	if not is_instance_valid(_player): return false
	var origin := global_position + Vector3(0, 1.0, 0)
	var target := _player.global_position + Vector3(0, 1.0, 0)
	if origin.distance_to(target) > reach: return false
	var ray := PhysicsRayQueryParameters3D.create(origin, target, 1)
	ray.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


func reset_encounter() -> void:
	if _dead: return
	hp = max_hp
	phase = 1
	_attack_number = 0
	_state = "rest"
	_timer = 2.5
	velocity = Vector3.ZERO
	if is_instance_valid(_warning): _warning.visible = false
	_update_label()
