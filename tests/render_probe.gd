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
	print("PROBE_FAIL: probe timed out after 120s (no frames were drawn)")
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

	# Resolution controller must reduce load when slow, recover when fast, and
	# leave High alone. This tests its hysteresis without depending on CI FPS.
	var slow: float = world.call("_next_dynamic_scale", 0, 0.9, 0.05)
	var fast: float = world.call("_next_dynamic_scale", 0, 0.8, 0.02)
	var stable: float = world.call("_next_dynamic_scale", 0, 0.8, 0.033)
	var high: float = world.call("_next_dynamic_scale", 2, 1.0, 0.05)
	_log("INFO" if is_equal_approx(slow, 0.85) and is_equal_approx(fast, 0.85) and is_equal_approx(stable, 0.8) and is_equal_approx(high, 1.0) else "FAIL",
		"dynamic resolution slow=%.2f fast=%.2f stable=%.2f high=%.2f" % [slow, fast, stable, high])
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
		var center: Vector2i = grass.get("_last_center")
		var checked_tier := false
		for key in live_chunks.keys():
			if int(grass.call("_tier_for_chunk", key, center)) == 0:
				var chunk: Node = live_chunks[key]
				chunk.set_meta("grass_tier", 2)
				grass.call("_queue_around", center)
				checked_tier = not live_chunks.has(key)
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
		menu.call("close_menu")
		_log("INFO" if screens_ok and not Game.is_paused else "FAIL", "offline adventure screens and close: %s" % str(screens_ok))
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
	Game.call("_refresh_quest")
	_log("INFO" if story_ok and no_duplicate and drop_ok else "FAIL", "story persistence=%s duplicate prevention=%s drop recovery=%s" % [str(story_ok), str(no_duplicate), str(drop_ok)])
	var old_jump: int = Game.key_for_action("jump")
	var settings_ok := Game.rebind_action("jump", KEY_K) and Game.key_for_action("jump") == KEY_K and not Game.rebind_action("move_forward", KEY_K) and Game.rebind_action("jump", old_jump)
	_log("INFO" if settings_ok else "FAIL", "key remapping and conflict prevention: %s" % str(settings_ok))

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

	# Capture every gameplay journal page, including the bottom of scrollable
	# pages. These are real UI states, not mockups or stitched images.
	if menu != null:
		for page in ["Inventory", "Character", "Quests", "Wish", "Level Up", "Story"]:
			menu.call("open_menu", page)
			await _capture_ui(out_dir, "game_" + page.to_lower().replace(" ", "_"), menu)
			menu.call("close_menu")
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
	Game.set_quality_tier(2)
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
	if passes >= 1 and visible < 1:
		_log("FAIL", "ENTITY_CULL everything is hidden - the visibility test rejects the whole world")
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
	# Always leave the transcript behind, whichever path reached here.
	if _out_dir != "":
		_dump_transcript(_out_dir)
	if fails == 0:
		print("PROBE_RESULT: PASS")
	else:
		print("PROBE_RESULT: FAIL (%d problems)" % fails)
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
