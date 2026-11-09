extends Node3D
## LastStar open world. Builds the valley, dresses it with Genshin-ish props
## (wind-gliders' arches, crystal formations, ruins), spawns enemies, sigils
## and waypoint statues, runs the day/night cycle and weather.

const FX := preload("res://scripts/fx.gd")
const SlimeScript := preload("res://scripts/slime.gd")
const SigilScript := preload("res://scripts/sigil.gd")
const WaypointScript := preload("res://scripts/waypoint_statue.gd")
const WaterScript := preload("res://scripts/water_plane.gd")
const PlayerScript := preload("res://scripts/player.gd")
const AudioDirectorScript := preload("res://scripts/audio_director.gd")

const ENEMY_COUNT := 14

@onready var terrain: Node3D = $Terrain
@onready var sun: DirectionalLight3D = $Sun
@onready var environment: WorldEnvironment = $WorldEnvironment

var _rng := RandomNumberGenerator.new()
var _props: Node3D
var _enemies: Node3D
var _collectibles: Node3D
var _day_time: float = 0.32
var _day_speed: float = 0.0055
var _time := 0.0


func _ready() -> void:
	# The app's main scene is the world itself: boot straight into a run with
	# full health/energy instead of inheriting menu state.
	if not Game.booted:
		Game.booted = true
		Game.boot_direct()
	if Game.pending_unpause:
		Game.pending_unpause = false
		Game.set_paused(false)
	_rng.seed = 90210
	_props = Node3D.new()
	_props.name = "Props"
	add_child(_props)
	_enemies = Node3D.new()
	_enemies.name = "Enemies"
	add_child(_enemies)
	_collectibles = Node3D.new()
	_collectibles.name = "Collectibles"
	add_child(_collectibles)

	_setup_environment()
	_build_lake()
	_build_spawn_glade()
	_scatter_landmarks()
	_spawn_waypoints()
	_spawn_sigils()
	_spawn_enemies()
	_spawn_player()
	_spawn_clouds()
	_add_audio()
	Game.quest_changed.emit(Game.quest_text)
	apply_quality()


func apply_quality() -> void:
	## 0 Balanced · 1 Performance · 2 High. Lets the same APK scale from a
	## budget phone to a flagship without shipping two builds.
	var tier := Game.quality_tier
	if tier == 1:
		sun.shadow_enabled = false
		if has_node("Vegetation"):
			get_node("Vegetation").visible = false
		RenderingServer.directional_shadow_atlas_set_size(1024, true)
	elif tier == 2:
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 260.0
		var env := environment.environment as Environment
		if env:
			env.glow_intensity = 0.55
			env.ssao_enabled = true
			env.ssao_radius = 1.2


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.46, 0.86)
	sky_mat.sky_horizon_color = Color(0.76, 0.90, 0.98)
	sky_mat.sky_curve = 0.13
	sky_mat.sky_energy_multiplier = 1.15
	sky_mat.ground_bottom_color = Color(0.30, 0.42, 0.38)
	sky_mat.ground_horizon_color = Color(0.78, 0.90, 0.96)
	sky_mat.ground_curve = 0.08
	sky_mat.sun_angle_max = 24.0
	sky_mat.sun_curve = 0.12
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.05
	env.ambient_light_color = Color(0.78, 0.87, 1.0)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.02
	env.tonemap_white = 2.4

	env.fog_enabled = true
	env.fog_light_color = Color(0.76, 0.88, 0.97)
	env.fog_density = 0.0011
	env.fog_aerial_perspective = 0.85
	env.fog_sky_affect = 0.28
	env.fog_depth_begin = 160.0
	env.fog_depth_end = 780.0
	env.fog_depth_curve = 0.68

	env.glow_enabled = true
	env.glow_intensity = 0.42
	env.glow_strength = 0.9
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.0

	env.adjustment_enabled = true
	env.adjustment_brightness = 1.04
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.15

	environment.environment = env

	sun.light_color = Color(1.0, 0.95, 0.84)
	sun.light_energy = 1.55
	sun.light_angular_distance = 0.4
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 190.0
	sun.directional_shadow_split_1 = 0.16
	sun.light_specular = 0.8
	sun.rotation_degrees = Vector3(-48, -38, 0)


func _process(delta: float) -> void:
	_time += delta
	if Game.is_paused:
		return
	_day_time = fposmod(_day_time + delta * _day_speed, 1.0)
	_update_time_of_day()


func _update_time_of_day() -> void:
	# 0.0 = dawn, 0.25 = noon, 0.5 = dusk, 0.75 = midnight.
	var sun_angle: float = (_day_time - 0.25) * TAU
	sun.rotation_degrees = Vector3(rad_to_deg(sun_angle) * 0.55 - 12.0, -38.0, 0.0)
	var day := clampf(sin(_day_time * TAU - 0.5) * 0.5 + 0.5, 0.0, 1.0)
	var dusk := pow(clampf(1.0 - absf(day - 0.42) / 0.42, 0.0, 1.0), 3.0)
	sun.light_energy = 0.25 + day * 1.5
	sun.light_color = Color(1.0, 0.92, 0.8).lerp(Color(1.0, 0.62, 0.42), clampf(dusk, 0.0, 1.0) * 0.7)
	var env := environment.environment as Environment
	env.ambient_light_energy = 0.45 + day * 0.75
	env.fog_light_color = Color(0.72, 0.84, 0.96).lerp(Color(1.0, 0.72, 0.55), clampf(dusk, 0.0, 1.0) * 0.6)
	sun.visible = day > 0.03


