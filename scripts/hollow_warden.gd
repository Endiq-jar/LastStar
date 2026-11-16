extends CharacterBody3D
## Two-phase guardian using Quaternius CC0 animated creature models.
## Visible ground telegraphs, deliberate recovery windows and a distinct second
## pattern make this a readable encounter rather than a contact-damage sponge.
signal defeated
const DEMON := preload("res://assets/creatures/Demon.gltf")
const BLUE_DEMON := preload("res://assets/creatures/BlueDemon.gltf")
var is_vault := false
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
	if is_vault:
		max_hp = 1550.0
		hp = max_hp
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.7
	shape.height = 2.0
	collider.shape = shape
	collider.position.y = 1.0
	add_child(collider)
	_visual = (BLUE_DEMON if is_vault else DEMON).instantiate() as Node3D
	_visual.scale = Vector3.ONE * 0.68
	add_child(_visual)
	_animation = _visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_play_animation("Idle")
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
			_play_animation("Walk")
			move_and_slide()
		else:
			_play_animation("Idle")
		if _timer <= 0.0:
			_state = "warning"
			_timer = 1.6 if phase == 1 else (1.15 if is_vault else 1.25)
			_attack_number += 1
			var targeted := phase == 1 or (is_vault and _attack_number % 2 == 0)
			_target = _player.global_position if targeted else global_position
			_play_animation("Punch")
			_target.y = global_position.y + 0.08
			if is_instance_valid(_warning):
				_warning.global_position = _target
				_warning.visible = true
			Game.toast.emit("%s: %s — dodge the red circle!" % ["Vault Sentinel" if is_vault else "Hollow Warden", "strike" if targeted else "shockwave"])
	elif _timer <= 0.0:
		if is_instance_valid(_warning): _warning.visible = false
		var delta_pos := _player.global_position - _target
		delta_pos.y = 0
		if delta_pos.length() < 2.6 and absf(_player.global_position.y - _target.y) < 2.5:
			_player.call("take_damage", Game.max_hp() * (0.22 if phase == 1 else 0.28), global_position)
		_state = "rest"
		_timer = 2.4 if phase == 1 else 1.8


func take_hit(power: float, _element: int, _direction: Vector3) -> void:
	if _dead: return
	hp = maxf(0.0, hp - maxf(power, 0.0))
	if hp <= max_hp * 0.5 and phase == 1:
		phase = 2
		Game.toast.emit("%s phase 2: %s" % ["Vault Sentinel" if is_vault else "Warden", "it alternates strikes and shockwaves!" if is_vault else "it will strike around itself!"])
	_update_label()
	if hp <= 0.0:
		_dead = true
		if is_instance_valid(_warning): _warning.queue_free()
		defeated.emit()
		queue_free()


func take_combined_hit(power: float, first: int, _second: int, direction: Vector3) -> void:
	take_hit(power, first, direction)


func _update_label() -> void:
	_label.text = "%s · Phase %d\n%d / %d" % ["Vault Sentinel" if is_vault else "Hollow Warden", phase, int(hp), int(max_hp)]


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
