extends Area3D
## Waypoint statue ("Teleport Statue" stand-in). Touch to heal the party, set
## the respawn checkpoint and open its wings with a light burst.

@export var statue_name: String = "Starlit Waypoint"

const FX := preload("res://scripts/fx.gd")

var _activated := false
var _time := 0.0
var _wings: Array[Node3D] = []
var _crystal: MeshInstance3D
var _light: OmniLight3D


func _ready() -> void:
	collision_layer = 4
	collision_mask = 2
	monitoring = true
	add_to_group("waypoint")

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 3.4
	shape.shape = sphere
	shape.position.y = 1.0
	add_child(shape)

	var stone := ShaderMaterial.new()
	stone.shader = load("res://shaders/anime_toon.gdshader")
	stone.set_shader_parameter("albedo_color", Color(0.86, 0.88, 0.94))
	stone.set_shader_parameter("shadow_tint", Color(0.6, 0.66, 0.95))
	stone.set_shader_parameter("rim_strength", 0.6)

	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.emission_enabled = true
	glow.emission = Color(0.55, 0.9, 1.0)
	glow.emission_energy_multiplier = 2.6
	glow.albedo_color = Color(0.7, 0.95, 1.0)

	# Plinth
	var base := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.5
	cyl.bottom_radius = 1.9
	cyl.height = 0.6
	cyl.radial_segments = 6
	base.mesh = cyl
	base.material_override = stone
	base.position.y = 0.3
	add_child(base)

	# Tapered spire
	var spire := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.28
	cone.bottom_radius = 0.75
	cone.height = 4.2
	cone.radial_segments = 6
	spire.mesh = cone
	spire.material_override = stone
	spire.position.y = 2.4
	add_child(spire)

	# Floating element crystal
	_crystal = MeshInstance3D.new()
	var octa := SphereMesh.new()
	octa.radius = 0.42
	octa.height = 0.9
	octa.radial_segments = 4
	octa.rings = 2
	_crystal.mesh = octa
	_crystal.material_override = glow
	_crystal.position.y = 5.0
	add_child(_crystal)

	# Folded wings that open on activation.
	for side in [-1.0, 1.0]:
		var pivot := Node3D.new()
		pivot.position = Vector3(0.3 * side, 3.2, 0)
		pivot.rotation_degrees = Vector3(0, 0, -70.0 * side)
		add_child(pivot)
		var wing := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(2.6, 1.5)
		wing.mesh = quad
		var wm := StandardMaterial3D.new()
		wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wm.albedo_color = Color(0.55, 0.9, 1.0, 0.45)
		wm.emission_enabled = true
		wm.emission = Color(0.5, 0.88, 1.0)
		wm.emission_energy_multiplier = 1.6
		wm.cull_mode = BaseMaterial3D.CULL_DISABLED
		wing.material_override = wm
		wing.position = Vector3(1.3 * side, 0.0, 0.0)
		pivot.add_child(wing)
		_wings.append(pivot)

	_light = OmniLight3D.new()
	_light.light_color = Color(0.55, 0.9, 1.0)
	_light.light_energy = 1.4
	_light.omni_range = 9.0
	_light.position.y = 4.0
	add_child(_light)

	var label := Label3D.new()
	label.text = statue_name
	label.font_size = 96
	label.pixel_size = 0.006
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.outline_size = 16
	label.position.y = 6.2
	label.modulate = Color(0.9, 0.97, 1.0, 0.9)
	add_child(label)

	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	_time += delta
	if _crystal:
		_crystal.rotation.y += delta * 0.9
		_crystal.position.y = 5.0 + sin(_time * 1.6) * 0.16
	if _light:
		_light.light_energy = (2.0 if _activated else 1.2) + sin(_time * 2.2) * 0.3


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	if not _activated:
		_activated = true
		for w in _wings:
			var tw := w.create_tween()
			tw.tween_property(w, "rotation:z", deg_to_rad(-22.0 * signf(w.rotation.z)), 1.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	Game.activate_waypoint(statue_name, global_position + Vector3(0, 1.0, 0))
	var amb := get_tree().get_first_node_in_group("ambience")
	if amb and amb.has_method("play_waypoint"):
		amb.play_waypoint()
	await get_tree().create_timer(0.6).timeout
	if is_instance_valid(body):
		FX.heal_burst(get_parent(), global_position + Vector3(0, 1.2, 0), Color(0.55, 0.9, 1.0))
