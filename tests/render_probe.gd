extends Node
## Headless-friendly visual regression probe.
##
## Boots the real world scene, waits for it to settle, then measures what is
## actually on screen: does a camera exist, is the 3D layer non-black, how many
## distinct colours are present, what is the mean luminance. Prints RESULT lines
## the CI job parses. Also writes PNGs to user:// so a human can look at them.
##
## Usage:
##   godot --headless --path . res://tests/render_probe.tscn -- --out=/tmp/probe

const WORLD := "res://scenes/world.tscn"
const SETTLEMENTS := preload("res://scripts/settlement_data.gd")

var _fail := 0
## Every line the probe logs, in order.
##
## Annotations are capped at about ten per run and this job needs most of them
## for the shader census, so the interesting lines were being produced and then
## dropped - three separate rounds of debugging happened against annotations that
## existed all along but never reached the API. The full transcript is written
## next to the frames instead, where nothing caps it.
var _transcript := PackedStringArray()
var _out_dir := ""


## Exclusive upper bound for `for i in range(lo, _sample_end(n, step), step)`.
##
## Every sampling loop in this file picks a stride as a fraction of the image
## (`w / 200`) and then walks `range(0, w, step)`. The stride almost never divides
## the dimension, so the last iteration lands at or past the edge and the
## following get_pixel() is a hard error - Image.get_pixel does not clamp, and an
## out-of-range read takes the whole probe down. That is not hypothetical: the
## grass diagnostic in scripts/grass_field.gd read row 248 of a 226 px card and
## failed the boot step.
##
## Walking back to the last index the stride actually reaches keeps the sample
## count identical and stops losing a whole probe to a rounding error.
func _sample_end(n: int, step: int) -> int:
	step = maxi(1, step)
	return maxi(0, n - (n % step))


func _log(kind: String, msg: String) -> void:
	var line := "PROBE_%s: %s" % [kind, msg]
	print(line)
	_transcript.append(line)
	if kind == "FAIL":
		_fail += 1


## Write the whole transcript beside the frames.
func _dump_transcript(dir: String) -> void:
	var f := FileAccess.open(dir.path_join("probe.log.txt"), FileAccess.WRITE)
	if f == null:
		return
	for line in _transcript:
		f.store_line(line)
	f.close()


func _ready() -> void:
	# Hard watchdog: the probe must always terminate. A wedged await (typically
	# RenderingServer.frame_post_draw never firing when no frame is drawn) would
	# otherwise hang the job until the 60 minute timeout.
	_watchdog.call_deferred()
	# Never touch the tree from _ready(): while a node propagates READY its parent
	# has `blocked > 0`, and add_child() to it fails with "Parent node is busy
	# setting up children". Defer to an idle frame so the world really boots.
	_run.call_deferred()


