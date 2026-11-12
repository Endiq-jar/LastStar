extends RefCounted
## Bone cloth: the cloth in this world, made of cloth and bones.
##
## The valley dresses itself in cloth in four places - the ruin gates, the camp
## shelters, the spawn altar and the waypoint statues - and every one of them was
## bare geometry. This turns each of them into bone cloth: sun-bleached linen on
## a wooden pole, with bones lashed along the hem and a skull at its shoulder,
## plus a carpet and a bone pile on the ground.
##
## Models are by Quaternius, CC0-1.0 (public domain), vendored under
## assets/cloth/ - see assets/cloth/README.md for the per-file source URLs. They
## are re-materialled rather than used raw: the imported glTF materials are flat,
## single-sided PBR, and a hanging banner has to be double-sided and read as
## cel-shaded cloth next to the rest of the world (the terrain, the character and
## every prop in the valley use a toon ramp).
##
## The GLBs are preloaded, not loaded by path at runtime, so they are a real
## export dependency and an unimported model fails the build loudly instead of
## silently leaving the world bare.

const BANNER := preload("res://assets/cloth/bone_cloth_banner.glb")
const BANNER_WALL := preload("res://assets/cloth/bone_cloth_banner_wall.glb")
const CURTAIN := preload("res://assets/cloth/bone_cloth_curtain.glb")
const CARPET := preload("res://assets/cloth/bone_cloth_carpet.glb")
const BONES := preload("res://assets/cloth/bone_cloth_bones.glb")
const SKULL := preload("res://assets/cloth/bone_cloth_skull.glb")

const MODELS := {
	"banner": BANNER,
	"banner_wall": BANNER_WALL,
	"curtain": CURTAIN,
	"carpet": CARPET,
	"bones": BONES,
	"skull": SKULL,
}

## glTF material name -> colour. The models ship with flat PBR materials whose
## only distinguishing information is the name, so the palette maps by name and
## keeps the wooden pole wooden, the iron rings iron and the cloth cloth.
const PALETTE := {
	"Main": Color(0.86, 0.82, 0.73),       # the banner itself
	"Wood": Color(0.33, 0.24, 0.18),
	"Metal": Color(0.24, 0.24, 0.28),
	"DarkMetal": Color(0.16, 0.16, 0.19),
	"LightMetal": Color(0.46, 0.46, 0.49),
	"Bones": Color(0.88, 0.84, 0.72),
	"Bone": Color(0.91, 0.87, 0.75),
	"Red": Color(0.58, 0.20, 0.18),
	"Gold": Color(0.74, 0.57, 0.26),
	"Couch_Blue": Color(0.30, 0.36, 0.44),
}

## Surfaces that are cloth rather than hardware. They get a double-sided
## material: a banner is a flat plane, and single-sided it disappears the moment
## the player walks around it.
const CLOTH_KEYS := ["Main", "Red", "Couch_Blue", "Fabric", "Cloth"]

## Bone is bone whatever the cloth is tinted, so ornaments ignore the tint.
const BONE_TINT := Color(0.90, 0.86, 0.74)

## Shared per-colour materials. Every placement reuses these, so the whole
## valley's bone cloth costs a handful of material objects instead of one per
## piece - the same reasoning as the slime material cache.
static var _mats := {}


## Build one model, re-materialled and tinted. Returns null if the model is not
## importable, so a caller can simply skip the placement.
static func make(kind: String, tint: Color, size: float = 1.0) -> Node3D:
	if not MODELS.has(kind):
		return null
	var packed: PackedScene = MODELS[kind]
	if packed == null:
		return null
	var root := Node3D.new()
	root.name = "BoneCloth_" + kind
	root.add_to_group("bone_cloth")
	var inst := packed.instantiate()
	if inst == null:
		root.free()
		return null
	root.add_child(inst)
	_retint(root, tint)
	root.scale = Vector3.ONE * size
	return root


## A banner hanging from its own top edge - the pivot sits where the beam holds
## it, so a caller only has to say where the beam is.
static func hanging(tint: Color, size: float = 1.0) -> Node3D:
	var root := make("banner", tint, size)
	if root == null:
		return null
	var box := bounds_of(root)
	_hang_from_top(root, box)
	# Bones lashed along the hem and a skull at the shoulder: this is what makes
	# it *bone* cloth rather than a banner.
	var bones := make("bones", BONE_TINT, 0.30 * size)
	if bones != null:
		bones.position = Vector3(0.0, -box.size.y + 0.30 * size, 0.04)
		root.add_child(bones)
	var skull := make("skull", BONE_TINT, 0.42 * size)
	if skull != null:
		skull.position = Vector3(0.0, -box.size.y * 0.55, -0.05)
		skull.rotation_degrees = Vector3(0, 0, 14.0)
		root.add_child(skull)
	return root