func _build_lake() -> void:
	var water := Node3D.new()
	water.name = "Lake"
	water.set_script(WaterScript)
	add_child(water)


func _height(x: float, z: float) -> float:
	if terrain and terrain.has_method("get_height_at"):
		return terrain.get_height_at(x, z)
	return 0.0


func _build_spawn_glade() -> void:
	var center := Vector3(0, _height(0, 0), 0)
	# A ring of standing stones with a glowing wind altar at the spawn point.
	var altar := Node3D.new()
	altar.name = "WindAltar"
	altar.position = center
	add_child(altar)

	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.emission_enabled = true
	glow.emission = Color(0.55, 0.95, 0.9)
	glow.emission_energy_multiplier = 2.2
	glow.albedo_color = Color(0.7, 1.0, 0.95)

	var disc := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 2.6
	cylinder.bottom_radius = 3.0
	cylinder.height = 0.25
	cylinder.radial_segments = 24
	disc.mesh = cylinder
	disc.material_override = glow
	altar.add_child(disc)

	var stone := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 2.2, 0.6)
	stone.mesh = box
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.82, 0.86, 0.9)
	stone.material_override = sm
	stone.position.y = 1.1
	stone.rotation_degrees = Vector3(0, 25, 0)
	altar.add_child(stone)

	for i in range(6):
		var a := TAU * float(i) / 6.0
		var pillar := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.9, _rng.randf_range(3.4, 5.2), 0.9)
		pillar.mesh = mesh
		pillar.material_override = sm
		pillar.position = center + Vector3(cos(a) * 9.0, mesh.size.y * 0.5 - 0.4, sin(a) * 9.0)
		pillar.rotation_degrees = Vector3(0, rad_to_deg(a) + 8.0, _rng.randf_range(-5.0, 5.0))
		_props.add_child(pillar)

		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = mesh.size
		col.shape = shape
		body.add_child(col)
		pillar.add_child(body)

	var light := OmniLight3D.new()
	light.light_color = Color(0.55, 0.95, 0.9)
	light.light_energy = 3.0
	light.omni_range = 14.0
	light.position = center + Vector3(0, 2.0, 0)
	add_child(light)


