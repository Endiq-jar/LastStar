extends Node3D
## Telegraph before every pulse. A short damage window and a long rest make the
## trial avoidable; no collision shapes or unbounded timers are spawned.
var trial_name := "Hollow pulse"
var player: CharacterBody3D
var _power_multiplier := 1.0
var _state := "rest"
var _timer := 2.5
var _warning: MeshInstance3D
const RADIUS := 1.7


func _ready() -> void:
	_power_multiplier = Game.enemy_power_multiplier()
	_warning = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = RADIUS
	disc.bottom_radius = RADIUS
	disc.height = 0.04
	disc.radial_segments = 20
	_warning.mesh = disc
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.25, 0.12, 0.55)
	_warning.material_override = material
	_warning.visible = false
	add_child(_warning)
	var label := Label3D.new()
	label.text = trial_name + " · dodge the circle"
	label.position.y = 1.1
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 32
	label.pixel_size = 0.003
	label.outline_size = 6
	label.visibility_range_end = 12.0
	add_child(label)


func _physics_process(delta: float) -> void:
	if Game.is_paused or not is_instance_valid(player): return
	if _state == "rest" and player.global_position.distance_to(global_position) > 12.0: return
	_timer -= delta
	if _timer > 0.0: return
	if _state == "rest":
		_state = "warning"
		_timer = 1.6
		_warning.visible = true
	else:
		_warning.visible = false
		var difference := player.global_position - global_position
		var height := absf(difference.y)
		difference.y = 0.0
		if difference.length() < RADIUS and height < 2.5:
			player.take_damage(Game.max_hp() * 0.08 * _power_multiplier, global_position)
		_state = "rest"
		_timer = 3.5
