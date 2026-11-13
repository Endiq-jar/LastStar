extends Node3D
## LastStar open world. Builds the valley, dresses it with Genshin-ish props
## (wind-gliders' arches, crystal formations, ruins), spawns enemies, sigils
## and waypoint statues, runs the day/night cycle and weather.

const SlimeScript := preload("res://scripts/slime.gd")
const SigilScript := preload("res://scripts/sigil.gd")
const WaypointScript := preload("res://scripts/waypoint_statue.gd")
const WaterScript := preload("res://scripts/water_plane.gd")
const PlayerScript := preload("res://scripts/player.gd")
const AudioDirectorScript := preload("res://scripts/audio_director.gd")
const GrassFieldScript := preload("res://scripts/grass_field.gd")
const VegWindScript := preload("res://scripts/performance/vegetation_wind.gd")
const VegLayerScript := preload("res://scripts/performance/vegetation_layer.gd")
const VegPresets := preload("res://scripts/performance/vegetation_presets.gd")
const VegMeshes := preload("res://scripts/performance/vegetation_meshes.gd")
const EntityCullerScript := preload("res://scripts/performance/entity_culler.gd")
const BoneCloth := preload("res://scripts/bone_cloth.gd")

const ENEMY_COUNT := 14

@onready var terrain: Node3D = $Terrain
@onready var sun: DirectionalLight3D = $Sun
@onready var environment: WorldEnvironment = $WorldEnvironment

var _rng := RandomNumberGenerator.new()
var _props: Node3D
var _enemies: Node3D
var _collectibles: Node3D
## One hundredth of a day is about 15 in-game minutes with the default cycle
## speed - finer than the lighting curve moves perceptibly, coarse enough that
## the environment is rewritten a few times a second instead of every frame.
const DAY_UPDATE_STEP := 0.01
var _day_time: float = 0.32
var _day_speed: float = 0.0055
## Last _day_time value whose lighting was actually pushed to the engine.
var _day_applied := -1.0
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
## Async occluder that decides which entities are actually on screen.
var _culler: Node
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
	# Clouds are drawn by shaders/sky/sky_anime.gdshader now, not spawned as 3D
	# billboards - see the note there on why billboards could not be placed.
	_scatter_landmarks()
	_spawn_waypoints()
	_spawn_sigils()
	_spawn_enemies()
	_build_entity_culler()
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
	# The map is 10 km across and the far shell reaches 5 km. A 900 m far plane
	# would cut the horizon off in a hard line, so the fallback camera matches
	# the player's.
	cam.far = 4200.0
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
	#
	# Performance used to switch the sun's shadow map off completely. That single
	# line is the whole "the character is floating on nothing" problem: with no
	# shadow map there is no contact shadow under her, no cast shadow from the
	# hills, and no self-shadowing anywhere. The world flattens into pure ambient
	# and every object looks pasted on. A short-radius shadow map is one of the
	# cheapest things on the GPU and it is the single most important depth cue in
	# the frame, so no tier turns it off now - the tiers only shorten its reach.
	if tier == 1:
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 70.0
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
	#
	# Performance used to set the whole Vegetation node invisible: every tree,
	# rock, flower and shrub in the valley vanished and the player was left on
	# bare terrain with a few far-off waypoints. That is why the phone screenshots
	# look like an empty green plane with props scattered on it while the desktop
	# renders have hillsides full of trees. Thinning the scatter is a fair trade;
	# deleting the entire world's dressing is not, so no tier does that now.
	if veg:
		veg.visible = true
		if veg.has_method("set_detail_scale"):
			veg.call("set_detail_scale", 1.0 if tier >= 2 else (0.8 if tier == 0 else 0.55))

	# --- resolution scale ----------------------------------------------------
	#
	# The single most effective lever on a fill-rate-bound mobile GPU, and the
	# one the quality tiers were missing entirely. Every earlier tier changed
	# how much geometry existed; none changed how many pixels the screen has.
	# Rendering the 3D pass at 0.8x and letting the canvas upscale costs a
	# little softness on a 6-inch screen and removes a third of the fragment
	# work - which is where the grass, the terrain shader and the shadow
	# resolve all actually live.
	#
	# 3D scaling on the Compatibility renderer only became available in 4.3,
	# which is the version pinned in project.godot, so this is safe on the
	# GLES3 path the phone build uses. It is a no-op rather than an error on any
	# driver that refuses it.
	match tier:
		1:
			_set_3d_scale(0.75)
		0:
			_set_3d_scale(0.9)
		_:
			_set_3d_scale(1.0)

	if env == null:
		return

	# --- glow / ambient occlusion / AA -------------------------------------
	# SSAO is a Vulkan-renderer feature; setting it on OpenGL is a no-op and
	# only risks confusing the state when switching renderers.
	#
	# Note that the colour grade is NOT set here any more. It used to be, which
	# meant apply_quality() and the day/night pass both wrote
	# adjustment_saturation/contrast and the last writer won: at the default tier
	# saturation was forced to 1.22 and contrast to 1.10 behind the day pass's
	# back. Saturation at that level is what pushed every already-saturated green
	# the last few percent into a clipped, channel-starved neon. The grade lives
	# in exactly one place now - _grade_env(), called from the day pass.
	match tier:
		1:
			env.glow_enabled = false
			env.ssao_enabled = false
			_env_msaa(RenderingServer.VIEWPORT_MSAA_DISABLED)
		2:
			env.glow_enabled = true
			env.glow_intensity = 0.30
			env.glow_hdr_threshold = 1.25
			env.ssao_enabled = not compat
			if not compat:
				env.ssao_radius = 1.4
				env.ssao_intensity = 1.6
			_env_msaa(RenderingServer.VIEWPORT_MSAA_4X if not compat else RenderingServer.VIEWPORT_MSAA_DISABLED)
		_:
			env.glow_enabled = true
			env.glow_intensity = 0.26 if not compat else 0.22
			env.glow_hdr_threshold = 1.35
			env.ssao_enabled = false
			_env_msaa(RenderingServer.VIEWPORT_MSAA_2X if not compat else RenderingServer.VIEWPORT_MSAA_DISABLED)
	# Re-apply the grade so a tier change never leaves the frame at whatever
	# saturation it happened to be using.
	_grade_env(env)


