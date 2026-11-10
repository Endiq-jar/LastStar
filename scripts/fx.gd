extends RefCounted
## Lightweight, allocation-friendly combat/VFX helpers.
##
## Mobile budget: no screen-space particles for the small stuff. We animate a
## handful of unshaded meshes tweened by GDScript, which reads as crisp anime
## VFX and costs almost nothing on a phone GPU.

static func _add(parent: Node, node: Node3D) -> void:
	parent.add_child(node)


static func _unshaded(color: Color, energy: float = 3.0, additive: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	# Emission is clamped well below 1.0 per channel. Passing the requested
	# energy straight through meant every effect that asked for 3-4x clipped to
	# pure white, so all element colours came out identical and the VFX read as
	# flat white shards. Glow supplies the brightness; the colour has to survive.
	m.emission = Color(minf(color.r, 0.85), minf(color.g, 0.85), minf(color.b, 0.85))
	m.emission_energy_multiplier = energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return m


static func sparkle(parent: Node, pos: Vector3, color: Color, scale: float = 1.0) -> void:
	if parent == null:
		return
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.05
	mesh.height = 0.1
	mesh.radial_segments = 4
	mesh.rings = 2
	mi.mesh = mesh
	var mat := _unshaded(Color(color.r, color.g, color.b, 0.95), 3.5, true)
	mi.material_override = mat
	mi.position = pos + Vector3(randf_range(-0.3, 0.3), randf_range(-0.2, 0.4), randf_range(-0.3, 0.3))
	mi.scale = Vector3.ONE * scale
	_add(parent, mi)

	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "position", mi.position + Vector3(randf_range(-0.6, 0.6), randf_range(0.6, 1.4), randf_range(-0.6, 0.6)), 0.85)
	tw.tween_property(mi, "scale", Vector3.ONE * 0.05, 0.85)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.85)
	tw.chain().tween_callback(mi.queue_free)


static func dust_puff(parent: Node, pos: Vector3, color: Color) -> void:
	if parent == null:
		return
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.55
	mesh.bottom_radius = 0.75
	mesh.height = 0.18
	mesh.radial_segments = 12
	mi.mesh = mesh
	var mat := _unshaded(color, 0.0)
	mi.material_override = mat
	mi.position = pos + Vector3(0, 0.08, 0)
	_add(parent, mi)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(2.4, 1.0, 2.4), 0.45)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(mi.queue_free)


static func slash(parent: Node, pos: Vector3, forward: Vector3, color: Color, combo: int) -> void:
	if parent == null:
		return
	var root := Node3D.new()
	root.position = pos
	if forward.length() > 0.01:
		root.look_at(pos + forward, Vector3.UP)
	_add(parent, root)

	var mi := MeshInstance3D.new()
	var arc := TorusMesh.new()
	arc.inner_radius = 0.55
	arc.outer_radius = 1.15
	arc.rings = 18
	arc.ring_segments = 4
	mi.mesh = arc
	var mat := _unshaded(Color(color.r, color.g, color.b, 0.9), 2.6, true)
	mi.material_override = mat
	mi.rotation_degrees = Vector3(90, 0, 0)
	if combo == 1:
		mi.rotation_degrees = Vector3(90, 0, 70)
	elif combo == 2:
		mi.rotation_degrees = Vector3(90, 0, -45)
	root.add_child(mi)
	root.scale = Vector3(0.35, 0.35, 0.35)

	var tw := root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(root, "scale", Vector3.ONE, 0.12)
	tw.tween_property(root, "scale:x", 3.2, 0.22).set_delay(0.1)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.32).set_delay(0.06)
	tw.chain().tween_callback(root.queue_free)


static func element_burst(parent: Node, pos: Vector3, color: Color, element: int) -> void:
	if parent == null:
		return
	ring_burst(parent, pos, color, 2.4)
	for i in range(9):
		var a := TAU * float(i) / 9.0
		var orb := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.13
		mesh.height = 0.26
		mesh.radial_segments = 6
		mesh.rings = 3
		orb.mesh = mesh
		var mat := _unshaded(Color(color.r, color.g, color.b, 0.95), 4.0, true)
		orb.material_override = mat
		orb.position = pos
		_add(parent, orb)
		var target := pos + Vector3(cos(a), 0.2 + sin(a * 2.0) * 0.2, sin(a)) * 3.6
		var tw := orb.create_tween()
		tw.set_parallel(true)
		tw.tween_property(orb, "position", target, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color:a", 0.0, 0.6)
		tw.chain().tween_callback(orb.queue_free)


static func ring_burst(parent: Node, pos: Vector3, color: Color, radius: float) -> void:
	if parent == null:
		return
	var mi := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.35
	mesh.outer_radius = 0.5
	mesh.rings = 20
	mesh.ring_segments = 4
	mi.mesh = mesh
	var mat := _unshaded(Color(color.r, color.g, color.b, 0.95), 3.0, true)
	mi.material_override = mat
	mi.position = pos
	_add(parent, mi)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * (radius / 0.5), 0.42)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tw.chain().tween_callback(mi.queue_free)


