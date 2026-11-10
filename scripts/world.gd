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
const GrassFieldScript := preload("res://scripts/grass_field.gd")

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
## True once _ready() finished wiring the environment, sun and player.
var _built := false
## Rolling frame-time probe used to auto-pick a quality tier on weak hardware.
var _perf_frames := 0
var _perf_warmup := 45
var _perf_accum := 0.0
var _perf_done := false
## Countdown of frames to wait before sampling the framebuffer once.
var _grass_field: Node3D
var _render_check_countdown := -1
var _render_checked := false


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

	# Environment + player come first and are guaranteed: without a camera the
	# 3D viewport renders nothing at all (black screen, while the CanvasLayer
	# HUD still draws), so nothing optional may run before them.
	_setup_environment()
	_spawn_player()

	# Everything else is scenery dressed on afterwards.
	_build_lake()
	_build_spawn_glade()
	_scatter_landmarks()
	_spawn_waypoints()
	_spawn_sigils()
	_spawn_enemies()
	_spawn_clouds()
	_add_audio()
	Game.quest_changed.emit(Game.quest_text)
	apply_quality()
	_build_grass_field.call_deferred()

	# Never ship a black screen: if for any reason the player's camera did not
	# come up current, park a fallback camera over the valley, then keep an eye
	# on the framebuffer for the first seconds in case the view is still blank.
	_built = true
	_ensure_camera.call_deferred()
	_watch_render()
	_autotune_performance()


func _autotune_performance() -> void:
	## Phones like the Oppo F19 Pro (Helio P95 / PowerVR GM9446) can render this
	## world but not with every effect on. Measure real frame time once and drop
	## to the Performance tier if frames are being missed.
	##
	## Purely frame-driven - no coroutines, no timers - so it cannot wedge.
	if _perf_done:
		return
	_perf_done = true
	var measured := _perf_frames - _perf_warmup
	if measured < 20:
		return
	var avg_ms := (_perf_accum / float(measured)) * 1000.0
	print("LastStar: average frame time %.1f ms over %d frames" % [avg_ms, measured])
	# Worse than ~24 fps: shed effects instead of stuttering.
	if avg_ms > 42.0 and Game.quality_tier != 1:
		Game.set_quality_tier(1)
		apply_quality()
		Game.toast.emit("Performance mode enabled for smooth play")


func _watch_render() -> void:
	## Safety net. A camera can exist and still render nothing (wrong far plane,
	## environment without a sky, driver refusing the scene). After the first
	## frames we look at the actual pixels once; if the 3D layer came out black
	## we repair the most likely causes so the player is never stuck staring at
	## a black screen with a HUD floating on top of it.
	##
	## Deliberately does NOT await RenderingServer.frame_post_draw: on a device
	## whose render loop has stalled that signal never fires, which would leave
	## this coroutine (and the auto-tuner behind it) wedged forever instead of
	## repairing anything. A plain frame counter is enough here.
	if DisplayServer.get_name() == "headless":
		return
	# No GPU readback here on purpose: get_texture().get_image() forces a
	# pipeline stall and can wedge software/GL drivers. The watchdog instead
	# verifies state that is cheap and safe to inspect (camera, lights, env).
	_render_check_countdown = 10
	_render_checked = false


func _check_rendered_frame() -> void:
	## Cheap, allocation-free sanity check of the render state.
	##
	## Earlier versions read the framebuffer back with get_image() to prove the
	## view was not black. That readback blocks until the GPU completes, and on
	## software/GL drivers it wedged the main loop long enough to hang the CI
	## job. Pixel proof belongs in tests/render_probe.tscn; at runtime we verify
	## the things that actually go wrong: a missing camera, a disabled sun, or
	## an environment that was never assigned.
	_render_checked = true
	var problems := PackedStringArray()
	if get_viewport().get_camera_3d() == null:
		problems.append("no active camera")
	if sun == null or not sun.visible or sun.light_energy <= 0.01:
		problems.append("sun not lighting the scene")
	if environment == null or environment.environment == null:
		problems.append("no Environment assigned")
	if problems.is_empty():
		return
	push_warning("LastStar: render state problem (%s) - repairing" % ", ".join(problems))
	repair_render()