func _watchdog() -> void:
	await get_tree().create_timer(120.0).timeout
	_log("FAIL", "probe timed out after 120s (no frames were drawn)")
	_transcript.append("PROBE_RESULT: FAIL (watchdog)")
	_transcript.append("PROBE_END")
	if _out_dir != "": _dump_transcript(_out_dir)
	print("PROBE_RESULT: FAIL (watchdog)")
	print("PROBE_END")
	get_tree().quit(1)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := "/tmp/probe"
	for a in args:
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_out_dir = out_dir

	_test_white_blob_detection()
	print("PROBE_BEGIN godot=%s renderer=%s driver=%s" % [
		Engine.get_version_info().string,
		ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		ProjectSettings.get_setting("rendering/rendering_device/driver"),
	])

	# --- boot the real game scene -----------------------------------------
	# Add it to the scene ROOT (not to this probe node): a child added under a
	# node that has not notified READY yet never gets its own _ready() called,
	# because Node::_set_tree() only propagates READY when the parent is ready.
	var packed := load(WORLD) as PackedScene
	if packed == null:
		_log("FAIL", "could not load %s" % WORLD)
		_finish(0)
		return
	var world := packed.instantiate()
	get_tree().root.add_child(world)

	# Calling the tuner before sampling must not disable the later measurement.
	world.call("_autotune_performance")
	if bool(world.get("_perf_done")):
		_log("FAIL", "performance tuner stopped before collecting frames")
	else:
		_log("INFO", "performance tuner waits for frame samples")

	# Let _ready() chains, vegetation (one frame await) and tweens settle.
	# Bounded by a wall-clock guard as well as a frame count: `process_frame`
	# stops arriving if the main loop is blocked, which would hang the job.
	for i in range(45):
		await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout

	# Diagnostic breadcrumbs: these survive the CI annotation cap, so they are
	# the fastest way to explain a failed probe.
	_log("INFO", "world is_node_ready=%s children=%d [%s]" % [
		str(world.is_node_ready()), world.get_child_count(),
		", ".join(world.get_children().map(func(c): return c.name))])
	await get_tree().create_timer(0.6).timeout
	for i in range(15):
		await get_tree().process_frame

	# Presets preserve legacy choices, change effects, and restore them on switch.
	var quality_before: int = Game.quality_tier
	var legacy_quality := ConfigFile.new()
	legacy_quality.set_value("video", "quality_tier", 0)
	var quality_ok: bool = int(Game.call("_quality_from_config", legacy_quality)) == 2
	legacy_quality.set_value("video", "quality_tier", 1)
	quality_ok = quality_ok and int(Game.call("_quality_from_config", legacy_quality)) == 1
	legacy_quality.set_value("video", "quality_tier", 2)
	quality_ok = quality_ok and int(Game.call("_quality_from_config", legacy_quality)) == 3
	legacy_quality.set_value("video", "quality_version", 2)
	legacy_quality.set_value("video", "quality_tier", 4)
	quality_ok = quality_ok and int(Game.call("_quality_from_config", legacy_quality)) == 4 and Game.QUALITY_NAMES.size() == 5
	var quality_sun := world.get_node("Sun") as DirectionalLight3D
	Game.quality_tier = 0
	world.call("apply_quality")
	world.call("_update_time_of_day")
	quality_ok = quality_ok and not quality_sun.shadow_enabled and is_equal_approx(float(world.get("_dynamic_scale")), 0.60)
	Game.quality_tier = 1
	world.call("apply_quality")
	quality_ok = quality_ok and quality_sun.shadow_enabled and is_equal_approx(float(world.get("_dynamic_scale")), 0.70)
	Game.quality_tier = 2
	world.call("apply_quality")
	quality_ok = quality_ok and is_equal_approx(float(world.get("_dynamic_scale")), 0.85)
	Game.quality_tier = 4
	world.call("apply_quality")
	quality_ok = quality_ok and quality_sun.shadow_enabled and is_equal_approx(float(world.get("_dynamic_scale")), 1.0)
	var slow: float = world.call("_next_dynamic_scale", 2, 0.85, 0.05)
	var fast: float = world.call("_next_dynamic_scale", 2, 0.75, 0.02)
	var stable: float = world.call("_next_dynamic_scale", 2, 0.75, 0.033)
	var high: float = world.call("_next_dynamic_scale", 4, 1.0, 0.05)
	quality_ok = quality_ok and is_equal_approx(slow, 0.80) and is_equal_approx(fast, 0.80) and is_equal_approx(stable, 0.75) and is_equal_approx(high, 1.0)
	Game.quality_tier = quality_before
	world.call("apply_quality")
	_log("INFO" if quality_ok else "FAIL", "five quality profiles, legacy migration and resolution control=%s" % str(quality_ok))
	# Quality changes invalidate streamed vegetation; let the restored profile
	# repopulate before the independent vegetation and grass assertions.
	for quality_frame in range(90):
		await get_tree().process_frame
	var monitor := world.get_node_or_null("HUD/PerformanceMonitor")
	if monitor == null:
		_log("FAIL", "performance monitor missing")
	else:
		monitor.call("_refresh_text", 0.016)
		_log("INFO", "performance monitor metrics available")

	# --- structural checks ------------------------------------------------
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		_log("FAIL", "no current Camera3D - the 3D viewport cannot render anything")
	else:
		_log("INFO", "camera=%s pos=%s fov=%.1f near=%.3f far=%.1f" % [
			cam.get_path(), str(cam.global_position), cam.fov, cam.near, cam.far])

	# Which renderer actually came up? Comparing this against what the APK ships
	# is what would have caught the Vulkan/PowerVR black screen immediately.
	var runtime_method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	if DisplayServer.get_name() != "headless":
		_log("INFO", "renderer=%s (project method %s)" % [
			RenderingServer.get_video_adapter_name(), runtime_method])

	var players := get_tree().get_nodes_in_group("player")
	if players.size() == 1:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.device = InputEvent.DEVICE_ID_EMULATION
		var emulated: bool = players[0].call("_is_world_attack_input", click)
		click.device = 0
		var physical: bool = players[0].call("_is_world_attack_input", click)
		_log("INFO" if not emulated and physical else "FAIL",
			"attack input: touch-emulated=%s physical-mouse=%s" % [str(emulated), str(physical)])
	_log("INFO" if players.size() == 1 else "FAIL",
		"player nodes in group = %d" % players.size())
	# Measure the sole-to-ground gap HERE, immediately, because the annotation
	# channel keeps only the newest ~30 messages and this number was landing
	# outside it. It is the one measurement that settles whether the character
	# actually floats or merely looks like she does.
	if players.size() > 0:
		var probe_player := players[0] as Node3D
		var probe_terrain := world.get_node_or_null("Terrain")
		if probe_player != null and probe_terrain != null and probe_terrain.has_method("surface_height_at"):
			var fx := probe_player.global_position.x
			var fz := probe_player.global_position.z
			var feet_y: float = probe_player.global_position.y + 0.05
			var ground_y: float = probe_terrain.surface_height_at(fx, fz)
			_log("INFO", "GROUND_ANCHOR feet=%.3f ground=%.3f gap=%.3f m" % [
				feet_y, ground_y, feet_y - ground_y])

	# --- every script compiles ---------------------------------------------
	# Load each GDScript through the real compiler. This catches the class of
	# error that only Godot rejects (type inference on lazily-typed properties,
	# preload cycles) and names the offending file instead of leaving us with
	# "Failed to load hud.gd".
	var script_failures := PackedStringArray()
	var compiled := 0
	for dir_path in ["res://scripts", "res://tests"]:
		for f in _gd_files(dir_path):
			compiled += 1
			if load(f) == null:
				script_failures.append(f)
	if script_failures.is_empty():
		_log("INFO", "all %d scripts compile" % compiled)
	else:
		for f in script_failures:
			_log("FAIL", "script failed to compile: %s" % f)

	# --- terrain orientation ------------------------------------------------
	# The terrain winding used to be inverted, which is invisible to every other
	# check here: the mesh still has vertices, the collision shape still has
	# faces, and the framebuffer is simply full of sky. Sample the actual normals.
	# The terrain is a grid of tiles now, not one mesh. Ask for the first one -
	# the winding is a property of how the grid is emitted, so every tile shares
	# it - but do not name the tile, because the count is a tuning parameter.
	var tmesh: MeshInstance3D = null
	var terrain_node := world.get_node_or_null("Terrain")
	if terrain_node != null:
		for c in terrain_node.find_children("*", "MeshInstance3D", true, false):
			var tmi2 := c as MeshInstance3D
			if tmi2.mesh != null and tmi2.name.begins_with("Near"):
				tmesh = tmi2
				break
	if tmesh == null or tmesh.mesh == null:
		_log("FAIL", "Terrain has no mesh tile - nothing to look at")
	else:
		var arr := tmesh.mesh.surface_get_arrays(0)
		var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var checked := 0
		var down := 0
		var step_i := maxi(1, normals.size() / 400)
		for i in range(0, normals.size(), step_i):
			checked += 1
			# A skirt is a wall hanging off the tile edge, so its normal is
			# horizontal by design. The question here is only whether the ground
			# is inside out, which is a normal pointing *down*.
			if normals[i].y < -0.01:
				down += 1
		if checked == 0:
			_log("FAIL", "terrain mesh has no normals")
		else:
			var pct := float(down) / float(checked) * 100.0
			_log("INFO" if pct < 1.0 else "FAIL",
				"terrain normals face up: %.1f%% of %d sampled point down" % [pct, checked])

	# --- is the character actually on screen? -------------------------------
	# Run early, deliberately: the annotation API returns only the first ~24
	# entries, so a check that reports late is invisible in CI even when it fails.
	# The character has been buried by grass and pushed behind the HUD band
	# several times, and both were found only by looking at a PNG.
	if cam:
		_check_player_visible(cam, world)
		# Visual-tree first: it is the summary that matters, and the cap truncates
		# the tail.
		_test_toon_material()
		_dump_visual_tree(world.get_node_or_null("Player"))
		_dump_player_parts(cam, world)

	# --- what is in front of the camera ------------------------------------
	# An opaque, unshaded blob that covers a third of the gameplay frame has
	# shown up twice now and both times the cause was guessed at from the PNG.
	# This dumps the actual geometry inside the camera frustum (distance, size,
	# material class and colour), so the next occurrence is identified from
	# data instead of a visual hunch.
	if cam:
		_dump_frustum(cam, world)

	# --- async entity occlusion culling ------------------------------------
	# Pure CPU, so this gates headlessly too - and it has to, because the
	# structural probe is the job that always runs.
	await _check_entity_culling(world)

	# --- bone cloth --------------------------------------------------------
	_check_bone_cloth(world)

	# --- nature pack -------------------------------------------------------
	_check_nature_pack(world)

	# Compact one-liner so the grass totals survive the annotation cap: the API
	# returns only the first ~24 annotations, and the detailed grass report runs
	# later in the log than that.
	var gf := world.get_node_or_null("GrassField")
	if gf != null:
		_log("INFO", "GRASS_SUMMARY blades=%d chunks=%d diag=%s" % [
			gf.call("blade_count"), gf.call("chunk_count"), str(gf.call("diagnostics"))])
		# The card's alpha is what cuts the blade shape out of the quad. If it is
		# missing the meadow draws as plain green rectangles, which looks like a
		# shader bug but is a texture-import one.
		#
		# This line printed `PROBE_INFO: GRASS_CARD ` - with nothing after it -
		# on every build, and an empty diagnostic is worse than none: it looks
		# like the card was checked and passed. Rather than guess why, the three
		# ways it can be blank are now told apart and two of them are failures.
		if not gf.has_method("card_report"):
			_log("FAIL", "GrassField has no card_report() - the card was never checked")
		else:
			var report: String = str(gf.call("card_report"))
			if report.is_empty():
				_log("FAIL", "card_report() returned an empty string - the card was not reported")
			else:
				_log("INFO", "GRASS_CARD %s" % report)

	# --- environment dressing ----------------------------------------------
	# Logs and pebbles are what stop the grass reading as a flat painted
	# texture. Assert they actually spawned rather than silently picking zero
	# valid spots.
	#
	# Matched by PREFIX, not by exact name. Each population is split across
	# spatial tiles so the frustum test can reject some of it, which means the
	# nodes are named `Pebbles_3_5`, `FallenLogs_0_2`, and so on. The tiled names
	# exist because a single batch spanning the valley can never be culled; a
	# gate that insists on one node per population is a gate that forbids the
	# fix for the slowest thing in the frame.
	var veg := world.get_node_or_null("Vegetation")
	var log_nodes := _children_named(veg, "FallenLogs")
	var pebble_nodes := _children_named(veg, "Pebbles")
	_log("INFO" if log_nodes.size() > 0 else "FAIL",
		"FallenLogs = %d batch(es)" % log_nodes.size())
	_log("INFO" if pebble_nodes.size() > 0 else "FAIL",
		"Pebbles = %d batch(es)" % pebble_nodes.size())
	if veg != null:
		var peb_n := 0
		for n in pebble_nodes:
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm != null:
				peb_n += mm.instance_count
		_log("INFO", "scatter: %d log batch(es), %d pebbles" % [log_nodes.size(), peb_n])

	# --- terrain textures ---------------------------------------------------
	for tex_name in ["meadow", "rock", "sand", "macro", "path"]:
		var path := "res://textures/terrain/%s.webp" % tex_name
		_log("INFO" if ResourceLoader.exists(path) else "FAIL",
			"terrain texture %s %s" % [tex_name, "loaded" if ResourceLoader.exists(path) else "MISSING"])

	# --- grass field --------------------------------------------------------
	var grass := world.get_node_or_null("GrassField")
	if grass == null:
		_log("FAIL", "GrassField missing - the meadow is not being built")
	else:
		var blades: int = grass.call("blade_count")
		var chunks: int = grass.call("chunk_count")
		_log("INFO" if blades > 500 and chunks > 4 else "FAIL",
			"grass: %d blades across %d chunks near the player" % [blades, chunks])
		# Per-chunk breakdown: how many chunks actually produced instances.
		var populated := 0
		var nearest := 0
		for child in grass.get_children():
			var mmi := child as MultiMeshInstance3D
			if mmi == null or mmi.multimesh == null:
				continue
			# instance_count reads back through the renderer, which is a dummy
			# server in --headless - guard the whole read.
			var n := 0
			if mmi.multimesh.instance_count >= 0:
				n = mmi.multimesh.instance_count
			if n > 0:
				populated += 1
			nearest = maxi(nearest, n)
		_log("INFO", "grass chunks populated=%d/%d, largest=%d" % [
			populated, chunks, nearest])
		_log("INFO", "grass diagnostics: %s" % str(grass.call("diagnostics")))
		# Simulate a far batch becoming near after travel. It must be removed
		# and queued again rather than remaining permanently sparse.
		var live_chunks: Dictionary = grass.get("_chunks")
		var checked_tier := false
		for key in live_chunks.keys():
			# The paved village may contain no near grass. Simulate travel to an
			# existing grassy chunk rather than assuming spawn is meadow.
			var chunk: Node = live_chunks[key]
			chunk.set_meta("grass_tier", 2)
			grass.call("_queue_around", key)
			checked_tier = int(grass.call("_tier_for_chunk", key, key)) == 0 and not live_chunks.has(key)
			break
		_log("INFO" if checked_tier else "FAIL", "grass density upgrades when a far chunk becomes near: %s" % str(checked_tier))
		# A quality change must retire the old dense batches rather than merely
		# changing the budget for future chunks. Restore the original setting
		# afterwards; subsequent frames stream the ring back in.
		var old_density: float = float(grass.get("_density"))
		grass.call("set_density_scale", 0.2 if old_density > 0.3 else 0.65)
		if int(grass.call("chunk_count")) != 0:
			_log("FAIL", "grass quality change left old chunks alive")
		else:
			_log("INFO", "grass quality change queues a fresh density")
		grass.call("set_density_scale", old_density)
		for i in range(45):
			await get_tree().process_frame

		# Density gate: the meadow must actually be a meadow. A slope/height bug
		# once cut this to 5% of intent and nothing noticed.
		#
		# Performance mode deliberately builds fewer cards, and the ring is
		# streamed over multiple frames rather than generated in one startup hitch.
		if blades < 2000:
			_log("FAIL", "grass is far too sparse (%d cards near the player, expected >2000)" % blades)

	_check_world_scale(world)

	# --- spellbook / spell wheel -------------------------------------------
	var w: Wander = Game.wander
	if w == null:
		_log("FAIL", "Game.wander is null - the spell wheel has no spellbook")
	else:
		var known: int = w.levels.size()
		_log("INFO" if known >= 3 else "FAIL",
			"wander spells known=%d slots=%s" % [known, str(w.slots)])
		var wheel := world.get_node_or_null("HUD/Root/SpellWheel")
		if wheel == null:
			_log("FAIL", "HUD/SpellWheel missing - no spell buttons on screen")
		else:
			_log("INFO", "spell wheel present (%d slots)" % w.MAX_SLOTS)
		# Cast path: spend Light, start a cooldown, land a hit.
		var first_id: String = w.equipped_at(0)
		if first_id == "":
			_log("FAIL", "slot 1 is empty - the wheel would show nothing to cast")
		elif not w.known(first_id):
			_log("FAIL", "slot 1 holds %s which the player has not learned" % first_id)
		else:
			var cd: float = float(w.spell(first_id)["cooldown"])
			w.begin_cast(first_id)
			_log("INFO" if w.cooldown_left(first_id) > 0.0 else "FAIL",
				"casting %s started a %.1fs cooldown (left %.2f)" % [
					first_id, cd, w.cooldown_left(first_id)])
			w.tick(cd + 0.1)
			_log("INFO" if w.cooldown_left(first_id) <= 0.0 else "FAIL",
				"cooldown expired after ticking")

	# --- terrain collision diagnostics -------------------------------------
	var tbody := world.get_node_or_null("Terrain/TerrainBody") as StaticBody3D
	if tbody == null:
		_log("FAIL", "Terrain/TerrainBody missing - nothing to stand on")
	else:
		var faces := 0
		for c in tbody.get_children():
			if c is CollisionShape3D and c.shape is ConcavePolygonShape3D:
				faces = (c.shape as ConcavePolygonShape3D).get_faces().size()
		_log("INFO", "terrain body layer=%d shapes=%d face_verts=%d" % [
			tbody.collision_layer, tbody.get_child_count(), faces])

	# Direct physics query, independent of the player: if this misses too, the
	# problem is the space/raycast, not the player script.
	if tbody != null:
		# Explicit types: direct_space_state/intersect_ray resolve lazily and
		# `:=` cannot infer them (a parse error that only shows at runtime).
		var sp: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
		if sp != null:
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(0.0, 200.0, 6.0), Vector3(0.0, -200.0, 6.0), 0xFFFFFFFF)
			var h: Dictionary = sp.intersect_ray(q)
			_log("INFO" if not h.is_empty() else "FAIL",
				"probe raycast from y=200 hit=%s" % (
					str(h.get("position")) if not h.is_empty() else "NOTHING"))
		else:
			_log("FAIL", "no direct_space_state")

	# The player must be standing on the ground, not falling through the world.
	if players.size() > 0:
		var pl := players[0] as Node3D
		var py := pl.global_position.y
		if py < -5.0:
			_log("FAIL", "player is below the world (y=%.1f) - terrain collision or spawn is broken" % py)
		else:
			# Report the GAP between her soles and the rendered ground, in metres.
			#
			# "She looks like she is floating" has been reported on the device four
			# times and every previous attempt to fix it changed something plausible
			# without ever measuring it. The number that matters is the distance
			# from the bottom of her boots to the surface under them, so print it
			# rather than describing it.
			var gnode := pl.get_parent()
			var gap_text := "unknown"
			if gnode != null:
				var terr := gnode.get_node_or_null("Terrain")
				if terr != null and terr.has_method("surface_height_at"):
					var feet: float = py + 0.05
					var ground: float = terr.surface_height_at(pl.global_position.x, pl.global_position.z)
					gap_text = "%.3f m (feet y=%.2f, ground y=%.2f)" % [feet - ground, feet, ground]
			_log("INFO", "player standing at y=%.1f (on_floor=%s), sole-to-ground gap %s" % [
				py, str(pl is CharacterBody3D and (pl as CharacterBody3D).is_on_floor()), gap_text])

	var wenv := world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if wenv == null or wenv.environment == null:
		_log("FAIL", "WorldEnvironment has no Environment assigned")
	else:
		var env := wenv.environment
		_log("INFO", "environment bg_mode=%d ambient=%d glow=%s fog=%s" % [
			env.background_mode, env.ambient_light_source,
			str(env.glow_enabled), str(env.fog_enabled)])
		_log("INFO" if env.adjustment_enabled and env.adjustment_saturation >= 1.29 and env.adjustment_brightness >= 1.07 else "FAIL",
			"vivid grade: saturation=%.2f brightness=%.2f exposure=%.2f" % [
				env.adjustment_saturation, env.adjustment_brightness, env.tonemap_exposure])

	var terrain := world.get_node_or_null("Terrain")
	if terrain != null and terrain.has_method("is_path"):
		var path_ok := bool(terrain.call("is_path", 18.0, 0.0)) and not bool(terrain.call("is_path", 30.0, 0.0))
		_log("INFO" if path_ok else "FAIL", "yellow path placement matches the meadow clearing: %s" % str(path_ok))
	else:
		_log("FAIL", "terrain path placement missing")
	var meshes := 0
	if terrain:
		meshes = terrain.find_children("*", "MeshInstance3D", true, false).size()
	_log("INFO" if meshes > 0 else "FAIL", "terrain MeshInstance3D count = %d" % meshes)

	var sun := world.get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		_log("INFO" if sun.visible else "FAIL",
			"sun visible=%s energy=%.2f rot=%s" % [
				str(sun.visible), sun.light_energy, str(sun.rotation_degrees)])

	# Pause menu controls and overlay must still work after restyling.
	var hud := world.get_node_or_null("HUD")
	if hud == null:
		_log("FAIL", "HUD missing")
	else:
		hud.call("_pause")
		var dimmer := hud.get_node_or_null("Root/PauseDimmer") as ColorRect
		var paused_ok := Game.is_paused and dimmer != null and dimmer.visible
		hud.call("_resume")
		_log("INFO" if paused_ok and not Game.is_paused and dimmer != null and not dimmer.visible else "FAIL",
			"celestial pause overlay and resume: %s" % str(paused_ok and not Game.is_paused))

	# Exercise all offline screens and the transaction/save boundaries.
	var menu := world.get_node_or_null("HUD/Root/AdventureMenu")
	if menu == null:
		_log("FAIL", "adventure menu missing")
	else:
		menu.call("open_menu", "Character")
		var screens_ok: bool = menu.visible and Game.is_paused
		for page in ["Character", "Inventory", "Quests", "Wish", "Level Up", "Shop", "Profile", "Settings", "Story"]:
			menu.call("_select", page)
			var body: VBoxContainer = menu.get("_body")
			if body == null or body.get_child_count() == 0:
				screens_ok = false
		var rail: Dictionary = menu.get("_tab_buttons")
		var nav_icons_ok := rail.size() == 6
		for page in rail:
			var tab: Button = rail[page]
			nav_icons_ok = nav_icons_ok and tab.icon != null and not tab.pressed.get_connections().is_empty()
		menu.call("_select", "Settings")
		var settings_body: VBoxContainer = menu.get("_body")
		var settings_icon_found := false
		for child in settings_body.get_children():
			if child is Button and child.icon != null:
				settings_icon_found = true
		menu.call("close_menu")
		_log("INFO" if screens_ok and not Game.is_paused else "FAIL", "offline adventure screens and close: %s" % str(screens_ok))
		_log("INFO" if nav_icons_ok and settings_icon_found else "FAIL", "interface icons and navigation rail: %s" % str(nav_icons_ok and settings_icon_found))
	var old_coins := Game.coins
	var old_starlight := Game.starlight
	var old_potions := Game.potions
	var old_levels := Game.character_levels.duplicate()
	var old_items := Game.collectibles.duplicate(true)
	var old_wishes := Game.wish_count
	var old_packs := Game.owned_backpacks.duplicate()
	var old_equipped := Game.equipped_backpack
	Game.owned_backpacks = [0]
	Game.equipped_backpack = 0
	Game.potions = 2
	Game.collectibles = {}
	Game.coins = 100
	Game.starlight = 30
	Game.character_levels[0] = 1
	var shop_ok := Game.buy_potion() and Game.coins == 75
	var level_ok := Game.upgrade_character(0) and Game.coins == 25 and Game.character_levels[0] == 2
	var item := Game.make_wish()
	var wish_ok := item != "" and Game.starlight == 0
	Game.coins = 0
	Game.load_collection()
	var save_ok := Game.coins == 25 and Game.character_levels[0] == 2
	Game.potions = 10
	Game.collectibles = {}
	Game.coins = 500
	Game.starlight = 30
	var full_ok := Game.inventory_capacity() == 10 and not Game.buy_potion() and Game.make_wish() == "" and Game.coins == 500 and Game.starlight == 30
	var pack_ok := Game.buy_backpack(1) and Game.equip_backpack(1) and Game.inventory_capacity() == 15 and Game.buy_potion() and not Game.equip_backpack(0)
	Game.save_collection()
	Game.equipped_backpack = 0
	Game.owned_backpacks = [0]
	Game.load_collection()
	pack_ok = pack_ok and Game.equipped_backpack == 1 and Game.owned_backpacks.has(1) and Game.inventory_used() == 11
	_log("INFO" if full_ok and pack_ok else "FAIL", "inventory capacity and backpack persistence: full=%s pack=%s" % [str(full_ok), str(pack_ok)])
	Game.owned_backpacks.assign(old_packs)
	Game.equipped_backpack = old_equipped
	Game.coins = old_coins
	Game.starlight = old_starlight
	Game.potions = old_potions
	for i in range(Game.character_levels.size()):
		Game.character_levels[i] = old_levels[i]
	Game.collectibles = old_items
	Game.wish_count = old_wishes
	Game.save_collection()
	_log("INFO" if shop_ok and level_ok and wish_ok and save_ok else "FAIL",
		"offline transactions: shop=%s level=%s wish=%s save=%s" % [str(shop_ok), str(level_ok), str(wish_ok), str(save_ok)])

	# Story progress and dropped items must survive reloading without duplicating
	# sigil rewards, or discarding items when the inventory is full.
	var saved_sigils := Game.sigils_seen.duplicate(true)
	var saved_count := Game.sigils_collected
	var saved_slimes := Game.slimes_defeated
	var saved_waypoints := Game.waypoints_seen.duplicate(true)
	var saved_waypoint_count := Game.waypoints_activated
	var saved_checkpoint := Game.checkpoint
	var saved_has_checkpoint := Game.has_checkpoint
	var saved_waypoint_name := Game.last_waypoint_name
	var saved_complete := Game.story_complete
	var saved_drops := Game.dropped_items.duplicate(true)
	var saved_next_drop := Game.next_drop_id
	Game.sigils_seen = {}
	Game.sigils_collected = 0
	Game.slimes_defeated = 3
	Game.waypoints_seen = {"Probe waypoint": true}
	Game.waypoints_activated = 1
	Game.has_checkpoint = true
	Game.checkpoint = Vector3(10, 20, 30)
	Game.last_waypoint_name = "Probe waypoint"
	Game.story_complete = false
	Game.collect_sigil("probe_sigil")
	var reward_coins := Game.coins
	Game.collect_sigil("probe_sigil")
	var no_duplicate := Game.sigils_collected == 1 and Game.coins == reward_coins
	Game.potions = 2
	Game.collectibles = {}
	Game.dropped_items = {}
	var drop_id: String = Game.drop_item("Potion", Vector3(3, 2, 1))
	Game.sigils_seen = {}
	Game.slimes_defeated = 0
	Game.waypoints_seen = {}
	Game.dropped_items = {}
	Game.load_collection()
	var story_ok := Game.sigils_seen.has("probe_sigil") and Game.sigils_collected == 1 and Game.slimes_defeated == 3 and Game.waypoints_seen.has("Probe waypoint") and Game.checkpoint == Vector3(10, 20, 30)
	var drop_ok := drop_id != "" and Game.dropped_items.has(drop_id) and Game.recover_drop(drop_id) and Game.potions == 2
	Game.sigils_collected = Game.TOTAL_SIGILS - 1
	Game.collect_sigil("probe_last_sigil")
	var journey_continues := Game.story_complete and not Game.has_won and hollow_player_can_continue(world)
	Game.sigils_seen = saved_sigils
	Game.sigils_collected = saved_count
	Game.slimes_defeated = saved_slimes
	Game.waypoints_seen = saved_waypoints
	Game.waypoints_activated = saved_waypoint_count
	Game.checkpoint = saved_checkpoint
	Game.has_checkpoint = saved_has_checkpoint
	Game.last_waypoint_name = saved_waypoint_name
	Game.story_complete = saved_complete
	Game.dropped_items = saved_drops
	Game.next_drop_id = saved_next_drop
	Game.coins = old_coins
	Game.starlight = old_starlight
	Game.potions = old_potions
	Game.collectibles = old_items
	Game.save_collection()
	Game.sigils_changed.emit(Game.sigils_collected, Game.TOTAL_SIGILS)
	Game.call("_refresh_quest")
	_log("INFO" if story_ok and no_duplicate and drop_ok and journey_continues else "FAIL", "story persistence=%s duplicate prevention=%s drop recovery=%s journey continues=%s" % [str(story_ok), str(no_duplicate), str(drop_ok), str(journey_continues)])
	var old_jump: int = Game.key_for_action("jump")
	var settings_ok := Game.rebind_action("jump", KEY_K) and Game.key_for_action("jump") == KEY_K and not Game.rebind_action("move_forward", KEY_K) and Game.rebind_action("jump", old_jump)
	_log("INFO" if settings_ok else "FAIL", "key remapping and conflict prevention: %s" % str(settings_ok))

	# Quest choice, one-time reward and Wander progression survive reload.
	var guard_before := Game.guard_story.duplicate(true)
	var wander_before := Game.wander.levels.duplicate(true)
	var slots_before := Game.wander.slots.duplicate()
	var progress_before := Game.wander_levels.duplicate(true)
	var saved_slots_before := Game.wander_slots.duplicate()
	var sigil_count_before := Game.sigils_collected
	Game.guard_story = {}
	Game.sigils_collected = 0
	var accepted: bool = Game.guard_accept("seal", "curiosity")
	var gated: bool = not Game.guard_complete("seal")
	Game.sigils_collected = 1
	var rewarded: bool = Game.guard_complete("seal") and Game.wander.known("stone_bulwark")
	var once: bool = not Game.guard_complete("seal")
	Game.wander.set_slot(2, "stone_bulwark")
	Game.wander.begin_cast("stone_bulwark")
	Game.load_collection()
	var old_hp := Game.current_hp()
	Game.shield_points = 100.0
	Game.damage(35.0)
	var shield_ok := Game.current_hp() == old_hp and is_equal_approx(Game.shield_points, 65.0)
	Game.shield_points = 0.0
	_log("INFO" if shield_ok else "FAIL", "stone shield absorbs damage: %s" % str(shield_ok))
	var restored_wander := Wander.new()
	restored_wander.restore(Game.wander_levels, Game.wander_slots)
	var persist_wander: bool = restored_wander.known("stone_bulwark") and restored_wander.equipped_at(2) == "stone_bulwark" and int(restored_wander.levels.get("stone_bulwark_xp", 0)) == 1
	var persist_choice: bool = Game.guard_story.get("answer", "") == "curiosity" and bool(Game.guard_story.get("seal_done", false))
	_log("INFO" if accepted and gated and rewarded and once and persist_wander and persist_choice else "FAIL", "quest dialogue, one-time reward, Wander persistence: %s" % str(accepted and gated and rewarded and once and persist_wander and persist_choice))
	Game.guard_story = guard_before
	Game.wander.levels = wander_before
	Game.wander.slots.assign(slots_before)
	Game.wander_levels = progress_before
	Game.wander_slots = saved_slots_before
	Game.sigils_collected = sigil_count_before
	Game.save_collection()
	Game.sigils_changed.emit(Game.sigils_collected, Game.TOTAL_SIGILS)
	Game.call("_refresh_quest")

	# Verify registered controller events, heavy-attack cost, and dodge i-frames.
	var mapped := true
	for pair in [["attack", JOY_BUTTON_X], ["dodge", JOY_BUTTON_B], ["jump", JOY_BUTTON_A], ["journal", JOY_BUTTON_BACK]]:
		var button := InputEventJoypadButton.new()
		button.button_index = pair[1]
		button.pressed = true
		if not button.is_action(pair[0]):
			mapped = false
	var combat_player := world.get_node_or_null("Player")
	var combat_ok := combat_player != null
	if combat_player != null:
		var hp_before := Game.current_hp()
		var stamina_before := Game.stamina
		var shield_before := Game.shield_points
		Game.shield_points = 0.0
		Game.stamina = Game.MAX_STAMINA
		combat_player.set("_dodge_time", 0.2)
		combat_player.call("take_damage", 25.0, Vector3.ZERO)
		combat_ok = is_equal_approx(Game.current_hp(), hp_before)
		combat_player.set("_dodge_time", 0.0)
		combat_player.set("_attack_cd", 0.0)
		combat_player.call("_do_attack", true)
		combat_ok = combat_ok and is_equal_approx(Game.stamina, Game.MAX_STAMINA - 15.0)
		combat_player.set("_attack_cd", 0.0)
		Game.stamina = stamina_before
		Game.shield_points = shield_before
	_log("INFO" if mapped and combat_ok else "FAIL", "controller mappings=%s heavy attack and dodge=%s" % [str(mapped), str(combat_ok)])

	# Research is gated by story and earned starlight, creates a real castable
	# recipe, and persists the parameters, mastery and equipped slot.
	var research_guard := Game.guard_story.duplicate(true)
	var research_starlight := Game.starlight
	var research_levels := Game.wander.levels.duplicate(true)
	var research_slots := Game.wander.slots.duplicate()
	var research_saved_levels := Game.wander_levels.duplicate(true)
	var research_saved_slots := Game.wander_slots.duplicate()
	Game.guard_story = {}
	Game.starlight = 30
	var locked := Game.research_spell(0, 1, 1, 1, 1) == "" and Game.starlight == 30
	Game.guard_story["seal_done"] = true
	var research_clears := Game.dungeon_clears.duplicate(true)
	Game.dungeon_clears.erase("memory_10")
	Game.dungeon_clears.erase("memory_15")
	Game.dungeon_clears.erase("memory_24")
	var extra_locked := Game.research_spell(3, 4, 0, 0, 0) == "" and Game.starlight == 30
	Game.dungeon_clears["memory_10"] = true
	Game.dungeon_clears["memory_15"] = true
	Game.dungeon_clears["memory_24"] = true
	var extra_ids_ok := Game.research_element_unlocked(3) and Game.research_element_unlocked(4) and Game.research_element_unlocked(5)
	extra_ids_ok = extra_ids_ok and Wander.research_id(6, 0, 0, 0, 0) == "" and not Game.wander.spell(Wander.research_id(3, 4, 0, 0, 0)).is_empty()
	Game.dungeon_clears = research_clears
	var recipe_id: String = Game.research_spell(0, 1, 1, 1, 1)
	var recipe_data: Dictionary = Game.wander.spell(recipe_id)
	var created := recipe_id != "" and Game.starlight == 20 and Game.wander.known(recipe_id)
	var no_double := Game.research_spell(0, 1, 1, 1, 1) == "" and Game.starlight == 20
	var shape_ok := int(recipe_data.get("secondary_element", -1)) == 1 and float(recipe_data.get("radius", 0.0)) == 6.0 and float(recipe_data.get("cost", 0.0)) == 29.0
	Game.wander.set_slot(3, recipe_id)
	Game.load_collection()
	var research_book := Wander.new()
	research_book.restore(Game.wander_levels, Game.wander_slots)
	var research_saved := research_book.known(recipe_id) and research_book.equipped_at(3) == recipe_id
	var reaction_ok := true
	var enemies := get_tree().get_nodes_in_group("enemy")
	if not enemies.is_empty():
		var enemy: Node = enemies[0]
		var enemy_hp: float = enemy.get("hp")
		var enemy_element: int = enemy.get("element")
		var first_mult: float = enemy.call("_reaction_multiplier", 0)
		var second_mult: float = enemy.call("_reaction_multiplier", 1)
		enemy.call("take_combined_hit", 1.0, 0, 1, Vector3.ZERO)
		reaction_ok = is_equal_approx(enemy.get("hp"), enemy_hp - (first_mult + second_mult) * 0.5)
		enemy.set("hp", enemy_hp)
		enemy.set("element", enemy_element)
	Game.guard_story = research_guard
	Game.starlight = research_starlight
	Game.wander.levels = research_levels
	Game.wander.slots.assign(research_slots)
	Game.wander_levels = research_saved_levels
	Game.wander_slots = research_saved_slots
	Game.save_collection()
	_log("INFO" if locked and extra_locked and extra_ids_ok and created and no_double and shape_ok and research_saved and reaction_ok else "FAIL", "spell research locked=%s new_elements_locked=%s new_elements_valid=%s created=%s duplicate=%s shape=%s saved=%s combined=%s" % [str(locked), str(extra_locked), str(extra_ids_ok), str(created), str(no_double), str(shape_ok), str(research_saved), str(reaction_ok)])

	# Each of the 14 residents has independent, persistent main and side quests.
	var site_data = load("res://scripts/settlement_data.gd")
	var quests_before := Game.settlement_quests.duplicate(true)
	var site_coins := Game.coins
	var site_starlight := Game.starlight
	var site_potions := Game.potions
	Game.settlement_quests = {}
	var village_ok: bool = site_data.SITES.size() == 14
	for site in site_data.SITES:
		var id: String = site["id"]
		for kind in ["main", "side"]:
			if not Game.accept_settlement_quest(id, kind) or Game.complete_settlement_quest(id, kind) or not Game.collect_settlement_item(id, kind) or not Game.complete_settlement_quest(id, kind) or Game.complete_settlement_quest(id, kind):
				village_ok = false
	Game.settlement_quests = {}
	Game.load_collection()
	for site in site_data.SITES:
		for kind in ["main", "side"]:
			if Game.settlement_quest_status(site["id"], kind) != "done":
				village_ok = false
	Game.settlement_quests = quests_before
	Game.coins = site_coins
	Game.starlight = site_starlight
	Game.potions = site_potions
	Game.save_collection()
	Game.collection_changed.emit()
	var settlement_manager := world.get_node_or_null("Settlements")
	var stream_ok: bool = settlement_manager != null and settlement_manager.get("_sites").size() == 14 and not get_tree().get_nodes_in_group("story_npc").is_empty()
	_log("INFO" if village_ok and stream_ok else "FAIL", "settlement quest persistence=%s streamed sites=%s" % [str(village_ok), str(stream_ok)])
	# All village centers are resolved before terrain meshes/collision build.
	# Verify the paved square and approach to each house use one level height.
	var flat_villages_ok := settlement_manager != null and terrain_node != null
	if flat_villages_ok:
		var flat_sites: Array = settlement_manager.get("_sites")
		for flat_site in flat_sites:
			var center: Vector2 = flat_site["resolved"]
			var level: float = terrain_node.call("get_height_at", center.x, center.y)
			flat_villages_ok = flat_villages_ok and level > 1.2
			for offset in [Vector2.ZERO, Vector2(-55, -55), Vector2(55, -55), Vector2(-55, 55), Vector2(55, 55), Vector2(-12, -6), Vector2(12, -6), Vector2(0, 14)]:
				var point: Vector2 = center + offset
				flat_villages_ok = flat_villages_ok and absf(float(terrain_node.call("get_height_at", point.x, point.y)) - level) < 0.001
				flat_villages_ok = flat_villages_ok and absf(float(terrain_node.call("surface_height_at", point.x, point.y)) - level) < 0.001
				flat_villages_ok = flat_villages_ok and bool(terrain_node.call("is_village_ground", point.x, point.y))
			# All resident and quest anchors must lie on the actual paving, not
			# merely in the wider flat terrain margin.
			for resident_index in range(site_data.RESIDENT_COUNT):
				var resident_point: Vector2 = settlement_manager.call("_resident_position", center, resident_index)
				var resident_offset: Vector2 = resident_point - center
				flat_villages_ok = flat_villages_ok and maxf(absf(resident_offset.x), absf(resident_offset.y)) < site_data.PAVING_HALF_SIZE
				for quest_kind in ["main", "side"]:
					var quest_offset: Vector2 = site_data.quest_offset(resident_index, quest_kind)
					flat_villages_ok = flat_villages_ok and maxf(absf(quest_offset.x), absf(quest_offset.y)) < site_data.PAVING_HALF_SIZE
	_log("INFO" if flat_villages_ok else "FAIL", "All 14 settlements have level dry paved ground and level house approaches=%s" % str(flat_villages_ok))
	# Compare the spatial index with a full ordered scan, including negative
	# coordinates, cell boundaries, and every village's blend edge.
	var village_index_ok := terrain_node != null
	if terrain_node != null:
		var all_pads: Array = terrain_node.get("_village_pads")
		var samples: Array[Vector2] = [Vector2.ZERO, Vector2(-256, -256), Vector2(256, 256), Vector2(4999, -4999)]
		for pad in all_pads:
			var pad_center: Vector2 = pad["center"]
			for dx in [-89.0, -88.0, -64.0, 0.0, 64.0, 88.0, 89.0]:
				for dz in [-89.0, -64.0, 0.0, 64.0, 89.0]:
					samples.append(pad_center + Vector2(dx, dz))
		for sample in samples:
			var expected: Array = []
			for pad in all_pads:
				if float(terrain_node.call("_village_blend", sample.x, sample.y, pad)) > 0.0: expected.append(pad)
			var indexed: Array = terrain_node.call("_nearby_village_pads", sample.x, sample.y)
			var actual: Array = []
			for pad in indexed:
				if float(terrain_node.call("_village_blend", sample.x, sample.y, pad)) > 0.0: actual.append(pad)
			village_index_ok = village_index_ok and expected == actual
		var empty_sample: Array = terrain_node.call("_nearby_village_pads", 4999.0, -4999.0)
		village_index_ok = village_index_ok and empty_sample.is_empty()
	_log("INFO" if village_index_ok else "FAIL", "Village spatial index preserves full-scan terrain results=%s" % str(village_index_ok))
	var grid_ok := terrain_node != null
	if terrain_node != null:
		for visual in [false, true]:
			var origin := Vector2(-149.0, 54.0)
			var grid: PackedVector3Array = terrain_node.call("_sample_grid", origin, 8.0, 4, visual)
			grid_ok = grid_ok and grid.size() == 25
			for z in range(5):
				for x in range(5):
					var point: Vector3 = grid[z * 5 + x]
					var expected_point: Vector3 = terrain_node.call("_surface_point", point.x, point.z) if visual else Vector3(point.x, terrain_node.call("get_height_at", point.x, point.z), point.z)
					grid_ok = grid_ok and point.is_equal_approx(expected_point)
	_log("INFO" if grid_ok else "FAIL", "Shared terrain sampling matches direct heights and visual points=%s" % str(grid_ok))

	# Twenty distinct residents in the streamed outpost, each with independent
	# quest state. Index zero retains the old save key for existing players.
	var resident_ok := false
	var quest_ui_ok := false
	var house_ok := false
	var interior_variants_ok := true
	var interior_variants := {}
	var prop_census := {}
	# All prop types use one cached mesh surface, per-face normals and palette
	# colours. Three-box props have 72 split-normal vertices (near the 70 target).
	var prop_factory = load("res://scripts/interior_props.gd")
	var prop_budget_ok: bool = prop_factory.ITEMS.size() == 20
	for prop_type in range(prop_factory.ITEMS.size()):
		var prop_sample: Node3D = prop_factory.make(prop_type)
		var prop_repeat: Node3D = prop_factory.make(prop_type)
		var prop_mesh := prop_sample.get_node_or_null("Model") as MeshInstance3D
		var prop_mesh_repeat := prop_repeat.get_node_or_null("Model") as MeshInstance3D
		if prop_mesh == null or prop_mesh_repeat == null:
			prop_budget_ok = false
		else:
			var prop_counts := _weapon_mesh_budget(prop_sample)
			prop_budget_ok = prop_budget_ok and prop_sample.get_child_count() == 1 and prop_mesh.mesh.get_surface_count() == 1 and prop_mesh.mesh == prop_mesh_repeat.mesh
			prop_budget_ok = prop_budget_ok and prop_counts.x > 0 and prop_counts.x <= 200 and prop_counts.y <= 72
		prop_sample.free()
		prop_repeat.free()
	_log("INFO" if prop_budget_ok else "FAIL", "20 props: shared single-surface meshes within 200 triangles and 72 vertices=%s" % str(prop_budget_ok))
	if settlement_manager != null:
		for settlement_index in range(14):
			for house_index in range(3):
				var sample_house: Node3D = settlement_manager.call("_house", settlement_index, house_index)
				var furnishing_list: Array = sample_house.get("furniture")
				interior_variants[int(sample_house.get_meta("interior_variant"))] = true
				interior_variants_ok = interior_variants_ok and furnishing_list.size() >= 4 and furnishing_list.size() <= 7
				for furnishing in furnishing_list:
					var furnishing_node := sample_house.get_node_or_null("Furniture_" + str(furnishing["id"]))
					interior_variants_ok = interior_variants_ok and furnishing_node != null
					if furnishing_node != null and not str(furnishing["id"]).begins_with("prop_"):
						var furniture_near := furnishing_node.get_node_or_null("Near")
						var furniture_mid := furnishing_node.get_node_or_null("Middle")
						interior_variants_ok = interior_variants_ok and furniture_near != null
						if furniture_near != null:
							interior_variants_ok = interior_variants_ok and _mesh_ranges_match(furniture_near, 0.0, 15.0 if furniture_mid != null else 50.0)
							if furniture_mid != null:
								var near_count := _recursive_mesh_triangles(furniture_near)
								var mid_count := _recursive_mesh_triangles(furniture_mid)
								interior_variants_ok = interior_variants_ok and _mesh_ranges_match(furniture_mid, 15.0, 50.0) and mid_count > 0 and mid_count < near_count
						interior_variants_ok = interior_variants_ok and (furniture_mid != null) == (str(furnishing["id"]) in ["bed", "chair", "couch", "shelf"])
					if str(furnishing["id"]).begins_with("prop_"):
						prop_census[str(furnishing["id"])] = true
						interior_variants_ok = interior_variants_ok and not str(furnishing["message"]).is_empty()
				interior_variants_ok = interior_variants_ok and not (sample_house.has_node("Furniture_bed") and sample_house.has_node("Furniture_couch"))
				sample_house.free()
	else:
		interior_variants_ok = false
	interior_variants_ok = interior_variants_ok and interior_variants.size() == 42 and prop_census.size() == 20
	_log("INFO" if interior_variants_ok else "FAIL", "42 house variants contain 20 registered props without all models=%s" % str(interior_variants_ok))
	if settlement_manager != null and menu != null:
		var loaded: Dictionary = settlement_manager.get("_loaded")
		if loaded.has("ashvale"):
			var settlement: Node = loaded["ashvale"]
			var residents: Array[Node] = []
			var houses: Array[Node] = []
			for child in settlement.get_children():
				if child.get_script() != null and child.get_script().resource_path == "res://scripts/settler.gd":
					residents.append(child)
				elif child.is_in_group("village_house"):
					houses.append(child)
			resident_ok = residents.size() == 20 and houses.size() == 3
			var paving := settlement.get_node_or_null("StonePaving") as MeshInstance3D
			resident_ok = resident_ok and paving != null and paving.mesh is PlaneMesh and paving.material_override is ShaderMaterial
			if paving != null and paving.mesh is PlaneMesh:
				resident_ok = resident_ok and (paving.mesh as PlaneMesh).size == Vector2.ONE * site_data.PAVING_HALF_SIZE * 2.0
			for village_house in houses:
				resident_ok = resident_ok and not village_house.has_node("EntranceRamp") and village_house.find_children("*Stair*", "", true, false).is_empty()
			# Each resident shares four actual meshes with strictly descending
			# triangle counts, and disappears beyond the final distance band.
			if not residents.is_empty():
				var prior_triangles := 1501
				for lod_index in range(4):
					var resident_visual := residents[0].get_node_or_null("ResidentLOD%d" % lod_index) as MeshInstance3D
					if resident_visual == null or resident_visual.mesh == null:
						resident_ok = false
						continue
					var triangles: int = resident_visual.mesh.get_faces().size() / 3
					resident_ok = resident_ok and triangles > 0 and triangles < prior_triangles
					resident_ok = resident_ok and is_equal_approx(resident_visual.visibility_range_begin, [0.0, 10.0, 25.0, 50.0][lod_index]) and is_equal_approx(resident_visual.visibility_range_end, [10.0, 25.0, 50.0, 100.0][lod_index])
					if residents.size() > 1:
						var shared_visual := residents[1].get_node_or_null("ResidentLOD%d" % lod_index) as MeshInstance3D
						resident_ok = resident_ok and shared_visual != null and shared_visual.mesh == resident_visual.mesh
					prior_triangles = triangles
			var indices := {}
			for person in residents:
				indices[int(person.get("resident_index"))] = true
			resident_ok = resident_ok and indices.size() == 20
			var saved_quests := Game.settlement_quests.duplicate(true)
			var saved_coins := Game.coins
			Game.settlement_quests.erase("ashvale:main")
			Game.settlement_quests.erase("ashvale:19:main")
			menu.set("dialogue_site_id", "ashvale")
			menu.set("dialogue_resident_index", 19)
			menu.call("open_menu", "Dialogue")
			menu.call("_accept_settlement", "main")
			var quest_item := settlement.get_node_or_null("QuestItem_19_main") as Node3D
			quest_ui_ok = Game.settlement_quest_status("ashvale", "main", 19) == "active" and Game.settlement_quest_status("ashvale", "main", 0) == "available" and quest_item != null and quest_item.visible
			if quest_item != null:
				quest_item.call("_on_body_entered", world.get_node("Player"))
				quest_ui_ok = quest_ui_ok and Game.settlement_quest_status("ashvale", "main", 19) == "found"
			menu.call("_complete_settlement", "main")
			quest_ui_ok = quest_ui_ok and Game.settlement_quest_status("ashvale", "main", 19) == "done" and Game.coins == saved_coins + 25
			Game.load_collection()
			quest_ui_ok = quest_ui_ok and Game.settlement_quest_status("ashvale", "main", 19) == "done"
			menu.call("close_menu")
			menu.set("dialogue_site_id", "")
			menu.set("dialogue_resident_index", 0)
			Game.settlement_quests = saved_quests
			Game.coins = saved_coins
			Game.save_collection()
			Game.collection_changed.emit()
			# Check actual physics shapes: an open door ray, a solid wall ray,
			# a floor collider, and roof visibility when the player enters.
			if not houses.is_empty():
				await get_tree().physics_frame
				var house := houses[0] as Node3D
				var player := world.get_node("Player") as CharacterBody3D
				var space := house.get_world_3d().direct_space_state
				var door_ray := PhysicsRayQueryParameters3D.create(house.to_global(Vector3(-1, 1, -2.7)), house.to_global(Vector3(-1, 1, -1.2)), 1)
				door_ray.exclude = [player.get_rid()]
				var wall_ray := PhysicsRayQueryParameters3D.create(house.to_global(Vector3(0, 1, 0)), house.to_global(Vector3(2.5, 1, 0)), 1)
				wall_ray.exclude = [player.get_rid()]
				var door_closed := not space.intersect_ray(door_ray).is_empty()
				var wall_hit := space.intersect_ray(wall_ray)
				var old_pos := player.global_position
				player.global_position = house.to_global(Vector3(-1, 0.1, -3))
				var door_opened: bool = house.call("try_interact", player)
				await get_tree().process_frame
				await get_tree().physics_frame
				var door_hit := space.intersect_ray(door_ray)
				player.global_position = house.to_global(Vector3(-1, 0.1, -3))
				var door_closed_again: bool = house.call("try_interact", player) and not bool(house.get("_open"))
				player.global_position = house.to_global(Vector3(0, 0.1, 0))
				house.call("_process", 0.2)
				var roof := house.get_node("RoofParts") as Node3D
				var roof_hidden := not roof.visible
				var roof_near := roof.get_node_or_null("RoofNear") as Node3D
				var roof_mid := roof.get_node_or_null("RoofMid") as Node3D
				var roof_far := roof.get_node_or_null("RoofFar") as Node3D
				var roof_lod_ok := roof_near != null and roof_mid != null and roof_far != null
				if roof_lod_ok:
					var near_triangles := _recursive_mesh_triangles(roof_near)
					var mid_triangles := _recursive_mesh_triangles(roof_mid)
					var far_triangles := _recursive_mesh_triangles(roof_far)
					roof_lod_ok = near_triangles > mid_triangles and mid_triangles > far_triangles and far_triangles > 0
					roof_lod_ok = roof_lod_ok and _mesh_ranges_match(roof_near, 0.0, 25.0) and _mesh_ranges_match(roof_mid, 25.0, 50.0) and _mesh_ranges_match(roof_far, 50.0, 100.0)
				_log("INFO" if roof_lod_ok else "FAIL", "House roof distance meshes=%s" % str(roof_lod_ok))
				# The proximity button and keyboard action share the same live target.
				var furniture_hud := world.get_node("HUD")
				var old_health: float = Game.current_hp()
				Game.set_hp(Game.max_hp() * 0.5)
				player.global_position = house.to_global(Vector3(1.0, 0.1, 0.35))
				furniture_hud.call("_update_nearby_object_button")
				var nearby_button := furniture_hud.get("_context_button") as Button
				var furniture_ok := nearby_button != null and nearby_button.visible and nearby_button.text == "Rest at bed"
				furniture_hud.call("_use_nearby_house_object")
				furniture_ok = furniture_ok and Game.current_hp() > Game.max_hp() * 0.5
				player.global_position = house.to_global(Vector3(1.55, 0.1, -0.55))
				furniture_hud.call("_update_nearby_object_button")
				var prop_choice: Dictionary = house.call("interaction_for", player)
				furniture_ok = furniture_ok and str(prop_choice.get("id", "")).begins_with("prop_") and nearby_button.visible and nearby_button.text.begins_with("Inspect")
				furniture_ok = furniture_ok and bool(house.call("try_interact", player))
				Game.set_hp(old_health)
				player.global_position = house.to_global(Vector3(100, 0.1, 100))
				furniture_hud.call("_update_nearby_object_button")
				furniture_ok = furniture_ok and not nearby_button.visible
				if residents.size() == 20:
					var interaction_person := residents[19] as Node3D
					player.global_position = interaction_person.global_position
					furniture_hud.call("_update_nearby_object_button")
					furniture_ok = furniture_ok and nearby_button.visible and nearby_button.text.begins_with("Talk to ")
					furniture_hud.call("_use_nearby_house_object")
					furniture_ok = furniture_ok and menu.visible and str(menu.get("dialogue_site_id")) == "ashvale" and int(menu.get("dialogue_resident_index")) == 19
					menu.call("close_menu")
				house_ok = furniture_ok
				player.global_position = old_pos
				house.call("_process", 0.2)
				house_ok = house_ok and roof_lod_ok and door_closed and door_opened and door_hit.is_empty() and door_closed_again and house.scale.x > 1.0 and not wall_hit.is_empty() and roof_hidden and roof.visible and not house.has_node("EntranceRamp")
				_log("INFO", "House checks closed=%s opened=%s clear=%s reclosed=%s scale=%s wall=%s roof_hidden=%s roof_visible=%s no_ramp=%s" % [door_closed, door_opened, door_hit.is_empty(), door_closed_again, house.scale, not wall_hit.is_empty(), roof_hidden, roof.visible, not house.has_node("EntranceRamp")])
	_log("INFO" if resident_ok and quest_ui_ok and house_ok else "FAIL", "20 residents=%s independent quest=%s enterable house=%s" % [str(resident_ok), str(quest_ui_ok), str(house_ok)])
	var guard_lod_ok := false
	var ilyra_lod := world.get_node_or_null("StarGuardIlyra") as Node3D
	if ilyra_lod != null:
		guard_lod_ok = ilyra_lod.is_in_group("story_npc")
		var guard_prior := 4001
		for guard_lod_index in range(4):
			var guard_visual := ilyra_lod.get_node_or_null("GuardLOD%d" % guard_lod_index) as MeshInstance3D
			if guard_visual == null or guard_visual.mesh == null:
				guard_lod_ok = false
				continue
			var guard_triangles: int = guard_visual.mesh.get_faces().size() / 3
			guard_lod_ok = guard_lod_ok and guard_triangles > 0 and guard_triangles < guard_prior and guard_visual.visibility_range_end == [10.0, 25.0, 50.0, 100.0][guard_lod_index]
			guard_prior = guard_triangles
	_log("INFO" if guard_lod_ok else "FAIL", "Ilyra uses four shared low-poly LODs and remains talkable=%s" % str(guard_lod_ok))

	# Quest rewards survive saves, can be used, and cannot be claimed twice.
	var old_rewards := {"quests": Game.settlement_quests.duplicate(true), "coins": Game.coins, "starlight": Game.starlight, "weapons": Game.owned_weapons.duplicate(), "weapon": Game.equipped_weapon, "outfits": Game.owned_outfits.duplicate(), "outfit": Game.outfit_style, "cosmetics": Game.owned_cosmetics.duplicate(), "cosmetic": Game.equipped_cosmetic, "blueprints": Game.owned_blueprints.duplicate(), "levels": Game.wander.levels.duplicate(true), "slots": Game.wander.slots.duplicate()}
	Game.owned_weapons = []
	Game.owned_cosmetics = []
	Game.owned_blueprints = []
	Game.owned_outfits = [0, 1, 2]
	var rewards_ok := true
	for i in range(5):
		var key: String = "ashvale:main" if i == 0 else "ashvale:%d:main" % i
		Game.settlement_quests[key] = "found"
		rewards_ok = Game.complete_settlement_quest("ashvale", "main", i) and rewards_ok
		rewards_ok = not Game.complete_settlement_quest("ashvale", "main", i) and rewards_ok
	rewards_ok = rewards_ok and Game.owned_weapons.has("trail_blade") and Game.owned_weapons.has("leaf_blade") and Game.owned_blueprints.has(Game.BLUEPRINT_ID) and Game.owned_cosmetics.has("star_pin") and Game.owned_outfits.has(3)
	rewards_ok = Game.equip_reward_weapon("trail_blade") and Game.equip_reward_cosmetic("star_pin") and rewards_ok
	Game.set_outfit_style(3)
	Game.load_collection()
	rewards_ok = rewards_ok and Game.equipped_weapon == "trail_blade" and Game.equipped_cosmetic == "star_pin" and Game.outfit_style == 3 and Game.owned_blueprints.has(Game.BLUEPRINT_ID)
	if not Game.wander.known(Game.BLUEPRINT_ID):
		rewards_ok = Game.learn_reward_blueprint(Game.BLUEPRINT_ID) and rewards_ok
	rewards_ok = rewards_ok and Game.wander.known(Game.BLUEPRINT_ID)
	# All 100 IDs, display names and quest locations must be unique and valid.
	var weapon_catalog_ok := true
	var ids := {}
	var names := {}
	for site_index in range(5):
		for i in range(20):
			var site_id: String = SETTLEMENTS.SITES[site_index]["id"]
			var id: String = Game.WEAPONS.quest_weapon(site_id, i)
			var expected_index := site_index * 20 + i
			var display: String = Game.WEAPONS.name_for_id(id)
			weapon_catalog_ok = weapon_catalog_ok and id == Game.WEAPONS.id_for_index(expected_index) and Game.WEAPONS.index_for_id(id) == expected_index and not ids.has(id) and not names.has(display) and Game.WEAPONS.bonus(id) > 0.0
			ids[id] = true
			names[display] = true
			Game.call("_grant_quest_weapon", site_id, i)
	weapon_catalog_ok = weapon_catalog_ok and ids.size() == 100 and names.size() == 100 and Game.owned_weapons.size() == 100 and not Game.equip_reward_weapon("weapon_999")
	weapon_catalog_ok = Game.equip_reward_weapon("weapon_099") and weapon_catalog_ok
	Game.load_collection()
	weapon_catalog_ok = weapon_catalog_ok and Game.owned_weapons.size() == 100 and Game.equipped_weapon == "weapon_099"
	var builder = load("res://scripts/character_builder.gd")
	for shape in range(10):
		var anchor := Node3D.new()
		builder._build_reward_sword(anchor, Game.WEAPONS.id_for_index(shape))
		weapon_catalog_ok = weapon_catalog_ok and anchor.get_node_or_null("RewardBlade") != null
		var reward_budget: Vector2i = _weapon_mesh_budget(anchor)
		weapon_catalog_ok = weapon_catalog_ok and reward_budget.x <= 500 and reward_budget.y <= 350
		anchor.free()
	# Default sword, bow and focus use their own builders and must meet the same budget.
	for base_kind in ["sword", "bow", "focus"]:
		var base_anchor := Node3D.new()
		var base_glow: StandardMaterial3D = builder._glow(Color.WHITE)
		var base_accent: ShaderMaterial = builder._toon(Color.WHITE)
		builder._build_weapon(base_anchor, base_kind, base_glow, base_accent)
		var base_budget: Vector2i = _weapon_mesh_budget(base_anchor)
		weapon_catalog_ok = weapon_catalog_ok and base_budget.x <= 500 and base_budget.y <= 350
		base_anchor.free()
	_log("INFO" if weapon_catalog_ok else "FAIL", "100 weapons, equipment, saves and 500 triangle / 350 vertex budgets=%s" % str(weapon_catalog_ok))
	# Count every mesh in the playable rigs, including outline shells, gear and
	# normally hidden wings; preserve save state and do not replace the live rig.
	var avatar_outfit_before: int = Game.outfit_style
	var avatar_backpack_before: int = Game.equipped_backpack
	var avatar_cosmetic_before: String = Game.equipped_cosmetic
	Game.outfit_style = 4
	Game.equipped_backpack = 1
	Game.equipped_cosmetic = "star_pin"
	var avatar_budget_ok := true
	for avatar_data in Game.PARTY:
		var avatar_host := Node3D.new()
		var avatar_rig: Dictionary = builder.build(avatar_host, avatar_data)
		var avatar_triangles: int = _recursive_mesh_triangles(avatar_host)
		if str(avatar_data["name"]) == "Sora": _report_avatar_meshes(avatar_host)
		avatar_budget_ok = avatar_budget_ok and not avatar_rig.is_empty() and avatar_triangles > 0 and avatar_triangles <= 8000
		_log("INFO", "Playable %s: %d triangles including outlines and equipment" % [avatar_data["name"], avatar_triangles])
		avatar_host.free()
	Game.outfit_style = avatar_outfit_before
	Game.equipped_backpack = avatar_backpack_before
	Game.equipped_cosmetic = avatar_cosmetic_before
	_log("INFO" if avatar_budget_ok else "FAIL", "Playable rigs within 8000 triangle budget=%s" % str(avatar_budget_ok))
	Game.settlement_quests = old_rewards["quests"]
	Game.coins = old_rewards["coins"]
	Game.starlight = old_rewards["starlight"]
	Game.owned_weapons = old_rewards["weapons"]
	Game.equipped_weapon = old_rewards["weapon"]
	Game.owned_outfits = old_rewards["outfits"]
	Game.outfit_style = old_rewards["outfit"]
	Game.owned_cosmetics = old_rewards["cosmetics"]
	Game.equipped_cosmetic = old_rewards["cosmetic"]
	Game.owned_blueprints = old_rewards["blueprints"]
	Game.wander.levels = old_rewards["levels"]
	Game.wander.slots.assign(old_rewards["slots"])
	Game.save_wander()
	Game.character_changed.emit(Game.party_index)
	Game.collection_changed.emit()
	_log("INFO" if rewards_ok else "FAIL", "quest reward persistence, equipment and blueprint=%s" % str(rewards_ok))

	# Every established memory has a narrative account, hidden until its own
	# existing clear flag. This also verifies old saves need no new story keys.
	var chronicle_clears: Dictionary = Game.dungeon_clears.duplicate(true)
	var chronicle_ashvale: bool = Game.ashvale_hollow_cleared
	var chronicle_story: Dictionary = Game.guard_story.duplicate(true)
	Game.dungeon_clears = {}
	Game.ashvale_hollow_cleared = false
	Game.guard_story = {}
	var chronicle_ok := Game.all_story_memories().size() == 25 and Game.STORY_CHRONICLE.ACCOUNTS.size() == 25 and Game.STORY_CHRONICLE.REGION_HOOKS.size() == 14 and Game.STORY_CHRONICLE.REGIONAL_PAYOFFS.size() == 14
	chronicle_ok = chronicle_ok and Game.story_connections().is_empty()
	for memory in Game.all_story_memories():
		var memory_id := str(memory["id"])
		chronicle_ok = chronicle_ok and Game.story_account(memory_id).is_empty() and not Game.STORY_CHRONICLE.account(memory_id).is_empty()
		if memory_id == "ashvale": Game.ashvale_hollow_cleared = true
		else: Game.dungeon_clears[memory_id] = true
		chronicle_ok = chronicle_ok and Game.story_account(memory_id) == Game.STORY_CHRONICLE.account(memory_id)
	chronicle_ok = chronicle_ok and Game.story_connections().size() == Game.STORY_CHRONICLE.CONNECTIONS.size()
	Game.dungeon_clears.erase("memory_25")
	chronicle_ok = chronicle_ok and Game.story_connections().size() == Game.STORY_CHRONICLE.CONNECTIONS.size() - 1
	Game.dungeon_clears["memory_25"] = true
	for story_site in SETTLEMENTS.SITES:
		chronicle_ok = chronicle_ok and not str(Game.STORY_CHRONICLE.REGION_HOOKS.get(story_site["id"], "")).is_empty()
		var regional_payoff: Array = Game.STORY_CHRONICLE.REGIONAL_PAYOFFS.get(story_site["id"], [])
		chronicle_ok = chronicle_ok and regional_payoff.size() == 2
		if regional_payoff.size() == 2: chronicle_ok = chronicle_ok and not str(regional_payoff[0]).is_empty() and not str(regional_payoff[1]).is_empty()
	chronicle_ok = chronicle_ok and Game.story_ending().is_empty() and not Game.resolve_keeper_memory("witness")
	Game.guard_story["keeper_defeated"] = true
	Game.guard_story["memory_choice"] = "share"
	var shared_ending: String = Game.story_ending()
	Game.guard_story["memory_choice"] = "study"
	chronicle_ok = chronicle_ok and not shared_ending.is_empty() and shared_ending != Game.story_ending()
	chronicle_ok = chronicle_ok and not Game.resolve_keeper_memory("invalid") and Game.resolve_keeper_memory("private")
	var private_ending: String = Game.story_ending()
	chronicle_ok = chronicle_ok and not Game.resolve_keeper_memory("witness")
	Game.guard_story.erase("keeper_resolution")
	chronicle_ok = chronicle_ok and Game.resolve_keeper_memory("witness") and private_ending != Game.story_ending()
	Game.save_collection()
	Game.guard_story = {}
	Game.dungeon_clears = {}
	Game.ashvale_hollow_cleared = false
	Game.load_collection()
	chronicle_ok = chronicle_ok and Game.story_memory_count() == 25 and str(Game.guard_story.get("memory_choice", "")) == "study" and str(Game.guard_story.get("keeper_resolution", "")) == "witness" and not Game.story_ending().is_empty()
	# Exercise the actual dialogue view at all three leader quest stages.
	var quest_dialogues_before: Dictionary = Game.settlement_quests.duplicate(true)
	if menu != null:
		for leader_site in SETTLEMENTS.SITES:
			var leader_id := str(leader_site["id"])
			menu.set("dialogue_site_id", leader_id)
			menu.set("dialogue_resident_index", 0)
			for leader_stage in ["available", "found", "done"]:
				Game.settlement_quests[leader_id + ":main"] = leader_stage
				menu.call("open_menu", "Dialogue")
				var dialogue_body := menu.get("_body") as VBoxContainer
				var expected_line := str(Game.STORY_CHRONICLE.REGION_HOOKS[leader_id]) if leader_stage == "available" else str(Game.STORY_CHRONICLE.REGIONAL_PAYOFFS[leader_id][0 if leader_stage == "found" else 1])
				var found_line := false
				for dialogue_child in dialogue_body.get_children():
					if dialogue_child is Label and dialogue_child.text == expected_line: found_line = true
				chronicle_ok = chronicle_ok and found_line
			Game.settlement_quests[leader_id + ":main"] = "done"
			menu.call("open_menu", "Dialogue")
			var ending_body := menu.get("_body") as VBoxContainer
			var ending_line := str(Game.STORY_CHRONICLE.REGIONAL_EPILOGUES.get(leader_id, ""))
			var ending_found := false
			for child in ending_body.get_children():
				if child is Label and child.text == ending_line: ending_found = true
			chronicle_ok = chronicle_ok and not ending_line.is_empty() and ending_found
		menu.call("close_menu")
		menu.set("dialogue_site_id", "")
		menu.set("dialogue_resident_index", 0)
	else:
		chronicle_ok = false
	Game.settlement_quests = quest_dialogues_before
	Game.dungeon_clears = chronicle_clears
	Game.ashvale_hollow_cleared = chronicle_ashvale
	Game.guard_story = chronicle_story
	Game.save_collection()
	_log("INFO" if chronicle_ok else "FAIL", "25 gated story accounts, 14 regional arcs, finale choices and save compatibility=%s" % str(chronicle_ok))

	# Optional companion quest: real memorial interaction, prerequisites, both
	# decisions, once-only reward, older clears and save persistence.
	var arc_story: Dictionary = Game.guard_story.duplicate(true)
	var arc_clears: Dictionary = Game.dungeon_clears.duplicate(true)
	var arc_quests: Dictionary = Game.settlement_quests.duplicate(true)
	var arc_light: int = Game.starlight
	Game.guard_story = {}
	Game.dungeon_clears = {}
	Game.settlement_quests = {}
	var arc_ok := not Game.begin_ilyra_arc() and not Game.read_ilyra_memorial()
	Game.guard_story["memory_done"] = true
	arc_ok = arc_ok and Game.begin_ilyra_arc() and not Game.begin_ilyra_arc() and not Game.hear_ilyra_guard_record()
	var memorial = load("res://scripts/patrol_memorial.gd").new()
	world.add_child(memorial)
	var arc_actor := Node3D.new()
	world.add_child(arc_actor)
	arc_actor.global_position = memorial.global_position
	arc_ok = arc_ok and memorial.call("try_interact", arc_actor) and not memorial.call("try_interact", arc_actor)
	arc_ok = arc_ok and not Game.hear_ilyra_guard_record()
	Game.settlement_quests["capital:main"] = "done"
	arc_ok = arc_ok and Game.hear_ilyra_guard_record() and not Game.finish_ilyra_arc("names")
	Game.dungeon_clears["memory_vault"] = true
	arc_ok = arc_ok and not Game.finish_ilyra_arc("invalid") and Game.finish_ilyra_arc("names") and not Game.finish_ilyra_arc("names")
	arc_ok = arc_ok and int(Game.guard_story.get("ilyra_arc_stage", 0)) == 5 and Game.starlight == arc_light
	arc_ok = arc_ok and memorial.call("try_interact", arc_actor) and not Game.complete_ilyra_arc()
	arc_ok = arc_ok and Game.starlight == arc_light + 60 and int(Game.guard_story.get("ilyra_bond", 0)) == 3
	Game.save_collection()
	Game.guard_story = {}
	Game.load_collection()
	arc_ok = arc_ok and int(Game.guard_story.get("ilyra_arc_stage", 0)) == 4 and str(Game.guard_story.get("ilyra_arc_choice", "")) == "names"
	Game.guard_story["keeper_defeated"] = true
	var names_ending: String = Game.story_ending()
	Game.guard_story["ilyra_arc_stage"] = 3
	arc_ok = arc_ok and Game.finish_ilyra_arc("letters") and int(Game.guard_story.get("ilyra_arc_stage", 0)) == 6
	arc_ok = arc_ok and Game.complete_ilyra_arc() and names_ending != Game.story_ending()
	memorial.queue_free()
	arc_actor.queue_free()
	Game.guard_story = arc_story
	Game.dungeon_clears = arc_clears
	Game.settlement_quests = arc_quests
	Game.starlight = arc_light
	Game.save_collection()
	Game.collection_changed.emit()
	_log("INFO" if arc_ok else "FAIL", "Ilyra companion quest, memorial, choices and persistence=%s" % str(arc_ok))

	# Cross-region side story: prerequisites, both plans, one-time spell reward,
	# persistent decision, actual dialogue routes and spell mechanics.
	var harbor_story_before: Dictionary = Game.guard_story.duplicate(true)
	var harbor_clears_before: Dictionary = Game.dungeon_clears.duplicate(true)
	var harbor_quests_before: Dictionary = Game.settlement_quests.duplicate(true)
	var harbor_levels_before: Dictionary = Game.wander.levels.duplicate(true)
	var harbor_stamina_before: float = Game.stamina
	var harbor_shield_before: float = Game.shield_points
	Game.guard_story = {}
	Game.dungeon_clears = {}
	Game.settlement_quests = {}
	Game.wander.levels.erase("harbor_light")
	var harbor_ok := not Game.begin_harbor_story() and not Game.finish_harbor_story()
	Game.settlement_quests["tidefall:main"] = "done"
	harbor_ok = harbor_ok and Game.begin_harbor_story() and not Game.begin_harbor_story()
	Game.dungeon_clears["memory_11"] = true
	Game.dungeon_clears["memory_12"] = true
	harbor_ok = harbor_ok and not Game.choose_harbor_story("shared")
	Game.settlement_quests["glassheaven:main"] = "done"
	harbor_ok = harbor_ok and not Game.choose_harbor_story("invalid") and Game.choose_harbor_story("shared")
	Game.save_collection()
	Game.guard_story = {}
	Game.load_collection()
	harbor_ok = harbor_ok and int(Game.guard_story.get("harbor_stage", 0)) == 2 and str(Game.guard_story.get("harbor_choice", "")) == "shared"
	harbor_ok = harbor_ok and Game.finish_harbor_story() and not Game.finish_harbor_story() and Game.wander.known("harbor_light")
	Game.save_collection()
	Game.guard_story = {}
	Game.load_collection()
	harbor_ok = harbor_ok and int(Game.guard_story.get("harbor_stage", 0)) == 3 and Game.wander_levels.has("harbor_light")
	var harbor_actor := world.get_node_or_null("Player") as Node3D
	if harbor_actor != null:
		Game.stamina = 0.0
		Game.shield_points = 0.0
		harbor_actor.call("_on_spell_cast", "harbor_light", Game.wander.spell("harbor_light"))
		harbor_ok = harbor_ok and Game.stamina > 0.0 and Game.shield_points > 0.0
	else:
		harbor_ok = false
	Game.guard_story["harbor_stage"] = 1
	harbor_ok = harbor_ok and Game.choose_harbor_story("station") and str(Game.guard_story.get("harbor_choice", "")) == "station"
	if menu != null:
		menu.set("dialogue_site_id", "tidefall")
		menu.set("dialogue_resident_index", 0)
		menu.call("open_menu", "Dialogue")
		var harbor_body := menu.get("_body") as VBoxContainer
		var station_found := false
		for harbor_child in harbor_body.get_children():
			if harbor_child is Label and "harbour station" in harbor_child.text: station_found = true
		harbor_ok = harbor_ok and station_found
		menu.call("close_menu")
		menu.set("dialogue_site_id", "")
	else:
		harbor_ok = false
	Game.guard_story = harbor_story_before
	Game.dungeon_clears = harbor_clears_before
	Game.settlement_quests = harbor_quests_before
	Game.wander.levels = harbor_levels_before
	Game.stamina = harbor_stamina_before
	Game.shield_points = harbor_shield_before
	Game.save_wander()
	Game.collection_changed.emit()
	_log("INFO" if harbor_ok else "FAIL", "cross-region harbor quest, choices, spell and persistence=%s" % str(harbor_ok))

	# A lost Wander: exercise streaming, the actual interaction, both choices,
	# persistent progress and the spell's damage/slow on a real scout.
	var lost_story: Dictionary = Game.guard_story.duplicate(true)
	var lost_clears: Dictionary = Game.dungeon_clears.duplicate(true)
	var lost_quests: Dictionary = Game.settlement_quests.duplicate(true)
	var lost_levels: Dictionary = Game.wander.levels.duplicate(true)
	var lost_actor := world.get_node_or_null("Player") as CharacterBody3D
	var lost_position: Vector3 = lost_actor.global_position
	Game.guard_story = {}
	Game.dungeon_clears = {}
	Game.settlement_quests = {}
	Game.wander.levels.erase("echo_resonance")
	var lost_ok := not Game.begin_wander_story() and not Game.trace_lost_wander() and not Game.recover_lost_wander()
	Game.settlement_quests["lunareth:main"] = "done"
	lost_ok = lost_ok and Game.begin_wander_story() and not Game.begin_wander_story()
	Game.dungeon_clears["memory_09"] = true
	Game.dungeon_clears["memory_22"] = true
	lost_ok = lost_ok and not Game.trace_lost_wander()
	Game.settlement_quests["evergloom:main"] = "done"
	lost_ok = lost_ok and Game.trace_lost_wander()
	if settlement_manager != null:
		var lost_sites: Array = settlement_manager.get("_sites")
		var lost_center: Vector2 = lost_sites[12]["resolved"]
		lost_actor.global_position = Vector3(lost_center.x, float(world.call("_height", lost_center.x, lost_center.y)) + 0.2, lost_center.y)
		settlement_manager.call("_update_stream")
		var loaded_sites: Dictionary = settlement_manager.get("_loaded")
		var lost_root := loaded_sites.get("evergloom") as Node3D
		var lost_book: Node = lost_root.get_node_or_null("LostWander") if lost_root != null else null
		if lost_book != null:
			lost_actor.global_position = lost_book.global_position + Vector3(0, 0.2, 0)
			lost_ok = bool(lost_book.call("try_interact", lost_actor)) and lost_ok
			lost_ok = lost_ok and int(Game.guard_story.get("wander_story_stage", 0)) == 3 and not Game.recover_lost_wander()
		else:
			lost_ok = false
	else:
		lost_ok = false
	Game.save_collection()
	Game.guard_story = {}
	Game.load_collection()
	lost_ok = lost_ok and int(Game.guard_story.get("wander_story_stage", 0)) == 3 and not Game.finish_wander_story("invalid")
	lost_ok = lost_ok and Game.finish_wander_story("public") and not Game.finish_wander_story("families") and Game.wander.known("echo_resonance")
	Game.guard_story["keeper_defeated"] = true
	var lost_public_ending: String = Game.story_ending()
	Game.guard_story["wander_story_stage"] = 3
	lost_ok = lost_ok and Game.finish_wander_story("families") and lost_public_ending != Game.story_ending()
	Game.guard_story = {}
	Game.load_collection()
	lost_ok = lost_ok and str(Game.guard_story.get("wander_story_choice", "")) == "families" and Game.wander_levels.has("echo_resonance")
	lost_actor.global_position = Vector3(0, 800, 0)
	var lost_scout = load("res://scripts/hollow_sentry.gd").new()
	world.add_child(lost_scout)
	lost_scout.global_position = Vector3(2, 800, 0)
	await get_tree().physics_frame
	lost_actor.call("_on_spell_cast", "echo_resonance", Game.wander.spell("echo_resonance"))
	lost_ok = lost_ok and float(lost_scout.get("hp")) < 260.0 and float(lost_scout.get("_slow_remaining")) > 0.0
	lost_scout.queue_free()
	lost_actor.global_position = lost_position
	Game.guard_story = lost_story
	Game.dungeon_clears = lost_clears
	Game.settlement_quests = lost_quests
	Game.wander.levels = lost_levels
	Game.save_wander()
	Game.collection_changed.emit()
	if settlement_manager != null: settlement_manager.call("_update_stream")
	_log("INFO" if lost_ok else "FAIL", "lost Wander investigation, streaming, choices, spell and persistence=%s" % str(lost_ok))

	# Neri is one character, not a duplicate resident: she joins after her
	# quest, talks through the same dialogue, supports combat and returns home.
	var neri_story_before: Dictionary = Game.guard_story.duplicate(true)
	var neri_energy_before: float = Game.energy
	var neri_shield_before: float = Game.shield_points
	var neri_player := world.get_node_or_null("Player") as CharacterBody3D
	var neri_player_before := neri_player.global_position
	var neri := world.get_node_or_null("CompanionNeri") as Node3D
	Game.guard_story = {}
	Game.collection_changed.emit()
	var neri_ok := neri != null and not Game.set_neri_following(true)
	Game.guard_story["harbor_stage"] = 3
	if neri != null and settlement_manager != null:
		var neri_sites: Array = settlement_manager.get("_sites")
		var tide_center: Vector2 = neri_sites[3]["resolved"]
		neri_player.global_position = Vector3(tide_center.x, float(world.call("_height", tide_center.x, tide_center.y)) + 0.2, tide_center.y)
		settlement_manager.call("_update_stream")
		var neri_loaded: Dictionary = settlement_manager.get("_loaded")
		var tide_root := neri_loaded.get("tidefall") as Node3D
		neri_ok = neri_ok and tide_root != null and tide_root.has_node("Resident_00")
		neri_ok = neri_ok and Game.set_neri_following(true) and neri.visible and neri.is_in_group("story_npc") and not tide_root.has_node("Resident_00")
		neri.call("_process", 0.1)
		neri_ok = neri_ok and neri.global_position.distance_to(neri_player.global_position) < 4.0
		var neri_hud := world.get_node("HUD")
		neri_ok = neri_ok and str(neri_hud.call("_npc_name", neri)) == "Neri"
		neri_hud.call("_open_npc_dialogue", neri)
		neri_ok = neri_ok and menu.visible and str(menu.get("dialogue_site_id")) == "tidefall"
		menu.call("close_menu")
		Game.guard_story = {}
		Game.load_collection()
		neri_ok = neri_ok and bool(Game.guard_story.get("neri_following", false))
		neri_player.global_position = Vector3(0, 800, 0)
		var neri_scout = load("res://scripts/hollow_sentry.gd").new()
		world.add_child(neri_scout)
		neri_scout.global_position = Vector3(2, 800, 0)
		Game.energy = 0.0
		Game.shield_points = 0.0
		Game.guard_story["ilyra_following"] = false
		neri.set("_support_cooldown", 0.0)
		neri.call("_process", 0.1)
		neri_ok = neri_ok and Game.energy == 14.0 and Game.shield_points == 0.0 and float(neri.get("_support_cooldown")) > 0.0
		Game.energy = 0.0
		Game.guard_story["ilyra_following"] = true
		neri.set("_support_cooldown", 0.0)
		neri.call("_process", 0.1)
		neri_ok = neri_ok and Game.energy == 14.0 and Game.shield_points == 35.0
		neri_scout.queue_free()
		neri_ok = neri_ok and Game.set_neri_following(false) and not neri.visible and tide_root.has_node("Resident_00")
	else:
		neri_ok = false
	neri_player.global_position = neri_player_before
	Game.guard_story = neri_story_before
	Game.energy = neri_energy_before
	Game.shield_points = neri_shield_before
	Game.save_collection()
	Game.collection_changed.emit()
	if settlement_manager != null: settlement_manager.call("_update_stream")
	_log("INFO" if neri_ok else "FAIL", "Neri companion, dialogue identity, support synergy and save=%s" % str(neri_ok))

	# Frostmere defense uses a real streamed encounter and retries after respawn.
	var watch_story_before: Dictionary = Game.guard_story.duplicate(true)
	var watch_quests_before: Dictionary = Game.settlement_quests.duplicate(true)
	var watch_levels_before: Dictionary = Game.wander.levels.duplicate(true)
	var watch_actor := world.get_node_or_null("Player") as CharacterBody3D
	var watch_position_before := watch_actor.global_position
	var watch_hp_before: float = Game.current_hp()
	var watch_shield_before: float = Game.shield_points
	Game.guard_story = {}
	Game.settlement_quests = {}
	Game.wander.levels.erase("watchfire")
	var watch_ok := not Game.begin_watch_story() and not Game.finish_watch_story("patrol")
	Game.settlement_quests["frostmere:main"] = "done"
	watch_ok = watch_ok and Game.begin_watch_story() and not Game.begin_watch_story()
	if settlement_manager != null:
		var watch_sites: Array = settlement_manager.get("_sites")
		var watch_center: Vector2 = watch_sites[5]["resolved"]
		watch_actor.global_position = Vector3(watch_center.x, float(world.call("_height", watch_center.x, watch_center.y)) + 0.2, watch_center.y)
		settlement_manager.call("_update_stream")
		var watch_loaded: Dictionary = settlement_manager.get("_loaded")
		var watch_root := watch_loaded.get("frostmere") as Node3D
		var watch: Node = watch_root.get_node_or_null("VillageWatch") if watch_root != null else null
		if watch != null:
			watch_actor.global_position = (watch as Node3D).global_position + Vector3(0, 0.2, 0)
			watch_ok = bool(watch.call("try_interact", watch_actor)) and watch_ok
			watch_ok = watch_ok and int(watch.get("_remaining")) == 2 and bool(watch.get("_active"))
			# Repeated interaction cannot spawn an additional wave.
			watch_ok = bool(watch.call("try_interact", watch_actor)) and watch_ok
			var first_wave: Array = []
			for child in watch.get_children():
				if child is CharacterBody3D: first_wave.append(child)
			watch_ok = watch_ok and first_wave.size() == 2
			Game.respawned.emit()
			watch_ok = watch_ok and not bool(watch.get("_active")) and int(Game.guard_story.get("watch_stage", 0)) == 1
			await get_tree().process_frame
			watch_actor.global_position = (watch as Node3D).global_position + Vector3(0, 0.2, 0)
			watch_ok = bool(watch.call("try_interact", watch_actor)) and watch_ok
			var retry_wave: Array = []
			for child in watch.get_children():
				if child is CharacterBody3D and not child.is_queued_for_deletion(): retry_wave.append(child)
			watch_ok = watch_ok and retry_wave.size() == 2
			for foe in retry_wave: foe.call("take_hit", 10000.0, 0, Vector3.ZERO)
			watch_ok = watch_ok and int(Game.guard_story.get("watch_stage", 0)) == 2 and not watch_root.has_node("VillageWatch")
		else:
			watch_ok = false
	else:
		watch_ok = false
	Game.guard_story = {}
	Game.load_collection()
	watch_ok = watch_ok and int(Game.guard_story.get("watch_stage", 0)) == 2 and not Game.finish_watch_story("bad")
	watch_ok = watch_ok and Game.finish_watch_story("patrol") and not Game.finish_watch_story("patrol") and Game.wander.known("watchfire")
	Game.guard_story["keeper_defeated"] = true
	var patrol_ending: String = Game.story_ending()
	Game.guard_story["watch_stage"] = 2
	watch_ok = watch_ok and Game.finish_watch_story("evacuation") and Game.story_ending() != patrol_ending
	Game.guard_story = {}
	Game.load_collection()
	watch_ok = watch_ok and str(Game.guard_story.get("watch_choice", "")) == "evacuation" and Game.wander_levels.has("watchfire")
	Game.set_hp(Game.max_hp() * 0.5)
	Game.shield_points = 0.0
	var watch_hp_cast: float = Game.current_hp()
	watch_actor.call("_on_spell_cast", "watchfire", Game.wander.spell("watchfire"))
	watch_ok = watch_ok and Game.current_hp() > watch_hp_cast and Game.shield_points > 0.0
	watch_actor.global_position = watch_position_before
	Game.guard_story = watch_story_before
	Game.settlement_quests = watch_quests_before
	Game.wander.levels = watch_levels_before
	Game.set_hp(watch_hp_before)
	Game.shield_points = watch_shield_before
	Game.save_wander()
	Game.collection_changed.emit()
	if settlement_manager != null: settlement_manager.call("_update_stream")
	_log("INFO" if watch_ok else "FAIL", "Frostmere defense, retry, choices, spell and save=%s" % str(watch_ok))

	# Earned tier resonance is offensive only, derived from the existing clear
	# flags, capped to the current encounter and reset when leaving.
	var resonance_clears: Dictionary = Game.dungeon_clears.duplicate(true)
	var resonance_player := world.get_node_or_null("Player") as CharacterBody3D
	var resonance_position := resonance_player.global_position
	Game.dungeon_clears = {}
	var resonance_ok := Game.earned_hollow_resonance("optional_000") == 1.0 and Game.earned_hollow_resonance("memory_04") == 1.0
	for number in range(4, 24): Game.dungeon_clears["memory_%02d" % number] = true
	resonance_ok = resonance_ok and Game.earned_hollow_resonance("optional_000") == 10.0
	for number in range(20): Game.dungeon_clears["optional_%03d" % number] = true
	resonance_ok = resonance_ok and Game.earned_hollow_resonance("optional_020") == 200.0 and Game.earned_hollow_resonance("optional_000") == 10.0
	for number in range(20, 40): Game.dungeon_clears["optional_%03d" % number] = true
	resonance_ok = resonance_ok and Game.earned_hollow_resonance("optional_040") == 2000.0
	for number in range(40, 60): Game.dungeon_clears["optional_%03d" % number] = true
	resonance_ok = resonance_ok and Game.earned_hollow_resonance("optional_060") == 3000.0 and Game.earned_hollow_resonance("last_seal") == 3000.0 and Game.earned_hollow_resonance("ashvale") == 1.0
	resonance_player.global_position = Vector3(0, 800, 0)
	var resonance_scout = load("res://scripts/hollow_sentry.gd").new()
	resonance_scout._power_multiplier = 100.0
	world.add_child(resonance_scout)
	resonance_scout.global_position = Vector3(2, 800, 0)
	await get_tree().physics_frame
	var hp_start: float = resonance_scout.hp
	resonance_player.call("_on_spell_cast", "echo_resonance", Game.wander.spell("echo_resonance"))
	var ordinary_damage: float = hp_start - resonance_scout.hp
	Game.enter_hollow_resonance("optional_000")
	resonance_player.call("_on_spell_cast", "echo_resonance", Game.wander.spell("echo_resonance"))
	var boosted_damage: float = hp_start - ordinary_damage - resonance_scout.hp
	resonance_ok = resonance_ok and ordinary_damage > 0.0 and is_equal_approx(boosted_damage / ordinary_damage, 10.0)
	Game.leave_hollow_resonance("different_id")
	resonance_ok = resonance_ok and Game.hollow_resonance == 10.0
	Game.leave_hollow_resonance("optional_000")
	resonance_ok = resonance_ok and Game.hollow_resonance == 1.0 and Game.resonance_source.is_empty()
	resonance_scout.queue_free()
	resonance_player.global_position = resonance_position
	Game.dungeon_clears = resonance_clears
	_log("INFO" if resonance_ok else "FAIL", "earned Hollow resonance, tier caps, damage and cleanup=%s" % str(resonance_ok))

	# Fixed tiers scale regional encounters and the Keeper without a setting.
	var tier_ok := is_equal_approx(Game.hollow_power_multiplier("memory_04"), 1.0) and is_equal_approx(Game.hollow_power_multiplier("optional_000"), 20.0) and is_equal_approx(Game.hollow_power_multiplier("optional_019"), 20.0) and is_equal_approx(Game.hollow_power_multiplier("optional_020"), 500.0) and is_equal_approx(Game.hollow_power_multiplier("optional_039"), 500.0) and is_equal_approx(Game.hollow_power_multiplier("optional_040"), 7500.0) and is_equal_approx(Game.hollow_power_multiplier("optional_059"), 7500.0) and is_equal_approx(Game.hollow_power_multiplier("optional_060"), 15000.0) and is_equal_approx(Game.hollow_power_multiplier("optional_079"), 15000.0) and is_equal_approx(Game.hollow_power_multiplier("optional_080"), 1.0)
	var challenge_fixture := Node3D.new()
	world.add_child(challenge_fixture)
	challenge_fixture.global_position = Vector3(0, 800, 0)
	var challenge_scout = load("res://scripts/hollow_sentry.gd").new()
	var challenge_boss = load("res://scripts/hollow_warden.gd").new()
	var challenge_slime = load("res://scripts/slime.gd").new()
	var challenge_trap = load("res://scripts/story_hollow_trap.gd").new()
	var damage_receiver = load("res://tests/damage_receiver.gd").new()
	challenge_fixture.add_child(damage_receiver)
	challenge_scout._power_multiplier = 15000.0
	challenge_boss._power_multiplier = 15000.0
	challenge_trap._power_multiplier = 15000.0
	challenge_trap.player = damage_receiver
	challenge_fixture.add_child(challenge_scout)
	var scout_orc = load("res://scripts/hollow_sentry.gd").new()
	scout_orc.is_orc = true
	challenge_fixture.add_child(scout_orc)
	challenge_fixture.add_child(challenge_boss)
	var second_boss = load("res://scripts/hollow_warden.gd").new()
	challenge_fixture.add_child(second_boss)
	# Telegraphs share immutable geometry/materials and belong to their enemy.
	# Top-level keeps a committed marker fixed even if its owner moves or rotates.
	var scout_warning: MeshInstance3D = challenge_scout.get("_warning")
	var orc_warning: MeshInstance3D = scout_orc.get("_warning")
	var boss_warning: MeshInstance3D = challenge_boss.get("_warning")
	var second_warning: MeshInstance3D = second_boss.get("_warning")
	var warning_ok: bool = scout_warning.get_parent() == challenge_scout and boss_warning.get_parent() == challenge_boss and scout_warning.top_level and boss_warning.top_level
	warning_ok = warning_ok and scout_warning.mesh == orc_warning.mesh and scout_warning.material_override == orc_warning.material_override
	warning_ok = warning_ok and boss_warning.mesh == second_warning.mesh and boss_warning.material_override == second_warning.material_override
	var disc: CylinderMesh = challenge_boss._disc_mesh(3.4)
	var line: BoxMesh = challenge_boss._line_mesh()
	var ring: TorusMesh = challenge_boss._ring_mesh()
	warning_ok = warning_ok and disc == challenge_boss._disc_mesh(3.4) and is_equal_approx(disc.top_radius, 3.4)
	warning_ok = warning_ok and line == second_boss._line_mesh() and line.size == Vector3(2.0, 0.04, 12.0)
	warning_ok = warning_ok and ring == second_boss._ring_mesh() and is_equal_approx(ring.inner_radius, 2.2) and is_equal_approx(ring.outer_radius, 5.0)
	var committed_target := Vector3(3, 805, 4)
	scout_warning.global_position = committed_target
	challenge_scout.global_position += Vector3(2, 0, 0)
	warning_ok = warning_ok and scout_warning.global_position.is_equal_approx(committed_target)
	_log("INFO" if warning_ok else "FAIL", "Combat telegraphs are owner-scoped, world-fixed and shared=%s" % str(warning_ok))
	challenge_fixture.add_child(challenge_slime)
	challenge_fixture.add_child(challenge_trap)
	tier_ok = tier_ok and is_equal_approx(challenge_scout.hp, 3900000.0) and is_equal_approx(challenge_boss.max_hp, 16500000.0) and is_equal_approx(challenge_slime.max_hp, 150.0)
	# Both imported variants must retain their rig and stay under the triangle
	# budget. Godot expands vertex seams, so report (but do not hide) that count.
	for scout in [challenge_scout, scout_orc]:
		var scout_visual: Node3D = scout.get("_visual")
		var scout_anim: AnimationPlayer = scout.get("_animation")
		var scout_triangles := _recursive_mesh_triangles(scout_visual)
		var scout_vertices := _recursive_mesh_vertices(scout_visual)
		tier_ok = tier_ok and scout_triangles > 0 and scout_triangles <= 2000 and scout_vertices > 0
		tier_ok = tier_ok and not scout_visual.find_children("*", "Skeleton3D", true, false).is_empty() and scout_anim != null and not scout_anim.current_animation.is_empty()
		_log("INFO", "Scout %s: %d triangles, %d vertices" % ["orc" if scout.is_orc else "ghost", scout_triangles, scout_vertices])
	challenge_trap._state = "warning"
	challenge_trap._timer = 0.0
	challenge_trap._physics_process(0.01)
	tier_ok = tier_ok and is_equal_approx(damage_receiver.last_damage, Game.max_hp() * 0.08 * 15000.0)
	challenge_fixture.queue_free()
	_log("INFO" if tier_ok else "FAIL", "Fixed dungeon tiers: normal, 20x, 500x, 7500x and 15000x enemy and trial damage=%s" % str(tier_ok))

	# Progression requires Ilyra's memory quest and the local leader's guide.
	var progression_story := Game.guard_story.duplicate(true)
	var progression_quests := Game.settlement_quests.duplicate(true)
	var progression_armor_owned: bool = Game.owned_wayfarer_armor
	var progression_armor_equipped: bool = Game.equipped_wayfarer_armor
	var progression_potions: int = Game.potions
	var progression_hp: float = Game.current_hp()
	Game.guard_story = {}
	Game.settlement_quests = {}
	var progression_ok := not Game.can_enter_hollow("ashvale", "ashvale", false) and not Game.can_enter_hollow("memory_09", "lunareth", false)
	Game.guard_story["memory_accepted"] = true
	progression_ok = progression_ok and Game.can_enter_hollow("ashvale", "ashvale", false) and not Game.can_enter_hollow("memory_09", "lunareth", false)
	Game.guard_story["memory_done"] = true
	progression_ok = progression_ok and not Game.can_enter_hollow("memory_09", "lunareth", false)
	var locked_vault := world.get_node_or_null("MemoryVault")
	var progression_player := world.get_node_or_null("Player") as CharacterBody3D
	if locked_vault != null and progression_player != null:
		var before_gate_pos := progression_player.global_position
		progression_player.global_position = locked_vault.get("entrance")
		progression_ok = locked_vault.call("try_interact", progression_player) and not bool(locked_vault.get("inside")) and progression_ok
		progression_player.global_position = before_gate_pos
	else:
		progression_ok = false
	Game.settlement_quests["lunareth:main"] = "done"
	progression_ok = progression_ok and Game.can_enter_hollow("memory_09", "lunareth", false) and Game.can_enter_hollow("memory_09", "lunareth", true)
	var progression_old_clears: Dictionary = Game.dungeon_clears.duplicate(true)
	Game.dungeon_clears = {}
	Game.settlement_quests["ashvale:main"] = "done"
	progression_ok = progression_ok and not Game.can_enter_hollow("optional_000", "ashvale", false)
	for number in range(4, 23): Game.dungeon_clears["memory_%02d" % number] = true
	progression_ok = progression_ok and Game.first_tier_clear_count() == 19 and not Game.can_enter_hollow("optional_000", "ashvale", false)
	Game.dungeon_clears["memory_23"] = true
	progression_ok = progression_ok and Game.first_tier_clear_count() == 20 and Game.can_enter_hollow("optional_000", "ashvale", false)
	Game.settlement_quests["suncrest:main"] = "done"
	progression_ok = progression_ok and not Game.can_enter_hollow("optional_020", "suncrest", false)
	for number in range(19): Game.dungeon_clears["optional_%03d" % number] = true
	progression_ok = progression_ok and Game.second_tier_clear_count() == 19 and not Game.can_enter_hollow("optional_020", "suncrest", false)
	Game.dungeon_clears["optional_019"] = true
	progression_ok = progression_ok and Game.second_tier_clear_count() == 20 and Game.can_enter_hollow("optional_020", "suncrest", false)
	progression_ok = progression_ok and not Game.can_enter_hollow("optional_040", "ashvale", false)
	for number in range(20, 39): Game.dungeon_clears["optional_%03d" % number] = true
	progression_ok = progression_ok and Game.third_tier_clear_count() == 19 and not Game.can_enter_hollow("optional_040", "ashvale", false)
	Game.dungeon_clears["optional_039"] = true
	progression_ok = progression_ok and Game.third_tier_clear_count() == 20 and Game.can_enter_hollow("optional_040", "ashvale", false) and Game.can_enter_hollow("optional_040", "ashvale", true)
	progression_ok = progression_ok and not Game.can_enter_hollow("optional_060", "ashvale", false)
	for number in range(40, 59): Game.dungeon_clears["optional_%03d" % number] = true
	progression_ok = progression_ok and Game.fourth_tier_clear_count() == 19 and not Game.can_enter_hollow("optional_060", "ashvale", false)
	Game.dungeon_clears["optional_059"] = true
	progression_ok = progression_ok and Game.fourth_tier_clear_count() == 20 and Game.can_enter_hollow("optional_060", "ashvale", false) and Game.can_enter_hollow("optional_060", "ashvale", true)
	Game.dungeon_clears = progression_old_clears
	Game.settlement_quests["ashvale:3:side"] = "found"
	var potion_before: int = Game.potions
	progression_ok = Game.complete_settlement_quest("ashvale", "side", 3) and progression_ok
	progression_ok = progression_ok and Game.potions == potion_before + 1 and Game.owned_wayfarer_armor and Game.equip_wayfarer_armor(true)
	Game.shield_points = 0.0
	Game.set_hp(Game.max_hp())
	Game.damage(100.0)
	progression_ok = progression_ok and is_equal_approx(Game.current_hp(), Game.max_hp() - 90.0)
	Game.load_collection()
	progression_ok = progression_ok and Game.owned_wayfarer_armor and Game.equipped_wayfarer_armor and Game.potions == potion_before + 1
	Game.owned_wayfarer_armor = progression_armor_owned
	Game.equipped_wayfarer_armor = progression_armor_equipped
	Game.potions = progression_potions
	Game.set_hp(progression_hp)
	Game.guard_story = {"memory_done": true, "memory_accepted": true}
	Game.settlement_quests = {}
	for progression_site in Game.SETTLEMENT_DATA.SITES:
		Game.settlement_quests[str(progression_site["id"]) + ":main"] = "done"
	Game.save_collection()
	_log("INFO" if progression_ok else "FAIL", "story gates, quest guide, potion, armor and save=%s" % str(progression_ok))

	# Real entrance, two-phase telegraph combat, one-time reward, and safe exit.
	var hollow_ok := false
	var story_companion_ok := false
	var hollow := world.get_node_or_null("AshvaleHollow")
	var hollow_player := world.get_node_or_null("Player") as CharacterBody3D
	if hollow != null and hollow_player != null and settlement_manager != null:
		var original_pos := hollow_player.global_position
		var original_hp: float = Game.current_hp()
		var original_coins: int = Game.coins
		var original_light: int = Game.starlight
		var original_clear: bool = Game.ashvale_hollow_cleared
		var original_story: Dictionary = Game.guard_story.duplicate(true)
		var original_wander: Dictionary = Game.wander.levels.duplicate(true)
		var original_slots: Array = Game.wander.slots.duplicate()
		Game.guard_story = {"seal_done": true}
		story_companion_ok = Game.set_ilyra_following(true) and Game.accept_hollow_memory() and not Game.accept_hollow_memory() and not Game.resolve_hollow_memory("share")
		Game.ashvale_hollow_cleared = false
		var entrance: Vector3 = hollow.get("entrance")
		hollow_player.global_position = entrance + Vector3(0, 0.2, 0)
		hollow_ok = hollow.call("try_interact", hollow_player) and bool(hollow.get("inside"))
		await get_tree().process_frame
		await get_tree().physics_frame
		if DisplayServer.get_name() != "headless":
			await _capture_ui(out_dir, "game_ashvale_hollow", null)
		var scouts: Array = []
		for enemy in get_tree().get_nodes_in_group("enemy"):
			if enemy.get_parent() == hollow.get("chamber"): scouts.append(enemy)
		hollow_ok = hollow_ok and scouts.size() == 2 and hollow.get("boss") == null
		for scout in scouts:
			scout.call("take_hit", 9999.0, 0, Vector3.ZERO)
		var warden := hollow.get("boss") as Node3D
		var ilyra := world.get_node_or_null("StarGuardIlyra")
		if warden != null and ilyra != null:
			Game.set_hp(Game.max_hp() * 0.5)
			var hp_before_heal: float = Game.current_hp()
			ilyra.set("_support_cooldown", 0.0)
			ilyra.call("_process", 0.1)
			story_companion_ok = story_companion_ok and Game.current_hp() > hp_before_heal and float(ilyra.get("_support_cooldown")) > 0.0
			Game.set_hp(original_hp)
			var chamber: Node3D = hollow.get("chamber")
			var previous_pos := hollow_player.global_position
			hollow_player.global_position = chamber.global_position + Vector3(0, 0.2, 0)
			var blink: Vector3 = hollow_player.call("_safe_spatial_destination", Vector3.RIGHT, 14.0)
			story_companion_ok = story_companion_ok and blink.x < chamber.global_position.x + 9.5 and absf(blink.y - chamber.global_position.y) < 2.0
			hollow_player.global_position = previous_pos
		if warden == null:
			hollow_ok = false
		else:
			warden.call("take_hit", 560.0, 0, Vector3.ZERO)
			hollow_ok = hollow_ok and int(warden.get("phase")) == 2
			warden.set("_state", "warning")
			warden.set("_timer", 0.0)
			warden.set("_target", hollow_player.global_position)
			warden.call("_physics_process", 0.01)
			hollow_ok = hollow_ok and Game.current_hp() < original_hp
			warden.call("take_hit", 9999.0, 0, Vector3.ZERO)
			hollow_ok = hollow_ok and Game.ashvale_hollow_cleared and Game.coins == original_coins + 100 and Game.starlight == original_light + 30
			hollow.call("_on_defeated")
			hollow_ok = hollow_ok and Game.coins == original_coins + 100
			var chest := (hollow.get("chamber") as Node3D).get_node_or_null("VictoryChest") as Node3D
			if chest != null:
				hollow_player.global_position = chest.global_position + Vector3(0, 0.2, 1)
				story_companion_ok = hollow.call("try_interact", hollow_player) and bool(Game.guard_story.get("memory_found", false)) and story_companion_ok
			else:
				story_companion_ok = false
			story_companion_ok = Game.resolve_hollow_memory("share") and not Game.resolve_hollow_memory("study") and Game.wander.known("sun_spear") and story_companion_ok
			Game.ashvale_hollow_cleared = false
			Game.guard_story = {}
			Game.load_collection()
			hollow_ok = hollow_ok and Game.ashvale_hollow_cleared
			story_companion_ok = story_companion_ok and bool(Game.guard_story.get("ilyra_following", false)) and str(Game.guard_story.get("memory_choice", "")) == "share" and int(Game.guard_story.get("ilyra_bond", 0)) == 2 and Game.wander_levels.has("sun_spear")
			Game.guard_story = {"seal_done": true, "memory_accepted": true, "memory_found": true}
			story_companion_ok = Game.resolve_hollow_memory("study") and Game.wander.known("tide_step") and int(Game.guard_story.get("ilyra_bond", 0)) == 1 and story_companion_ok
		var exit_point: Vector3 = hollow.get("_exit_point")
		hollow_player.global_position = exit_point
		hollow_ok = hollow.call("try_interact", hollow_player) and not bool(hollow.get("inside")) and hollow_ok
		hollow_player.global_position = original_pos
		hollow_player.velocity = Vector3.ZERO
		Game.set_hp(original_hp)
		Game.ashvale_hollow_cleared = original_clear
		Game.guard_story = original_story
		Game.wander.levels = original_wander
		Game.wander.slots.assign(original_slots)
		Game.save_wander()
		Game.coins = original_coins
		Game.starlight = original_light
		Game.save_collection()
		Game.collection_changed.emit()
	var vault_ok := false
	var vault := world.get_node_or_null("MemoryVault")
	if vault != null and hollow_player != null:
		var vault_old_pos := hollow_player.global_position
		var vault_old_clears: Dictionary = Game.dungeon_clears.duplicate(true)
		var vault_old_coins: int = Game.coins
		var vault_old_light: int = Game.starlight
		var vault_old_levels: Dictionary = Game.wander.levels.duplicate(true)
		Game.dungeon_clears.erase("memory_vault")
		hollow_player.global_position = vault.get("entrance") + Vector3(0, 0.2, 0)
		vault_ok = vault.call("try_interact", hollow_player)
		var vault_scouts: Array = []
		for enemy in get_tree().get_nodes_in_group("enemy"):
			if enemy.get_parent() == vault.get("chamber"): vault_scouts.append(enemy)
		vault_ok = vault_ok and vault_scouts.size() == 2
		for scout in vault_scouts:
			scout.call("take_hit", 9999.0, 0, Vector3.ZERO)
		var sentinel := vault.get("boss") as Node3D
		if sentinel != null:
			sentinel.call("take_hit", 800.0, 0, Vector3.ZERO)
			vault_ok = vault_ok and int(sentinel.get("phase")) == 2
			sentinel.call("take_hit", 9999.0, 0, Vector3.ZERO)
			vault_ok = vault_ok and bool(Game.dungeon_clears.get("memory_vault", false)) and Game.coins == vault_old_coins + 150 and Game.starlight == vault_old_light + 50 and Game.wander.known("verdant_bloom")
			vault.call("_on_defeated")
			vault_ok = vault_ok and Game.coins == vault_old_coins + 150
			Game.dungeon_clears = {}
			Game.load_collection()
			vault_ok = vault_ok and bool(Game.dungeon_clears.get("memory_vault", false))
		else:
			vault_ok = false
		hollow_player.global_position = vault.get("_exit_point")
		vault_ok = vault.call("try_interact", hollow_player) and vault_ok
		hollow_player.global_position = vault_old_pos
		Game.dungeon_clears = vault_old_clears
		Game.coins = vault_old_coins
		Game.starlight = vault_old_light
		Game.wander.levels = vault_old_levels
		Game.save_wander()
		Game.save_collection()

	# Each available story memory follows a unique persistent clear; old clear
	# flags migrate naturally and re-entering cannot grant the reward twice.
	var roost_ok := false
	var roost := world.get_node_or_null("SuncrestRoost")
	if roost != null and hollow_player != null:
		var roost_pos := hollow_player.global_position
		var roost_clears: Dictionary = Game.dungeon_clears.duplicate(true)
		var roost_ashvale: bool = Game.ashvale_hollow_cleared
		var roost_coins: int = Game.coins
		var roost_light: int = Game.starlight
		Game.ashvale_hollow_cleared = true
		Game.dungeon_clears = {"memory_vault": true}
		roost_ok = Game.story_memory_count() == 2 and not Game.story_memory_owned("suncrest_roost")
		hollow_player.global_position = roost.get("entrance") + Vector3(0, 0.2, 0)
		roost_ok = roost.call("try_interact", hollow_player) and roost_ok
		var roost_enemies: Array = []
		for enemy in get_tree().get_nodes_in_group("enemy"):
			if enemy.get_parent() == roost.get("chamber"): roost_enemies.append(enemy)
		roost_ok = roost_ok and roost_enemies.size() == 2
		for enemy in roost_enemies:
			enemy.call("take_hit", 9999.0, 0, Vector3.ZERO)
		var dragon := roost.get("boss") as Node3D
		if dragon != null:
			dragon.call("take_hit", 950.0, 0, Vector3.ZERO)
			roost_ok = roost_ok and int(dragon.get("phase")) == 2 and bool(dragon.get("is_dragon"))
			var slash_hp: float = Game.current_hp()
			hollow_player.global_position = dragon.global_position + Vector3(0, 0, 5)
			dragon.set("_attack_number", 2)
			dragon.set("_state", "rest")
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			roost_ok = roost_ok and str(dragon.get("_attack_kind")) == "line" and float(dragon.get("_timer")) >= 1.4
			hollow_player.global_position = dragon.global_position + Vector3(3, 0, 5)
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			roost_ok = roost_ok and is_equal_approx(Game.current_hp(), slash_hp)
			hollow_player.global_position = dragon.global_position + Vector3(0, 0, 5)
			dragon.set("_attack_number", 2)
			dragon.set("_state", "rest")
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			roost_ok = roost_ok and Game.current_hp() < slash_hp
			Game.set_hp(slash_hp)
			# Eclipse ring has a visible wind-up, a safe centre and a dangerous band.
			hollow_player.global_position = dragon.global_position + Vector3(0, 0, 3.5)
			dragon.set("_attack_number", 3)
			dragon.set("_state", "rest")
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			roost_ok = roost_ok and str(dragon.get("_attack_kind")) == "ring" and float(dragon.get("_timer")) >= 1.4
			var ring_center: Vector3 = dragon.get("_target")
			hollow_player.global_position = ring_center + Vector3(1, 0, 0)
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			roost_ok = roost_ok and is_equal_approx(Game.current_hp(), slash_hp)
			hollow_player.global_position = dragon.global_position + Vector3(0, 0, 3.5)
			dragon.set("_attack_number", 3)
			dragon.set("_state", "rest")
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			ring_center = dragon.get("_target")
			hollow_player.global_position = ring_center + Vector3(3.5, 0, 0)
			dragon.set("_timer", 0.0)
			dragon.call("_physics_process", 0.01)
			roost_ok = roost_ok and Game.current_hp() < slash_hp
			Game.set_hp(slash_hp)
			dragon.call("take_hit", 9999.0, 0, Vector3.ZERO)
			roost_ok = roost_ok and Game.story_memory_count() == 3 and Game.story_memory_owned("suncrest_roost") and Game.coins == roost_coins + 200 and Game.starlight == roost_light + 60
			roost.call("_on_defeated")
			roost_ok = roost_ok and Game.coins == roost_coins + 200
			Game.dungeon_clears = {}
			Game.load_collection()
			roost_ok = roost_ok and Game.story_memory_count() == 3
		else:
			roost_ok = false
		hollow_player.global_position = roost.get("_exit_point")
		roost_ok = roost.call("try_interact", hollow_player) and roost_ok
		hollow_player.global_position = roost_pos
		Game.dungeon_clears = roost_clears
		Game.ashvale_hollow_cleared = roost_ashvale
		Game.coins = roost_coins
		Game.starlight = roost_light
		Game.save_collection()
	_log("INFO" if roost_ok else "FAIL", "Suncrest Roost dragon and unique persistent story memories=%s" % str(roost_ok))
	_log("INFO" if vault_ok else "FAIL", "Memory Vault scouts, sentinel, reward and persistence=%s" % str(vault_ok))
	_log("INFO" if hollow_ok else "FAIL", "Ashvale Hollow entry, boss phases, damage and reward=%s" % str(hollow_ok))
	_log("INFO" if story_companion_ok else "FAIL", "Ilyra companion, memory choices, persistence and safe spatial movement=%s" % str(story_companion_ok))

	# Check the 22-entry streamed catalog and several full representative fights.
	var memories_ok := false
	var verified_story_clears: Dictionary = {}
	var stream := world.get_node_or_null("StoryDungeons")
	if stream != null and hollow_player != null:
		var memories_pos := hollow_player.global_position
		var memories_clears: Dictionary = Game.dungeon_clears.duplicate(true)
		var memories_coins: int = Game.coins
		var memories_light: int = Game.starlight
		var memories_wander: Dictionary = Game.wander.levels.duplicate(true)
		var memories_stamina: float = Game.stamina
		var memories_hp: float = Game.current_hp()
		Game.dungeon_clears = {}
		var story_probe_locations: Array = stream.get("_locations")
		var story_probe_ids := {}
		memories_ok = story_probe_locations.size() == 22 and Game.all_story_memories().size() == 25
		var authored_designs = load("res://scripts/story_hollow_designs.gd")
		var authored_names := {}
		memories_ok = memories_ok and authored_designs.DESIGNS.size() == 22 and authored_designs.ENCOUNTERS.size() == 22
		for authored_id in authored_designs.DESIGNS:
			var authored: Dictionary = authored_designs.get_design(authored_id)
			memories_ok = memories_ok and authored.has("depth") and authored.has("rule") and authored.has("attack") and authored.has("hazard") and not authored_names.has(authored["boss"])
			authored_names[authored["boss"]] = true
		for story_probe_entry in story_probe_locations:
			story_probe_ids[str(story_probe_entry["id"])] = true
			var story_probe_point: Vector2 = story_probe_entry["pos"]
			if bool(world.call("_is_wet", story_probe_point.x, story_probe_point.y)):
				_log("FAIL", "Memory entrance is wet: %s" % story_probe_entry["id"])
				memories_ok = false
		memories_ok = memories_ok and story_probe_ids.size() == 22
		for memory_probe_definition in Game.STORY_DUNGEONS.ENTRIES:
			var memory_probe_chosen: String = memory_probe_definition["id"]
			var story_probe_location: Dictionary = {}
			for memory_probe_item in story_probe_locations:
				if str(memory_probe_item["id"]) == memory_probe_chosen: story_probe_location = memory_probe_item
			if story_probe_location.is_empty():
				memories_ok = false
				continue
			var story_probe_xy: Vector2 = story_probe_location["pos"]
			hollow_player.global_position = Vector3(story_probe_xy.x, float(world.call("_height", story_probe_xy.x, story_probe_xy.y)) + 0.2, story_probe_xy.y)
			stream.call("_update_stream")
			var story_probe_loaded: Dictionary = stream.get("_loaded")
			var memory_dungeon := story_probe_loaded.get(memory_probe_chosen) as Node3D
			if memory_dungeon == null:
				memories_ok = false
				continue
			memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok
			var memory_guards: Array = []
			for memory_probe_enemy in get_tree().get_nodes_in_group("enemy"):
				if memory_probe_enemy.get_parent() == memory_dungeon.get("chamber") and not memory_probe_enemy.is_queued_for_deletion(): memory_guards.append(memory_probe_enemy)
			memories_ok = memories_ok and memory_guards.size() >= 2 and memory_guards.size() <= 4
			var early_design: Dictionary = memory_dungeon.get("_design")
			if not early_design.is_empty():
				# The inner echo is locked either by ordering or by living guards.
				var early_echoes: Array = memory_dungeon.get("_rune_nodes")
				if early_echoes.size() == 2:
					hollow_player.global_position = early_echoes[1].global_position + Vector3(0, 0.2, 0)
					memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok
					memories_ok = memories_ok and not bool((memory_dungeon.get("_runes_found") as Array)[1])
				else:
					memories_ok = false
			if memory_probe_chosen == "memory_22" and not memory_guards.is_empty():
				var interrupted := memory_guards[0] as Node3D
				hollow_player.global_position = interrupted.global_position + Vector3(0, 0, 2)
				interrupted.set("_state", "warning")
				interrupted.set("_timer", 0.1)
				hollow_player.call("_on_spell_cast", "dusk_seal", Game.wander.spell("dusk_seal"))
				memories_ok = memories_ok and str(interrupted.get("_state")) == "rest" and float(interrupted.get("_timer")) >= 2.0 and float(interrupted.get("hp")) < 260.0
			for memory_probe_guard in memory_guards: memory_probe_guard.call("take_hit", 1000000000.0, 0, Vector3.ZERO)
			var story_design: Dictionary = memory_dungeon.get("_design")
			if not story_design.is_empty():
				# Both echoes must be recalled through the normal interaction route.
				memories_ok = memories_ok and memory_dungeon.get("boss") == null
				var story_echoes: Array = memory_dungeon.get("_rune_nodes")
				memories_ok = memories_ok and story_echoes.size() == 2
				# Physics verifies the doorway is open and the annex has a floor.
				await get_tree().physics_frame
				var story_side: int = int(story_design["side"])
				var story_room: Node3D = memory_dungeon.get("chamber")
				var story_space := story_room.get_world_3d().direct_space_state
				var door_ray := PhysicsRayQueryParameters3D.create(story_room.to_global(Vector3(story_side * 8, 1, 0)), story_room.to_global(Vector3(story_side * 14, 1, 0)), 1)
				var floor_ray := PhysicsRayQueryParameters3D.create(story_room.to_global(Vector3(story_side * 14, 2, 0)), story_room.to_global(Vector3(story_side * 14, -2, 0)), 1)
				memories_ok = memories_ok and story_space.intersect_ray(door_ray).is_empty() and not story_space.intersect_ray(floor_ray).is_empty()
				var inner_door_ray := PhysicsRayQueryParameters3D.create(story_room.to_global(Vector3(story_side * 16, 1, 0)), story_room.to_global(Vector3(story_side * 22, 1, 0)), 1)
				var inner_x: float = story_side * (18.0 + float(story_design["depth"]) - 3.0)
				var inner_floor_ray := PhysicsRayQueryParameters3D.create(story_room.to_global(Vector3(inner_x, 2, 0)), story_room.to_global(Vector3(inner_x, -2, 0)), 1)
				memories_ok = memories_ok and story_space.intersect_ray(inner_door_ray).is_empty() and not story_space.intersect_ray(inner_floor_ray).is_empty()
				var story_trap := story_room.get_node_or_null("StoryTrial") as Node3D
				memories_ok = memories_ok and story_trap != null
				if story_trap != null and memory_probe_chosen == "memory_04":
					var trap_hp: float = Game.current_hp()
					var trap_shield: float = Game.shield_points
					Game.shield_points = 0.0
					hollow_player.global_position = story_trap.global_position + Vector3(3, 0, 0)
					story_trap.set("_state", "rest")
					story_trap.set("_timer", 0.0)
					story_trap.call("_physics_process", 0.01)
					memories_ok = memories_ok and str(story_trap.get("_state")) == "warning" and float(story_trap.get("_timer")) >= 1.5
					story_trap.set("_timer", 0.0)
					story_trap.call("_physics_process", 0.01)
					memories_ok = memories_ok and is_equal_approx(Game.current_hp(), trap_hp)
					hollow_player.global_position = story_trap.global_position
					story_trap.set("_timer", 0.0)
					story_trap.call("_physics_process", 0.01)
					story_trap.set("_timer", 0.0)
					story_trap.call("_physics_process", 0.01)
					memories_ok = memories_ok and Game.current_hp() < trap_hp
					Game.set_hp(trap_hp)
					Game.shield_points = trap_shield
					hollow_player.velocity = Vector3.ZERO
				if story_echoes.size() == 2:
					hollow_player.global_position = story_echoes[0].global_position + Vector3(0, 0.2, 0)
					memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok
					memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok and memory_dungeon.get("boss") == null
					hollow_player.global_position = story_echoes[1].global_position + Vector3(0, 0.2, 0)
					memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok
			var memory_boss := memory_dungeon.get("boss") as Node3D
			if memory_boss != null:
				if not story_design.is_empty():
					memories_ok = memories_ok and str(memory_boss.get("attack_profile")) == str(story_design["attack"])
					var favoured := "line" if story_design["attack"] == "slash" else ("ring" if story_design["attack"] == "ring" else "circle")
					memories_ok = memories_ok and str(memory_boss.call("_choose_attack", 2, 2)) == favoured
				memory_boss.call("take_hit", 9999.0, 0, Vector3.ZERO)
				memories_ok = memories_ok and Game.story_memory_owned(memory_probe_chosen)
				if Game.MEMORY_SPELLS.has(memory_probe_chosen):
					memories_ok = memories_ok and Game.wander.known(str(Game.MEMORY_SPELLS[memory_probe_chosen]))
				var story_probe_after_reward: int = Game.coins
				memory_dungeon.call("_on_defeated")
				memories_ok = memories_ok and Game.coins == story_probe_after_reward
			else:
				memories_ok = false
			hollow_player.global_position = memory_dungeon.get("_exit_point")
			memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok
			if memory_probe_chosen == "memory_19":
				# A previously cleared Hollow can be revisited and its lore read again,
				# without respawning the trial, boss or one-time reward.
				var revisit_coins: int = Game.coins
				hollow_player.global_position = memory_dungeon.get("entrance") + Vector3(0, 0.2, 0)
				memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok
				var revisit_room: Node3D = memory_dungeon.get("chamber")
				var revisit_echoes: Array = memory_dungeon.get("_rune_nodes")
				memories_ok = memories_ok and revisit_room != null and revisit_room.get_node_or_null("StoryTrial") == null and memory_dungeon.get("boss") == null and revisit_echoes.size() == 2
				if revisit_echoes.size() == 2:
					hollow_player.global_position = revisit_echoes[1].global_position + Vector3(0, 0.2, 0)
					memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok and Game.coins == revisit_coins
				hollow_player.global_position = memory_dungeon.get("_exit_point")
				memories_ok = memory_dungeon.call("try_interact", hollow_player) and memories_ok
			# Release completed arenas regularly rather than retaining all 22 at once.
			if int(memory_probe_chosen.trim_prefix("memory_")) % 4 == 0:
				await get_tree().process_frame
		Game.set_hp(Game.max_hp() * 0.5)
		var memory_before_heal: float = Game.current_hp()
		hollow_player.call("_on_spell_cast", "tide_remedy", Game.wander.spell("tide_remedy"))
		memories_ok = memories_ok and Game.current_hp() > memory_before_heal
		Game.stamina = 10.0
		hollow_player.call("_on_spell_cast", "winter_resolve", Game.wander.spell("winter_resolve"))
		memories_ok = memories_ok and Game.stamina > 10.0
		for memory_spell_id in Game.MEMORY_SPELLS.values():
			Game.wander.levels.erase(memory_spell_id)
		Game.save_wander() # simulate a save from before these rewards existed
		Game.dungeon_clears = {}
		Game.load_collection()
		for memory_spell_id in Game.MEMORY_SPELLS.values():
			memories_ok = memories_ok and Game.wander.known(str(memory_spell_id)) and Game.wander_levels.has(memory_spell_id)
		for story_probe_memory in Game.STORY_DUNGEONS.ENTRIES:
			memories_ok = memories_ok and Game.story_memory_owned(str(story_probe_memory["id"]))
		verified_story_clears = Game.dungeon_clears.duplicate(true)
		Game.dungeon_clears = memories_clears
		Game.wander.levels = memories_wander
		Game.stamina = memories_stamina
		Game.set_hp(memories_hp)
		Game.coins = memories_coins
		Game.starlight = memories_light
		hollow_player.global_position = memories_pos
		stream.call("_update_stream")
		Game.save_wander()
		Game.save_collection()
	_log("INFO" if memories_ok else "FAIL", "22 streamed memory Hollows, fights, unique rewards and save=%s" % str(memories_ok))

	# Optional Hollows have stable independent IDs and a compact streamed roster.
	var optional_ok := false
	var verified_optional_clears: Dictionary = {}
	if stream != null and hollow_player != null:
		var optional_pos := hollow_player.global_position
		var optional_clears: Dictionary = Game.dungeon_clears.duplicate(true)
		for story_clear_id in verified_story_clears: Game.dungeon_clears[story_clear_id] = verified_story_clears[story_clear_id]
		var optional_coins: int = Game.coins
		var optional_light: int = Game.starlight
		var optional_memory_count: int = Game.story_memory_count()
		var optional_locations: Array = stream.get("_extra_locations")
		var optional_ids := {}
		optional_ok = optional_locations.size() == 80 and Game.OPTIONAL_DUNGEONS.COUNT == 80
		var extra_designs = load("res://scripts/optional_hollow_designs.gd")
		var extra_names := {}
		optional_ok = optional_ok and extra_designs.ENTRIES.size() == 80
		for extra_index in range(80):
			var extra_id := "optional_%03d" % extra_index
			var extra_design: Dictionary = extra_designs.get_design(extra_id)
			optional_ok = optional_ok and not extra_design.is_empty() and not extra_names.has(extra_design["name"]) and Game.OPTIONAL_DUNGEONS.by_id(extra_id)["name"] == extra_design["name"]
			extra_names[extra_design["name"]] = true
		for optional_location in optional_locations:
			var optional_id := str(optional_location["id"])
			var optional_point: Vector2 = optional_location["pos"]
			optional_ids[optional_id] = true
			if bool(world.call("_is_wet", optional_point.x, optional_point.y)):
				_log("FAIL", "Optional entrance is wet: %s" % optional_id)
				optional_ok = false
			for prior in optional_locations:
				if str(prior["id"]) != optional_id and optional_point.distance_to(prior["pos"]) < 10.0:
					_log("FAIL", "Optional entrances overlap: %s and %s" % [optional_id, prior["id"]])
					optional_ok = false
		optional_ok = optional_ok and optional_ids.size() == 80
		var optional_to_check: Array[String] = ["optional_000", "optional_015", "optional_037", "optional_054", "optional_074", "optional_079"]
		if DisplayServer.get_name() != "headless":
			# Framebuffer runs representative encounters; grant prerequisite flags.
			for prerequisite in range(60): Game.dungeon_clears["optional_%03d" % prerequisite] = true
		if DisplayServer.get_name() == "headless":
			optional_to_check.clear()
			for optional_definition in optional_locations:
				optional_to_check.append(str(optional_definition["id"]))
		for optional_chosen in optional_to_check:
			var optional_place: Dictionary = {}
			for optional_candidate in optional_locations:
				if optional_candidate["id"] == optional_chosen: optional_place = optional_candidate
			if optional_place.is_empty():
				optional_ok = false
				continue
			Game.dungeon_clears.erase(optional_chosen)
			var optional_xy: Vector2 = optional_place["pos"]
			hollow_player.global_position = Vector3(optional_xy.x, float(world.call("_height", optional_xy.x, optional_xy.y)) + 0.2, optional_xy.y)
			stream.call("_update_stream")
			var optional_loaded: Dictionary = stream.get("_loaded")
			var optional_dungeon := optional_loaded.get(optional_chosen) as Node3D
			if optional_dungeon == null:
				optional_ok = false
				continue
			optional_ok = optional_dungeon.call("try_interact", hollow_player) and optional_ok
			optional_ok = optional_ok and Game.resonance_source == optional_chosen and is_equal_approx(Game.hollow_resonance, Game.earned_hollow_resonance(optional_chosen))
			var optional_guards: Array = []
			for optional_enemy in get_tree().get_nodes_in_group("enemy"):
				if optional_enemy.get_parent() == optional_dungeon.get("chamber") and not optional_enemy.is_queued_for_deletion(): optional_guards.append(optional_enemy)
			optional_ok = optional_ok and optional_guards.size() >= 2 and optional_guards.size() <= 4
			var expected_multiplier: float = Game.hollow_power_multiplier(optional_chosen)
			for optional_guard in optional_guards:
				optional_ok = optional_ok and is_equal_approx(float(optional_guard.get("hp")), 260.0 * expected_multiplier)
			var extra_design: Dictionary = optional_dungeon.get("_design")
			if not extra_design.is_empty():
				var extra_echoes: Array = optional_dungeon.get("_rune_nodes")
				optional_ok = optional_ok and extra_echoes.size() == 2
				if extra_echoes.size() == 2:
					hollow_player.global_position = extra_echoes[1].global_position + Vector3(0, 0.2, 0)
					optional_ok = optional_dungeon.call("try_interact", hollow_player) and optional_ok and not bool((optional_dungeon.get("_runes_found") as Array)[1])
			for optional_guard in optional_guards: optional_guard.call("take_hit", 1000000000.0, 0, Vector3.ZERO)
			if not extra_design.is_empty():
				var extra_room: Node3D = optional_dungeon.get("chamber")
				var extra_echoes: Array = optional_dungeon.get("_rune_nodes")
				optional_ok = optional_ok and optional_dungeon.get("boss") == null and extra_room.has_node("StoryTrial") and extra_room.has_node("StoryTrial2")
				if expected_multiplier >= 500.0: optional_ok = optional_ok and extra_room.has_node("StoryTrial3")
				if expected_multiplier >= 7500.0: optional_ok = optional_ok and extra_room.has_node("StoryTrial4")
				if expected_multiplier == 15000.0: optional_ok = optional_ok and extra_room.has_node("StoryTrial5")
				await get_tree().physics_frame
				var extra_side: int = int(extra_design["side"])
				var extra_space := extra_room.get_world_3d().direct_space_state
				var extra_door := PhysicsRayQueryParameters3D.create(extra_room.to_global(Vector3(extra_side * 16, 1, 0)), extra_room.to_global(Vector3(extra_side * 22, 1, 0)), 1)
				var extra_inner_x: float = extra_side * (18.0 + float(extra_design["depth"]) - 3.0)
				var extra_floor := PhysicsRayQueryParameters3D.create(extra_room.to_global(Vector3(extra_inner_x, 2, 0)), extra_room.to_global(Vector3(extra_inner_x, -2, 0)), 1)
				optional_ok = optional_ok and extra_space.intersect_ray(extra_door).is_empty() and not extra_space.intersect_ray(extra_floor).is_empty()
				if extra_echoes.size() == 2:
					for echo in extra_echoes:
						hollow_player.global_position = echo.global_position + Vector3(0, 0.2, 0)
						optional_ok = optional_dungeon.call("try_interact", hollow_player) and optional_ok
			var optional_boss := optional_dungeon.get("boss") as Node3D
			if optional_boss != null:
				optional_ok = optional_ok and is_equal_approx(float(optional_boss.get("_power_multiplier")), expected_multiplier)
				var optional_before_coins: int = Game.coins
				optional_boss.call("take_hit", 1000000000.0, 0, Vector3.ZERO)
				optional_ok = optional_ok and bool(Game.dungeon_clears.get(optional_chosen, false)) and Game.coins > optional_before_coins
				var optional_after_coins: int = Game.coins
				optional_dungeon.call("_on_defeated")
				optional_ok = optional_ok and Game.coins == optional_after_coins and Game.story_memory_count() == optional_memory_count
			else:
				optional_ok = false
			hollow_player.global_position = optional_dungeon.get("_exit_point")
			optional_ok = optional_dungeon.call("try_interact", hollow_player) and optional_ok
			optional_ok = optional_ok and Game.hollow_resonance == 1.0 and Game.resonance_source.is_empty()
			await get_tree().process_frame
		Game.dungeon_clears = {}
		Game.load_collection()
		for optional_saved_id in optional_to_check:
			optional_ok = optional_ok and bool(Game.dungeon_clears.get(optional_saved_id, false))
		verified_optional_clears = Game.dungeon_clears.duplicate(true)
		Game.dungeon_clears = optional_clears
		Game.coins = optional_coins
		Game.starlight = optional_light
		hollow_player.global_position = optional_pos
		stream.call("_update_stream")
		Game.save_collection()
	_log("INFO" if optional_ok else "FAIL", "80 optional Hollows, placement, rewards and save=%s" % str(optional_ok))

	# Exercise both the locked gate and the live 25-memory unlock path.
	var finale_ok := false
	var finale := world.get_node_or_null("LastSeal")
	if finale != null and hollow_player != null:
		var finale_pos := hollow_player.global_position
		var finale_story: Dictionary = Game.guard_story.duplicate(true)
		var finale_clears: Dictionary = Game.dungeon_clears.duplicate(true)
		var finale_ashvale: bool = Game.ashvale_hollow_cleared
		Game.dungeon_clears = {}
		Game.ashvale_hollow_cleared = false
		var finale_coins: int = Game.coins
		var finale_light: int = Game.starlight
		var finale_hp: float = Game.current_hp()
		Game.guard_story.erase("keeper_defeated")
		Game.guard_story.erase("keeper_resolution")
		Game.guard_story.erase("renewal_mask")
		finale_ok = not Game.offer_renewal_light(0) and Game.renewal_count() == 0
		hollow_player.global_position = finale.get("entrance") + Vector3(0, 0.2, 0)
		finale_ok = finale.call("try_interact", hollow_player) and not bool(finale.get("inside"))
		Game.ashvale_hollow_cleared = true
		Game.dungeon_clears = verified_story_clears.duplicate(true)
		Game.dungeon_clears["memory_vault"] = true
		Game.dungeon_clears["suncrest_roost"] = true
		# All memories alone are insufficient. Check the 99/100 boundary too.
		finale_ok = Game.story_memory_count() == 25 and finale.call("try_interact", hollow_player) and not bool(finale.get("inside")) and finale_ok
		for optional_index in range(Game.OPTIONAL_DUNGEONS.COUNT):
			var finale_optional_id: String = Game.OPTIONAL_DUNGEONS.entry(optional_index)["id"]
			# The headless probe actually cleared every optional encounter; framebuffer
			# runs use four representatives and synthesize the other save flags.
			if DisplayServer.get_name() == "headless": finale_ok = finale_ok and bool(verified_optional_clears.get(finale_optional_id, false))
			Game.dungeon_clears[finale_optional_id] = true
		Game.dungeon_clears.erase("optional_074")
		finale_ok = finale_ok and Game.original_hollow_clear_count() == 99 and Game.dungeon_count() == 104 and finale.call("try_interact", hollow_player) and not bool(finale.get("inside"))
		Game.dungeon_clears["optional_074"] = true
		for new_index in range(75, 80): Game.dungeon_clears.erase("optional_%03d" % new_index)
		finale_ok = finale_ok and Game.original_hollow_clear_count() == 100 and Game.dungeon_count() == 100 and Game.can_enter_finale()
		for new_index in range(75, 80): Game.dungeon_clears["optional_%03d" % new_index] = true
		finale_ok = finale_ok and Game.original_hollow_clear_count() == 100 and Game.dungeon_count() == 105 and finale.call("try_interact", hollow_player)
		var depths := finale.get("chamber") as Node3D
		finale_ok = finale_ok and Game.resonance_source == "last_seal" and Game.hollow_resonance == 3000.0
		finale_ok = finale_ok and bool(finale.get("inside")) and Game.in_final_dungeon and depths != null and depths.global_position.y < 0 and (finale.get("_gates") as Array).size() == 10
		if depths != null:
			var finale_echoes: Array = finale.get("_story_echoes")
			finale_ok = finale_ok and finale_echoes.size() == 3
			var echo_hud := world.get_node("HUD")
			for echo in finale_echoes:
				hollow_player.global_position = echo.global_position
				finale_ok = finale_ok and bool(finale.call("try_interact", hollow_player))
				var echo_toast := echo_hud.get("_toast") as Label
				finale_ok = finale_ok and echo_toast != null and echo_toast.text == str(echo.get_meta("story"))
			hollow_player.global_position = finale.get("_checkpoint")
			await get_tree().physics_frame
			var finale_space := depths.get_world_3d().direct_space_state
			for floor_index in range(10):
				var expected_floor := depths.to_global(Vector3(0, -8.0 * (float(floor_index) + 0.5), -100.0 * (float(floor_index) + 0.5)))
				var floor_query := PhysicsRayQueryParameters3D.create(expected_floor + Vector3(0, 3, 0), expected_floor - Vector3(0, 3, 0), 1)
				var finale_floor_hit := finale_space.intersect_ray(floor_query)
				finale_ok = finale_ok and not finale_floor_hit.is_empty() and absf(float(finale_floor_hit.get("position", Vector3.ZERO).y) - expected_floor.y) < 0.5
			var finale_ilyra := world.get_node_or_null("StarGuardIlyra") as Node3D
			Game.guard_story["ilyra_following"] = true
			if finale_ilyra != null:
				finale_ilyra.call("_process", 0.1)
				finale_ok = finale_ok and absf(finale_ilyra.global_position.y - hollow_player.global_position.y) < 3.0
			else:
				finale_ok = false
			for level in range(10):
				var guards: Array = []
				for enemy in get_tree().get_nodes_in_group("enemy"):
					if enemy.get_parent() == depths and not enemy.is_queued_for_deletion(): guards.append(enemy)
				finale_ok = finale_ok and guards.size() == 2 and int(finale.get("sector")) == level
				for guard in guards:
					guard.call("take_hit", 1000000000.0, 0, Vector3.ZERO)
				if level == 0:
					Game._on_party_down()
					var checkpoint_pos: Vector3 = finale.get("_checkpoint")
					finale_ok = finale_ok and Game.resonance_source == "last_seal" and Game.hollow_resonance == 3000.0
		finale_ok = finale_ok and bool(finale.get("inside")) and Game.in_final_dungeon and hollow_player.global_position.distance_to(checkpoint_pos) < 0.1 and int(finale.get("sector")) == 1
			var keeper := finale.get("boss") as Node3D
			if keeper != null:
				finale_ok = finale_ok and bool(keeper.get("is_keeper")) and is_equal_approx(float(keeper.get("max_hp")), 67500000.0)
				keeper.call("take_hit", 18000000.0, 0, Vector3.ZERO)
				finale_ok = finale_ok and int(keeper.get("phase")) == 2
				keeper.call("take_hit", 18000000.0, 0, Vector3.ZERO)
				finale_ok = finale_ok and int(keeper.get("phase")) == 3
				keeper.call("take_hit", 18000000.0, 0, Vector3.ZERO)
				finale_ok = finale_ok and int(keeper.get("phase")) == 4
				keeper.call("take_hit", 1000000000.0, 0, Vector3.ZERO)
				finale_ok = finale_ok and bool(Game.guard_story.get("keeper_defeated", false)) and Game.coins == finale_coins + 1000 and Game.starlight == finale_light + 200
				var renewal_lights: Array = finale.get("_renewal_lights")
				finale_ok = finale_ok and renewal_lights.size() == 7 and not Game.offer_renewal_light(-1) and not Game.offer_renewal_light(7)
				if renewal_lights.size() == 7:
					for index in range(3):
						hollow_player.global_position = renewal_lights[index].global_position
						finale_ok = bool(finale.call("try_interact", hollow_player)) and finale_ok
					finale_ok = finale_ok and Game.renewal_count() == 3 and not Game.offer_renewal_light(0)
					Game.guard_story = {}
					Game.load_collection()
					finale_ok = finale_ok and Game.renewal_count() == 3
				var ending_marker := finale.get("_resolution_marker") as Node3D
				finale_ok = finale_ok and ending_marker != null
				if ending_marker != null and menu != null:
					hollow_player.global_position = ending_marker.global_position
					finale_ok = finale_ok and bool(finale.call("try_interact", hollow_player)) and menu.visible and str(menu.get("_tab")) == "Finale"
					menu.call("_resolve_keeper_memory", "witness")
					finale_ok = finale_ok and str(Game.guard_story.get("keeper_resolution", "")) == "witness" and not Game.story_ending().is_empty()
					menu.call("close_menu")
				else:
					finale_ok = false
				finale.call("_keeper_defeated")
				finale_ok = finale_ok and Game.coins == finale_coins + 1000
				Game.guard_story = {}
				Game.load_collection()
				finale_ok = finale_ok and bool(Game.guard_story.get("keeper_defeated", false)) and str(Game.guard_story.get("keeper_resolution", "")) == "witness"
			else:
				finale_ok = false
			hollow_player.global_position = finale.get("_arena_exit")
			finale_ok = finale.call("try_interact", hollow_player) and not Game.in_final_dungeon and finale_ok
			finale_ok = finale_ok and Game.resonance_source.is_empty() and Game.hollow_resonance == 1.0
			# An already-completed save without the newer decision can return and
			# choose without fighting again or receiving the boss reward twice.
			Game.guard_story.erase("keeper_resolution")
			Game.save_collection()
			hollow_player.global_position = finale.get("entrance")
			finale_ok = finale_ok and bool(finale.call("try_interact", hollow_player)) and bool(finale.get("inside"))
			var revisit_lights: Array = finale.get("_renewal_lights")
			finale_ok = finale_ok and revisit_lights.size() == 7 and Game.renewal_count() == 3
			if revisit_lights.size() == 7:
				for index in range(3, 7):
					hollow_player.global_position = revisit_lights[index].global_position
					finale_ok = bool(finale.call("try_interact", hollow_player)) and finale_ok
				finale_ok = finale_ok and Game.renewal_count() == 7 and "seven witnesses" in Game.story_ending()
				Game.guard_story = {}
				Game.load_collection()
				finale_ok = finale_ok and Game.renewal_count() == 7
			var revisit_marker := finale.get("_resolution_marker") as Node3D
			finale_ok = finale_ok and revisit_marker != null and not is_instance_valid(finale.get("boss"))
			if revisit_marker != null and menu != null:
				hollow_player.global_position = revisit_marker.global_position
				finale_ok = finale_ok and bool(finale.call("try_interact", hollow_player)) and menu.visible
				menu.call("_resolve_keeper_memory", "private")
				menu.call("close_menu")
				Game.guard_story = {}
				Game.load_collection()
				finale_ok = finale_ok and str(Game.guard_story.get("keeper_resolution", "")) == "private" and Game.coins == finale_coins + 1000 and Game.starlight == finale_light + 200
			else:
				finale_ok = false
			hollow_player.global_position = finale.get("_arena_exit")
			finale_ok = bool(finale.call("try_interact", hollow_player)) and not Game.in_final_dungeon and finale_ok
		hollow_player.global_position = finale_pos
		Game.guard_story = finale_story
		Game.dungeon_clears = finale_clears
		Game.ashvale_hollow_cleared = finale_ashvale
		Game.coins = finale_coins
		Game.starlight = finale_light
		Game.set_hp(finale_hp)
		Game.save_collection()
	_log("INFO" if finale_ok else "FAIL", "Last Seal gate, guarded kilometre, four boss phases, ending and save=%s" % str(finale_ok))
	Game.guard_story = progression_story
	Game.settlement_quests = progression_quests
	Game.save_collection()

	# The compact HUD list opens from its button and shows independent NPC quests.
	var quest_box_ok := false
	if hud != null:
		var button := hud.get_node_or_null("Root/HBoxContainer/QuestsButton") as Button
		# Find by name rather than relying on the container's autogenerated name.
		if button == null:
			button = hud.find_child("QuestsButton", true, false) as Button
		var box := hud.get_node_or_null("Root/QuestBox") as Control
		var list := hud.find_child("QuestList", true, false) as Label
		if button != null and box != null and list != null:
			var previous: Dictionary = Game.settlement_quests.duplicate(true)
			for i in range(5):
				Game.settlement_quests["ashvale:main" if i == 0 else "ashvale:%d:main" % i] = "active"
			button.pressed.emit()
			quest_box_ok = box.visible
			for i in range(5):
				var resident: Dictionary = SETTLEMENTS.resident("ashvale", i)
				quest_box_ok = quest_box_ok and list.text.contains(resident["name"]) and list.text.contains(resident["main"])
			button.pressed.emit()
			quest_box_ok = quest_box_ok and not box.visible
			Game.settlement_quests = previous
	_log("INFO" if quest_box_ok else "FAIL", "quest button and five NPC quests=%s" % str(quest_box_ok))

	# --- pixel checks -----------------------------------------------------
	# A headless run has no framebuffer, so this only reports on a real device /
	# xvfb run. That is fine: the structural checks above still gate CI.
	if DisplayServer.get_name() == "headless":
		_log("INFO", "headless server - skipping pixel capture")
		await _check_title_screen(world, out_dir, false)
		_finish(_fail)
		return

	# A wandering enemy parked on the camera lens and a burst pillar frozen mid
	# cast have both ruined otherwise fine captures. Clear anything transient
	# that has drifted into the lens before shooting.
	_clear_frame(world)

	# Give the renderer a few real frames without blocking on frame_post_draw,
	# which never fires if the loop is stalled.
	await get_tree().create_timer(0.4).timeout
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		_log("FAIL", "viewport texture empty (nothing is being rendered)")
		_finish(_fail)
		return
	img.save_png(out_dir.path_join("world.png"))
	# Equip a real backpack and render a rear close-up to verify it is attached
	# to the character. Restore the collection after the screenshot.
	var equipment_player := world.get_node_or_null("Player") as Node3D
	if equipment_player != null:
		var before_packs := Game.owned_backpacks.duplicate()
		var before_pack := Game.equipped_backpack
		if not Game.owned_backpacks.has(1):
			Game.owned_backpacks.append(1)
		var equip_ok: bool = Game.equip_backpack(1)
		var pack_node := equipment_player.get_node_or_null("Visual/Torso/Backpack") as Node3D
		_log("INFO" if equip_ok and pack_node != null and pack_node.visible else "FAIL", "equipped backpack visible on character: %s" % str(equip_ok and pack_node != null and pack_node.visible))
		var equipment_camera := Camera3D.new()
		equipment_camera.fov = 40.0
		world.add_child(equipment_camera)
		var focus := equipment_player.global_position + Vector3(0, 1.05, 0)
		equipment_camera.global_position = focus + equipment_player.global_basis.z * 3.4 + Vector3(0, 0.25, 0)
		equipment_camera.look_at(focus, Vector3.UP)
		equipment_camera.current = true
		await _capture_ui(out_dir, "equipped_backpack", null)
		cam.current = true
		equipment_camera.queue_free()
		Game.owned_backpacks.assign(before_packs)
		Game.equipped_backpack = before_pack
		Game.save_collection()
		Game.collection_changed.emit()

	# Actual streamed Ashvale outpost and its resident dialogue, from a review
	# camera. This is not a travel or gameplay spawn change.
	if settlement_manager != null:
		var all_sites: Array = settlement_manager.get("_sites")
		if not all_sites.is_empty():
			var center: Vector2 = all_sites[0]["resolved"]
			var ground: float = world.call("_height", center.x, center.y)
			var village_cam := Camera3D.new()
			world.add_child(village_cam)
			var aim := Vector3(center.x, ground + 1.8, center.y)
			village_cam.global_position = aim + Vector3(25, 32, 28)
			village_cam.look_at(aim, Vector3.UP)
			village_cam.current = true
			await _capture_ui(out_dir, "settlement_ashvale", null)
			cam.current = true
			village_cam.queue_free()
	if menu != null:
		menu.set("dialogue_site_id", "ashvale")
		menu.call("open_menu", "Dialogue")
		await _capture_ui(out_dir, "game_resident_dialogue", menu)
		menu.call("close_menu")
		menu.set("dialogue_site_id", "")

	# Capture every gameplay journal page, including the bottom of scrollable
	# pages. These are real UI states, not mockups or stitched images.
	if menu != null:
		for page in ["Inventory", "Character", "Quests", "Wish", "Level Up", "Story", "Dialogue"]:
			menu.call("open_menu", page)
			await _capture_ui(out_dir, "game_" + page.to_lower().replace(" ", "_"), menu)
			menu.call("close_menu")
		# Show unlocked research as a separate, clearly named review state.
		var original_guard := Game.guard_story.duplicate(true)
		Game.guard_story["seal_done"] = true
		menu.call("open_menu", "Story")
		await _capture_ui(out_dir, "game_wander_research_unlocked", menu)
		menu.call("close_menu")
		Game.guard_story = original_guard
	if hud != null:
		hud.call("_pause")
		await _capture_ui(out_dir, "pause", null)
		hud.call("_resume")
		hud.call("_toggle_perf_monitor")
		await get_tree().create_timer(0.6, true).timeout
		await _capture_ui(out_dir, "performance", null)
		hud.call("_toggle_perf_monitor")
		var wheel := hud.get_node_or_null("Root/SpellWheel")
		if wheel != null and Game.wander != null:
			wheel.call("_set_open", true, true)
			await _capture_ui(out_dir, "spell_wheel", null)
			wheel.call("_open_editor", 0)
			await _capture_ui(out_dir, "spell_editor", wheel)
			wheel.call("_on_editor_close")
			wheel.call("_set_open", false, true)
		else:
			_log("FAIL", "spell wheel unavailable for UI screenshots")
		# Preview mobile controls in the same viewport, without claiming this is
		# an actual Android device or a mobile performance measurement.
		var was_touch_active: bool = Game.touch_active
		var touch = load("res://scripts/touch_controls.gd").new()
		hud.add_child(touch)
		await _capture_ui(out_dir, "touch_controls_simulated", null)
		touch.queue_free()
		Game.touch_active = was_touch_active
		hud.call("_on_game_won")
		await _capture_ui(out_dir, "victory", null)
		var win_panel: Control = hud.get("_win_panel")
		win_panel.visible = false

	# What is actually under the camera's feet?
	#
	# The gameplay frame has a large, flat, untextured slab across the bottom
	# third, and it reads as a bare apron rather than as meadow. Two very
	# different causes look identical in a screenshot - the terrain shader
	# printing flat there, or something else entirely (a decal, a plane, a
	# mis-scaled chunk) covering it - and eyeballing it cost rounds on the
	# grass/terrain mix-up already. So ask the physics space what is down there.
	_probe_near_ground(world, cam)
	var stats := _analyse(img)
	var ground := _measure_ground_ratio(img)
	if float(ground["ratio"]) > 0.0:
		var note := ""
		if float(ground["ratio"]) >= 4.0:
			note = " (shadowed ground is reading as a hole)"
		_log("INFO" if note == "" else "WARN",
			"ground contrast p95=%.3f@(%s) p05=%.3f@(%s) median=%.3f ratio=%.2fx%s" % [
				ground["lit"], ground["lit_at"],
				ground["dark"], ground["dark_at"],
				ground["median"], ground["ratio"], note])
	else:
		_log("INFO", "ground contrast: not measurable in this frame")
	_check_blob(img, "gameplay")
	# Nothing in the frame may be black foliage. See _check_black_props.
	await _check_black_props()
	_log("INFO", "size=%dx%d mean_luma=%.3f nonblack=%.1f%% distinct_colours=%d sky_blue=%.1f%%" % [
		img.get_width(), img.get_height(), stats["luma"],
		stats["nonblack"] * 100.0, stats["colours"], stats["sky"] * 100.0])

	if stats["luma"] < 0.02:
		_log("FAIL", "framebuffer is black (mean luminance %.4f)" % stats["luma"])
	elif stats["nonblack"] < 0.15:
		_log("FAIL", "almost nothing rendered (non-black pixels %.1f%%)" % (stats["nonblack"] * 100.0))
	if stats["colours"] < 12:
		# A clear sky-only view is legitimately low-variety; call it out loudly
		# but let the luminance/coverage checks decide pass or fail.
		_log("WARN", "image is flat - only %d distinct colours" % stats["colours"])

	# Orbit the camera and capture again, to catch a camera that exists but is
	# stuck in geometry or pointed at the void.
	#
	# Two previous versions of this were no-ops, and both failed silently:
	#
	#   1. writing cam.global_position - the camera is a child of a SpringArm3D
	#      whose transform is rebuilt every frame, so the write was discarded
	#      before the next draw;
	#   2. turning the CameraPivot node - but the pivot is a child of the Player,
	#      and player.gd's _physics_process does
	#          _pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	#      every single tick from _yaw/_target_yaw. The rotation was gone before
	#      the frame that followed. world_alt.png came out 23% different from
	#      world.png and I read that as "the orbit works"; the 23% was the sun
	#      and the wind animation moving, not a quarter turn.
	#
	# The probe therefore has to ask the player for a new look angle, not poke
	# its children. This is also the honest way round: it exercises the same
	# path a player's mouse drag does.
	var orbit_ok := _orbit_player(world, 0.5 * PI, -0.42)
	if orbit_ok:
		await get_tree().create_timer(0.5).timeout
		await get_tree().process_frame
		var img2 := get_viewport().get_texture().get_image()
		if img2:
			img2.save_png(out_dir.path_join("world_alt.png"))
			var s2 := _analyse(img2)
			# Assert the orbit actually happened. A view that is 97% similar to
			# the first is not a second view, and a check that cannot tell the
			# difference is decoration.
			var diff := _image_difference(img, img2)
			var verdict := "OK"
			if diff < 0.12:
				verdict = "IDENTICAL"
			_log("WARN" if diff < 0.12 else "INFO",
				"alt view mean_luma=%.3f nonblack=%.1f%% colours=%d differs=%.1f%% (%s)" % [
					s2["luma"], s2["nonblack"] * 100.0, s2["colours"], diff * 100.0, verdict])
	else:
		_log("WARN", "could not orbit the camera - world_alt will repeat the main frame")

	# A second orbit, higher and to the other side, for a third distinct angle.
	if _orbit_player(world, -0.85 * PI, -0.62):
		await get_tree().create_timer(0.5).timeout
		await get_tree().process_frame
		var img3 := get_viewport().get_texture().get_image()
		if img3:
			img3.save_png(out_dir.path_join("world_side.png"))
			_log("INFO", "side view differs=%.1f%% from main" % (_image_difference(img, img3) * 100.0))

	# --- character close-up -------------------------------------------------
	# A frame of the character from the front at conversational distance. The
	# gameplay camera cannot answer "is the model correct" - it answers "is the
	# model readable in play", and those are different questions.
	var player_node := world.get_node_or_null("Player") as Node3D
	if player_node != null:
		var portrait := Camera3D.new()
		portrait.fov = 40.0
		portrait.near = 0.05
		portrait.far = 60.0
		world.add_child(portrait)
		# Frame the whole character: aim at her waist and stand far enough back that
		# 1.95 m of body fits the 40-degree lens. The previous version aimed at her
		# chest from 2.9 m with the camera only 0.16 m above it, so the frame was
		# mostly sky and the HUD covered her feet - useless as a reference.
		var focus := player_node.global_position + Vector3(0.0, 1.00, 0.0)
		# Shoot her from the FRONT.
		#
		# Every portrait so far was taken from +Z, which is where the third-person
		# camera sits, and the character faces -Z. So this capture has been a view
		# of her back in all fifteen runs, and the face - the one thing a character
		# review is actually about - has never once been checked. Offset along the
		# direction she is facing instead of along world +Z.
		var facing := -player_node.global_transform.basis.z
		facing.y = 0.0
		if facing.length() < 0.01:
			facing = Vector3(0.0, 0.0, -1.0)
		facing = facing.normalized()
		portrait.global_position = focus + facing * 4.6 + Vector3(0.0, 0.45, 0.0)
		portrait.look_at(focus, Vector3.UP)
		portrait.current = true
		# Portrait key light.
		#
		# The sun sits behind her right shoulder in the world, which is what makes
		# the third-person view read - but it means a camera placed in front of her
		# is looking at the shadow side, and the character reference frame came out
		# so dark the face was barely legible. This is a review frame, not gameplay,
		# so it gets its own key hung just off the lens. Parented to the portrait
		# camera so the existing portrait.queue_free() takes it with it - freeing a
		# node and then touching its handle is what crashed this probe before.
		var portrait_key := DirectionalLight3D.new()
		# Deliberately weak and off-axis. At 1.15 pointing straight down the lens it
		# lit her like a flashgun: black cloth went pale pink, and the key also
		# spilled onto the river valley behind her, lifting the whole frame into
		# something that looked nothing like the game. A 30-degree key off the
		# shoulder at 0.55 fills her face without flat-lighting her and without
		# visibly touching the ground.
		portrait_key.light_color = Color(1.0, 0.95, 0.88)
		portrait_key.light_energy = 0.55
		portrait_key.shadow_enabled = false
		portrait_key.rotation_degrees = Vector3(-32.0, 34.0, 0.0)
		portrait.add_child(portrait_key)

		# Report where her body actually lands on screen, in pixels. The close-up
		# has twice shown a figure far smaller than 1.95 m at 4.6 m would be, so
		# this measures it instead of leaving the discrepancy to the eye.
		var vis_node := player_node.get_node_or_null("Visual") as Node3D
		if vis_node != null:
			var box := AABB()
			var firstbox := true
			for mi in vis_node.find_children("*", "MeshInstance3D", true, false):
				var m := mi as MeshInstance3D
				if m.mesh == null or not m.is_visible_in_tree():
					continue
				var b := m.global_transform * m.get_aabb()
				box = b if firstbox else box.merge(b)
				firstbox = false
			var lo := cam.unproject_position(box.position)
			var hi := cam.unproject_position(box.end)
			_log("INFO", "portrait: character AABB %.2fm tall projects to %dpx tall (screen %d)" % [
				box.size.y, int(absf(hi.y - lo.y)), get_viewport().get_visible_rect().size.y])

		await get_tree().create_timer(0.35).timeout
		await get_tree().process_frame
		var pimg := get_viewport().get_texture().get_image()
		if pimg != null and not pimg.is_empty():
			pimg.save_png(out_dir.path_join("player.png"))
			_log("INFO", "saved character close-up")

		# Same frame again with every character material replaced by flat unshaded
		# magenta. If magenta appears where the body should be, the geometry and its
		# visibility are fine and the problem is a material; if it does not, the
		# problem is the geometry or the transform.
		var flat := StandardMaterial3D.new()
		flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flat.albedo_color = Color(1.0, 0.0, 1.0)
		var replaced: Array[MeshInstance3D] = []
		if vis_node != null:
			for mi in vis_node.find_children("*", "MeshInstance3D", true, false):
				var m2 := mi as MeshInstance3D
				if m2.mesh == null:
					continue
				replaced.append(m2)
				m2.material_override = flat
		await get_tree().create_timer(0.3).timeout
		await get_tree().process_frame
		var fimg := get_viewport().get_texture().get_image()
		if fimg != null and not fimg.is_empty():
			fimg.save_png(out_dir.path_join("player_flat.png"))
			var magenta := 0
			var step := maxi(1, int(fimg.get_width() / 200.0))
			for y in range(0, _sample_end(fimg.get_height(), step), step):
				for x in range(0, _sample_end(fimg.get_width(), step), step):
					var c := fimg.get_pixel(x, y)
					if c.r > 0.7 and c.b > 0.7 and c.g < 0.3:
						magenta += 1
			_log("INFO", "flat-material test: %d magenta samples in frame" % magenta)
			if magenta == 0:
				_log("FAIL", "character geometry does not rasterise at all, even with a flat material")
		portrait.queue_free()

	# --- clear combat VFX before the beauty frame --------------------------
	# Same rule as _clear_frame: only anonymous effect roots directly under the
	# world. This block used to repeat the "free anything unshaded and emissive"
	# logic, which armed the bug described in _clear_frame.
	_clear_frame(world)
	await get_tree().process_frame

	# --- environment beauty shot -------------------------------------------
	# A fixed, wide vantage point over the valley. The gameplay camera is a
	# close third-person shoulder view, which is useless for judging terrain,
	# grass and sky; this frame is what the environment actually looks like.
	var beauty := Camera3D.new()
	beauty.fov = 68.0
	beauty.near = 0.1
	beauty.far = 1200.0
	world.add_child(beauty)
	# Positioned on a hillside looking along the valley toward the lake, with
	# the ridge line near the upper third and foreground meadow in the bottom
	# third. The old framing sat in the middle of a slope at eye level with the
	# horizon dead centre, which is the least flattering composition possible -
	# it showed neither the valley nor the sky.
	# Chosen so the grass field (which follows the player, radius 130 m) is still
	# in frame: the previous vantage sat just outside it, so the beauty shot had
	# no foreground grass at all and the slope read as bare green geometry.
	# Stand on the meadow 45 m from the player, 11 m up, looking across the valley.
	# The grass field streams in a 130 m radius around the *player*, so a vantage
	# further out than that has bare terrain in the foreground - which is why
	# every beauty frame so far showed a smooth green slope with no grass on it,
	# while the gameplay frame was full of it.
	var eye := Vector3(-34.0, 0.0, -30.0)
	var terrain_node_2 := world.get_node_or_null("Terrain")
	if terrain_node_2 != null and terrain_node_2.has_method("get_height_at"):
		eye.y = terrain_node_2.get_height_at(eye.x, eye.z) + 11.0
	else:
		eye.y = 30.0
	beauty.global_position = eye
	# Aim into the middle distance along the valley, keeping the horizon high in
	# the frame so the meadow occupies the lower half.
	beauty.look_at(Vector3(70.0, eye.y - 12.0, 80.0), Vector3.UP)
	# Rebuild the grass ring around this vantage so the shot has its own meadow.
	var beauty_grass := world.get_node_or_null("GrassField")
	if beauty_grass != null and beauty_grass.has_method("focus_at"):
		beauty_grass.call("focus_at", eye)

	# Push the sun to a warm low morning for the beauty frame so the shot shows
	# the graded palette rather than whatever time the world happened to boot at.
	# Force the richest quality tier for the beauty frame. The autotuner drops to
	# Performance on any slow or software renderer - which is exactly what CI
	# runs - and that tier disables glow, SSAO and MSAA, so the published
	# screenshot was showing the worst settings the game can produce.
	Game.set_quality_tier(4)
	if world.has_method("apply_quality"):
		world.call("apply_quality")
	if world.has_method("_set_beauty_time"):
		world.call("_set_beauty_time", 0.302)
	beauty.current = true
	await get_tree().create_timer(0.5).timeout
	await get_tree().process_frame
	var img3 := get_viewport().get_texture().get_image()
	if img3:
		img3.save_png(out_dir.path_join("world_wide.png"))
		_check_blob(img3, "wide")
		_report_palette(img3, "wide")
		var s3 := _analyse(img3)
		_log("INFO", "wide view mean_luma=%.3f nonblack=%.1f%% colours=%d sky=%.1f%%" % [
			s3["luma"], s3["nonblack"] * 100.0, s3["colours"], s3["sky"] * 100.0])
		# A washed-out frame is the failure mode we actually hit: everything
		# blown to near-white. Flag it.
		if s3["luma"] > 0.72:
			_log("WARN", "wide view is overexposed (mean luma %.2f)" % s3["luma"])
		_report_frame_cost(world)

	await _check_title_screen(world, out_dir, true)
	_finish(_fail)


