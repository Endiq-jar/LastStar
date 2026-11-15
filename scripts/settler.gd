extends Node3D
## Every spawned resident has a stable settlement id and two quest lines.
const DATA := preload("res://scripts/settlement_data.gd")
var site_id := ""


func _ready() -> void:
	add_to_group("story_npc")
	var site := DATA.by_id(site_id)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.76, 0.59, 0.49)
	var cloth := StandardMaterial3D.new()
	var hue := float(abs(site_id.hash()) % 360) / 360.0
	cloth.albedo_color = Color.from_hsv(hue, 0.38, 0.62)
	var body := CapsuleMesh.new()
	body.radius = 0.26
	body.height = 0.95
	_piece(body, cloth, Vector3(0, 1.04, 0))
	var head := SphereMesh.new()
	head.radius = 0.19
	head.height = 0.38
	_piece(head, skin, Vector3(0, 1.75, 0))
	var limbs := BoxMesh.new()
	limbs.size = Vector3(0.18, 0.55, 0.21)
	for side in [-1.0, 1.0]:
		_piece(limbs, cloth, Vector3(side * 0.13, 0.27, 0))
		_piece(limbs, cloth, Vector3(side * 0.35, 1.05, 0))
	var label := Label3D.new()
	label.text = "%s · %s\n%s  |  F / Talk" % [site.get("npc", "Resident"), site.get("role", ""), site.get("name", "")]
	label.position.y = 2.3
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
	add_child(part)
