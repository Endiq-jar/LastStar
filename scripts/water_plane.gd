extends Node3D
## Stylized lake. Sized to the terrain lake bowl; animated by water_anime.gdshader.

@export var size: float = 420.0

func _ready() -> void:
	var center := Game.lake_center
	var level := Game.water_level

	var mi := MeshInstance3D.new()
	mi.name = "LakeSurface"
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	plane.subdivide_width = 64
	plane.subdivide_depth = 64
	mi.mesh = plane
	mi.position = Vector3(center.x, level + 0.35, center.y)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/water/water_anime.gdshader")
	mat.set_shader_parameter("shallow_color", Color(0.42, 0.88, 0.86))
	mat.set_shader_parameter("deep_color", Color(0.05, 0.30, 0.55))
	mat.set_shader_parameter("foam_color", Color(0.95, 0.99, 1.0))
	mat.set_shader_parameter("wave_scale", 0.10)
	mat.set_shader_parameter("wave_speed", 0.55)
	mat.set_shader_parameter("wave_height", 0.05)
	mat.set_shader_parameter("opacity", 0.8)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	# Sparkle lights above the water for the anime reflection look.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for i in range(14):
		var sparkle := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.5, 0.5)
		sparkle.mesh = quad
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(1, 1, 0.95, 0.55)
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		sparkle.material_override = m
		var r := rng.randf_range(10.0, size * 0.35)
		var a := rng.randf() * TAU
		sparkle.position = Vector3(center.x + cos(a) * r, level + rng.randf_range(0.5, 2.5), center.y + sin(a) * r)
		add_child(sparkle)
		var tw := sparkle.create_tween().set_loops()
		tw.tween_property(sparkle, "scale", Vector3(0.2, 0.2, 0.2), rng.randf_range(0.6, 1.4))
		tw.tween_property(sparkle, "scale", Vector3(1.2, 1.2, 1.2), rng.randf_range(0.6, 1.4))