func _scatter_landmarks() -> void:
	var stone_mat := StandardMaterial3D.new()
	stone_mat.albedo_color = Color(0.78, 0.8, 0.86)
	stone_mat.roughness = 0.85

	# Wind arches: tall broken gates that read like Genshin's ruins.
	for i in range(7):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(60.0, 260.0)
		var x := cos(a) * r
		var z := sin(a) * r
		if Vector2(x, z).distance_to(Game.lake_center) < Game.lake_radius * 0.9:
			continue
		var y := _height(x, z)
		if y < 2.0 or y > 90.0:
			continue
		var gate := Node3D.new()
		gate.position = Vector3(x, y, z)
		gate.rotation.y = _rng.randf() * TAU
		_props.add_child(gate)
		for side in [-1.0, 1.0]:
			var pillar := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(1.4, 8.5, 1.4)
			pillar.mesh = box
			pillar.material_override = stone_mat
			pillar.position = Vector3(2.6 * side, 4.25, 0)
			gate.add_child(pillar)
		var lintel := MeshInstance3D.new()
		var box2 := BoxMesh.new()
		box2.size = Vector3(7.0, 1.1, 1.6)
		lintel.mesh = box2
		lintel.material_override = stone_mat
		lintel.position.y = 8.4
		gate.add_child(lintel)

	# Floating crystal formations.
	var crystal_colors := [Color(0.55, 0.85, 1.0), Color(0.75, 0.6, 1.0), Color(1.0, 0.78, 0.55)]
	for i in range(14):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(40.0, 300.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 1.5:
			continue
		var cluster := Node3D.new()
		cluster.position = Vector3(x, y - 0.2, z)
		_props.add_child(cluster)
		var col: Color = crystal_colors[i % crystal_colors.size()]
		for k in range(_rng.randi_range(3, 6)):
			var crystal := MeshInstance3D.new()
			var mesh := PrismMesh.new()
			var h := _rng.randf_range(0.8, 2.4)
			mesh.size = Vector3(_rng.randf_range(0.3, 0.7), h, _rng.randf_range(0.3, 0.7))
			crystal.mesh = mesh
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(col.r, col.g, col.b, 0.85)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.emission_enabled = true
			m.emission = col
			m.emission_energy_multiplier = 1.2
			m.roughness = 0.15
			m.metallic = 0.4
			crystal.material_override = m
			crystal.position = Vector3(_rng.randf_range(-1.2, 1.2), h * 0.5, _rng.randf_range(-1.2, 1.2))
			crystal.rotation_degrees = Vector3(_rng.randf_range(-18, 18), _rng.randf() * 360, _rng.randf_range(-18, 18))
			cluster.add_child(crystal)

	# Campfires + wooden shelter props near waypoints for a lived-in feel.
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.32, 0.23)
	for i in range(6):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(70.0, 240.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 2.5 or Vector2(x, z).distance_to(Game.lake_center) < Game.lake_radius:
			continue
		var camp := Node3D.new()
		camp.position = Vector3(x, y, z)
		_props.add_child(camp)
		for k in range(3):
			var log_mesh := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.16
			cyl.bottom_radius = 0.2
			cyl.height = 1.8
			cyl.radial_segments = 6
			log_mesh.mesh = cyl
			log_mesh.material_override = wood
			var aa := TAU * float(k) / 3.0
			log_mesh.position = Vector3(cos(aa) * 0.5, 0.2, sin(aa) * 0.5)
			log_mesh.rotation_degrees = Vector3(74, rad_to_deg(aa), 0)
			camp.add_child(log_mesh)
		var fire := MeshInstance3D.new()
		var fmesh := SphereMesh.new()
		fmesh.radius = 0.28
		fmesh.height = 0.9
		fire.mesh = fmesh
		var fm := StandardMaterial3D.new()
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fm.albedo_color = Color(1.0, 0.6, 0.2, 0.9)
		fm.emission_enabled = true
		fm.emission = Color(1.0, 0.55, 0.15)
		fm.emission_energy_multiplier = 3.0
		fire.material_override = fm
		fire.position.y = 0.4
		camp.add_child(fire)
		var fire_light := OmniLight3D.new()
		fire_light.light_color = Color(1.0, 0.6, 0.25)
		fire_light.light_energy = 2.4
		fire_light.omni_range = 8.0
		fire_light.position.y = 1.0
		camp.add_child(fire_light)
		var t := fire_light.create_tween().set_loops()
		t.tween_property(fire_light, "light_energy", 1.6, 0.5)
		t.tween_property(fire_light, "light_energy", 2.6, 0.7)


func _spawn_waypoints() -> void:
	var spots := [
		{"name": "Starlit Shore", "pos": Vector3(0.0, 0.0, 0.0)},
		{"name": "Windrise Lookout", "pos": Vector3(-140.0, 0.0, -60.0)},
		{"name": "Jadewater Glade", "pos": Vector3(250.0, 0.0, 120.0)},
	]
	for spot in spots:
		var p: Vector3 = spot["pos"]
		var statue := Area3D.new()
		statue.set_script(WaypointScript)
		statue.statue_name = str(spot["name"])
		statue.position = Vector3(p.x, _height(p.x, p.z) - 0.2, p.z)
		add_child(statue)


func _spawn_sigils() -> void:
	var placed := 0
	var attempts := 0
	var used: Array[Vector3] = []
	while placed < Game.TOTAL_SIGILS and attempts < 600:
		attempts += 1
		var a := TAU * float(placed) / float(Game.TOTAL_SIGILS) + _rng.randf_range(-0.25, 0.25)
		var r := _rng.randf_range(55.0, 300.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 1.6 or y > 120.0:
			continue
		if Vector2(x, z).distance_to(Game.lake_center) < Game.lake_radius * 0.75:
			continue
		var too_close := false
		for u in used:
			if Vector2(u.x, u.z).distance_to(Vector2(x, z)) < 30.0:
				too_close = true
				break
		if too_close:
			continue
		used.append(Vector3(x, y, z))
		var sigil := Area3D.new()
		sigil.set_script(SigilScript)
		sigil.position = Vector3(x, y + 0.6, z)
		sigil.name = "Sigil_%d" % placed
		_collectibles.add_child(sigil)
		placed += 1


func _spawn_enemies() -> void:
	for i in range(ENEMY_COUNT):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(25.0, 250.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 1.8 or Vector2(x, z).distance_to(Game.lake_center) < Game.lake_radius * 0.8:
			continue
		var slime := CharacterBody3D.new()
		slime.set_script(SlimeScript)
		slime.position = Vector3(x, y + 1.2, z)
		slime.set_element(i % 3)
		_enemies.add_child(slime)


func _spawn_player() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(PlayerScript)
	var spawn := Vector3(0, _height(0, 0) + 4.0, 6.0)
	player.position = spawn
	add_child(player)


func _add_audio() -> void:
	var audio := Node3D.new()
	audio.name = "Ambience"
	audio.set_script(AudioDirectorScript)
	add_child(audio)


func _spawn_clouds() -> void:
	# Big soft billboard clouds drifting above the valley for depth.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.32)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.no_depth_test = false
	for i in range(18):
		var cloud := MeshInstance3D.new()
		var quad := QuadMesh.new()
		var s := _rng.randf_range(60.0, 150.0)
		quad.size = Vector2(s, s * 0.45)
		cloud.mesh = quad
		cloud.material_override = mat
		cloud.position = Vector3(_rng.randf_range(-400.0, 400.0), _rng.randf_range(95.0, 170.0), _rng.randf_range(-400.0, 400.0))
		cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cloud)