## A free-standing standard: the banner above, the pole planted in a cairn of
## bones at the foot. The origin is on the ground, so a caller only has to say
## where it stands - which is what the spawn altar needs, since there is no
## beam over the glade to hang a banner from.
static func standard(tint: Color, size: float = 1.0) -> Node3D:
	var hung := hanging(tint, size)
	if hung == null:
		return null
	var box := bounds_of(hung)
	hung.position.y = box.size.y
	var root := Node3D.new()
	root.name = "BoneCloth_standard"
	root.add_to_group("bone_cloth")
	root.add_child(hung)
	var foot := bone_pile(0.55 * size)
	if foot != null:
		foot.position = Vector3(0.0, 0.0, 0.0)
		root.add_child(foot)
	return root


## The same idea on the narrower wall banner, for a statue or a pillar.
static func totem(tint: Color, size: float = 1.0) -> Node3D:
	var root := make("banner_wall", tint, size)
	if root == null:
		return null
	var box := bounds_of(root)
	_hang_from_top(root, box)
	var skull := make("skull", BONE_TINT, 0.34 * size)
	if skull != null:
		skull.position = Vector3(0.0, -box.size.y * 0.35, -0.04)
		root.add_child(skull)
	return root


## A hanging drape (a shelter curtain) with a skull hung at its top corner.
static func drape(tint: Color, size: float = 1.0) -> Node3D:
	var root := make("curtain", tint, size)
	if root == null:
		return null
	var box := bounds_of(root)
	_hang_from_top(root, box)
	var skull := make("skull", BONE_TINT, 0.38 * size)
	if skull != null:
		skull.position = Vector3(box.size.x * 0.32, -box.size.y * 0.22, -0.05)
		root.add_child(skull)
	return root


## A carpet lying flat, centred on its own footprint at ground level.
static func ground_cloth(tint: Color, size: float = 1.0) -> Node3D:
	var root := make("carpet", tint, size)
	if root == null:
		return null
	var box := bounds_of(root)
	var inner := root.get_child(0) as Node3D
	if inner != null:
		inner.position = Vector3(
			-(box.position.x + box.end.x) * 0.5,
			-box.position.y,
			-(box.position.z + box.end.z) * 0.5)
	return root


## A heap of bones with a skull dropped into it.
static func bone_pile(size: float = 1.0) -> Node3D:
	var root := make("bones", BONE_TINT, size)
	if root == null:
		return null
	var box := bounds_of(root)
	var inner := root.get_child(0) as Node3D
	if inner != null:
		inner.position.y = -box.position.y
	var skull := make("skull", BONE_TINT, 0.55 * size)
	if skull != null:
		skull.position = Vector3(0.30 * size, 0.10 * size, 0.12 * size)
		skull.rotation_degrees = Vector3(0, 38, 0)
		root.add_child(skull)
	return root


## World-space-free bounds of everything under `root`, in root-local space.
## Needed because the Quaternius scenes are authored in centimetres behind a
## 100x node scale, so "how tall is this banner" cannot be assumed.
static func bounds_of(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := _transform_to(root, mi)
		var b: AABB = xf * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


static func _transform_to(root: Node, node: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## Shift the model inside a hangable root so its top edge is the root's origin.
static func _hang_from_top(root: Node3D, box: AABB) -> void:
	var inner := root.get_child(0) as Node3D
	if inner != null:
		inner.position.y -= box.end.y


## Re-material every surface by its glTF material name.
static func _retint(root: Node3D, tint: Color) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		# Cloth must not be treated as a wall by the entity culler: soft, thin
		# and see-through-around, a hanging banner is not an occluder.
		mi.add_to_group("cloth_soft")
		var surfaces := mi.mesh.get_surface_count()
		for i in range(surfaces):
			var src := mi.get_active_material(i)
			var key := ""
			var base := Color(0.84, 0.81, 0.74)
			if src != null:
				key = str(src.resource_name)
				if src is StandardMaterial3D:
					base = (src as StandardMaterial3D).albedo_color
			var col: Color = base
			if PALETTE.has(key):
				col = PALETTE[key]
			var cloth: bool = CLOTH_KEYS.has(key)
			if cloth:
				col = Color(col.r * tint.r, col.g * tint.g, col.b * tint.b, 1.0)
			mi.set_surface_override_material(i, _material(col, cloth))


static func _material(col: Color, cloth: bool) -> StandardMaterial3D:
	var key := "%s|%s" % [col.to_html(false), str(cloth)]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	# Toon diffuse to match the cel-shaded world, without the custom character
	# shader (which is cull_back and built for the rig's outline pass).
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_TOON
	m.roughness = 0.94
	m.metallic = 0.0
	m.metallic_specular = 0.15
	if cloth:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[key] = m
	return m