func _set_3d_scale(scale: float) -> void:
	## 3D buffer resolution as a fraction of the window. 2D (the HUD) stays at
	## native, so text and buttons keep their crispness while the world behind
	## them renders cheaper - which is the whole reason to scale here rather
	## than dropping the viewport size.
	var vp := get_viewport()
	if vp == null:
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = scale


func _env_msaa(mode: RenderingServer.ViewportMSAA) -> void:
	RenderingServer.viewport_set_msaa_3d(get_viewport().get_viewport_rid(), mode)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	# The stock ProceduralSkyMaterial only gives a two-colour gradient, and the
	# published wide shot read exactly like one: 85% of the frame was a flat blue
	# wash with no clouds, no haze band at the ridge and no sun anywhere in it.
	# shaders/sky/sky_anime.gdshader gives the stacked horizon haze and an analytic sun
	# disc that tracks the directional light, for a few smoothsteps per sky pixel.
	# preload, not load, so the export dependency scanner is guaranteed to pick
	# the shader up and ship it in the APK.
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky/sky_anime.gdshader")
	# Tuned here rather than left at the shader defaults so the values that shape
	# the frame live next to the rest of the lighting rig.
	sky_mat.set_shader_parameter("zenith_color", Color(0.10, 0.28, 0.68))
	sky_mat.set_shader_parameter("horizon_color", Color(0.86, 0.93, 1.0))
	sky_mat.set_shader_parameter("glow_strength", 0.45)
	sky_mat.set_shader_parameter("band_strength", 0.11)
	sky_mat.set_shader_parameter("gradient_power", 0.52)
	# Cloud layer. The height is deliberately far above the terrain rim: the
	# layer is projected, so what matters is that it is high enough that its
	# perspective converges slowly, not that it clears any particular hill.
	sky_mat.set_shader_parameter("cloud_height", 1250.0)
	sky_mat.set_shader_parameter("cloud_scale", 0.0021)
	sky_mat.set_shader_parameter("cloud_coverage", 0.34)
	sky_mat.set_shader_parameter("cloud_opacity", 0.95)
	sky_mat.set_shader_parameter("cloud_color", Color(1.0, 1.0, 1.0))
	sky_mat.set_shader_parameter("cloud_shadow_color", Color(0.74, 0.80, 0.90))
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
	env.ambient_light_energy = 1.35
	env.ambient_light_color = Color(0.57, 0.66, 0.82)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Sky ambient alone can dip to near-black once the sun is low; this floor
	# guarantees every surface always receives usable light.
	env.ambient_light_sky_contribution = 0.45

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.02
	env.tonemap_white = 2.4

	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.80, 0.90)
	# Depth-based fog, not exponential. Exponential fog is a uniform veil: it
	# greys out the near hillside exactly as much as the far ridge, so nothing
	# gains depth - the whole map just looks slightly dirty. A begin/end depth
	# gradient stays at zero through the playable range and then ramps in, which
	# is what separates the ridge layers the way a painted background does.
	#
	# The end depth is also the far draw distance in disguise. The mountains are
	# 2-3.2 km out and the far shell reaches 5 km; with the fog ending at 780 m
	# everything past that was a flat blue wall of terrain with no shape to it.
	# Full fog at 3.7 km puts the ridge line in the haze where it belongs - still
	# readable as a shape - and hides the point where the drawn ground stops.
	env.fog_density = 0.0
	env.fog_depth_begin = 200.0
	env.fog_depth_end = 3700.0
	env.fog_depth_curve = 1.35
	env.fog_aerial_perspective = 0.55
	env.fog_sky_affect = 0.10

	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_strength = 1.0
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.09
	env.adjustment_saturation = 1.10

	environment.environment = env
	_grade_env(env)

	sun.light_color = Color(1.0, 0.95, 0.86)
	# Matches the daytime value the day/night pass computes.
	sun.light_energy = 1.35
	# A wider angular diameter is the only thing that actually softens a
	# directional shadow: shadow_blur only feathers the edge of a hard silhouette,
	# and at 0.4 degrees the sun was effectively a point source, so the character
	# cast a crisp black cut-out with razor edges. That is what made her look
	# superimposed on the ground rather than standing on it. The real sun is about
	# 0.53 degrees, but stylised open worlds exaggerate it considerably to get a
	# soft contact shadow - 1.6 keeps the terminator readable and gives a shadow
	# that fades out rather than ending.
	sun.light_angular_distance = 1.6
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 220.0
	sun.directional_shadow_split_1 = 0.13
	sun.shadow_blur = 2.2
	sun.light_specular = 0.8
	sun.rotation_degrees = Vector3(-34, -52, 0)


