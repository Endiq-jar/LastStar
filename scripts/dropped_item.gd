extends Area3D
## Small recoverable pickup. State is owned by Game and survives restarts.
var drop_id := ""


func _ready() -> void:
	collision_layer = 4
	collision_mask = 2
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.25
	shape.shape = sphere
	add_child(shape)
	var mesh := MeshInstance3D.new()
	var orb := SphereMesh.new()
	orb.radius = 0.28
	orb.height = 0.56
	mesh.mesh = orb
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.70, 0.54, 0.95)
	material.emission_enabled = true
	material.emission = Color(0.30, 0.16, 0.48)
	mesh.material_override = material
	add_child(mesh)
	var label := Label3D.new()
	label.text = str(Game.dropped_items.get(drop_id, {}).get("item", "Item"))
	label.position.y = 0.55
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.006
	add_child(label)
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	if Game.recover_drop(drop_id):
		Game.toast.emit("Item recovered")
		queue_free()
	else:
		Game.toast.emit("Inventory full")
