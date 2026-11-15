extends Node3D
## Every spawned resident has a stable settlement id and two quest lines.
const DATA := preload("res://scripts/settlement_data.gd")
var site_id := ""
var resident_index := 0
static var _body_mesh: CapsuleMesh
static var _head_mesh: SphereMesh
static var _limb_mesh: BoxMesh
static var _skin: StandardMaterial3D
static var _clothes: Dictionary = {}


func _ready() -> void:
	add_to_group("story_npc")
	var site := DATA.by_id(site_id)
	var person := DATA.resident(site_id, resident_index)
	if _skin == null:
		_skin = StandardMaterial3D.new()
		_skin.albedo_color = Color(0.76, 0.59, 0.49)
		_body_mesh = CapsuleMesh.new()
		_body_mesh.radius = 0.26
		_body_mesh.height = 0.95
		_head_mesh = SphereMesh.new()
		_head_mesh.radius = 0.19
		_head_mesh.height = 0.38
		_limb_mesh = BoxMesh.new()
		_limb_mesh.size = Vector3(0.18, 0.55, 0.21)
	var color_index := abs((site_id + str(resident_index)).hash()) % 12
	if not _clothes.has(color_index):
		var cloth := StandardMaterial3D.new()
		cloth.albedo_color = Color.from_hsv(float(color_index) / 12.0, 0.38, 0.62)
		_clothes[color_index] = cloth
	var clothing: Material = _clothes[color_index]
	_piece(_body_mesh, clothing, Vector3(0, 1.04, 0))
	_piece(_head_mesh, _skin, Vector3(0, 1.75, 0))
	for side in [-1.0, 1.0]:
		_piece(_limb_mesh, clothing, Vector3(side * 0.13, 0.27, 0))
		_piece(_limb_mesh, clothing, Vector3(side * 0.35, 1.05, 0))
	var label := Label3D.new()
	label.text = "%s · %s\n%s  |  F / Talk" % [person.get("name", "Resident"), person.get("role", ""), site.get("name", "")]
	label.position.y = 2.3
	label.visibility_range_end = 24.0
	label.visibility_range_end_margin = 3.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.004
	label.outline_size = 8
	add_child(label)


func _piece(mesh: Mesh, material: Material, at: Vector3) -> void:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = at
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.visibility_range_end = 75.0
	part.visibility_range_end_margin = 8.0
	add_child(part)
