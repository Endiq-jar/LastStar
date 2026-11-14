extends Node3D
## A lightweight first story contact; interaction is handled by the HUD.


func _ready() -> void:
	add_to_group("story_npc")
	var coat := StandardMaterial3D.new()
	coat.albedo_color = Color(0.19, 0.29, 0.45)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.76, 0.59, 0.49)
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.80, 0.62, 0.28)
	var body := CapsuleMesh.new()
	body.radius = 0.26
	body.height = 0.95
	_piece(body, coat, Vector3(0, 1.04, 0))
	var head := SphereMesh.new()
	head.radius = 0.19
	head.height = 0.38
	_piece(head, skin, Vector3(0, 1.75, 0))
	var leg := BoxMesh.new()
	leg.size = Vector3(0.18, 0.55, 0.21)
	for side in [-1.0, 1.0]:
		_piece(leg, coat, Vector3(side * 0.13, 0.27, 0))
		var arm := BoxMesh.new()
		arm.size = Vector3(0.16, 0.70, 0.16)
		_piece(arm, coat, Vector3(side * 0.35, 1.05, 0))
	var badge := SphereMesh.new()
	badge.radius = 0.065
	badge.height = 0.13
	_piece(badge, gold, Vector3(0, 1.27, -0.24))
	var label := Label3D.new()
	label.text = "Star Guard Ilyra\nTalk: F or Talk button"
	label.position.y = 2.25
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.005
	label.outline_size = 8
	add_child(label)


func _piece(mesh: Mesh, material: Material, at: Vector3) -> void:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = at
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(part)