func _process(delta: float) -> void:
	_time += delta
	if Game.is_paused or not _built:
		return
	_day_time = fposmod(_day_time + delta * _day_speed, 1.0)
	# _update_time_of_day() was called every single frame, and it is not a cheap
	# function: it writes ~20 Environment properties, reassigns the sun's
	# rotation, colour and energy, and re-applies the whole colour grade. Every
	# one of those is an engine-side setter that dirties the environment and, for
	# the sky, re-sends shader uniforms to the GPU - so the cost is not the
	# GDScript, it is that the renderer re-uploaded lighting state 60 times a
	# second to describe a sun that moves about a degree per minute.
	#
	# The projected-set getter for the environment is a full redraw of the
	# lighting rig, and on the target phone it was a measurable slice of a frame
	# budget that had nothing to spare. Nothing in here changes perceptibly
	# faster than a hundredth of a day, so that is the resolution it is updated
	# at. _set_beauty_time() still calls it directly, so the render probe gets a
	# deterministic frame.
	if absf(_day_time - _day_applied) >= DAY_UPDATE_STEP or _day_applied < 0.0:
		_day_applied = _day_time
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


func _set_beauty_time(t: float) -> void:
	## Freeze the clock at a given time of day. Used by the render probe so the
	## beauty frame always shows the same graded lighting instead of whatever
	## hour the boot happened to land on.
	_day_speed = 0.0
	_day_time = t
	_update_time_of_day()


