extends Area3D
## A quest item is visible/collectable only while that quest is active.
const DATA := preload("res://scripts/settlement_data.gd")
var site_id := ""
var quest_kind := ""


func _ready() -> void:
	collision_layer = 4
	collision_mask = 2
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.8
	shape.shape = sphere
	add_child(shape)
	var mesh := MeshInstance3D.new()
	var crystal := PrismMesh.new()
	crystal.size = Vector3(0.5, 0.8, 0.5)
	mesh.mesh = crystal
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.68, 0.32) if quest_kind == "main" else Color(0.46, 0.75, 0.92)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color * 0.35
	mesh.material_override = mat
	add_child(mesh)
	var label := Label3D.new()
	label.text = str(DATA.by_id(site_id).get(quest_kind, "Quest item"))
	label.position.y = 1.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.004
	label.outline_size = 8
	add_child(label)
	body_entered.connect(_on_body_entered)
	Game.collection_changed.connect(_sync)
	_sync()


func _sync() -> void:
	var active: bool = Game.settlement_quest_status(site_id, quest_kind) == "active"
	visible = active
	set_deferred("monitoring", active)


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player") and Game.collect_settlement_item(site_id, quest_kind):
		Game.toast.emit("Quest item found — return to the resident")
