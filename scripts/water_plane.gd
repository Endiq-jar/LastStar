extends Node3D
## The world's water: one surface at sea level, covering everything below it.
##
## It used to be a 420 m disc over the lake bowl, because the lake was the only
## water in the world. There is a sea in the south-east, a river running from the
## mountains through the valley into it, and six ponds now - and all of them sit
## on the same water table, so all of them are the same plane. The terrain is what
## decides where water shows: everything carved below SEA_LEVEL is under this
## surface, everything above it is dry land, and the shoreline needs no special
## case at all.
##
## It is one mesh with one material and no per-frame work. Its fragment cost only
## applies where it is actually visible, because the terrain in front of it wins
## the depth test.

@export var size: float = 10000.0

func _ready() -> void:
	var level := Game.water_level
	var span := size
	if Game.world_size > 0.0:
		span = maxf(size, Game.world_size)

	var mi := MeshInstance3D.new()
	mi.name = "WaterSurface"
	var plane := PlaneMesh.new()
	plane.size = Vector2(span, span)
	# 96 across 10 km is a 104 m quad. The shader's waves are a displacement of a
	# few centimetres, which is far below what that can resolve - but they are
	# only ever read as moving highlights, never as a silhouette, so the coarse
	# grid costs nothing visible and keeps the mesh at 18k triangles.
	plane.subdivide_width = 96
	plane.subdivide_depth = 96
	mi.mesh = plane
	mi.position = Vector3(0.0, level + 0.35, 0.0)
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

	# Sparkle lights over the lake, where the player first sees water.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var center := Game.lake_center
	var lake_r := Game.lake_radius
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
		var r := rng.randf_range(10.0, lake_r * 0.75)
		var a := rng.randf() * TAU
		sparkle.position = Vector3(center.x + cos(a) * r, level + rng.randf_range(0.5, 2.5), center.y + sin(a) * r)
		add_child(sparkle)
		var tw := sparkle.create_tween().set_loops()
		tw.tween_property(sparkle, "scale", Vector3(0.2, 0.2, 0.2), rng.randf_range(0.6, 1.4))
		tw.tween_property(sparkle, "scale", Vector3(1.2, 1.2, 1.2), rng.randf_range(0.6, 1.4))