func _check_title_screen(world: Node, out_dir: String, capture: bool) -> void:
	## Instantiate the real menu, exercise its wiring, and capture the actual UI.
	world.queue_free()
	await get_tree().process_frame
	var menu_scene := load("res://scenes/main_menu.tscn") as PackedScene
	if menu_scene == null:
		_log("FAIL", "title screen scene missing")
		return
	var menu := menu_scene.instantiate()
	get_tree().root.add_child(menu)
	await get_tree().process_frame
	var art := menu.get_node_or_null("CelestialBackground") as TextureRect
	var button := menu.get_node_or_null("LeftPanel/Panel/VBox/StartButton") as Button
	var ok := art != null and art.texture != null and button != null and not button.pressed.get_connections().is_empty()
	_log("INFO" if ok else "FAIL", "celestial title art and start button wired: %s" % str(ok))
	var home_nav := menu.get_node_or_null("LeftPanel/Panel/VBox/HomeNavigation")
	var home_pages_ok := home_nav != null
	if home_pages_ok:
		for page in ["Wardrobe", "Profile", "Settings", "Shop"]:
			var home_button := home_nav.get_node_or_null(page + "Button") as Button
			if home_button == null or home_button.pressed.get_connections().is_empty():
				home_pages_ok = false
			else:
				home_button.emit_signal("pressed")
				var overlay := menu.get_node_or_null("AdventureMenu") as Control
				if overlay == null or not overlay.visible or overlay.get("_tab") != page or Game.is_paused:
					home_pages_ok = false
				else:
					if capture:
						await _capture_ui(out_dir, "home_" + page.to_lower(), overlay)
					overlay.call("close_menu")
	_log("INFO" if home_pages_ok else "FAIL", "home navigation and pages: %s" % str(home_pages_ok))
	if capture:
		await get_tree().create_timer(0.2).timeout
		var title_img := get_viewport().get_texture().get_image()
		if title_img != null and not title_img.is_empty():
			title_img.save_png(out_dir.path_join("title.png"))
	menu.queue_free()