func repair_render() -> void:
	## Rebuild the rendering state from scratch. Cheap enough to run once, and
	## it fixes the whole class of "entity exists but nothing draws" problems.
	var env_node := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node == null:
		env_node = WorldEnvironment.new()
		env_node.name = "WorldEnvironment"
		add_child(env_node)
	if env_node.environment == null:
		env_node.environment = Environment.new()
	_setup_environment()

	# Make sure a camera is current. A fallback is only installed when the
	# viewport genuinely has none, so the player's own camera is never replaced.
	_ensure_camera()
	var cam := get_viewport().get_camera_3d()
	if cam:
		cam.near = 0.05

	# The sun must exist and point down, otherwise everything is a black
	# silhouette lit only by ambient.
	if sun:
		sun.visible = true
		# Enough to light the scene, not enough to clip it: 1.4 here fought the
		# calibrated daytime value every time the self-repair ran.
		sun.light_energy = maxf(sun.light_energy, 0.85)
		sun.rotation_degrees = Vector3(-48.0, -38.0, 0.0)

	# Bring the player's own camera back to a sane orbit distance.
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		var p := players[0]
		for child in p.get_children():
			if child is SpringArm3D:
				child.spring_length = 4.6
				child.collision_mask = 1
				child.margin = 0.25
		p.global_position = Vector3(0.0, _height(0.0, 0.0) + 3.0, 6.0)
	Game.toast.emit("Rendering repaired")


func _ensure_camera() -> void:
	if get_viewport().get_camera_3d() != null:
		return
	push_error("LastStar: no active camera after world build - installing fallback")
	var cam := Camera3D.new()
	cam.name = "FallbackCamera"
	cam.fov = 70.0
	cam.near = 0.08
	cam.far = 900.0
	cam.position = Vector3(0.0, _height(0.0, 0.0) + 9.0, 26.0)
	cam.rotation_degrees = Vector3(-11.0, 0.0, 0.0)
	cam.current = true
	add_child(cam)



func _is_compatibility() -> bool:
	## True on the OpenGL ES 3.0 renderer (what Android ships with).
	return str(ProjectSettings.get_setting("rendering/renderer/rendering_method")) == "gl_compatibility"


func apply_quality() -> void:
	## 0 Balanced · 1 Performance · 2 High. Lets the same APK scale from a
	## budget phone to a flagship. Every tier restores what it changes, so
	## cycling through them is lossless, and tiers never enable a feature the
	## active renderer does not implement (SSAO does not exist on OpenGL).
	var tier := Game.quality_tier
	var compat := _is_compatibility()
	var env := environment.environment as Environment
	var veg := get_node_or_null("Vegetation")

	# --- shadows -----------------------------------------------------------
	if tier == 1:
		sun.shadow_enabled = false
		sun.directional_shadow_max_distance = 120.0
	elif compat:
		# Compatibility shadows are cheap but not free; keep the radius short.
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 110.0 if tier == 0 else 150.0
	else:
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 260.0 if tier == 2 else 190.0

	# --- grass -------------------------------------------------------------
	# Grass is the single biggest draw on a mobile GPU, so the tier controls its
	# density rather than switching it off: an empty valley looks broken, a
	# thinner meadow still looks like a meadow.
	if _grass_field != null and _grass_field.has_method("set_density_scale"):
		_grass_field.call("set_density_scale", 1.0 if tier >= 2 else (0.65 if tier == 0 else 0.35))

	# --- vegetation ---------------------------------------------------------
	if veg:
		veg.visible = tier != 1

	if env == null:
		return

	# --- glow / ambient occlusion / AA -------------------------------------
	# SSAO is a Vulkan-renderer feature; setting it on OpenGL is a no-op and
	# only risks confusing the state when switching renderers.
	match tier:
		1:
			env.glow_enabled = false
			env.ssao_enabled = false
			env.adjustment_saturation = 1.05
			_env_msaa(RenderingServer.VIEWPORT_MSAA_DISABLED)
		2:
			env.glow_enabled = true
			env.glow_intensity = 0.32
			env.glow_hdr_threshold = 1.25
			env.ssao_enabled = not compat
			if not compat:
				env.ssao_radius = 1.4
				env.ssao_intensity = 1.6
			env.adjustment_saturation = 1.24
			env.adjustment_contrast = 1.08
			_env_msaa(RenderingServer.VIEWPORT_MSAA_4X if not compat else RenderingServer.VIEWPORT_MSAA_DISABLED)
		_:
			env.glow_enabled = true
			env.glow_intensity = 0.26 if not compat else 0.22
			env.glow_hdr_threshold = 1.30
			env.ssao_enabled = false
			env.adjustment_saturation = 1.22
			env.adjustment_contrast = 1.10
			_env_msaa(RenderingServer.VIEWPORT_MSAA_2X if not compat else RenderingServer.VIEWPORT_MSAA_DISABLED)


