extends Node3D
## A physical stall streamed with each settlement. Geometry is shared across
## stalls; the counter collision and interaction are independent of the art.
const SHOPS := preload("res://scripts/settlement_shops.gd")
var site_id := ""
static var _stall_mesh: ArrayMesh
static var _wood: StandardMaterial3D
static var _cloth: StandardMaterial3D


static func _add_box(tool: SurfaceTool, size: Vector3, at: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = size
	tool.append_from(box, 0, Transform3D(Basis.IDENTITY, at))


static func _build_mesh() -> void:
	if _stall_mesh != null: return
	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box(wood, Vector3(3.2, 0.18, 1.5), Vector3(0, 1.0, 0))
	_add_box(wood, Vector3(3.0, 0.65, 0.28), Vector3(0, 0.48, 0.55))
	# A low-poly shopkeeper stands behind the counter as part of the same
	# two shared batches, rather than adding an always-running NPC process.
	_add_box(wood, Vector3(0.38, 0.42, 0.34), Vector3(0, 1.84, 0.88))
	for x in [-1.4, 1.4]:
		for z in [-0.55, 0.55]: _add_box(wood, Vector3(0.14, 2.35, 0.14), Vector3(x, 1.175, z))
	var cloth := SurfaceTool.new()
	cloth.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box(cloth, Vector3(0.48, 0.85, 0.34), Vector3(0, 1.22, 0.88))
	_add_box(cloth, Vector3(3.45, 0.16, 1.95), Vector3(0, 2.4, 0))
	_add_box(cloth, Vector3(3.45, 0.32, 0.12), Vector3(0, 2.19, -0.93))
	_stall_mesh = ArrayMesh.new()
	wood.commit(_stall_mesh)
	cloth.commit(_stall_mesh)
	_wood = StandardMaterial3D.new()
	_wood.albedo_color = Color(0.38, 0.23, 0.14)
	_wood.roughness = 0.9
	_cloth = StandardMaterial3D.new()
	_cloth.albedo_color = Color(0.68, 0.28, 0.24)
	_cloth.roughness = 0.9


func _ready() -> void:
	add_to_group("story_interaction")
	_build_mesh()
	var visual := MeshInstance3D.new()
	visual.name = "MarketStall"
	visual.mesh = _stall_mesh
	visual.set_surface_override_material(0, _wood)
	visual.set_surface_override_material(1, _cloth)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual.visibility_range_end = 100.0
	add_child(visual)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.2, 1.1, 1.5)
	shape.shape = box
	shape.position.y = 0.55
	body.add_child(shape)
	var shop: Dictionary = SHOPS.by_id(site_id)
	var label := Label3D.new()
	label.text = "%s\n%s · F / Shop" % [shop.get("name", "Market"), shop.get("merchant", "Merchant")]
	label.position.y = 3.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.pixel_size = 0.004
	label.outline_size = 6
	label.visibility_range_end = 35.0
	add_child(label)


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or SHOPS.by_id(site_id).is_empty(): return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 4.0: return {}
	return {"name": "Shop · " + str(SHOPS.by_id(site_id)["name"]), "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if Game.is_paused or Game.has_won or interaction_for(actor).is_empty(): return false
	var world := actor.get_parent()
	var menu := world.get_node_or_null("HUD/Root/AdventureMenu") if world != null else null
	if menu == null or not menu.has_method("open_settlement_shop"): return false
	menu.call("open_settlement_shop", site_id)
	return true