func _update_time_of_day() -> void:
	## A graded cycle: dawn -> warm morning -> noon -> golden afternoon -> dusk.
	##
	## The old version only lerped the sun colour and ambient energy, so the
	## world barely changed character across the day. Genshin's look comes from
	## the whole frame moving together: warm low sun, purple-blue shadows, sky
	## that shifts hue, and fog that picks up the sun's colour. Every one of
	## those is driven from a single `warmth` value here.
	var sun_angle: float = (_day_time - 0.25) * TAU
	# Low and to the side. A sun 48 degrees up and 38 off-axis flattens the whole
	# valley into evenly-lit green because almost every surface faces it; the
	# long raking light that gives Genshin its shape only happens near the
	# horizon. The cycle now spends most of its time in that band.
	var elevation := sin(sun_angle) * 21.0 + 3.0
	var azimuth := -58.0 + cos(sun_angle) * 14.0
	sun.rotation_degrees = Vector3(-clampf(elevation, -10.0, 60.0), azimuth, 0.0)
	sun.visible = true

	# 1.0 at the warmest (dawn/dusk), 0.0 at high noon.
	var low_sun := 1.0 - clampf((elevation - 2.0) / 22.0, 0.0, 1.0)
	# Capped below 1.0. A fully amber key (1.0, 0.66, 0.36) multiplies blue by a
	# third, and every green surface in the world is already blue-poor - the
	# result was that the whole meadow collapsed onto hue 92 with a blue channel
	# of 9 out of 255. Holding warmth at 0.72 keeps a clearly warm morning key
	# while leaving enough blue in the light for greens to stay greens.
	var warmth := pow(clampf(low_sun, 0.0, 1.0), 1.25) * 0.72

	# --- key light ---------------------------------------------------------
	# Energy peaks slightly *below* noon: a low sun rakes across the hills, and
	# brightening it keeps the lit faces punchy while the shadows stay long.
	sun.light_energy = lerpf(1.28, 1.60, warmth)
	var noon_col := Color(1.0, 0.96, 0.89)
	var dawn_col := Color(1.0, 0.72, 0.46)
	sun.light_color = noon_col.lerp(dawn_col, warmth)
	sun.shadow_enabled = true

	var env := environment.environment as Environment
	if env == null:
		return

	# --- ambient -----------------------------------------------------------
	# Fill light goes cool under a warm sun - that cool-shadow/warm-light contrast
	# is most of the "anime morning" read. It stays bright, though: dim fill plus
	# a raking key is how you get the crushed, muddy shadow side that made the
	# hillsides look like dark green felt. Sky-blue fill keeps shade readable and
	# makes the greens look like they are lit by an open sky.
	var amb_warm := Color(0.50, 0.58, 0.76)
	var amb_noon := Color(0.57, 0.66, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = amb_noon.lerp(amb_warm, warmth)
	# Higher than it looks like it should be, deliberately. In this renderer the
	# terminator on the meadow falls off fast, and at 0.84 the shaded half of
	# every hill sat at rgb(0,38,0) - near black, which is what made the terrain
	# read as a dark green felt wedge rather than grass in shade. Shade in a
	# stylised world is a colour, not an absence of one.
	env.ambient_light_energy = lerpf(1.35, 1.15, warmth)

	# --- fog ---------------------------------------------------------------
	# Fog carries the sun's colour, which is what makes distant hills read as
	# warm-lit rather than grey haze. Pulled in tighter at the warm ends: morning
	# haze pooling in the valley is a signature of the look.
	env.fog_light_color = Color(0.78, 0.86, 0.95).lerp(Color(1.0, 0.82, 0.64), warmth)
	env.fog_depth_begin = lerpf(240.0, 160.0, warmth)
	env.fog_depth_end = lerpf(3800.0, 3200.0, warmth)
	env.fog_depth_curve = lerpf(1.25, 1.55, warmth)
	env.fog_aerial_perspective = lerpf(0.50, 0.62, warmth)

	# --- sky ---------------------------------------------------------------
	# Dawn sky is a soft peach near the horizon with a deeper blue overhead;
	# midday is the clean strong blue we had.
	var sky := env.sky
	if sky != null and sky.sky_material is ProceduralSkyMaterial:
		var mat := sky.sky_material as ProceduralSkyMaterial
		# Deeper at the zenith, paler and warmer at the horizon. The previous
		# pair were nearly the same value, so the whole upper half of the frame
		# was one flat blue slab and the sky competed with the terrain for
		# attention.
		mat.sky_top_color = Color(0.15, 0.32, 0.66).lerp(Color(0.22, 0.30, 0.55), warmth)
		mat.sky_horizon_color = Color(0.74, 0.88, 1.0).lerp(Color(1.0, 0.80, 0.62), warmth)
		mat.sky_energy_multiplier = lerpf(1.15, 1.0, warmth)
		mat.ground_horizon_color = mat.sky_horizon_color
		mat.ground_bottom_color = Color(0.20, 0.26, 0.22).lerp(Color(0.28, 0.24, 0.22), warmth)
	elif sky != null and sky.sky_material is ShaderMaterial:
		# Same intent for the painted sky: deepen the zenith and push the horizon
		# toward peach as the sun drops, so the whole frame moves together. The sun
		# disc and halo need no help - the shader reads LIGHT0 directly, so they
		# follow the light on their own.
		var sm := sky.sky_material as ShaderMaterial
		sm.set_shader_parameter("zenith_color",
			Color(0.10, 0.28, 0.68).lerp(Color(0.13, 0.20, 0.46), warmth))
		sm.set_shader_parameter("horizon_color",
			Color(0.86, 0.93, 1.0).lerp(Color(1.0, 0.83, 0.66), warmth))
		# The warm band is subtle at noon and broad and strong at dawn/dusk.
		sm.set_shader_parameter("glow_strength", lerpf(0.42, 0.78, warmth))
		sm.set_shader_parameter("horizon_glow",
			Color(1.0, 0.94, 0.80).lerp(Color(1.0, 0.70, 0.42), warmth))

	_grade_env(env, warmth)


func _grade_env(env: Environment, warmth: float = 0.5) -> void:
	## The one and only place the colour grade is written.
	##
	## Contrast pulls the frame together and the grade warms slightly as the sun
	## drops, but saturation stays close to 1.0. Pushing it up - which is the
	## obvious "make it pop" move, and was what this did - clips the most
	## saturated surface in the frame (the meadow) while leaving everything else
	## untouched, so the greens go neon and the rock does not change at all. Any
	## extra saturation has to come from the albedo, which this project already
	## has plenty of.
	if env == null:
		return
	env.adjustment_enabled = true
	# Raised to give the "more saturated" look, but the ceiling is deliberate.
	#
	# The old warning - that global saturation clips the most saturated surface in
	# the frame while leaving everything else alone - is still true and is why this
	# is 1.24 and not 1.45. The excess saturation the user is asking for comes from
	# the albedo (the greens were moved to a true green hue, and the rock now has
	# real texture instead of flat grey), so the grade only has to finish the job.
	# Pushed further, the meadow clips to a single flat green and the rock does not
	# move at all - the specific failure the previous comment was written about.
	env.adjustment_saturation = lerpf(1.14, 1.22, warmth)
	env.adjustment_contrast = lerpf(1.10, 1.15, warmth)
	env.adjustment_brightness = lerpf(1.0, 1.02, warmth)



func _build_lake() -> void:
	var water := Node3D.new()
	water.name = "Lake"
	water.set_script(WaterScript)
	add_child(water)


func _height(x: float, z: float) -> float:
	# Routed through TerrainGenerator.ground_point() rather than get_height_at().
	# The analytic field is smooth; the rendered mesh is not, and it sags up to a
	# few decimetres below the analytic surface across each 3 m triangle. Every
	# placement in this file - the player spawn, the glade, waypoints, sigils -
	# was asked for the analytic height, so all of them floated. ground_point()
	# exists for exactly this and had no caller.
	if terrain and terrain.has_method("ground_point"):
		return terrain.call("ground_point", x, z, 0.0).y
	if terrain and terrain.has_method("get_height_at"):
		return terrain.get_height_at(x, z)
	return 0.0


## Is this point under the waterline? Every kind of water - the bay, the lake,
## the river, each pond - is just terrain below sea level, so this one question
## covers all of them. Placement used to ask "am I inside the lake disc?", which
## after the map grew was true of a puddle and false of an ocean.
func _is_wet(x: float, z: float) -> bool:
	if terrain and terrain.has_method("is_underwater"):
		return bool(terrain.call("is_underwater", x, z))
	if terrain and terrain.has_method("get_height_at"):
		return float(terrain.call("get_height_at", x, z)) < Game.water_level
	return false


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
	# Emission colours that are already at 0.9-1.0 in a channel have nowhere to go
	# once multiplied by an energy above 1: they clip, and the result reads as a
	# flat white wedge rather than a glow. Kept under 1.0 with a modest energy so
	# glow picks up the excess instead of the tonemapper flattening it.
	glow.emission = Color(0.40, 0.86, 0.80)
	glow.emission_energy_multiplier = 1.25
	glow.albedo_color = Color(0.55, 0.86, 0.82)

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
	# A monolith with a taper, not a 1x2.2x0.6 box. Knee-high on the altar, not
	# chest-high: the glowing disc is the thing to look at here.
	stone.mesh = VegMeshes.trunk(1.5, 0.5, 0.26, 0.10, 5)
	var sm := StandardMaterial3D.new()
	# 0.82 albedo under a 1.3-energy sun clipped to white; these read as blank
	# white slabs. A weathered grey stone matches the rock band on the terrain.
	sm.albedo_color = Color(0.44, 0.45, 0.49)
	sm.roughness = 0.85
	sm.metallic = 0.0
	stone.material_override = sm
	stone.position.y = 0.75
	stone.rotation_degrees = Vector3(0, 25, 0)
	altar.add_child(stone)

	# Seven stones around an 11 m ring, 1.5-2.6 m tall.
	#
	# They were six at 3.4-5.2 m on a 9 m ring, which reads as a quarry wall
	# around the character's neck: at the spawn camera, three of them filled the
	# middle third of the frame and read as grey slabs standing in the grass. A
	# shrine's standing stones should be taller than her and no taller than twice
	# her, and they should leave the view out.
	for i in range(7):
		var a := TAU * float(i) / 7.0
		var pillar := MeshInstance3D.new()
		# A tapered, slightly leaning stone column instead of a box. Still
		# rectangular in plan - these are built ruins, not boulders - but with a
		# taper, a lean and a real rock texture, which is the difference between
		# "standing stone" and "grey rectangle".
		var ph := _rng.randf_range(1.5, 2.6)
		var mesh := VegMeshes.trunk(ph, 0.46, 0.18, _rng.randf_range(-0.06, 0.06), 6)
		pillar.mesh = mesh
		pillar.material_override = sm
		pillar.position = center + Vector3(cos(a) * 11.0, -0.4, sin(a) * 11.0)
		pillar.rotation_degrees = Vector3(0, rad_to_deg(a) + 8.0, _rng.randf_range(-5.0, 5.0))
		_props.add_child(pillar)

		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var col := CollisionShape3D.new()
		# BoxShape sized from the column's own height and radius. The old code read
		# `mesh.size`, which only exists on BoxMesh - a generated ArrayMesh has no
		# such property, so this had to be rewritten with the pillar rather than
		# left to fail at runtime.
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.72, ph, 0.72)
		col.shape = shape
		body.add_child(col)
		pillar.add_child(body)

	var light := OmniLight3D.new()
	light.light_color = Color(0.55, 0.95, 0.9)
	light.light_energy = 3.0
	light.omni_range = 14.0
	light.position = center + Vector3(0, 2.0, 0)
	add_child(light)

	# Bone cloth in the starting glade: a carpet up to the altar and a banner
	# hung behind the monolith, so the first thing a player sees is dressed.
	var carpet := BoneCloth.ground_cloth(Color(0.93, 0.90, 0.83), 0.55)
	if carpet != null:
		# In front of the altar on the side the player spawns, which is +Z: the
		# spawn is at z = +6 and she faces -Z.
		carpet.position = center + Vector3(0.0, 0.03, 3.6)
		add_child(carpet)
	# Two standards flanking the altar. Nothing hangs over this glade - there is
	# no beam, no lintel - so these stand on their own bone feet, planted on the
	# edge of the altar disc rather than in the grass that would swallow them.
	for side in [-1.0, 1.0]:
		var standard := BoneCloth.standard(Color(0.90, 0.87, 0.79), 0.55)
		if standard != null:
			standard.position = center + Vector3(2.3 * side, 0.14, 1.5)
			standard.rotation_degrees = Vector3(0, 24.0 * side, 0)
			add_child(standard)


