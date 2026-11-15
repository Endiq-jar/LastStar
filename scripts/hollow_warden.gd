extends CharacterBody3D
## Original temporary Hollow guardian. The requested Mantis models are not bundled.
## Visible ground telegraphs, deliberate recovery windows and a distinct second
## pattern make this a readable encounter rather than a contact-damage sponge.
signal defeated
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
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.7
	shape.height = 2.0
	collider.shape = shape
	collider.position.y = 1.0
	add_child(collider)
	var body := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.65
	mesh.height = 2.0
	body.mesh = mesh
	body.position.y = 1.0
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.22, 0.13, 0.31)
	body.material_override = material
	add_child(body)
	for side in [-1.0, 1.0]:
		var horn := MeshInstance3D.new()
		var horn_mesh := PrismMesh.new()
		horn_mesh.size = Vector3(0.30, 0.72, 0.30)
		horn.mesh = horn_mesh
		horn.material_override = material
		horn.position = Vector3(side * 0.42, 2.05, 0)
		horn.rotation.z = side * -0.45
		add_child(horn)
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
			move_and_slide()
		if _timer <= 0.0:
			_state = "warning"
			_timer = 1.6 if phase == 1 else 1.25
			_target = _player.global_position if phase == 1 else global_position
			_target.y = global_position.y + 0.08
			if is_instance_valid(_warning):
				_warning.global_position = _target
				_warning.visible = true
			Game.toast.emit("Hollow Warden: %s — dodge the red circle!" % ("strike" if phase == 1 else "shockwave"))
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
		Game.toast.emit("Warden phase 2: it will strike around itself!")
	_update_label()
	if hp <= 0.0:
		_dead = true
		if is_instance_valid(_warning): _warning.queue_free()
		defeated.emit()
		queue_free()


func take_combined_hit(power: float, first: int, _second: int, direction: Vector3) -> void:
	take_hit(power, first, direction)


func _update_label() -> void:
	_label.text = "Hollow Warden · Phase %d\n%d / %d" % [phase, int(hp), int(max_hp)]
