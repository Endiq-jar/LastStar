extends Control
## LastStar title screen: a slowly orbiting 3D diorama (stylized hills, a tree
## and floating sigils) behind an anime-styled menu panel.

@onready var start_btn: Button = %StartButton
@onready var quit_btn: Button = %QuitButton
@onready var party_row: HBoxContainer = %PartyRow
@onready var quality_btn: Button = %QualityButton

var _diorama: Node3D
var _pivot: Node3D
var _time := 0.0
var _sigils: Array[Node3D] = []


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Game.set_paused(false)
	Game.reset_run()
	start_btn.pressed.connect(_on_start)
	quit_btn.pressed.connect(func(): get_tree().quit())
	quality_btn.pressed.connect(_cycle_quality)
	start_btn.grab_focus()
	if Game.is_mobile() or OS.has_feature("web"):
		quit_btn.visible = false
	_update_quality_label()
	_build_diorama()
	_fill_party()


func _cycle_quality() -> void:
	Game.cycle_quality()
	_update_quality_label()


func _update_quality_label() -> void:
	quality_btn.text = "Quality: %s" % Game.quality_name()


func _fill_party() -> void:
	for i in range(Game.PARTY.size()):
		var data: Dictionary = Game.PARTY[i]
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 2)
		var element := Label.new()
		element.text = str(data["element"])
		element.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		element.add_theme_font_size_override("font_size", 12)
		element.add_theme_color_override("font_color", data["color"])
		v.add_child(element)
		var name_label := Label.new()
		name_label.text = str(data["name"])
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.add_theme_color_override("font_color", Color(1, 1, 1))
		v.add_child(name_label)
		party_row.add_child(v)


func _process(delta: float) -> void:
	_time += delta
	if _pivot:
		_pivot.rotation.y += delta * 0.09
	for i in range(_sigils.size()):
		var s := _sigils[i]
		s.position.y += sin(_time * 1.5 + i) * 0.002
		s.rotation.y += delta * 0.9


func _build_diorama() -> void:
	var host := SubViewportContainer.new()
	host.name = "DioramaHost"
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.stretch = true
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	move_child(host, 0)

	var vp := SubViewport.new()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.size = Vector2i(1280, 720)
	vp.msaa_3d = Viewport.MSAA_2X
	host.add_child(vp)

	var root := Node3D.new()
	vp.add_child(root)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.44, 0.85)
	sky_mat.sky_horizon_color = Color(0.82, 0.93, 1.0)
	sky_mat.ground_bottom_color = Color(0.34, 0.52, 0.44)
	sky_mat.ground_horizon_color = Color(0.78, 0.9, 0.97)
	sky_mat.sky_energy_multiplier = 1.2
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.fog_enabled = true
	env.fog_light_color = Color(0.8, 0.9, 1.0)
	env.fog_density = 0.006
	env_node.environment = env
	root.add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.light_energy = 1.6
	sun.rotation_degrees = Vector3(-42, -55, 0)
	root.add_child(sun)

	# Ground: a large sphere section = rolling green hilltop.
	var ground := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 42.0
	sphere.height = 84.0
	sphere.radial_segments = 48
	sphere.rings = 24
	ground.mesh = sphere
	var gm := ShaderMaterial.new()
	gm.shader = load("res://shaders/anime_toon.gdshader")
	gm.set_shader_parameter("albedo_color", Color(0.45, 0.72, 0.38))
	gm.set_shader_parameter("shadow_tint", Color(0.55, 0.66, 0.92))
	gm.set_shader_parameter("rim_strength", 0.5)
	ground.material_override = gm
	ground.position = Vector3(0, -42.0, 0)
	root.add_child(ground)

	# A hero tree.
	var tree := Node3D.new()
	tree.position = Vector3(-7, 0, -2)
	root.add_child(tree)
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.9
	cyl.height = 6.0
	trunk.mesh = cyl
	trunk.material_override = gm
	trunk.position.y = 3.0
	tree.add_child(trunk)
	for i in range(4):
		var crown := MeshInstance3D.new()
		var crown_mesh := SphereMesh.new()
		crown_mesh.radius = 3.0 - i * 0.45
		crown_mesh.height = 4.2 - i * 0.5
		crown.mesh = crown_mesh
		var lm := ShaderMaterial.new()
		lm.shader = load("res://shaders/anime_toon.gdshader")
		lm.set_shader_parameter("albedo_color", Color(0.42, 0.76, 0.36))
		lm.set_shader_parameter("rim_strength", 0.8)
		crown.material_override = lm
		crown.position = Vector3(cos(i * 1.6) * 1.4, 6.4 + i * 1.1, sin(i * 1.6) * 1.4)
		tree.add_child(crown)

	# Floating elemental sigils over the diorama.
	for i in range(7):
		var sigil := Node3D.new()
		var a := TAU * float(i) / 7.0
		sigil.position = Vector3(cos(a) * 9.0, 7.0 + sin(i * 1.3) * 2.5, sin(a) * 9.0)
		var crystal := MeshInstance3D.new()
		var prism := PrismMesh.new()
		prism.size = Vector3(0.45, 0.9, 0.45)
		crystal.mesh = prism
		var cm := StandardMaterial3D.new()
		var col := Color(0.6, 0.95, 1.0) if i % 2 == 0 else Color(1.0, 0.85, 0.5)
		cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cm.emission_enabled = true
		cm.emission = col
		cm.emission_energy_multiplier = 3.0
		cm.albedo_color = col
		crystal.material_override = cm
		sigil.add_child(crystal)
		root.add_child(sigil)
		_sigils.append(sigil)

	_pivot = Node3D.new()
	_pivot.position = Vector3(0, 4.0, 0)
	root.add_child(_pivot)
	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 46.0
	cam.position = Vector3(0, 2.2, 17.0)
	_pivot.add_child(cam)
	cam.look_at(Vector3(0, 2.4, 0), Vector3.UP)


func _on_start() -> void:
	Game.start_game()