func _capture_ui(out_dir: String, name: String, scroll_root: Node) -> void:
	# Let containers layout and the renderer paint before reading the viewport.
	await get_tree().create_timer(0.12, true).timeout
	await get_tree().process_frame
	var frame := get_viewport().get_texture().get_image()
	if frame == null or frame.is_empty() or frame.save_png(out_dir.path_join(name + ".png")) != OK:
		_log("FAIL", "could not capture UI: %s" % name)
		return
	_log("INFO", "captured UI: %s" % name)
	if name == "game_character":
		frame.save_png(out_dir.path_join("adventure.png"))
	if scroll_root == null:
		return
	for node in scroll_root.find_children("*", "ScrollContainer", true, false):
		var scroll := node as ScrollContainer
		if not scroll.is_visible_in_tree():
			continue
		var bar := scroll.get_v_scroll_bar()
		var bottom := int(maxf(0.0, bar.max_value - bar.page))
		if bottom <= 0:
			continue
		var previous := scroll.scroll_vertical
		scroll.scroll_vertical = bottom
		await get_tree().create_timer(0.12, true).timeout
		await get_tree().process_frame
		var lower := get_viewport().get_texture().get_image()
		if lower == null or lower.is_empty() or lower.save_png(out_dir.path_join(name + "_scrolled.png")) != OK:
			_log("FAIL", "could not capture scrolled UI: %s" % name)
		else:
			_log("INFO", "captured scrolled UI: %s" % name)
		scroll.scroll_vertical = previous
		break


