extends RefCounted
## Builds anime-styled characters out of primitives, shaded by the toon shader
## with an inverted-hull outline pass. Returns the rig nodes the player script
## animates (arms, legs, torso, head, cape/wings, weapon anchor).
##
## Everything is generated in code: no external models, no licensed assets.

const TOON_SHADER := preload("res://shaders/anime_toon.gdshader")
const OUTLINE_SHADER := preload("res://shaders/outline.gdshader")


static func _toon(color: Color, rim: float = 0.35) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = TOON_SHADER
	m.set_shader_parameter("albedo_color", color)
	m.set_shader_parameter("shadow_tint", Color(0.46, 0.48, 0.70))
	# Cool, not white. A warm white rim on near-black cloth is a 1.0-value line on
	# a 0.13-value surface - it reads as a pale streak stuck to her shoulder, which
	# is exactly what it looked like on the first front-on portrait. A sky-tinted
	# rim reads as reflected environment light and still separates the silhouette.
	m.set_shader_parameter("rim_color", Color(0.66, 0.75, 1.0))
	# Rim and spec used to run at 0.7-0.8 strength with a 0.45 spec energy; on a
	# build made mostly of spheres every one of them picked up a broad highlight
	# plus a full rim ring, and the accumulated radiance washed the character out
	# to a white blob. The shader clamps these now, and the values fed in are
	# deliberately restrained.
	m.set_shader_parameter("rim_strength", minf(rim, 0.30))
	m.set_shader_parameter("diffuse_energy", 1.0)
	m.set_shader_parameter("spec_energy", 0.18)
	# Deliberately left at 0. Setting render_priority on an opaque material takes it
	# out of the opaque queue and sorts it with the transparent pass, and on the
	# Compatibility renderer that made the whole upper body stop rasterising while
	# its meshes still reported visible with correct bounds. Grass is cleared around
	# the character in the grass shader instead; that is the correct place for it.
	return m


