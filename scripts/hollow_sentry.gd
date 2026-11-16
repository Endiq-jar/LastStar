extends CharacterBody3D
## A light but dangerous Hollow scout with an evadable targeted strike.
signal defeated
const CREATURE := preload("res://assets/creatures/Ghost_Skull.gltf")
const ORC := preload("res://assets/creatures/Orc.gltf")
var is_orc := false
var hp := 260.0
var _player: Node3D
var _visual: Node3D
var _animation: AnimationPlayer
var _label: Label3D
var _warning: MeshInstance3D
var _target := Vector3.ZERO
var _timer := 2.5
var _state := "rest"
var _dead := false


func _ready() -> void:
	add_to_group("enemy")
	collision_layer = 8
	collision_mask = 1
	_player = get_tree().get_first_node_in_group("player") as Node3D
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.48
	capsule.height = 1.5
	collision.shape = capsule
	collision.position.y = 0.75
	add_child(collision)
	_visual = (ORC if is_orc else CREATURE).instantiate() as Node3D
	_visual.scale = Vector3.ONE * (0.52 if is_orc else 0.42)
	add_child(_visual)
	_animation = _visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_play("Idle" if is_orc else "Flying_Idle")
	_label = Label3D.new()
	_label.text = "Vault raider · 260" if is_orc else "Hollow scout · 260"
	_label.position.y = 1.9
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 36
	_label.pixel_size = 0.004
	_label.outline_size = 6
	add_child(_label)
	_warning = MeshInstance3D.new()
	var circle := CylinderMesh.new()
	circle.top_radius = 1.65
	circle.bottom_radius = 1.65
	circle.height = 0.03
	circle.radial_segments = 24
	_warning.mesh = circle
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.32, 0.16, 0.48)
	_warning.material_override = mat
	_warning.visible = false
	get_parent().add_child.call_deferred(_warning)


func _physics_process(delta: float) -> void:
	if _dead or Game.is_paused or not is_instance_valid(_player): return
	_timer -= delta
	if _state == "rest":
		var toward := _player.global_position - global_position
		toward.y = 0
		if toward.length() > 2.5:
			velocity = toward.normalized() * 2.6
			_visual.rotation.y = lerp_angle(_visual.rotation.y, atan2(toward.x, toward.z), 6.0 * delta)
			move_and_slide()
		if _timer <= 0.0:
			_target = _player.global_position
			_target.y = global_position.y + 0.08
			if is_instance_valid(_warning):
				_warning.global_position = _target
				_warning.visible = true
			_state = "warning"
			_timer = 1.25
			_play("Punch" if is_orc else "Headbutt")
	elif _timer <= 0.0:
		if is_instance_valid(_warning): _warning.visible = false
		var diff := _player.global_position - _target
		diff.y = 0
		if diff.length() < 1.65 and absf(_player.global_position.y - _target.y) < 2.5:
			_player.call("take_damage", Game.max_hp() * 0.10, global_position)
		_state = "rest"
		_timer = 3.0
		_play("Idle" if is_orc else "Flying_Idle")


func take_hit(power: float, _element: int, _direction: Vector3) -> void:
	if _dead: return
	hp = maxf(0.0, hp - maxf(0.0, power))
	_label.text = "%s · %d" % ["Vault raider" if is_orc else "Hollow scout", int(hp)]
	if hp <= 0.0:
		_dead = true
		defeated.emit()
		queue_free()


func take_combined_hit(power: float, first: int, _second: int, direction: Vector3) -> void:
	take_hit(power, first, direction)


func _exit_tree() -> void:
	if is_instance_valid(_warning): _warning.queue_free()


func _play(part: String) -> void:
	if _animation == null: return
	for name in _animation.get_animation_list():
		if str(name).to_lower().ends_with(part.to_lower()):
			if _animation.current_animation != name or not _animation.is_playing():
				_animation.play(name)
			return