func _clear_frame(world: Node) -> void:
	## Remove anything sitting on top of the camera.
	##
	## The gameplay frame is a third-person view from about 4 m behind the player
	## and the world is paused when it is captured, so a tween-driven effect (a
	## burst pillar) never finishes and an enemy that wandered close stays put.
	## Both end up covering a large, opaque part of the frame and neither is what
	## the shot is meant to show.
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var removed := 0
	# Transient VFX live as anonymous "@Node3D" roots directly under the world.
	#
	# This deliberately does NOT hunt for unshaded emissive meshes anywhere in the
	# tree. It used to, and the character's elemental crest and glowing eyes are
	# exactly that - so the walk-up loop climbed from the crest to her Torso node
	# and freed 43 of her 51 meshes. THAT is what rendered her as a pair of boots
	# for half a dozen builds while the probe kept insisting her body was present
	# and visible. The lesson: a cleanup pass must be handcuffed to nodes it can
	# positively identify, never to a material class.
	for child in world.get_children():
		if not child.name.begins_with("@"):
			continue
		child.queue_free()
		removed += 1
	# Enemies that have drifted within 7 m of the lens.
	var enemies := world.get_node_or_null("Enemies")
	if enemies != null:
		for enemy in enemies.get_children():
			if enemy is Node3D and (enemy as Node3D).global_position.distance_to(cam.global_position) < 7.0:
				enemy.queue_free()
				removed += 1
	if removed > 0:
		_log("INFO", "cleared %d transient/enemy nodes from the camera frame" % removed)