static func _glow(color: Color, energy: float = 1.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


## Decorative layers sit a few millimetres off the body, so at the shadow map's
## resolution they cast a soft dark blob onto the surface underneath instead of a
## contact shadow: the hairpin painted a grey ellipse across the hair cap and the
## cape another across her chest, both plainly visible in the close-up. A toon
## character does not need self-shadowing - the ramp and the outline carry the
## form - so the small pieces opt out and only the body parts cast.
static func _no_shadow(mi: MeshInstance3D) -> MeshInstance3D:
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _add(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, node_name: String = "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	if node_name != "":
		mi.name = node_name
	parent.add_child(mi)
	return mi


## A short invisible outline copy is not needed for tiny props; we outline the
## big silhouette pieces only (torso, head, limbs) to keep the draw call count
## sane on mobile.
static func _outlined(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, width: float = 0.012) -> MeshInstance3D:
	var mi := _add(parent, mesh, mat, pos)
	var om := ShaderMaterial.new()
	om.shader = OUTLINE_SHADER
	om.set_shader_parameter("outline_width", width)
	om.set_shader_parameter("outline_color", Color(0.13, 0.11, 0.18, 1.0))
	var shell := MeshInstance3D.new()
	shell.mesh = mesh
	shell.material_override = om
	shell.name = "OutlineShell"
	mi.add_child(shell)
	return mi


static func build(host: Node3D, data: Dictionary) -> Dictionary:
	var visual := Node3D.new()
	visual.name = "Visual"
	host.add_child(visual)

	var skin_col: Color = data["skin"]
	var skin := _toon(skin_col)
	var hair_col: Color = data["hair"]
	var hair := _toon(hair_col, 0.5)
	var hair_tip_col: Color = data["hair_tip"]
	var hair_tip := _toon(hair_tip_col, 0.6)
	var outfit_col: Color = data["outfit"]
	var outfit := _toon(outfit_col)
	var accent_col: Color = data["outfit_accent"]
	var accent := _toon(accent_col, 0.45)
	var cape_col: Color = data["cape"]
	var cape_mat := _toon(cape_col, 0.7)
	var eye_col: Color = data["eye"]
	var eye := _glow(eye_col, 1.1)
	var element_col: Color = data["color"]
	var element_glow := _glow(element_col, 1.7)

	var torso := Node3D.new()
	torso.name = "Torso"
	visual.add_child(torso)

	# --- hips / skirt / torso ---------------------------------------------
	var skirt := CylinderMesh.new()
	skirt.top_radius = 0.20
	skirt.bottom_radius = 0.34
	skirt.height = 0.30
	skirt.radial_segments = 16
	_outlined(torso, skirt, accent, Vector3(0, 0.82, 0), 0.010)

	var chest := CapsuleMesh.new()
	chest.radius = 0.19
	chest.height = 0.56
	_outlined(torso, chest, outfit, Vector3(0, 1.18, 0), 0.009)

	# Was a 0.22 outer-radius hoop on a chest of radius 0.19 - a hula hoop floating
	# around her torso, which from the front rendered as a large grey donut sitting
	# on her sternum. Sized to actually ring the neck now.
	var collar := TorusMesh.new()
	collar.inner_radius = 0.105
	collar.outer_radius = 0.145
	collar.rings = 12
	collar.ring_segments = 8
	var collar_mi := _add(torso, collar, accent, Vector3(0, 1.44, 0))
	collar_mi.rotation_degrees = Vector3(90, 0, 0)
	_no_shadow(collar_mi)

	# Elemental crest on the chest.
	var crest := SphereMesh.new()
	crest.radius = 0.045
	crest.height = 0.09
	_no_shadow(_add(torso, crest, element_glow, Vector3(0, 1.30, -0.19)))

	# Belt + hanging cloth panels (a tiny bit of Genshin-ish silhouette).
	var belt := CylinderMesh.new()
	belt.top_radius = 0.21
	belt.bottom_radius = 0.21
	belt.height = 0.06
	_no_shadow(_add(torso, belt, _toon(Color(0.09, 0.08, 0.10)), Vector3(0, 0.99, 0)))
	for side in [-1.0, 1.0]:
		var panel := BoxMesh.new()
		panel.size = Vector3(0.12, 0.34, 0.03)
		var p := _no_shadow(_add(torso, panel, accent, Vector3(0.10 * side, 0.74, -0.26)))
		p.rotation_degrees = Vector3(8.0, 0.0, 3.0 * side)

	# --- head -------------------------------------------------------------
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 1.62, 0)
	torso.add_child(head)

	var skull := SphereMesh.new()
	skull.radius = 0.155
	skull.height = 0.30
	skull.radial_segments = 20
	skull.rings = 12
	# A thin outline on the head: at 0.012 the black hull around pale skin read as a
	# dark helmet rather than as a drawn contour.
	_outlined(head, skull, skin, Vector3.ZERO, 0.006)

	# Anime eyes: two glowing planes with a dark outline plane behind.
	#
	# They sit well forward of the skull surface on purpose. The head is a 0.155
	# sphere carrying an inverted-hull outline 0.006 thick, so the silhouette shell
	# reaches z = -0.149 at the eye line - and these quads were at -0.145, i.e.
	# *inside* it. The first face that rendered correctly was a completely blank
	# skin oval: the eyes had been there the whole time, behind the outline hull.
	# QuadMesh's front face points along +Z while the character faces -Z, so every
	# eye plane has to be yawed a half turn. Without it all three quads are
	# backface-culled and the face renders as a blank skin oval - which is exactly
	# how it looked, twice, while the meshes sat in the tree at the right position
	# with the right material.
	for side in [-1.0, 1.0]:
		var dark := QuadMesh.new()
		# Narrower than it was: at 0.092 the two backing quads nearly met over the
		# bridge of her nose and read as a pair of spectacles.
		dark.size = Vector2(0.078, 0.072)
		var dm := _glow(Color(0.09, 0.07, 0.11), 0.0)
		var d := _add(head, dark, dm, Vector3(0.058 * side, 0.005, -0.157))
		d.rotation_degrees = Vector3(0.0, 180.0, 0.0)

		var iris := QuadMesh.new()
		iris.size = Vector2(0.068, 0.062)
		var i := _add(head, iris, eye, Vector3(0.058 * side, 0.004, -0.161))
		i.rotation_degrees = Vector3(0.0, 180.0, 0.0)

		var shine := QuadMesh.new()
		shine.size = Vector2(0.020, 0.020)
		var sh := _add(head, shine, _glow(Color(1, 1, 1), 1.2), Vector3(0.066 * side, 0.020, -0.165))
		sh.rotation_degrees = Vector3(0.0, 180.0, 0.0)

	# A small mouth. Without one the face is an eye mask on a blank oval, which is
	# the difference between "anime girl" and "mannequin".
	var mouth := QuadMesh.new()
	mouth.size = Vector2(0.034, 0.011)
	var m := _add(head, mouth, _glow(Color(0.55, 0.26, 0.30), 0.0), Vector3(0.0, -0.079, -0.158))
	m.rotation_degrees = Vector3(0.0, 180.0, 0.0)

	# Hair: cap + bangs + side locks + long back.
	var cap := SphereMesh.new()
	cap.radius = 0.168
	cap.height = 0.28
	cap.is_hemisphere = true
	var cap_mi := _add(head, cap, hair, Vector3(0, 0.02, 0.01))
	cap_mi.scale = Vector3(1.06, 1.0, 1.08)
	cap_mi.rotation_degrees = Vector3(-8, 0, 0)

	# Bangs hang over the brow, not over the eyes.
	#
	# They used to be 0.20 tall centred 0.02 below the head origin, so they reached
	# y=-0.12 while the eyes sit at y=0.005: the fringe covered the entire face and
	# the first front-on portrait was a featureless black dome with a red fringe.
	# Shortened and raised so the fringe stops just above the brow line.
	for i in range(5):
		var bang := PrismMesh.new()
		bang.size = Vector3(0.075, 0.15, 0.05)
		var bx := -0.11 + 0.055 * i
		var b := _add(head, bang, hair if i % 2 == 0 else hair_tip, Vector3(bx, 0.075, -0.132))
		b.rotation_degrees = Vector3(6, 0, -14.0 + i * 7.0)

	for side in [-1.0, 1.0]:
		var lock := CapsuleMesh.new()
		lock.radius = 0.045
		lock.height = 0.42
		var l := _add(head, lock, hair_tip, Vector3(0.15 * side, -0.16, 0.0))
		l.rotation_degrees = Vector3(0, 0, 6.0 * side)

	var back_hair := CapsuleMesh.new()
	back_hair.radius = 0.13
	back_hair.height = 0.60
	_add(head, back_hair, hair, Vector3(0, -0.24, 0.09)).scale = Vector3(1.05, 1.0, 0.62)

	# A small hair ornament, not a halo.
	#
	# The old "hairpin" torus had a 0.165 outer radius against a hair cap of 0.168:
	# a ring the same diameter as her entire head, which from the front appeared as
	# a grey donut laid across the top of her hair. It was never a hairpin, and no
	# amount of shading was going to make it look like one.
	var ornament := SphereMesh.new()
	ornament.radius = 0.030
	ornament.height = 0.060
	_no_shadow(_add(head, ornament, element_glow, Vector3(0.115, 0.088, -0.055)))

	# --- arms -------------------------------------------------------------
	var arms: Array[Node3D] = []
	for side in [-1.0, 1.0]:
		var arm := Node3D.new()
		arm.name = "ArmL" if side < 0 else "ArmR"
		arm.position = Vector3(0.225 * side, 1.38, 0)
		torso.add_child(arm)
		var upper := CapsuleMesh.new()
		upper.radius = 0.055
		upper.height = 0.34
		_outlined(arm, upper, outfit, Vector3(0, -0.17, 0), 0.006)
		var glove := SphereMesh.new()
		glove.radius = 0.052
		_add(arm, glove, skin, Vector3(0, -0.36, 0))
		var cuff := TorusMesh.new()
		cuff.inner_radius = 0.05
		cuff.outer_radius = 0.075
		cuff.rings = 8
		cuff.ring_segments = 6
		var c := _no_shadow(_add(arm, cuff, accent, Vector3(0, -0.29, 0)))
		c.rotation_degrees = Vector3(90, 0, 0)
		arms.append(arm)

	# --- legs -------------------------------------------------------------
	var legs: Array[Node3D] = []
	for side in [-1.0, 1.0]:
		var leg := Node3D.new()
		leg.name = "LegL" if side < 0 else "LegR"
		leg.position = Vector3(0.095 * side, 0.80, 0)
		visual.add_child(leg)
		var thigh := CapsuleMesh.new()
		thigh.radius = 0.068
		thigh.height = 0.46
		_outlined(leg, thigh, skin, Vector3(0, -0.23, 0), 0.007)
		var boot := CapsuleMesh.new()
		boot.radius = 0.082
		boot.height = 0.40
		_add(leg, boot, accent, Vector3(0, -0.55, 0))

		var toe := BoxMesh.new()
		toe.size = Vector3(0.13, 0.09, 0.24)
		_add(leg, toe, _toon(Color(0.11, 0.09, 0.12)), Vector3(0, -0.75, -0.04))
		legs.append(leg)

	# --- cape and glide wings --------------------------------------------
	var cape_root := Node3D.new()
	cape_root.name = "Cape"
	cape_root.position = Vector3(0, 1.40, 0.13)
	torso.add_child(cape_root)
	var cape_mesh := QuadMesh.new()
	cape_mesh.size = Vector2(0.42, 0.72)
	var cape_mi := _no_shadow(_outlined(cape_root, cape_mesh, cape_mat, Vector3(0, -0.34, 0.02), 0.012))
	# No 180-degree yaw. QuadMesh's front face points along +Z, the character faces
	# -Z and the camera sits behind her on +Z, so the cape already faces the camera.
	# Yawing it by 180 turned its front away and left only the inverted-hull outline
	# shell visible - a solid black rectangle hanging down her back.
	cape_mi.rotation_degrees = Vector3(-6, 0, 0)

	var wings := Node3D.new()
	wings.name = "Wings"
	wings.position = Vector3(0, 1.30, 0.16)
	wings.visible = false
	torso.add_child(wings)
	for side in [-1.0, 1.0]:
		var wing_pivot := Node3D.new()
		wing_pivot.position = Vector3(0.10 * side, 0.0, 0.0)
		wing_pivot.rotation_degrees = Vector3(0, 0, -18.0 * side)
		wings.add_child(wing_pivot)
		var wing := QuadMesh.new()
		wing.size = Vector2(0.85, 0.52)
		var wm := _toon(cape_col, 0.9)
		wm.set_shader_parameter("emission_boost", 0.35)
		wm.set_shader_parameter("emission_color", element_col)
		var w := _add(wing_pivot, wing, wm, Vector3(0.46 * side, 0.16, 0.0))
		w.rotation_degrees = Vector3(-12, 0, -12.0 * side)

	# --- weapon -----------------------------------------------------------
	var weapon_anchor := Node3D.new()
	weapon_anchor.name = "Weapon"
	weapon_anchor.position = Vector3(0.24, 1.10, -0.10)
	torso.add_child(weapon_anchor)
	_build_weapon(weapon_anchor, str(data["weapon"]), element_glow, accent)

	var glow := OmniLight3D.new()
	glow.name = "ElementLight"
	glow.light_color = element_col
	glow.light_energy = 0.55
	glow.omni_range = 2.2
	glow.shadow_enabled = false
	torso.add_child(glow)

	return {
		"visual": visual,
		"torso": torso,
		"head": head,
		"arm_l": arms[0],
		"arm_r": arms[1],
		"leg_l": legs[0],
		"leg_r": legs[1],
		"cape": cape_mi,
		"wings": wings,
		"weapon": weapon_anchor,
		"glow": glow,
	}


static func _build_weapon(anchor: Node3D, kind: String, glow: StandardMaterial3D, accent: ShaderMaterial) -> void:
	var steel := _toon(Color(0.46, 0.47, 0.54), 0.45)
	match kind:
		"sword":
			var blade := BoxMesh.new()
			blade.size = Vector3(0.06, 0.86, 0.015)
			_add(anchor, blade, steel, Vector3(0, -0.18, 0))
			var tip := PrismMesh.new()
			tip.size = Vector3(0.06, 0.14, 0.015)
			_add(anchor, tip, glow, Vector3(0, -0.68, 0))
			var guard := BoxMesh.new()
			guard.size = Vector3(0.20, 0.035, 0.05)
			_add(anchor, guard, accent, Vector3(0, -0.24, 0))
			var grip := CapsuleMesh.new()
			grip.radius = 0.024
			grip.height = 0.16
			_add(anchor, grip, _toon(Color(0.10, 0.08, 0.10)), Vector3(0, -0.14, 0))
		"bow":
			var frame := TorusMesh.new()
			frame.inner_radius = 0.20
			frame.outer_radius = 0.235
			frame.rings = 16
			frame.ring_segments = 6
			var f := _add(anchor, frame, accent, Vector3(0, -0.15, 0))
			f.rotation_degrees = Vector3(0, 90, 0)
			f.scale = Vector3(1.0, 1.45, 1.0)
			var string := BoxMesh.new()
			string.size = Vector3(0.008, 0.58, 0.008)
			_add(anchor, string, glow, Vector3(0, -0.15, 0))
		_:
			var orb := SphereMesh.new()
			orb.radius = 0.10
			orb.height = 0.20
			_add(anchor, orb, glow, Vector3(0, -0.34, -0.02))
			var ring := TorusMesh.new()
			ring.inner_radius = 0.12
			ring.outer_radius = 0.145
			ring.rings = 12
			ring.ring_segments = 6
			var r := _add(anchor, ring, accent, Vector3(0, -0.34, 0))
			r.rotation_degrees = Vector3(72, 18, 0)