func _env_msaa(mode: RenderingServer.ViewportMSAA) -> void:
	RenderingServer.viewport_set_msaa_3d(get_viewport().get_viewport_rid(), mode)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.16, 0.42, 0.88)
	sky_mat.sky_horizon_color = Color(0.74, 0.89, 1.0)
	sky_mat.sky_curve = 0.11
	sky_mat.sky_energy_multiplier = 1.25
	# The ground half of a procedural sky is only seen below the horizon, but a
	# pitch-black or blown-out value there shows up in reflections and fog, so
	# keep it a soft hazy green-blue.
	sky_mat.ground_bottom_color = Color(0.30, 0.44, 0.40)
	sky_mat.ground_horizon_color = Color(0.80, 0.91, 0.97)
	sky_mat.ground_curve = 0.06
	sky_mat.sun_angle_max = 26.0
	sky_mat.sun_curve = 0.10
	sky.sky_material = sky_mat
	env.sky = sky
	# Ambient was 1.15 here, then recomputed every frame to 0.85-1.40 by the
	# day/night pass, on top of a bright procedural sky at 0.85 contribution and
	# a sun at up to 1.80 energy. Three bright lights stacked is what washed the
	# whole world to pale mint. An anime look wants a modest ambient and a
	# strong, contrasty key light instead.
	# Sky-sourced ambient inherits the full brightness of a very blue sky, which
	# tints every green surface toward cyan - that is why the valley read as
	# pale mint no matter how the light energies were tuned. A muted, slightly
	# warm ambient keeps grass green and lets the sun do the colouring.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.55
	env.ambient_light_color = Color(0.58, 0.62, 0.68)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Sky ambient alone can dip to near-black once the sun is low; this floor
	# guarantees every surface always receives usable light.
	env.ambient_light_sky_contribution = 0.35

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.02
	env.tonemap_white = 2.4

	env.fog_enabled = true
	env.fog_light_color = Color(0.58, 0.72, 0.84)
	# Exponential fog at 0.0006 still laid a visible mint veil over the whole
	# mid-ground. Depth fade is enough for scale; the colour is what sells it.
	env.fog_density = 0.00022
	# Aerial perspective at 0.65 blended every distant hillside straight into
	# the pale sky, which is why the range looked like white noise rather than
	# mountains. Keep only enough for depth separation.
	env.fog_aerial_perspective = 0.30
	env.fog_sky_affect = 0.18
	env.fog_depth_begin = 220.0
	env.fog_depth_end = 900.0
	env.fog_depth_curve = 0.75

	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_strength = 1.0
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	env.adjustment_enabled = true
	env.adjustment_brightness = 1.04
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.15

	environment.environment = env

	sun.light_color = Color(1.0, 0.95, 0.86)
	# Matches the daytime value the day/night pass computes (0.85-1.30).
	sun.light_energy = 1.05
	sun.light_angular_distance = 0.4
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 190.0
	sun.directional_shadow_split_1 = 0.16
	sun.light_specular = 0.8
	sun.rotation_degrees = Vector3(-48, -38, 0)


func _process(delta: float) -> void:
	_time += delta
	if Game.is_paused or not _built:
		return
	_day_time = fposmod(_day_time + delta * _day_speed, 1.0)
	_update_time_of_day()
	# One-shot black-frame check, a few frames in (no renderer awaits).
	if not _render_checked and _render_check_countdown >= 0:
		_render_check_countdown -= 1
		if _render_check_countdown <= 0:
			_check_rendered_frame()

	# Sample frame time; decide once we have enough real frames.
	if not _perf_done and _perf_frames < 400:
		_perf_frames += 1
		if _perf_frames > _perf_warmup:
			_perf_accum += delta
			if _perf_frames >= _perf_warmup + 60:
				_autotune_performance()


