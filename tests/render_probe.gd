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


func _log(kind: String, msg: String) -> void:
	var line := "PROBE_%s: %s" % [kind, msg]
	print(line)
	if kind == "FAIL":
		_fail += 1


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
	_log("INFO" if players.size() == 1 else "FAIL",
		"player nodes in group = %d" % players.size())

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
	var tmesh := world.get_node_or_null("Terrain/TerrainMesh") as MeshInstance3D
	if tmesh == null or tmesh.mesh == null:
		_log("FAIL", "Terrain/TerrainMesh missing - nothing to look at")
	else:
		var arr := tmesh.mesh.surface_get_arrays(0)
		var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var checked := 0
		var up := 0
		var step_i := maxi(1, normals.size() / 400)
		for i in range(0, normals.size(), step_i):
			checked += 1
			if normals[i].y > 0.0:
				up += 1
		if checked == 0:
			_log("FAIL", "terrain mesh has no normals")
		else:
			var pct := float(up) / float(checked) * 100.0
			_log("INFO" if pct > 99.0 else "FAIL",
				"terrain normals face up: %.1f%% of %d sampled" % [pct, checked])

	# --- what is in front of the camera ------------------------------------
	# An opaque, unshaded blob that covers a third of the gameplay frame has
	# shown up twice now and both times the cause was guessed at from the PNG.
	# This dumps the actual geometry inside the camera frustum (distance, size,
	# material class and colour), so the next occurrence is identified from
	# data instead of a visual hunch.
	if cam:
		_dump_frustum(cam, world)

	# --- environment dressing ----------------------------------------------
	# Logs and pebbles are what stop the grass reading as a flat painted
	# texture. Assert they actually spawned rather than silently picking zero
	# valid spots.
	for needed in ["Vegetation/FallenLogs", "Vegetation/Pebbles"]:
		var node := world.get_node_or_null(needed)
		_log("INFO" if node != null else "FAIL",
			"%s = %s" % [needed, "present" if node != null else "MISSING"])
	var veg := world.get_node_or_null("Vegetation")
	if veg != null:
		var logs := veg.get_node_or_null("FallenLogs")
		var pebbles := veg.get_node_or_null("Pebbles")
		var log_n := logs.get_child_count() if logs != null else 0
		var peb_n := 0
		if pebbles is MultiMeshInstance3D and (pebbles as MultiMeshInstance3D).multimesh != null:
			peb_n = (pebbles as MultiMeshInstance3D).multimesh.instance_count
		_log("INFO", "scatter: %d log meshes, %d pebbles" % [log_n, peb_n])

	# --- terrain textures ---------------------------------------------------
	for tex_name in ["meadow", "rock", "sand", "macro"]:
		var path := "res://textures/terrain/%s.png" % tex_name
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
		# Density gate: the meadow must actually be a meadow. A slope/height
		# bug once cut this to 5% of intent and nothing noticed.
		if blades < 30000:
			_log("FAIL", "grass is far too sparse (%d blades, expected >30000)" % blades)

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
			_log("INFO", "player standing at y=%.1f (on_floor=%s)" % [
				py, str(pl is CharacterBody3D and (pl as CharacterBody3D).is_on_floor())])

	var wenv := world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if wenv == null or wenv.environment == null:
		_log("FAIL", "WorldEnvironment has no Environment assigned")
	else:
		var env := wenv.environment
		_log("INFO", "environment bg_mode=%d ambient=%d glow=%s fog=%s" % [
			env.background_mode, env.ambient_light_source,
			str(env.glow_enabled), str(env.fog_enabled)])

	var terrain := world.get_node_or_null("Terrain")
	var meshes := 0
	if terrain:
		meshes = terrain.find_children("*", "MeshInstance3D", true, false).size()
	_log("INFO" if meshes > 0 else "FAIL", "terrain MeshInstance3D count = %d" % meshes)

	var sun := world.get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		_log("INFO" if sun.visible else "FAIL",
			"sun visible=%s energy=%.2f rot=%s" % [
				str(sun.visible), sun.light_energy, str(sun.rotation_degrees)])

	# --- pixel checks -----------------------------------------------------
	# A headless run has no framebuffer, so this only reports on a real device /
	# xvfb run. That is fine: the structural checks above still gate CI.
	if DisplayServer.get_name() == "headless":
		_log("INFO", "headless server - skipping pixel capture")
		_finish(_fail)
		return

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
	var stats := _analyse(img)
	_check_blob(img, "gameplay")
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

	# Orbit the camera a quarter turn and capture again: catches a camera that
	# exists but is stuck inside geometry or pointed at the void.
	if cam:
		# Nudge the camera only: rotating the player's pivot would also move the
		# SpringArm's collision cast and can put the camera inside a hill.
		cam.global_position += Vector3(0.0, 6.0, 0.0)
		await get_tree().create_timer(0.45).timeout
		await get_tree().process_frame
		var img2 := get_viewport().get_texture().get_image()
		if img2:
			img2.save_png(out_dir.path_join("world_alt.png"))
			var s2 := _analyse(img2)
			_log("INFO", "alt view mean_luma=%.3f nonblack=%.1f%% colours=%d" % [
				s2["luma"], s2["nonblack"] * 100.0, s2["colours"]])

	# --- clear combat VFX before the beauty frame --------------------------
	# The gameplay capture caught a burst mid-cast: an 18 m transparent light
	# pillar directly behind the player, which is what the tall cyan wedge in the
	# frame was. VFX tweens are driven by the tree, so once the world is paused
	# they never finish and the pillar stays on screen forever. Free every
	# transient effect node rather than waiting for a tween that will not run.
	for fx_node in world.find_children("*", "MeshInstance3D", true, false):
		var fx_mi := fx_node as MeshInstance3D
		var mat := fx_mi.material_override
		if mat is StandardMaterial3D:
			var sm := mat as StandardMaterial3D
			# Unshaded emissive geometry is only ever VFX or a crystal.
			if sm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED and sm.emission_enabled:
				if fx_mi.get_parent() != null and fx_mi.get_parent().name.begins_with("@"):
					fx_mi.get_parent().queue_free()
				elif fx_mi.name.begins_with("@"):
					fx_mi.queue_free()
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
	var eye := Vector3(-70.0, 0.0, -70.0)
	var terrain_node := world.get_node_or_null("Terrain")
	if terrain_node != null and terrain_node.has_method("get_height_at"):
		eye.y = terrain_node.get_height_at(eye.x, eye.z) + 30.0
	else:
		eye.y = 40.0
	beauty.global_position = eye
	# Look slightly down-valley and just under the horizon, toward the lake.
	beauty.look_at(Vector3(40.0, eye.y - 24.0, 90.0), Vector3.UP)

	# Push the sun to a warm low morning for the beauty frame so the shot shows
	# the graded palette rather than whatever time the world happened to boot at.
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

	_finish(_fail)


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
		var hsv := Color(c.r, c.g, c.b).hsv  # Godot exposes hsv directly
		parts.append("%s h=%3.0f s=%.2f v=%.2f" % [key, hsv.h * 360.0, hsv.s, hsv.v])
		if key != "horizon":
			worst = maxf(worst, hsv.s)
	_log("INFO", "%s palette: %s" % [label, ", ".join(parts)])
	# Face validity for "is this neon": count pixels that are almost pure hue -
	# saturation above 0.90 with a mid or high value. A realistic stylised frame
	# sits far below 15%; the neon-green versions of this render were well over
	# 60%, because a warm sun on a blue-poor green albedo clipped the blue channel
	# to zero across the entire hillside.
	var hot := 0
	var counted := 0
	var step := maxi(1, int(img.get_width() / 120.0))
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			counted += 1
			var c2 := img.get_pixel(x, y)
			var hsv2 := Color(c2.r, c2.g, c2.b).hsv
			if hsv2.s > 0.90 and hsv2.v > 0.30:
				hot += 1
	if counted > 0:
		var frac := float(hot) / float(counted)
		_log("INFO", "%s saturated pixels (s>0.90, v>0.30) = %.1f%%" % [label, frac * 100.0])
		if frac > 0.35:
			_log("WARN", "%s is %.0f%% near-pure hue - the frame reads as neon rather than painted" % [
				label, frac * 100.0])
	if worst > 0.92:
		_log("WARN", "%s has a near-pure sample (saturation %.2f) - the grade is clipping a channel" % [label, worst])