## Report real rendering and scene cost for the wide frame.
##
## These come straight from the engine's own monitors, so they are measured
## rather than estimated. The numbers to watch:
##
##   draw_calls  - total submitted draws. Vegetation batching took this from
##                 roughly 1,600 for the scatter alone to about 15.
##   objects     - drawable objects submitted.
##   primitives  - triangles issued. Batched MultiMesh draws are much larger
##                 single draws, so this should hold roughly steady while
##                 draw_calls collapses; a big drop here means geometry was
##                 actually removed, which is the thing we are NOT doing.
##   nodes       - live scene-tree nodes. The old scatter alone was ~4,800
##                 nodes (1,600 meshes plus their parents).
##   video_mem   - texture and vertex buffer residency in MB.
func _report_frame_cost(world: Node) -> void:
	var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objs := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var vmem := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var proc := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_log("INFO", "PERF draw_calls=%d objects=%d primitives=%d nodes=%d video_mem=%.1fMB fps=%.0f process=%.2fms physics=%.2fms" % [
		dc, objs, prims, nodes, vmem, fps, proc, phys])
	if world != null and world.has_method("perf_census"):
		var census: String = world.call("perf_census")
		if census != "":
			_log("INFO", "PERF %s" % census)
	_check_cull_actually_culls(world)