func _update_time_of_day() -> void:
	# Golden-hour biased cycle. The sun stays above the horizon for most of the
	# loop and never drops so low that the valley goes unlit: an open-world game
	# that spends a third of its time pitch black reads as "the screen is broken".
	var sun_angle: float = (_day_time - 0.25) * TAU
	var elevation := sin(sun_angle) * 26.0 + 4.0
	sun.rotation_degrees = Vector3(-clampf(elevation, -12.0, 72.0), -38.0, 0.0)

	var day := clampf(sin(sun_angle) * 0.5 + 0.6, 0.0, 1.0)
	var dusk := pow(clampf(1.0 - absf(day - 0.45) / 0.45, 0.0, 1.0), 2.0)

	# 0.85-1.80 was blowing out every sunlit surface; the terracing in the
	# terrain shader does the stylising, so the key light can be honest.
	sun.light_energy = 0.85 + day * 0.45
	sun.light_color = Color(1.0, 0.95, 0.86).lerp(Color(1.0, 0.70, 0.48), clampf(dusk, 0.0, 1.0) * 0.6)
	sun.visible = true

	var env := environment.environment as Environment
	if env == null:
		return
	# Keep ambient low and cool so the warm key light reads as sunlight rather
	# than as one of three equally bright lights.
	env.ambient_light_energy = 0.42 + day * 0.16
	env.ambient_light_color = Color(0.54, 0.58, 0.66).lerp(Color(0.62, 0.66, 0.72), day)
	env.fog_light_color = Color(0.70, 0.82, 0.96).lerp(Color(1.0, 0.76, 0.58), clampf(dusk, 0.0, 1.0) * 0.55)


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
	# 0.82 albedo under a 1.3-energy sun clipped to white; these read as blank
	# white slabs. A weathered grey stone matches the rock band on the terrain.
	sm.albedo_color = Color(0.46, 0.47, 0.50)
	sm.roughness = 0.85
	sm.metallic = 0.0
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
	# Start comfortably above the analytic surface; the player snaps itself onto
	# the collision mesh on its first physics frame. Ask the terrain node itself
	# for the height: _height() returns 0.0 if the terrain is not wired up yet,
	# and spawning at y=0 on a valley floor at y=+22 buries the body underground.
	var ground := 0.0
	if terrain != null and terrain.has_method("get_height_at"):
		ground = terrain.get_height_at(0.0, 6.0)
	else:
		ground = _height(0.0, 6.0)
	var spawn := Vector3(0.0, ground + 6.0, 6.0)
	player.position = spawn
	add_child(player)


func _build_grass_field() -> void:
	## A streaming grass carpet that follows the player, so the whole valley is
	## grassed without paying for blades that are nowhere near the camera.
	var player := get_node_or_null("Player")
	var t := get_node_or_null("Terrain")
	if player == null or t == null:
		push_warning("LastStar: no player/terrain - grass field not built")
		return
	var field := Node3D.new()
	field.set_script(GrassFieldScript)
	add_child(field)
	field.call("setup", t, player)
	_grass_field = field


func _add_audio() -> void:
	var audio := Node3D.new()
	audio.name = "Ambience"
	audio.set_script(AudioDirectorScript)
	add_child(audio)


func _spawn_clouds() -> void:
	## Soft billboard clouds drifting above the valley.
	##
	## These used to be plain unshaded white quads. With no texture and no
	## falloff they rendered as solid blue-white rectangles hanging in the sky -
	## the single most "this is a prototype" thing in the whole scene. Each
	## cloud is now a cluster of soft procedural puffs that fade at the rim.
	var tex := _cloud_texture()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = tex
	mat.albedo_color = Color(1.0, 0.99, 0.97, 0.55)

	for i in range(14):
		var cluster := Node3D.new()
		cluster.position = Vector3(
			_rng.randf_range(-520.0, 520.0),
			_rng.randf_range(120.0, 195.0),
			_rng.randf_range(-520.0, 520.0))
		# 3-5 overlapping puffs of different sizes make a believable cloud.
		var puffs := _rng.randi_range(3, 5)
		for p in range(puffs):
			var cloud := MeshInstance3D.new()
			var quad := QuadMesh.new()
			var s := _rng.randf_range(46.0, 96.0)
			quad.size = Vector2(s, s * 0.52)
			cloud.mesh = quad
			cloud.material_override = mat
			cloud.position = Vector3(
				_rng.randf_range(-0.55, 0.55) * s,
				_rng.randf_range(-0.10, 0.10) * s,
				_rng.randf_range(-0.55, 0.55) * s)
			cloud.rotation.y = _rng.randf() * TAU
			cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cluster.add_child(cloud)
		add_child(cluster)


func _cloud_texture() -> Texture2D:
	## A radial soft blob, generated once: opaque in the middle, transparent at
	## the rim, with a little noise so the edge is not a clean circle.
	var size := 96
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.055
	noise.seed = 7
	var half := float(size) * 0.5
	for y in range(size):
		for x in range(size):
			var nx := (float(x) + 0.5 - half) / half
			var ny := (float(y) + 0.5 - half) / half
			var r := sqrt(nx * nx + ny * ny)
			# Soft edge, pushed in and out by noise.
			var edge := 1.0 - smoothstep(0.45, 1.0, r + noise.get_noise_2d(x, y) * 0.14)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(edge, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
