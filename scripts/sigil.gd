extends Area3D
## Star Sigil collectible: a slowly spinning starburst crystal with a glow
## halo, sparkle trail and pickup burst. Collect all 12 to finish the run.

const FX := preload("res://scripts/fx.gd")

var _mesh: Node3D
var _halo: MeshInstance3D
var _halo_mat: StandardMaterial3D
var _sparkle_timer := 2.5
var _picked := false
var _time := 0.0
var _color := Color(1.0, 0.86, 0.45)


func _ready() -> void:
	collision_layer = 4
	collision_mask = 2
	monitoring = true
	add_to_group("sigil")

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.6
	shape.shape = sphere
	add_child(shape)

	_mesh = Node3D.new()
	_mesh.position = Vector3(0, 0.4, 0)
	add_child(_mesh)

	var core := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.6, 1.3, 0.6)
	core.mesh = prism
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = Color(_color.r, _color.g, _color.b, 0.9)
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.emission_enabled = true
	core_mat.emission = _color
	core_mat.emission_energy_multiplier = 2.4
	core_mat.roughness = 0.1
	core_mat.metallic = 0.6
	core.material_override = core_mat
	_mesh.add_child(core)

	# Four orbiting shards make the sigil read from far away.
	for i in range(4):
		var shard := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.09, 0.34, 0.09)
		shard.mesh = box
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(1, 1, 1, 1)
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.emission_enabled = true
		sm.emission = _color
		sm.emission_energy_multiplier = 3.0
		shard.material_override = sm
		var a := TAU * float(i) / 4.0
		shard.position = Vector3(cos(a) * 0.85, 0.0, sin(a) * 0.85)
		_mesh.add_child(shard)

	var halo := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.0
	torus.outer_radius = 1.12
	torus.rings = 24
	torus.ring_segments = 4
	halo.mesh = torus
	var hm := StandardMaterial3D.new()
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hm.albedo_color = Color(_color.r, _color.g, _color.b, 0.6)
	hm.emission_enabled = true
	hm.emission = _color
	hm.emission_energy_multiplier = 2.0
	hm.cull_mode = BaseMaterial3D.CULL_DISABLED
	halo.material_override = hm
	halo.rotation_degrees = Vector3(24, 0, 0)
	_mesh.add_child(halo)
	_halo = halo
	_halo_mat = hm

	# No per-sigil OmniLight3D.
	#
	# Each sigil used to carry a real-time point light. There are twelve of them
	# in the valley at once, and this renderer is `gl_compatibility`, which has no
	# clustered light path: every forward-lit object evaluates every light that
	# reaches it, per pixel. Twelve extra lights is a large, permanent cost paid
	# on every blade of grass, every tree and every metre of terrain in the
	# valley, all to make a 0.4 m crystal look bright.
	#
	# The halo below is already an emissive, additive, unshaded quad - it reads as
	# glow without lighting anything. The pulse that used to drive the light now
	# drives the halo's emission energy and scale instead, which costs one uniform
	# write and no lighting pass.

	body_entered.connect(_on_body_entered)
	_time = randf() * TAU


func _process(delta: float) -> void:
	if _picked:
		return
	_time += delta
	_mesh.rotation.y += delta * 1.4
	_mesh.position.y = 0.4 + sin(_time * 1.8) * 0.22
	# Drive the halo instead of the (now removed) light.
	if _halo != null and is_instance_valid(_halo):
		var pulse := 1.9 + sin(_time * 2.6) * 0.5
		_halo.scale = Vector3.ONE * (0.94 + 0.06 * sin(_time * 2.6))
		if _halo_mat != null:
			_halo_mat.emission_energy_multiplier = pulse
	# The sparkle burst was fired twice a second, per sigil. Each call allocates
	# particle nodes and then frees them, so twelve sigils were spawning and
	# destroying roughly 24 bursts a second for the whole session - a steady drip
	# of allocations and scene-tree churn that only ever showed up as stutter.
	# It is now one burst every 2.5 s, which reads as the same ambient twinkle.
	_sparkle_timer -= delta
	if _sparkle_timer <= 0.0:
		_sparkle_timer = 2.5
		FX.sparkle(get_parent(), global_position + Vector3(0, 0.8, 0), _color, 0.8)


func _on_body_entered(body: Node3D) -> void:
	if _picked or not body.is_in_group("player"):
		return
	_picked = true
	# Stop ticking this node entirely. The tween below still animates it away,
	# but there is no reason to keep running sin() and a smoke check every frame
	# for a sigil that no longer exists in the world.
	set_process(false)
	Game.collect_sigil()
	FX.heal_burst(get_parent(), global_position + Vector3(0, 0.8, 0), _color)
	_play_chime()
	var amb := get_tree().get_first_node_in_group("ambience")
	if amb and amb.has_method("play_waypoint"):
		amb.play_waypoint()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_mesh, "scale", Vector3.ZERO, 0.4)
	tw.chain().tween_callback(queue_free)


func _play_chime() -> void:
	var player := AudioStreamPlayer3D.new()
	player.stream = _make_chime()
	player.volume_db = -4.0
	player.max_distance = 40.0
	get_parent().add_child(player)
	player.global_position = global_position
	player.play()
	player.finished.connect(player.queue_free)


func _make_chime() -> AudioStreamWAV:
	var rate := 22050
	var duration := 0.5
	var n := int(rate * duration)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var t := float(i) / float(rate)
		var env := exp(-t * 5.0)
		var s := (sin(TAU * 880.0 * t) * 0.4 + sin(TAU * 1320.0 * t) * 0.24 + sin(TAU * 1760.0 * t) * 0.12) * env
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = data
	return stream