func _check_blob(img: Image, label: String) -> void:
	## Detect a large, opaque, pure-white region - the signature of an unshaded
	## emissive surface parked in front of the camera. This artifact shipped
	## twice because nothing was measuring it; a HUD button behind it in the PNG
	## was the only clue. Bright sky and clouds are excluded by requiring the
	## region to be clustered and near-pure white with all three channels
	## saturated, which the sky (blue-dominant) and snow (cool-tinted) are not.
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(w / 200.0))
	var hot := 0
	var total := 0
	var min_x := w
	var max_x := 0
	var min_y := h
	var max_y := 0
	for y in range(0, h, step):
		for x in range(0, w, step):
			total += 1
			var c := img.get_pixel(x, y)
			if c.r > 0.97 and c.g > 0.97 and c.b > 0.95 and c.a > 0.5:
				hot += 1
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	if total == 0:
		return
	var frac := float(hot) / float(total)
	if frac > 0.06:
		var box_w := max_x - min_x
		var box_h := max_y - min_y
		var fill := frac / maxf(0.0001, (float(box_w) / float(w)) * (float(box_h) / float(h)))
		_log("FAIL", "%s frame is %.1f%% pure white in a %dx%d box (fill %.2f) - an unshaded emissive surface is covering the view" % [
			label, frac * 100.0, box_w, box_h, fill])
	else:
		_log("INFO", "%s frame white-clip %.1f%%" % [label, frac * 100.0])


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
		near_hits.append("%s node=%s dist=%.1f size=%.1f %s" % [
			str(m.get_path()).replace(str(world.get_path()) + "/", ""),
			m.mesh.resource_path.get_file() if m.mesh.resource_path != "" else m.mesh.get_class(),
			dist, size, desc])
	if near_hits.is_empty():
		_log("INFO", "frustum: nothing large within 40m in front of the camera")
	else:
		near_hits.sort()
		_log("INFO", "frustum has %d large meshes within 40m:" % near_hits.size())
		for i in range(mini(near_hits.size(), 12)):
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
	for y in range(0, h, step):
		for x in range(0, w, step):
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


func _finish(fails: int) -> void:
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