## Assert that the scenes and batches are split finely enough for the frustum
## test to reject anything at all.
##
## This is the one performance property that can be verified without a
## framebuffer and without a phone, and it is the one that was broken for a long
## time. Godot culls by object AABB: a single MeshInstance3D spanning the whole
## valley, or a single MultiMeshInstance3D holding every tree, always intersects
## the frustum, so it is always submitted in full and half the world is drawn
## from behind the camera every frame. Nothing in the image looks wrong, and no
## test noticed, so the world just ran slowly.
##
## What is asserted is not a frame time - that is llvmpipe here and meaningless -
## but the structural precondition: enough drawables, and each one bounded to a
## small enough region that the count of them outside the view is large.
## Direct children of `parent` whose name starts with `prefix`.
func _children_named(parent: Node, prefix: String) -> Array[Node]:
	var out: Array[Node] = []
	if parent == null:
		return out
	for c in parent.get_children():
		if str(c.name).begins_with(prefix):
			out.append(c)
	return out


func _check_cull_actually_culls(world: Node) -> void:
	if world == null:
		return
	# Terrain tiles. One mesh covering the map means nothing is ever culled, and
	# the tiles are no longer direct children: near and mid layers are separate
	# node groups so the streaming code can free one layer without touching the
	# other.
	var terrain := world.get_node_or_null("Terrain")
	var tiles := 0
	var biggest_extent := 0.0
	if terrain != null:
		for c in terrain.find_children("*", "MeshInstance3D", true, false):
			var tmi := c as MeshInstance3D
			if tmi.mesh != null:
				tiles += 1
				var aabb: AABB = tmi.mesh.get_aabb()
				biggest_extent = maxf(biggest_extent, maxf(aabb.size.x, aabb.size.z))
	if tiles < 4:
		_fail += 1
		_log("FAIL", "CULL terrain is %d drawable(s); one mesh spanning the valley can never be culled" % tiles)
	else:
		_log("INFO", "CULL terrain tiles=%d largest_extent=%.0fm" % [tiles, biggest_extent])

	# Vegetation. Count the batches and the largest instance count in any one of
	# them; a batch holding the entire population is the failure mode.
	var batches := 0
	var largest := 0
	var total := 0
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MultiMeshInstance3D:
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm != null:
				batches += 1
				total += mm.instance_count
				largest = maxi(largest, mm.instance_count)
		for c in n.get_children():
			stack.append(c)
	# Thresholds, and why they are these:
	#
	#   batches   - the scatter must be split at all. One population per valley
	#               was the original bug; tens of tiles is the fix.
	#   largest   - a batch is cullable if its AABB covers one tile, not the
	#               world. Grass chunks are the big ones (a near chunk is ~14k
	#               blades inside 26 m), and that is fine: the shader culls
	#               blades behind the camera per instance, and the chunk is small
	#               enough that most of it is in front of or behind the camera as
	#               a unit. 20k is the line between "one chunk" and "the world".
	if batches < 8:
		_fail += 1
		_log("FAIL", "CULL only %d MultiMesh batch(es); the scatter is not split into cullable tiles" % batches)
	elif largest > 20000:
		_fail += 1
		_log("FAIL", "CULL one batch holds %d instances; its AABB cannot be culled" % largest)
	else:
		_log("INFO", "CULL multimesh_batches=%d instances=%d largest_batch=%d" % [batches, total, largest])


## Entity occlusion culling, which no screenshot can verify.
##
## A correctly culled entity and an entity that merely happens to be behind a
## wall look identical in a frame, so the property has to be asserted from
## outside the image:
##
##   * the culler's geometry predicates, on synthetic wall / ridge / roof cases
##     where the answer is known in advance;
##   * that the asynchronous pass has actually run against the live world and
##     split the entities into visible and hidden - everything visible means it
##     is doing nothing, everything hidden means it is rejecting the world;
##   * that every hidden entity's visual is really suppressed, and that the
##     entity's own cull flag agrees with the decision, since that flag is what
##     stops its ticks.
##
## Runs headlessly on purpose: the structural job is the one that always runs.
func _check_entity_culling(world: Node) -> void:
	# Yield first, unconditionally: this makes the function a coroutine on every
	# path, so the caller's `await` is always awaiting a real state rather than
	# relying on what Godot does with `await` on a value that returned at once.
	await get_tree().process_frame
	if world == null:
		return
	var culler := world.get_node_or_null("EntityCuller")
	if culler == null:
		_log("FAIL", "ENTITY_CULL no EntityCuller - occluded entities are still drawn and still ticking")
		return
	var geometry: Dictionary = culler.call("self_test")
	if bool(geometry.get("ok", false)):
		_log("INFO", "ENTITY_CULL geometry: %s" % str(geometry.get("summary", "")))
	else:
		for note in geometry.get("failures", []):
			_log("FAIL", "ENTITY_CULL geometry: %s" % str(note))
	# The pass runs at 5 Hz and needs two consecutive misses before hiding
	# anything, so wait for a decision instead of racing the first one.
	var waited := 0
	while waited < 12 and int(culler.call("stats").get("hidden", 0)) < 1:
		await get_tree().create_timer(0.15).timeout
		waited += 1
	var stats: Dictionary = culler.call("stats")
	var registered := int(stats.get("registered", 0))
	var hidden := int(stats.get("hidden", 0))
	var visible := int(stats.get("visible", 0))
	var passes := int(stats.get("probes", 0))
	if registered < 10:
		_log("FAIL", "ENTITY_CULL only %d entit(ies) registered - the spawns are not wired to the culler" % registered)
	if passes < 1:
		_log("FAIL", "ENTITY_CULL the visibility pass never completed - the async probe is not running")
	if passes >= 1 and hidden < 1:
		_log("FAIL", "ENTITY_CULL nothing is ever hidden - every entity is drawn and ticked regardless of occlusion")
	# A safe settlement spawn can legitimately have no registered enemies or
	# collectibles near the camera. Only demand a visible entity if one lies
	# inside the culler's unconditional near-hold radius.
	var near_entity := false
	var current_camera := get_viewport().get_camera_3d()
	if current_camera != null:
		for group_name in ["enemy", "sigil", "waypoint"]:
			for entity in get_tree().get_nodes_in_group(group_name):
				if entity is Node3D and entity.global_position.distance_to(current_camera.global_position) < 10.0:
					near_entity = true
	if passes >= 1 and visible < 1 and near_entity:
		_log("FAIL", "ENTITY_CULL hides an entity in the near-hold radius")
	if not bool(stats.get("consistent", false)):
		_log("FAIL", "ENTITY_CULL an entity's cull flag disagrees with the culler's decision - its ticks did not stop")
	if hidden > 0 and int(stats.get("render_skipped", 0)) < hidden:
		_log("FAIL", "ENTITY_CULL %d hidden entit(ies) still have a visible visual" % (hidden - int(stats.get("render_skipped", 0))))
	_log("INFO", "ENTITY_CULL registered=%d visible=%d hidden=%d passes=%d threads=%d grid=%d occluders=%d render_skipped=%d tick_reduced=%d" % [
		registered, visible, hidden, passes, int(stats.get("threads", 0)),
		int(stats.get("grid", 0)), int(stats.get("occluders", 0)),
		int(stats.get("render_skipped", 0)), int(stats.get("tick_reduced", 0))])


## Bone cloth, asserted as geometry rather than as a filename.
##
## The cloth pieces are vendored CC0 glTF models, so "the file is in the repo" and
## "the world is wearing it" are very different claims: an unimported model gives
## an empty scene, and a re-materialled surface can end up with no material at
## all. Count the pieces, their mesh instances and their surfaces - a banner is
## four surfaces, so a scene that imported but lost its primitives is visible here
## as a piece with zero meshes.
func _check_bone_cloth(world: Node) -> void:
	if world == null:
		return
	var pieces := get_tree().get_nodes_in_group("bone_cloth")
	if pieces.is_empty():
		_log("FAIL", "BONE_CLOTH no bone-cloth pieces in the world - the cloth assets are not being instanced")
		return
	var meshes := 0
	var surfaces := 0
	for n in pieces:
		for child in n.find_children("*", "MeshInstance3D", true, false):
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			meshes += 1
			surfaces += mi.mesh.get_surface_count()
	# The glTF scenes are authored in centimetres behind a 100x node scale, so the
	# one thing that can silently ruin every placement is that scale not surviving
	# import: the cloth would import correctly, instance correctly, hold its
	# surfaces - and be a 3 cm banner buried in the grass.
	var widest := 0.0
	for n in pieces:
		var box := AABB()
		var first := true
		for child in n.find_children("*", "MeshInstance3D", true, false):
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			var b: AABB = mi.global_transform * mi.get_aabb()
			box = b if first else box.merge(b)
			first = false
		if not first:
			widest = maxf(widest, maxf(box.size.x, maxf(box.size.y, box.size.z)))
	if widest < 0.2 or widest > 14.0:
		_log("FAIL", "BONE_CLOTH largest piece spans %.2f m - the glTF node scale did not survive import" % widest)
	else:
		_log("INFO", "BONE_CLOTH largest piece spans %.2f m" % widest)
	if pieces.size() < 10:
		_log("FAIL", "BONE_CLOTH only %d piece(s) in the whole world - the dressing did not place" % pieces.size())
	if meshes < 10 or surfaces < 20:
		_log("FAIL", "BONE_CLOTH %d piece(s) produced only %d mesh(es)/%d surface(s)" % [pieces.size(), meshes, surfaces])
	_log("INFO" if meshes >= 10 and surfaces >= 20 else "WARN",
		"BONE_CLOTH pieces=%d meshes=%d surfaces=%d (glTF imports alive)" % [pieces.size(), meshes, surfaces])
	if world.has_method("bone_cloth_census"):
		_log("INFO", "BONE_CLOTH census: %s" % str(world.call("bone_cloth_census")))


## First MultiMeshInstance3D under a node, for the material dump.
func _first_multimesh(node: Node) -> MultiMeshInstance3D:
	for child in node.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := child as MultiMeshInstance3D
		if mmi != null and mmi.multimesh != null:
			return mmi
	return null


## The same mesh and the same material, drawn once as a plain MeshInstance3D and
## once as a one-instance MultiMesh, both a couple of metres in front of the
## camera, with the pixel in the middle of each read back.
##
## This is the direct test of "do the pack's baked vertex colours reach the
## shader", which is the question that cost the most time on this asset: a
## black silhouette in a screenshot reads equally well as a shadow, an unlit
## material or a missing texture, and none of those was it. A green number here
## means the whole chain - bake, mesh, MultiMesh, shader - is intact.
func _probe_colour_path(world: Node) -> void:
	if world == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var NP = load("res://scripts/nature_pack.gd")
	if NP == null:
		return
	var kind := "bush_1"
	var mesh = NP.mesh_of(kind)
	if mesh == null:
		return
	var mat = NP.material(kind, 0.0)
	if mat == null:
		return
	var ahead: Vector3 = cam.global_position + (-cam.global_transform.basis.z) * 2.2

	var plain := MeshInstance3D.new()
	plain.mesh = mesh
	plain.material_override = mat
	plain.scale = Vector3(0.7, 0.7, 0.7)
	world.add_child(plain)
	plain.global_position = ahead
	await get_tree().process_frame
	await get_tree().process_frame
	var plain_colour := _centre_colour()
	_log("INFO", "COLOUR plain mesh = %s" % _colour_text(plain_colour))
	if plain_colour.y < 55.0:
		_log("FAIL", "COLOUR the pack's green baked into a mesh renders as %s - the vertex colour attribute is dead" % _colour_text(plain_colour))
	plain.visible = false

	var inst := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D())
	inst.multimesh = mm
	inst.material_override = mat
	inst.scale = Vector3(0.7, 0.7, 0.7)
	world.add_child(inst)
	inst.global_position = ahead
	await get_tree().process_frame
	await get_tree().process_frame
	var inst_colour := _centre_colour()
	_log("INFO", "COLOUR multimesh = %s" % _colour_text(inst_colour))
	if inst_colour.y < 55.0:
		_log("FAIL", "COLOUR a MultiMesh instance of the same mesh renders as %s" % _colour_text(inst_colour))

	# And with custom data on, which is how every vegetation layer used to be
	# built and is what broke it.
	mm.use_custom_data = true
	mm.set_instance_custom_data(0, Color(0.5, 0.0, 0.0, 0.0))
	await get_tree().process_frame
	await get_tree().process_frame
	var custom_colour := _centre_colour()
	_log("INFO", "COLOUR multimesh with custom data = %s (the layer path; must match the line above)" % _colour_text(custom_colour))
	if custom_colour.y < 55.0:
		_log("FAIL", "COLOUR custom data on a MultiMesh costs the mesh its vertex colours (%s) - the vegetation layers must not use it" % _colour_text(custom_colour))

	inst.visible = false
	await get_tree().process_frame
	plain.queue_free()
	inst.queue_free()


## Mean colour of a patch at the centre of the frame, as 0-255 per channel.
func _centre_colour() -> Vector3:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return Vector3.ZERO
	var cx := img.get_width() / 2
	var cy := img.get_height() / 2
	var sum := Vector3.ZERO
	var n := 0
	# Bounded by the image, not by a constant: a probe frame is whatever size the
	# runner could allocate, and get_pixel() past the edge is a hard error.
	var lo_y := clampi(cy - 20, 0, img.get_height() - 1)
	var hi_y := clampi(cy + 20, 0, img.get_height())
	var lo_x := clampi(cx - 20, 0, img.get_width() - 1)
	var hi_x := clampi(cx + 20, 0, img.get_width())
	for y in range(lo_y, hi_y, 2):
		for x in range(lo_x, hi_x, 2):
			var c := img.get_pixel(x, y)
			sum += Vector3(c.r, c.g, c.b)
			n += 1
	return (sum / maxf(1.0, float(n))) * 255.0


## A Vector3 of 0-255 channels, for the log.
func _colour_text(c: Vector3) -> String:
	return "(%d, %d, %d)" % [int(c.x), int(c.y), int(c.z)]


## How much of the frame is near-black. Foliage is drawn with an emissive fill,
## so a batch of it cannot be near-black unless something upstream ate its
## vertex colours - which is exactly what happened, and what took a dozen round
## trips to find because a black silhouette in a screenshot reads equally well
## as a shadow, an unlit material or a missing texture. The number settles it.
func _check_black_props() -> void:
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	var dark := _dark_fraction(img)
	_log("INFO", "DARK %.2f%% of the frame is near-black" % dark)
	if dark > 6.0:
		_log("FAIL", "BLACK_PROPS %.1f%% of the frame is near-black inside the nature batches - the vertex colours are not reaching the shader" % dark)


## Fraction of the frame that is very dark, as a percentage.
func _dark_fraction(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, h / 200)
	var dark := 0
	var total := 0
	for y in range(int(h * 0.18), _sample_end(h, step), step):
		for x in range(0, _sample_end(w, step), step):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) < 0.10:
				dark += 1
			total += 1
	return 100.0 * float(dark) / maxf(1.0, float(total))



## The map has to be a map: a wide playable interior with no wall inside a
## kilometre, mountains at the far edge, and all four kinds of water where the
## terrain says they are.
##
## This is the check the old 600 m bowl would have failed. It measures the height
## field itself rather than trusting constants, so a rim that creeps back in, a
## river that stops being carved or a sea that never gets below the waterline is a
## failed build rather than a screenshot somebody has to notice.
func _check_world_scale(world: Node) -> void:
	var terrain := world.get_node_or_null("Terrain")
	if terrain == null:
		_log("FAIL", "WORLD no terrain node to measure")
		return
	if terrain.has_method("census"):
		_log("INFO", "TERRAIN %s" % str(terrain.call("census")))

	# Biomes are anchored away from the starting meadow and share the shader's
	# parameters. They do not alter collision heights or saved world positions.
	var biome_data = load("res://scripts/biome_regions.gd")
	var biome_ok: bool = terrain.call("biome_at", 0.0, 0.0) == "meadow"
	for biome_name in biome_data.REGIONS:
		var region: Vector3 = biome_data.REGIONS[biome_name]
		biome_ok = biome_ok and terrain.call("biome_at", region.x, region.y) == biome_name
		var terrain_material: ShaderMaterial = terrain.get("_material")
		biome_ok = biome_ok and terrain_material != null and terrain_material.get_shader_parameter("region_" + str(biome_name)) == region
	biome_ok = biome_ok and bool(terrain.call("is_underwater", biome_data.TIDAL.x, biome_data.TIDAL.y))
	var pine_layer := world.get_node_or_null("Veg_northern_pines")
	var crystal_layer := world.get_node_or_null("FantasyCrystals")
	if pine_layer != null and crystal_layer != null:
		var taiga_key := Vector2i(floori(biome_data.TAIGA.x / 26.0), floori(biome_data.TAIGA.y / 26.0))
		var fantasy_key := Vector2i(floori(biome_data.FANTASY.x / 48.0), floori(biome_data.FANTASY.y / 48.0))
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				pine_layer.call("_build_chunk", taiga_key + Vector2i(dx, dz))
				crystal_layer.call("_build", fantasy_key + Vector2i(dx, dz))
		biome_ok = biome_ok and not (pine_layer.get("_chunks") as Dictionary).is_empty() and not (crystal_layer.get("_chunks") as Dictionary).is_empty()
	else:
		biome_ok = false
	_log("INFO" if biome_ok else "FAIL", "snow, savanna, taiga, tidal and fantasy regions, meadow, water and streamed scenery=%s" % str(biome_ok))

	# Playable interior: flat-or-hilly, not a wall, a kilometre out in four
	# directions.
	var wall := 0.0
	for probe in [Vector2(1000.0, 0.0), Vector2(-1000.0, 0.0),
			Vector2(0.0, 1000.0), Vector2(0.0, -1000.0)]:
		wall = maxf(wall, _world_height(terrain, probe.x, probe.y))
	_log("INFO" if wall < 110.0 else "FAIL",
		"WORLD interior peak at 1 km = %.0f m %s" % [wall, "(a wall, not a landscape)" if wall >= 110.0 else ""])

	# Mountains at the edge: the highest ground 3 km out has to be a real ridge.
	# Four bearings is not enough. The range only closes 240 degrees of the map -
	# the south-east is the bay, on purpose - and the two noise octaves swing the
	# height of any single sample by tens of metres, so a compass rose can miss
	# the ridge that is there. Eight bearings, and the check is that *some*
	# direction is a mountain, not that every one is.
	var peak := -999.0
	for i in range(16):
		var a := TAU * float(i) / 16.0
		peak = maxf(peak, _world_height(terrain, cos(a) * 3000.0, sin(a) * 3000.0))
	_log("INFO" if peak > 130.0 else "FAIL",
		"WORLD mountains at 3 km = %.0f m %s" % [peak, "(no ridge - the map just ends)" if peak <= 130.0 else ""])

	# Water. Every body is terrain below the waterline; the surface is scenery.
	var level := Game.water_level
	var lake_d := Vector2(Game.lake_center.x, Game.lake_center.y)
	var lake_h := _world_height(terrain, lake_d.x, lake_d.y)
	_log("INFO" if lake_h < level else "FAIL", "WATER lake bed = %.1f m (level %.1f)" % [lake_h, level])
	var pond_ok := false
	var pond_h := 99.0
	var script: Script = terrain.get_script()
	var ponds: Array = []
	if script != null:
		var constants: Dictionary = script.get_script_constant_map()
		if constants.has("PONDS"):
			ponds = constants["PONDS"]
	for i in range(ponds.size()):
		var pond: Vector3 = ponds[i]
		pond_h = minf(pond_h, _world_height(terrain, pond.x, pond.y))
		if pond_h < level:
			pond_ok = true
	_log("INFO" if pond_ok else "FAIL",
		"WATER %d pond(s), lowest bed = %.1f m" % [ponds.size(), pond_h])
	var river_h := 99.0
	if terrain.has_method("river_x"):
		for z in [-800.0, -200.0, 400.0, 900.0]:
			var rx := float(terrain.call("river_x", z))
			river_h = minf(river_h, _world_height(terrain, rx, z))
	_log("INFO" if river_h < level else "FAIL", "WATER river bed = %.1f m at four points along it" % river_h)
	var sea_h := _world_height(terrain, 1700.0, 1650.0)
	_log("INFO" if sea_h < level else "FAIL", "WATER sea bed in the south-east = %.1f m" % sea_h)

	# And the surface that makes it water.
	var surface: MeshInstance3D = null
	for node in world.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.name == "WaterSurface":
			surface = mi
			break
	if surface == null:
		_log("FAIL", "WATER no WaterSurface mesh - the sea, lake, river and ponds have no surface")
	elif surface.mesh is PlaneMesh:
		var span := (surface.mesh as PlaneMesh).size.x
		_log("INFO" if span >= 4000.0 else "FAIL",
			"WATER surface spans %.0f m at y=%.2f" % [span, surface.position.y])


func _world_height(terrain: Node, x: float, z: float) -> float:
	return float(terrain.call("get_height_at", x, z))



## The environment, asserted as baked geometry.
##
## Every tree, bush, plant, rock, log, stump and blade of grass in the frame is
## one of the nature pack's models, flattened by NaturePack into a single
## vertex-coloured surface so a MultiMesh can draw a whole batch with one
## material. Three things can go wrong silently: the models import empty (a node
## exists, draws nothing), they import without their 100x node scale (a forest of
## 3 cm trees), or the vertex colours are dropped in the bake (every prop one flat
## colour). All three are countable, so they are counted.
func _check_nature_pack(world: Node) -> void:
	var NP = load("res://scripts/nature_pack.gd")
	if NP == null:
		_log("FAIL", "NATURE_PACK scripts/nature_pack.gd did not load")
		return
	var kinds: Array = NP.kinds()
	var baked := 0
	var tris := 0
	var flat := 0
	for kind in kinds:
		var mesh: ArrayMesh = NP.mesh_of(kind)
		if mesh == null or mesh.get_surface_count() == 0:
			_log("FAIL", "NATURE_PACK model '%s' baked no surface" % kind)
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		baked += 1
		tris += idx.size() / 3
		if cols.size() != verts.size():
			flat += 1
		var h: float = NP.height_of(kind)
		if h < 0.2 or h > 8.0:
			_log("FAIL", "NATURE_PACK '%s' is %.2f m tall - the 100x glTF node scale did not survive import" % [kind, h])
	_log("INFO", "NATURE_PACK kinds=%d baked=%d triangles=%d" % [kinds.size(), baked, tris])
	if baked < 12:
		_log("FAIL", "NATURE_PACK only %d of %d models baked - the environment is not the pack" % [baked, kinds.size()])
	if tris < 4000:
		_log("FAIL", "NATURE_PACK baked only %d triangles - the models imported empty" % tris)
	if flat > 0:
		_log("FAIL", "NATURE_PACK %d model(s) lost their vertex colours - every prop of that kind would draw one flat colour" % flat)
	# What the world actually built from them. A batch node with no instances is
	# the difference between "the pack is vendored" and "the valley is the pack".
	var veg := world.get_node_or_null("Vegetation") if world != null else null
	var nature_nodes := 0
	var nature_instances := 0
	if veg != null:
		for n in veg.find_children("*", "MultiMeshInstance3D", true, false):
			var mmi := n as MultiMeshInstance3D
			if mmi.multimesh == null or mmi.multimesh.mesh == null:
				continue
			if not (mmi.multimesh.mesh is ArrayMesh):
				continue
			# Nature meshes are the ones whose surface carries vertex colours.
			var batch_arrays := (mmi.multimesh.mesh as ArrayMesh).surface_get_arrays(0)
			if batch_arrays.size() > Mesh.ARRAY_COLOR and batch_arrays[Mesh.ARRAY_COLOR] != null:
				nature_nodes += 1
				nature_instances += mmi.multimesh.instance_count
	_log("INFO" if nature_nodes > 0 else "FAIL",
		"NATURE_PACK scatter batches=%d instances=%d" % [nature_nodes, nature_instances])
	if nature_instances < 200:
		_log("FAIL", "NATURE_PACK only %d nature instances in the valley - the scatter did not spawn" % nature_instances)
	_log("INFO", "NATURE_PACK census: %s" % str(NP.census()))
	# Material and vertex-colour dump, one line per species.
	#
	# A textureless model has exactly two ways to end up the wrong colour: the
	# baked vertex colour is wrong, or the material's tint multiplies it to
	# nothing. Both are invisible in a screenshot except as "that prop is dark",
	# so the numbers are printed and the probe can be read instead of eyeballed.
	var Presets = load("res://scripts/performance/vegetation_presets.gd")
	if Presets != null:
		for spec in Presets.species():
			var layer: Node = null
			if world != null:
				layer = world.get_node_or_null("Veg_%s" % spec["name"])
			if layer == null:
				continue
			var batch := _first_multimesh(layer)
			if batch == null:
				if spec.has("biomes"):
					_log("INFO", "NATURE_MAT %s is restricted to its regional biomes" % spec["name"])
				else:
					_log("FAIL", "NATURE_MAT %s has no MultiMesh batch" % spec["name"])
				continue
			var shader_mat := batch.material_override as ShaderMaterial
			var vcol := Color.BLACK
			if batch.multimesh.mesh is ArrayMesh:
				var marr: Array = (batch.multimesh.mesh as ArrayMesh).surface_get_arrays(0)
				var mcols: PackedColorArray = marr[Mesh.ARRAY_COLOR]
				if mcols.size() > 0:
					vcol = mcols[0]
			if shader_mat == null:
				_log("FAIL", "NATURE_MAT %s has no ShaderMaterial (%s)" % [spec["name"], str(batch.material_override)])
				continue
			_log("INFO", "NATURE_MAT %s shader=%s tint=%s wind=%s sway=%.2f vcol=%s shadow=%s" % [
				spec["name"], str(shader_mat.shader.resource_path).get_file(),
				str(shader_mat.get_shader_parameter("base_tint")),
				str(shader_mat.get_shader_parameter("wind_strength")),
				float(shader_mat.get_shader_parameter("sway_height")),
				str(vcol), str(batch.cast_shadow)])
			_log("INFO", "NATURE_PARAM %s darken=%s rim=%s back=%s rough=%s var=%s fill=%s" % [
				spec["name"],
				str(shader_mat.get_shader_parameter("base_darken")),
				str(shader_mat.get_shader_parameter("rim_strength")),
				str(shader_mat.get_shader_parameter("backlight_scale")),
				str(shader_mat.get_shader_parameter("roughness_value")),
				str(shader_mat.get_shader_parameter("tint_variation")),
				str(shader_mat.get_shader_parameter("shadow_fill"))])