## Weathered stone, textured and triplanar.
##
## Every stone structure in the world used a bare StandardMaterial3D with a flat
## albedo, on BoxMesh primitives - which is why the altar ring and the ruin gates
## read as grey cardboard rectangles standing in the grass. A box with no texture
## at all is the single most obvious "placeholder" shape there is.
##
## The texture is the same painted rock the terrain uses, sampled triplanar so the
## boxes get rock detail on all six faces without any per-face UV work, and
## dark_notch vertex-colouring is off because these meshes have no vertex colours.
func _stone_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.60, 0.62, 0.66)
	m.roughness = 0.92
	m.metallic = 0.0
	var tex := _load_stone_tex("res://textures/terrain/rock.png")
	if tex != null:
		m.albedo_texture = tex
		m.uv1_triplanar = true
		# 0.35 tiles the 512px rock roughly every 3 m, which reads as boulder-scale
		# texture on a 1 m pillar rather than as fine noise.
		m.uv1_scale = Vector3(0.35, 0.35, 0.35)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m


func _load_stone_tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		push_warning("LastStar: missing stone texture " + path)
		return null
	var t := load(path)
	if t is Texture2D:
		return t as Texture2D
	return null


func _scatter_landmarks() -> void:
	var stone_mat := _stone_material()

	# Wind arches: tall broken gates that read like Genshin's ruins.
	for i in range(7):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(60.0, 700.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 2.0 or y > 90.0 or _is_wet(x, z):
			continue
		var gate := Node3D.new()
		gate.position = Vector3(x, y, z)
		gate.rotation.y = _rng.randf() * TAU
		_props.add_child(gate)
		for side in [-1.0, 1.0]:
			var pillar := MeshInstance3D.new()
			pillar.mesh = VegMeshes.trunk(8.5, 0.72, 0.22, 0.05 * side, 7)
			pillar.material_override = stone_mat
			pillar.position = Vector3(2.6 * side, 0.0, 0)
			gate.add_child(pillar)
		var lintel := MeshInstance3D.new()
		# The lintel stays a box - a fallen gate's crossbeam was a cut block - but
		# it now carries the rock texture like the pillars it sits on.
		var box2 := BoxMesh.new()
		box2.size = Vector3(7.0, 1.1, 1.6)
		lintel.mesh = box2
		lintel.material_override = stone_mat
		lintel.position.y = 8.4
		gate.add_child(lintel)

		# Bone cloth hung from the lintel: the gates are the one built structure a
		# player walks under, and a banner between the pillars is what makes them
		# read as a place rather than as two grey columns and a beam.
		var banner := BoneCloth.hanging(Color(0.92, 0.88, 0.79), 0.85)
		if banner != null:
			# The lintel is 1.1 m deep and centred on 8.4, so its underside is here.
			banner.position = Vector3(0.0, 7.85, 0.15)
			gate.add_child(banner)

	# Crystal formations.
	#
	# Opaque, and half as many. These were 85%-alpha prisms with an emission
	# energy of 1.2, and from any distance at all a transparent prism lit from
	# inside reads as a flat coloured plank lying on the hill - which is what the
	# thin blue rectangles scattered across the wide shot were. A crystal is a
	# solid object; the emission is what makes it glow, and it does not need the
	# alpha channel to do it.
	var crystal_colors := [Color(0.55, 0.85, 1.0), Color(0.75, 0.6, 1.0), Color(1.0, 0.78, 0.55)]
	for i in range(9):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(60.0, 760.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 1.5 or _is_wet(x, z):
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
			# Opaque, and the albedo is darker than the glow on purpose: the
			# emission is what the eye reads as the crystal, and an albedo as
			# bright as the emission just blows the shape out to a flat plate.
			m.albedo_color = Color(col.r * 0.55, col.g * 0.55, col.b * 0.60, 1.0)
			m.emission_enabled = true
			m.emission = col
			m.emission_energy_multiplier = 0.9
			m.roughness = 0.18
			m.metallic = 0.35
			crystal.material_override = m
			crystal.position = Vector3(_rng.randf_range(-1.2, 1.2), h * 0.5, _rng.randf_range(-1.2, 1.2))
			crystal.rotation_degrees = Vector3(_rng.randf_range(-18, 18), _rng.randf() * 360, _rng.randf_range(-18, 18))
			cluster.add_child(crystal)

	# Campfires + wooden shelter props near waypoints for a lived-in feel.
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.32, 0.23)
	for i in range(6):
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(70.0, 680.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 2.5 or _is_wet(x, z):
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
		# Campfire glow is emissive only - no OmniLight3D.
		#
		# Six campfires across the valley each added a real-time point light to a
		# renderer with no clustered lighting, so all six were evaluated per pixel
		# on every lit surface that overlapped their range. The fire mesh below is
		# already unshaded and emissive at 3x; the light added almost nothing to
		# the image and a permanent cost to the frame.
		#
		# If a genuine ground-glow is wanted later, the cheap version is a single
		# unshaded additive decal quad lying on the terrain, not a light.
		# Flicker the fire's own emission instead of a light's energy. Same visual
		# read, no lighting cost. The tween loops for the life of the node.
		var t := fire.create_tween().set_loops()
		t.tween_property(fm, "emission_energy_multiplier", 2.0, 0.5)
		t.tween_property(fm, "emission_energy_multiplier", 3.4, 0.7)

		# A roofed pavilion around the fire.
		#
		# Until now the valley had walls (the ruin gates, the altar ring) but no
		# ceilings, so there was nowhere for a player to stand that was covered -
		# and nothing for the entity culler to prove its roof test on. Four posts
		# and a slab also turn a campfire into a shelter, which is what the note
		# above has been calling it all along.
		for side in [-1.0, 1.0]:
			for front in [-1.0, 1.0]:
				var post := MeshInstance3D.new()
				var post_mesh := BoxMesh.new()
				post_mesh.size = Vector3(0.18, 2.6, 0.18)
				post.mesh = post_mesh
				post.material_override = wood
				post.position = Vector3(1.7 * side, 1.3, 1.7 * front)
				camp.add_child(post)
		var roof := MeshInstance3D.new()
		var roof_mesh := BoxMesh.new()
		roof_mesh.size = Vector3(4.4, 0.35, 4.4)
		roof.mesh = roof_mesh
		roof.material_override = wood
		roof.position.y = 2.7
		camp.add_child(roof)

		# Bone cloth in the shelter: a drape across the open side, a carpet on the
		# floor and a heap of bones the fire was lit on.
		var drape := BoneCloth.drape(Color(0.34, 0.40, 0.48), 0.42)
		if drape != null:
			drape.position = Vector3(0.0, 2.5, 1.95)
			drape.rotation_degrees = Vector3(0, 180, 0)
			camp.add_child(drape)
		var carpet := BoneCloth.ground_cloth(Color(0.66, 0.30, 0.28), 0.30)
		if carpet != null:
			carpet.position = Vector3(0.0, 0.02, 0.0)
			camp.add_child(carpet)
		var pile := BoneCloth.bone_pile(0.30)
		if pile != null:
			pile.position = Vector3(1.35, 0.02, -1.05)
			camp.add_child(pile)


## Count the bone cloth the world actually dressed itself in.
##
## A piece that placed geometry is a different claim from a piece that placed
## nothing, and only the counts separate them: the models are preloaded, so a
## failed import is a parse error, but an imported file that instanced an empty
## scene would otherwise be invisible in every screenshot.
func bone_cloth_census() -> String:
	var pieces := 0
	var meshes := 0
	var surfaces := 0
	for n in get_tree().get_nodes_in_group("bone_cloth"):
		pieces += 1
		for child in n.find_children("*", "MeshInstance3D", true, false):
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			meshes += 1
			surfaces += mi.mesh.get_surface_count()
	return "BONE_CLOTH pieces=%d meshes=%d surfaces=%d" % [pieces, meshes, surfaces]


## Count what the world is actually asking the renderer to draw.
##
## Walks the live tree once (probe only, never per frame) and tallies drawable
## nodes, how many of them are batched MultiMeshes and how many instances those
## batches carry. This is the number that says whether vegetation batching
## worked: the scatter used to be one node per prop, so `meshes` was ~1,600 and
## `multimesh_instances` was 0.
func perf_census() -> String:
	var meshes := 0
	var multimeshes := 0
	var instances := 0
	var lights := 0
	var bodies := 0
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MultiMeshInstance3D:
			multimeshes += 1
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm != null:
				instances += mm.instance_count
		elif n is MeshInstance3D:
			meshes += 1
		if n is Light3D:
			lights += 1
		if n is StaticBody3D or n is CharacterBody3D or n is Area3D:
			bodies += 1
		for c in n.get_children():
			stack.append(c)
	var out := "census meshes=%d multimeshes=%d multimesh_instances=%d lights=%d bodies=%d" % [
		meshes, multimeshes, instances, lights, bodies]
	# How many entities the culler is actually keeping out of the frame and out
	# of the tick. On the main census line's tail so it survives the annotation
	# cap in CI.
	if _culler != null and is_instance_valid(_culler) and _culler.has_method("census"):
		out += "\n" + str(_culler.call("census"))
	# Bone cloth: how many pieces the world actually dressed, and how many of them
	# resolved to real geometry after import. Zero here means the GLBs were not
	# imported, which is exactly the failure a census should name.
	out += "\n" + bone_cloth_census()
	# One line per vegetation layer, naming the mesh it actually resolved.
	#
	# "flowers are in the scene" and "flowers are drawn as flowers" are different
	# claims, and for two commits only the first was true: the layer fell through
	# to a rock for every kind it did not recognise and the species table asked
	# for "crossed" anyway. Vertex counts make the difference visible - a flower
	# cluster is hundreds of vertices, a rock sphere is a few dozen.
	for spec in VegPresets.species():
		var n := "Veg_%s" % spec["name"]
		var layer := get_node_or_null(n)
		if layer == null or not layer.has_method("census"):
			continue
		var c: Dictionary = layer.call("census")
		out += "\nVEG_LAYERS %s model=%s mesh=%s verts=%s chunks=%s instances=%s" % [
			spec["name"], c.get("model_kind", "?"), c.get("mesh_class", "?"),
			c.get("mesh_verts", 0), c.get("chunks", 0), c.get("instances", 0)]
	return out


func _spawn_waypoints() -> void:
	var spots := [
		{"name": "Starlit Shore", "pos": Vector3(0.0, 0.0, 0.0)},
		{"name": "Windrise Lookout", "pos": Vector3(-620.0, 0.0, -380.0)},
		{"name": "Jadewater Glade", "pos": Vector3(250.0, 0.0, 300.0)},
	]
	for spot in spots:
		var p: Vector3 = spot["pos"]
		var statue := Area3D.new()
		statue.set_script(WaypointScript)
		statue.statue_name = str(spot["name"])
		statue.position = Vector3(p.x, _height(p.x, p.z) - 0.2, p.z)
		add_child(statue)
		# Every waypoint wears bone cloth on its spire, like a shrine banner.
		var totem := BoneCloth.totem(Color(0.80, 0.86, 0.95), 0.34)
		if totem != null:
			totem.position = Vector3(0.0, 3.4, 0.62)
			statue.add_child(totem)


func _spawn_sigils() -> void:
	var placed := 0
	var attempts := 0
	var used: Array[Vector3] = []
	while placed < Game.TOTAL_SIGILS and attempts < 600:
		attempts += 1
		var a := TAU * float(placed) / float(Game.TOTAL_SIGILS) + _rng.randf_range(-0.25, 0.25)
		var r := _rng.randf_range(55.0, 820.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 1.6 or y > 120.0:
			continue
		if _is_wet(x, z):
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
		var r := _rng.randf_range(25.0, 620.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var y := _height(x, z)
		if y < 1.8 or _is_wet(x, z):
			continue
		var slime := CharacterBody3D.new()
		slime.set_script(SlimeScript)
		slime.position = Vector3(x, y + 1.2, z)
		slime.set_element(i % 3)
		_enemies.add_child(slime)


func _build_entity_culler() -> void:
	## Occlusion-cull the spawned entities on a worker thread.
	##
	## Registered by group rather than by handle: the slimes, sigils and waypoints
	## are spawned by three different functions, each of which can skip a spot,
	## and the groups are already the authoritative list of what exists (the HUD
	## counts sigils from the same one).
	var culler := Node.new()
	culler.name = "EntityCuller"
	culler.set_script(EntityCullerScript)
	add_child(culler)
	culler.call("setup", terrain, _props)
	for group_name in ["enemy", "sigil", "waypoint"]:
		culler.call("register_group", group_name)
	_culler = culler


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
	_build_environment_vegetation(t, player)


func _build_environment_vegetation(t: Node, player: Node3D) -> void:
	## The authored environment species: border grass, flowers, bushes, fallen
	## leaves and pebbles, plus a second grass layer that shares one material.
	##
	## The original grass field above stays in place - it is the dense carpet
	## directly under the player and it works. This adds the variety on top of it
	## that a meadow needs to stop reading as a single green plane, and it does so
	## as batched MultiMeshes so the prop count does not become draw calls.
	##
	## One wind driver node owns every foliage material. The GPU does the wind;
	## the driver's entire cost is one uniform write per material per frame.
	var wind := Node.new()
	wind.name = "VegetationWind"
	wind.set_script(VegWindScript)
	add_child(wind)
	wind.call("set_player", player)

	for spec in VegPresets.species():
		# The meadow's carpet is GrassField's job, which streams and thins by
		# distance; every species here is a discrete prop.
		# One material per species, built from the species' model so the wind
		# strength it asks for is the strength its shader uses.
		var mat: ShaderMaterial = VegPresets.material_for(spec)
		if mat == null:
			push_warning("LastStar: no material for species %s" % spec["name"])
			continue
		wind.call("register_material", mat)

		var layer := Node3D.new()
		layer.name = "Veg_%s" % spec["name"]
		layer.set_script(VegLayerScript)
		add_child(layer)
		# Density with a per-species falloff. A flat density across a limited
		# radius would leave a visible wall at the edge of each small layer, which
		# reads far worse than the detail simply thinning out. Grass holds its
		# density to the streaming edge; small props taper.
		layer.set("density", float(spec["density"]))
		# The scale range, not a height: the pack authors each model at its own
		# size and only a scale is honest about that. See vegetation_presets.gd.
		layer.set("min_height", spec["hmin"])
		layer.set("max_height", spec["hmax"])
		layer.set("max_slope", spec["slope"])
		layer.set("model_kind", spec["model"])
		# Per-species streaming radius. Small detail does not need to exist at
		# 130 m; see the note on the species table.
		layer.set("casts_shadow", bool(spec.get("casts_shadow", false)))
		layer.set("chunk_radius", int(spec["radius"]))
		layer.set("material", mat)
		# Fewer chunks per frame than the demo scene: the world is already
		# building terrain, enemies and the grass field on the same frames.
		layer.set("chunks_per_frame", 1)
		layer.call("setup", t, player, hash(spec["name"]))


func _add_audio() -> void:
	var audio := Node3D.new()
	audio.name = "Ambience"
	audio.set_script(AudioDirectorScript)
	add_child(audio)