static func shockwave(parent: Node, pos: Vector3, color: Color) -> void:
	if parent == null:
		return
	ring_burst(parent, pos, color, 7.0)
	dust_puff(parent, pos, Color(0.9, 0.92, 0.95, 0.5))
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 6.0
	light.omni_range = 9.0
	light.shadow_enabled = false
	light.position = pos + Vector3(0, 0.6, 0)
	_add(parent, light)
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.4)
	tw.tween_callback(light.queue_free)


static func ultimate(parent: Node, pos: Vector3, color: Color, element: int) -> void:
	if parent == null:
		return
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 12.0
	light.omni_range = 20.0
	light.shadow_enabled = false
	light.position = pos + Vector3(0, 1.5, 0)
	_add(parent, light)
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 1.2)

	for i in range(28):
		var a := TAU * float(i) / 28.0
		var orb := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.16 + randf() * 0.1
		mesh.height = 0.4
		mesh.radial_segments = 5
		mesh.rings = 2
		orb.mesh = mesh
		var mat := _unshaded(Color(color.r, color.g, color.b, 1.0), 5.0, true)
		orb.material_override = mat
		orb.position = pos + Vector3(cos(a) * 0.6, 0.2 + randf() * 2.0, sin(a) * 0.6)
		_add(parent, orb)
		var radius := 5.0 + randf() * 6.0
		var target := pos + Vector3(cos(a) * radius, randf_range(-0.5, 3.0), sin(a) * radius)
		var ot := orb.create_tween()
		ot.set_parallel(true)
		ot.tween_property(orb, "position", target, 0.9).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		ot.tween_property(mat, "albedo_color:a", 0.0, 1.1)
		ot.chain().tween_callback(orb.queue_free)

	# A pillar of light straight up (very Genshin burst).
	var pillar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 2.8
	cyl.height = 18.0
	cyl.radial_segments = 18
	pillar.mesh = cyl
	var pmat := _unshaded(Color(color.r, color.g, color.b, 0.55), 2.5, true)
	pillar.material_override = pmat
	pillar.position = pos + Vector3(0, 9.0, 0)
	_add(parent, pillar)
	var pt := pillar.create_tween()
	pt.set_parallel(true)
	pt.tween_property(pillar, "scale", Vector3(0.2, 1.0, 0.2), 0.9)
	pt.tween_property(pmat, "albedo_color:a", 0.0, 1.0)
	pt.chain().tween_callback(pillar.queue_free)


static func hit_flash(parent: Node, pos: Vector3, color: Color) -> void:
	if parent == null:
		return
	for i in range(6):
		sparkle(parent, pos, color, 1.4)
	var mi := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.6, 0.6)
	mi.mesh = mesh
	var mat := _unshaded(color, 4.0, true)
	mi.material_override = mat
	mi.position = pos
	_add(parent, mi)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(2.5, 2.5, 1.0), 0.2)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.24)
	tw.chain().tween_callback(mi.queue_free)


static func heal_burst(parent: Node, pos: Vector3, color: Color) -> void:
	if parent == null:
		return
	ring_burst(parent, pos, color, 3.4)
	for i in range(6):
		sparkle(parent, pos + Vector3(randf_range(-0.8, 0.8), randf_range(0.2, 1.6), randf_range(-0.8, 0.8)), color, 1.6)


static func seed_sparkle(parent: Node, pos: Vector3, color: Color) -> void:
	## Floating collectible shimmer, called every frame-ish by pickups.
	sparkle(parent, pos, color, 0.7)


static func elemental_damage_number(parent: Node, pos: Vector3, amount: float, color: Color) -> void:
	if parent == null:
		return
	var label := Label3D.new()
	label.text = str(int(round(amount)))
	label.modulate = color
	label.outline_modulate = Color(0.05, 0.05, 0.1, 0.9)
	label.outline_size = 12
	label.font_size = 96
	label.pixel_size = 0.004
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position = pos
	_add(parent, label)
	var tw := label.create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "position", pos + Vector3(randf_range(-0.4, 0.4), 1.6, 0), 0.7)
	tw.tween_property(label, "modulate:a", 0.0, 0.8)
	tw.chain().tween_callback(label.queue_free)