func _report_palette(img: Image, label: String) -> void:
	## Print hue/saturation for a few fixed sample points so the colour grade can
	## be checked as numbers instead of by eye. The neon-green problem that took
	## several render cycles to pin down was a saturation of 0.99 at hue 92 - a
	## value that a single measurement would have exposed immediately.
	var w := img.get_width()
	var h := img.get_height()
	var pts := {
		"foreground": Vector2i(int(w * 0.28), int(h * 0.86)),
		"meadow": Vector2i(int(w * 0.52), int(h * 0.62)),
		"far hill": Vector2i(int(w * 0.66), int(h * 0.44)),
		"horizon": Vector2i(int(w * 0.80), int(h * 0.30)),
	}
	var parts: Array[String] = []
	var worst := 0.0
	for key in pts.keys():
		var c := img.get_pixel(pts[key].x, pts[key].y)
		var hsv := _hsv_of(c)
		parts.append("%s h=%3.0f s=%.2f v=%.2f" % [key, hsv.x * 360.0, hsv.y, hsv.z])
		if key != "horizon":
			worst = maxf(worst, hsv.y)
	_log("INFO", "%s palette: %s" % [label, ", ".join(parts)])
	# Face validity for "is this neon": count pixels that are almost pure hue -
	# saturation above 0.90 with a mid or high value. A realistic stylised frame
	# sits far below 15%; the neon-green versions of this render were well over
	# 60%, because a warm sun on a blue-poor green albedo clipped the blue channel
	# to zero across the entire hillside.
	var hot := 0
	var counted := 0
	var step := maxi(1, int(img.get_width() / 120.0))
	for y in range(0, _sample_end(img.get_height(), step), step):
		for x in range(0, _sample_end(img.get_width(), step), step):
			counted += 1
			var c2 := img.get_pixel(x, y)
			var hsv2 := _hsv_of(c2)
			if hsv2.y > 0.90 and hsv2.z > 0.30:
				hot += 1
	if counted > 0:
		var frac := float(hot) / float(counted)
		_log("INFO", "%s saturated pixels (s>0.90, v>0.30) = %.1f%%" % [label, frac * 100.0])
		if frac > 0.35:
			_log("WARN", "%s is %.0f%% near-pure hue - the frame reads as neon rather than painted" % [
				label, frac * 100.0])
	if worst > 0.92:
		_log("WARN", "%s has a near-pure sample (saturation %.2f) - the grade is clipping a channel" % [label, worst])


func _dump_player_parts(cam: Camera3D, world: Node) -> void:
	## List every mesh on the character with its projected position and visibility.
	## The gameplay frame showed only her legs, and there is no way to tell from a
	## PNG whether the upper body is missing, unlit, transparent or off screen.
	var player := world.get_node_or_null("Player")
	if player == null:
		return
	var shown := 0
	var parts: Array[String] = []
	for mi in player.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var wp := m.global_position
		var scr := cam.unproject_position(wp)
		var behind := cam.is_position_behind(wp)
		var vis := m.is_visible_in_tree()
		var aabb := m.global_transform * m.get_aabb()
		parts.append("%s vis=%s behind=%s screen=(%d,%d) size=%.2f y=%.2f" % [
			str(m.get_path()).replace(str(player.get_path()) + "/", ""),
			str(vis), str(behind), int(scr.x), int(scr.y), aabb.size.length(), wp.y])
		if vis and not behind:
			shown += 1
	parts.sort()
	# The model's own bounds settle whether the upper body exists at all.
	var total := AABB()
	var first := true
	for mi in player.find_children("*", "MeshInstance3D", true, false):
		var m2 := mi as MeshInstance3D
		if m2.mesh == null:
			continue
		var box := m2.global_transform * m2.get_aabb()
		total = box if first else total.merge(box)
		first = false
	_log("INFO", "player bounds y=%.2f..%.2f (height %.2f m), x=%.2f..%.2f" % [
		total.position.y, total.end.y, total.size.y,
		total.position.x, total.end.x])
	_log("INFO", "player parts: %d meshes, %d on screen" % [parts.size(), shown])
	for i in range(mini(parts.size(), 4)):
		_log("INFO", "  " + parts[i])


func _dump_visual_tree(player: Node) -> void:
	## One line, deliberately: the annotation API truncates after ~24 entries and
	## a multi-line dump gets cut off before the part that matters.
	var visual := player.get_node_or_null("Visual") as Node3D if player != null else null
	if visual == null:
		_log("FAIL", "player has no Visual node")
		return
	var bits: Array[String] = []
	bits.append("Visual vis=%s children=%d" % [str(visual.visible), visual.get_child_count()])
	for child in visual.get_children():
		var n3 := child as Node3D
		if n3 == null:
			continue
		var meshes := n3.find_children("*", "MeshInstance3D", true, false)
		var box := AABB()
		var first := true
		for mi in meshes:
			var m := mi as MeshInstance3D
			if m.mesh == null:
				continue
			var b := m.global_transform * m.get_aabb()
			box = b if first else box.merge(b)
			first = false
		bits.append("%s vis=%s y=%.1f..%.1f n=%d" % [
			n3.name, str(n3.visible), box.position.y, box.end.y, meshes.size()])
	_log("INFO", "PLAYER_TREE " + " | ".join(bits))
	var vis_total := visual.find_children("*", "MeshInstance3D", true, false).size()
	var hidden := 0
	for mi in visual.find_children("*", "MeshInstance3D", true, false):
		if not (mi as MeshInstance3D).is_visible_in_tree():
			hidden += 1
	_log("INFO", "PLAYER_MESHES total=%d hidden_in_tree=%d" % [vis_total, hidden])
	# Exact world Y of the landmarks, relative to the player's own origin. If the
	# model is proportioned correctly the head sits at ~1.8 and the boots near 0.
	var origin_y: float = (player as Node3D).global_position.y
	for want in ["Torso", "Head", "ArmL", "LegL", "LegR"]:
		var node: Node3D = visual.find_child(want, true, false) as Node3D
		if node != null:
			_log("INFO", "PART %s world_y=%.2f (rel %.2f) scale=%s" % [
				want, node.global_position.y, node.global_position.y - origin_y,
				str(node.global_transform.basis.get_scale())])
	var mesh_y: Array[String] = []
	for mi in visual.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or not m.is_visible_in_tree():
			continue
		var b := m.global_transform * m.get_aabb()
		mesh_y.append("%s:%.1f-%.1f" % [str(m.name), b.position.y - origin_y, b.end.y - origin_y])
	if mesh_y.size() > 0:
		_log("INFO", "MESH_Y (rel to feet): " + " ".join(mesh_y.slice(0, 14)))


func _test_toon_material() -> void:
	## Build the character's toon material exactly the way character_builder does and
	## check it reached the renderer with sane parameters. A ShaderMaterial whose
	## shader failed to compile draws nothing at all, which is indistinguishable in a
	## screenshot from geometry that is missing or hidden.
	var shader := load("res://shaders/character/anime_toon.gdshader") as Shader
	if shader == null:
		_log("FAIL", "anime_toon.gdshader did not load")
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("albedo_color", Color(0.94, 0.96, 0.99))
	var params := 0
	for u in shader.get_shader_uniform_list():
		params += 1
	_log("INFO", "TOON_MAT shader_uniforms=%d code_len=%d render_priority=%d" % [
		params, shader.code.length(), mat.render_priority])
	if params == 0:
		_log("FAIL", "anime_toon.gdshader exposes no uniforms - it failed to compile")


func _check_player_visible(cam: Camera3D, world: Node) -> void:
	## Project the character's chest to the screen and confirm it is inside the
	## region the play view can actually see: above the bottom HUD band and inside
	## the viewport.
	var player := world.get_node_or_null("Player") as Node3D
	if player == null:
		_log("FAIL", "no Player node - nothing to look at in the gameplay frame")
		return
	var chest := player.global_position + Vector3(0.0, 1.2, 0.0)
	var screen := cam.unproject_position(chest)
	var vp := get_viewport().get_visible_rect().size
	# The bottom ~26% of the screen is the HUD action bar and the burst/stamina
	# bars. A character whose chest lands below that line is effectively hidden.
	var hud_top := vp.y * 0.74
	_log("INFO", "player chest projects to (%.0f,%.0f) of (%.0f,%.0f), HUD starts at y=%.0f" % [
		screen.x, screen.y, vp.x, vp.y, hud_top])
	if cam.is_position_behind(chest):
		_log("FAIL", "the character is behind the camera")
	elif screen.y > hud_top:
		_log("FAIL", "the character is behind the HUD (chest at y=%.0f, HUD from y=%.0f)" % [
			screen.y, hud_top])
	elif screen.x < 0.0 or screen.x > vp.x:
		_log("FAIL", "the character is off screen horizontally")
	else:
		_log("INFO", "character is in clear view")


func _hsv_of(c: Color) -> Vector3:
	## Hue in 0..1, then saturation, then value. Godot has no HSV accessor on
	## Color (there is a `from_hsv` constructor, but no getter), so this converts
	## by hand.
	var mx := maxf(c.r, maxf(c.g, c.b))
	var mn := minf(c.r, minf(c.g, c.b))
	var delta := mx - mn
	var h := 0.0
	if delta > 0.00001:
		if mx == c.r:
			h = fmod((c.g - c.b) / delta, 6.0) / 6.0
		elif mx == c.g:
			h = ((c.b - c.r) / delta + 2.0) / 6.0
		else:
			h = ((c.r - c.g) / delta + 4.0) / 6.0
		if h < 0.0:
			h += 1.0
	var sat := 0.0 if mx <= 0.0 else delta / mx
	return Vector3(h, sat, mx)


func _white_blob_stats(img: Image) -> Dictionary:
	## Connected components on a sampled mask, not one bounding box around
	## unrelated white pixels (e.g. clouds, text and HUD highlights).
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(w / 200.0))
	var cols := int(_sample_end(w, step) / step)
	var rows := int(_sample_end(h, step) / step)
	var total := cols * rows
	if total == 0:
		return {"total": 0, "hot": 0, "largest": 0}
	var mask := PackedByteArray()
	mask.resize(total)
	var hot := 0
	for gy in range(rows):
		for gx in range(cols):
			var c := img.get_pixel(gx * step, gy * step)
			if c.r > 0.97 and c.g > 0.97 and c.b > 0.95 and c.a > 0.5:
				mask[gy * cols + gx] = 1
				hot += 1
	var largest := 0
	for start in range(total):
		if mask[start] == 0:
			continue
		var queue := PackedInt32Array([start])
		mask[start] = 0
		var cursor := 0
		while cursor < queue.size():
			var idx := queue[cursor]
			cursor += 1
			var x := idx % cols
			var y := int(idx / cols)
			for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx: int = x + offset.x
				var ny: int = y + offset.y
				if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
					continue
				var neighbor: int = ny * cols + nx
				if mask[neighbor] == 1:
					mask[neighbor] = 0
					queue.append(neighbor)
		largest = maxi(largest, queue.size())
	return {"total": total, "hot": hot, "largest": largest}


func _check_blob(img: Image, label: String) -> void:
	## A large connected white patch is suspicious; scattered clouds are not.
	var stats := _white_blob_stats(img)
	var total: int = int(stats["total"])
	if total == 0:
		_log("WARN", "%s white-blob check had no samples" % label)
		return
	var fraction := float(stats["hot"]) / float(total)
	var blob := float(stats["largest"]) / float(total)
	if blob > 0.06:
		_log("FAIL", "%s frame has a connected white region covering %.1f%% of samples (%.1f%% white overall)" % [
			label, blob * 100.0, fraction * 100.0])
	else:
		_log("INFO", "%s frame white pixels %.1f%%, largest connected region %.1f%%" % [
			label, fraction * 100.0, blob * 100.0])


func _test_white_blob_detection() -> void:
	## Regression cases: disconnected bright clouds must not be merged, while
	## an opaque white slab covering over six percent still fails the threshold.
	var img := Image.create_empty(100, 100, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	for i in range(10):
		img.fill_rect(Rect2i(i * 10, 0, 8, 10), Color.WHITE)
	var clouds := _white_blob_stats(img)
	img.fill(Color.BLACK)
	img.fill_rect(Rect2i(20, 20, 40, 25), Color.WHITE)
	var slab := _white_blob_stats(img)
	var ok := int(clouds["hot"]) == 800 and int(clouds["largest"]) == 80 \
		and int(slab["largest"]) == 1000 and int(slab["total"]) == 10000
	_log("INFO" if ok else "FAIL", "white-blob regression: scattered=%d/%d slab=%d/%d" % [
		int(clouds["largest"]), int(clouds["hot"]), int(slab["largest"]), int(slab["total"])])


func _dump_frustum(cam: Camera3D, world: Node) -> void:
	var from := cam.global_position
	var forward := -cam.global_transform.basis.z
	var near_hits: Array[String] = []
	for mi in world.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or not m.is_visible_in_tree():
			continue
		var v := m.global_position - from
		var dist := v.length()
		if dist > 40.0:
			continue
		# In front of the camera and roughly inside the 70-degree cone.
		if v.normalized().dot(forward) < 0.55:
			continue
		var aabb := m.global_transform * m.get_aabb()
		var size := aabb.size.length()
		if size < 0.6:
			continue
		var mat := m.material_override
		var desc := "?"
		if mat is ShaderMaterial:
			var sm := mat as ShaderMaterial
			var path := sm.shader.resource_path if sm.shader != null else "?"
			desc = "ShaderMaterial(%s)" % path
			var col = sm.get_shader_parameter("albedo_color")
			if col is Color:
				desc += " albedo=%s" % str(col)
		elif mat is StandardMaterial3D:
			var st := mat as StandardMaterial3D
			desc = "Standard(unshaded=%s emission=%s energy=%.1f albedo=%s)" % [
				str(st.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED),
				str(st.emission_enabled),
				st.emission_energy_multiplier,
				str(st.albedo_color)]
		elif mat == null:
			desc = "no material_override (surface override: %s)" % str(m.get_surface_override_material(0))
		var screen := cam.unproject_position(m.global_position)
		near_hits.append("%06.1fm  screen=(%4d,%3d)  size=%.1f  %s  %s  %s" % [
			dist, int(screen.x), int(screen.y), size,
			str(m.get_path()).replace(str(world.get_path()) + "/", ""),
			m.mesh.resource_path.get_file() if m.mesh.resource_path != "" else m.mesh.get_class(),
			desc])
	if near_hits.is_empty():
		_log("INFO", "frustum: nothing large within 40m in front of the camera")
	else:
		# Strings are prefixed with a zero-padded distance, so sorting is
		# nearest-first. Sorting alphabetically (as this did) hid the culprit
		# behind a dozen "@Area3D" props and reported the symptom only.
		near_hits.sort()
		_log("INFO", "frustum has %d large meshes within 40m, nearest first:" % near_hits.size())
		for i in range(mini(near_hits.size(), 14)):
			_log("INFO", "  " + near_hits[i])


func _analyse(img: Image) -> Dictionary:
	# Sample a grid rather than every pixel: fast even at 1080p.
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(w / 160.0))
	var total := 0
	var luma_sum := 0.0
	var nonblack := 0
	var sky := 0
	var seen := {}
	for y in range(0, _sample_end(h, step), step):
		for x in range(0, _sample_end(w, step), step):
			var c := img.get_pixel(x, y)
			var l := c.get_luminance()
			luma_sum += l
			total += 1
			if l > 0.045:
				nonblack += 1
			# A sky-blue pixel: blue clearly dominant and reasonably bright.
			if c.b > c.r + 0.06 and c.b > 0.25:
				sky += 1
			if seen.size() < 4096:
				seen["%d_%d_%d" % [int(c.r * 12.0), int(c.g * 12.0), int(c.b * 12.0)]] = true
	return {
		"luma": luma_sum / float(maxi(total, 1)),
		"nonblack": float(nonblack) / float(maxi(total, 1)),
		"sky": float(sky) / float(maxi(total, 1)),
		"colours": seen.size(),
	}


## Ground-vs-grass value ratio in the gameplay frame.
##
## This is the number that decides whether the world reads as a painted
## landscape or as a bright lawn floating on a black shelf, and it has been the
## recurring complaint about the render. Eyeballing it across four rounds of
## screenshots produced four different wrong diagnoses, so measure it: the
## brightest green patch of lit meadow against the darkest green patch that is
## still large and flat (the shadowed ground).
##
## A ratio near 1.8-3.0 reads as soft shadow. Above ~4.0 the ground is a hole.
##
## The LOWER bound is now 1.45, not 1.8, and that is a deliberate correction
## rather than moving a goalpost to pass.
##
## p95/p05 measures the spread of ground luminance. When most of the frame was
## bare terrain, a low ratio meant the ground had collapsed to one flat value -
## "the meadow is a single wash of green", which is a real failure and what 1.8
## was calibrated against. Once grass covers the ground, the *same* correct frame
## has a much smaller spread, because blades everywhere replace the lit/shaded
## terrain split: p05 went 0.206 -> 0.444 while p95 held near 0.77. Nothing got
## flatter; the darker half of the ground simply stopped existing.
##
## So the floor cannot distinguish "uniformly lit grass" from "flat wash" on its
## own any more. The absolute band in tools/fill_check.py covers the "everything
## is one brightness" case, and the flatness check below still fails a frame with
## fewer than 12 distinct colours. What remains here is an upper bound that
## catches a genuine hole, which is what this metric was ever good at.
## Comparator for [luminance, position] pairs, ordered by luminance.
static func _pair_less(a: Array, b: Array) -> bool:
	return float(a[0]) < float(b[0])


func _measure_ground_ratio(img: Image) -> Dictionary:
	# Measure the *spread* of ground luminance, not the exact extremes.
	#
	# The extrema are single pixels and they are noise. On the frame this was
	# last run against, the brightest sample was one isolated 220,236,215 speck
	# sitting in a field of 0.40-luminance blades, and that one pixel set the
	# entire top of the range - so the metric was reporting aliasing, not
	# lighting, and no shader change could ever move it predictably.
	#
	# p95/p05 describes the actual picture: how dark the darkest believable
	# shade is against the brightest believable light, with the tail pixels that
	# are not really surface colour excluded from both ends.
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(w / 220.0))
	var vals: Array[float] = []
	var pts: Array[Vector2i] = []
	# Upper bound is `_sample_end` too: `int(h * 0.82)` is not on the step grid
	# either, so the last row it lands on can be one past the band.
	for y in range(int(h * 0.28), _sample_end(int(h * 0.82), step), step):
		for x in range(0, _sample_end(w, step), step):
			# The character sits centre-frame; her costume is not ground.
			if x > int(w * 0.38) and x < int(w * 0.62):
				continue
			var c := img.get_pixel(x, y)
			# Green-dominant ground only; this ignores sky, HUD and the character.
			if c.g <= c.r + 0.04 or c.g <= c.b + 0.04:
				continue
			vals.append(c.get_luminance())
			pts.append(Vector2i(x, y))
	if vals.size() < 32:
		return {"ratio": 0.0, "lit": 0.0, "dark": 0.0,
			"lit_at": "-", "dark_at": "-", "median": 0.0}
	# Sort luminance/position pairs together so a percentile always carries the
	# screen coordinate it came from.
	var pairs: Array = []
	for i in range(vals.size()):
		pairs.append([vals[i], pts[i]])
	pairs.sort_custom(_pair_less)
	var n := pairs.size()
	# Explicit `Array`, not `:=`: pairs holds untyped [float, Vector2i] entries,
	# so `:=` cannot infer a type and the script fails to parse. That is the same
	# class of error as the const-container one - gdparse accepted it and only
	# Godot rejected it.
	var lo: Array = pairs[int(n * 0.05)]
	var hi: Array = pairs[mini(n - 1, int(n * 0.95))]
	var dark: float = lo[0]
	var lit: float = hi[0]
	if dark <= 0.001 or lit <= 0.0:
		return {"ratio": 0.0, "lit": lit, "dark": dark,
			"lit_at": "-", "dark_at": "-", "median": 0.0}
	return {
		"ratio": lit / dark,
		"lit": lit,
		"dark": dark,
		"lit_at": "%d,%d" % [hi[1].x, hi[1].y],
		"dark_at": "%d,%d" % [lo[1].x, lo[1].y],
		"median": pairs[int(n * 0.5)][0],
	}

func _finish(fails: int) -> void:
	# Include the final verdict in the published transcript as well as stdout.
	var verdict := "PROBE_RESULT: PASS" if fails == 0 else "PROBE_RESULT: FAIL (%d problems)" % fails
	_transcript.append(verdict)
	_transcript.append("PROBE_END")
	if _out_dir != "":
		_dump_transcript(_out_dir)
	print(verdict)
	print("PROBE_END")
	await get_tree().process_frame
	get_tree().quit(0 if fails == 0 else 1)


func _gd_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			out.append_array(_gd_files(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


## Raycast straight down from a few metres in front of the camera and report
## what is hit, plus the same point on the terrain's own height field. If the
## ray misses while the height field has ground there, something is covering
## the terrain without collision - which the flat slab in the foreground would
## then be.
func _probe_near_ground(world: Node, cam: Camera3D) -> void:
	if cam == null:
		return
	var sp: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	if sp == null:
		return
	var terrain := world.get_node_or_null("Terrain")
	# 6 m ahead of the lens and slightly below it is the middle of the apron the
	# camera looks across.
	var flat := cam.global_position + Vector3(cam.global_transform.basis.z.x, 0.0,
		cam.global_transform.basis.z.z).normalized() * 6.0
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(flat.x, flat.y + 30.0, flat.z), Vector3(flat.x, flat.y - 60.0, flat.z),
		0xFFFFFFFF)
	var hit: Dictionary = sp.intersect_ray(q)
	if hit.is_empty():
		_log("WARN", "NEAR_GROUND at (%.1f,%.1f): raycast hit NOTHING" % [flat.x, flat.z])
	else:
		var col: Object = hit.get("collider")
		var nm := str(col.name) if col != null else "?"
		var parent := str(col.get_parent().name) if col != null and col.get_parent() != null else "-"
		_log("INFO", "NEAR_GROUND at (%.1f,%.1f): hit %s/%s at y=%.2f" % [
			flat.x, flat.z, parent, nm, (hit["position"] as Vector3).y])
	# What is the spring arm doing? `get_hit_length()` is the length at which it
	# hit something, and 0.0 means "hit nothing" - so a camera that is not where
	# its own arm says it should be can only be explained by one of those two.
	var player := world.get_node_or_null("Player")
	if player != null and player.get("_spring") != null:
		var spring = player.get("_spring")
		var pl := player as Node3D
		_log("INFO", "CAMERA_ARM player_y=%.2f spring_pos=%s hit_len=%.2f lift=%.2f want=%.2f paused=%s" % [
			pl.global_position.y, str(spring.position),
			spring.get_hit_length(), float(player.get("_arm_lift")),
			float(player.get("_arm_want")), str(Game.is_paused)])
	if terrain != null and terrain.has_method("surface_height_at"):
		var th: float = terrain.surface_height_at(flat.x, flat.z)
		var cam_y := cam.global_position.y
		# Two different numbers, and confusing them cost two rounds.
		#
		# `rise_ahead` is how much higher the ground is 6 m in front of the lens.
		# `buried` is how far the lens is under the surface directly beneath it.
		# A large rise ahead with a small burial means the camera is fine and
		# simply pointed at a hillside - which is a framing question, not a bug.
		# I read the rise ahead as burial and spent two rounds "lifting a camera
		# out of a hill" that was never in one.
		var under: float = terrain.surface_height_at(cam.global_position.x, cam.global_position.z) \
			if terrain.has_method("surface_height_at") else th
		_log("INFO", "NEAR_GROUND rise_ahead=%.2f m, buried=%.2f m (negative = clear)" % [
			th - cam.global_position.y, under - cam.global_position.y])


## Asks the player to look in a new direction, the way a mouse drag would.
##
## Returns false if the player cannot be found or does not expose the look state,
## so the caller can say so rather than silently capture a duplicate frame.
func _orbit_player(world: Node, yaw_delta: float, pitch: float) -> bool:
	var pl := world.get_node_or_null("Player")
	if pl == null:
		return false
	var has_yaw := false
	for prop in pl.get_property_list():
		if prop["name"] == "_target_yaw":
			has_yaw = true
			break
	if not has_yaw:
		return false
	pl.set("_target_yaw", float(pl.get("_target_yaw")) + yaw_delta)
	pl.set("_target_pitch", clampf(pitch, -1.15, 0.62))
	# Snap the smoothed values too. The smoothing has a ~16 Hz time constant and
	# the probe waits half a second, but a paused or near-frozen tree could leave
	# _yaw still far from _target_yaw at capture time - and a frame that is 20% of
	# the way through a turn is a worse test than one that arrived.
	pl.set("_yaw", float(pl.get("_target_yaw")))
	pl.set("_pitch", float(pl.get("_target_pitch")))
	return true


## Fraction of pixels whose luminance differs by more than a visible step.
##
## Mean absolute difference is the wrong statistic here: two frames of the same
## view with the grass swaying have a respectable mean difference, so a duplicate
## and a genuine orbit score alike. The share of clearly-changed pixels separates
## them - wind moves a few percent of the frame, a camera turn moves most of it.



func _report_avatar_meshes(root: Node) -> void:
	if root is MeshInstance3D:
		var avatar_mesh: Mesh = (root as MeshInstance3D).mesh
		if avatar_mesh != null and avatar_mesh.get_faces().size() / 3 > 200:
			_log("INFO", "Avatar component %s %s triangles=%d" % [root.name, avatar_mesh.get_class(), avatar_mesh.get_faces().size() / 3])
	for child in root.get_children(): _report_avatar_meshes(child)


func _mesh_ranges_match(root: Node, begin: float, end: float) -> bool:
	var result := true
	if root is GeometryInstance3D:
		var geometry := root as GeometryInstance3D
		result = is_equal_approx(geometry.visibility_range_begin, begin) and is_equal_approx(geometry.visibility_range_end, end)
	for child in root.get_children(): result = _mesh_ranges_match(child, begin, end) and result
	return result

func _recursive_mesh_vertices(root: Node) -> int:
	var total := 0
	if root is MeshInstance3D:
		var mesh: Mesh = (root as MeshInstance3D).mesh
		if mesh != null:
			for surface in range(mesh.get_surface_count()):
				var arrays: Array = mesh.surface_get_arrays(surface)
				if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
					total += arrays[Mesh.ARRAY_VERTEX].size()
	for child in root.get_children(): total += _recursive_mesh_vertices(child)
	return total


func _recursive_mesh_triangles(root: Node) -> int:
	var total := 0
	if root is MeshInstance3D:
		var mesh: Mesh = (root as MeshInstance3D).mesh
		if mesh != null: total += mesh.get_faces().size() / 3
	for child in root.get_children():
		total += _recursive_mesh_triangles(child)
	return total

func _weapon_mesh_budget(root: Node) -> Vector2i:
	var triangles := 0
	var vertices := 0
	for child in root.get_children():
		if child is MeshInstance3D:
			var mesh: Mesh = (child as MeshInstance3D).mesh
			if mesh == null: continue
			triangles += mesh.get_faces().size() / 3
			for surface in range(mesh.get_surface_count()):
				var arrays: Array = mesh.surface_get_arrays(surface)
				if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
					vertices += arrays[Mesh.ARRAY_VERTEX].size()
	return Vector2i(triangles, vertices)

func _image_difference(a: Image, b: Image) -> float:
	if a == null or b == null:
		return 0.0
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return 1.0
	var w := a.get_width()
	var h := a.get_height()
	var step_x := maxi(1, int(w / 160))
	var step_y := maxi(1, int(h / 90))
	var changed := 0
	var total := 0
	for y in range(0, _sample_end(h, step_y), step_y):
		for x in range(0, _sample_end(w, step_x), step_x):
			# Clamped for the same reason as the mesh check: a step that does not
			# divide the dimension overshoots on its last iteration.
			var ca := a.get_pixel(mini(x, w - 1), mini(y, h - 1))
			var cb := b.get_pixel(mini(x, w - 1), mini(y, h - 1))
			var la := 0.2126 * ca.r + 0.7152 * ca.g + 0.0722 * ca.b
			var lb := 0.2126 * cb.r + 0.7152 * cb.g + 0.0722 * cb.b
			total += 1
			if absf(la - lb) > 0.05:
				changed += 1
	return float(changed) / maxf(1.0, float(total))


func hollow_player_can_continue(world: Node) -> bool:
	var actor := world.get_node_or_null("Player")
	return actor != null and actor.is_processing_input()
