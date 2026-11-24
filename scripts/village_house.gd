extends Node3D
## Hide the roof while the player is indoors so the room stays visible.
const DOOR := preload("res://assets/village/Door_1_Round.gltf")
var _hinge: Node3D
var _door_shape: CollisionShape3D
var _open := false
var _player: Node3D
var _roof: Node3D
var _clock := 0.0


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player") as Node3D
	_roof = get_node_or_null("RoofParts") as Node3D
	add_to_group("village_house")
	_hinge = Node3D.new()
	_hinge.name = "DoorHinge"
	_hinge.position = Vector3(-1.5, 0, -2)
	add_child(_hinge)
	var door := DOOR.instantiate() as Node3D
	_hinge.add_child(door)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	_hinge.add_child(body)
	_door_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 2.3, 0.2)
	_door_shape.shape = box
	_door_shape.position = Vector3(0.5, 1.15, 0)
	body.add_child(_door_shape)


# Registered together with each actual model by the settlement builder.
var furniture: Array[Dictionary] = []


func register_furniture(id: String, label: String, at: Vector3) -> void:
	furniture.append({"id": id, "name": label, "position": at})


func interaction_for(actor: Node3D) -> Dictionary:
	var local := to_local(actor.global_position)
	if absf(local.x + 1.0) <= 1.3 and absf(local.z + 2.0) <= 1.5 and absf(local.y) <= 2.0:
		return {"id": "door", "name": "Close door" if _open else "Open door", "distance": actor.global_position.distance_to(to_global(Vector3(-1, 0, -2)))}
	if absf(local.x) >= 1.95 or absf(local.z) >= 1.95 or local.y < -0.7 or local.y > 3.2:
		return {}
	var best := 2.0
	var selected: Dictionary = {}
	for item in furniture:
		var anchor: Vector3 = item["position"]
		var distance := Vector2(local.x - anchor.x, local.z - anchor.z).length()
		if distance < best:
			best = distance
			selected = item.duplicate()
			selected["distance"] = distance * scale.x
	return selected


func try_interact(actor: Node3D) -> bool:
	var choice := interaction_for(actor)
	if choice.is_empty(): return false
	var id := str(choice["id"])
	if id != "door":
		match id:
			"bed":
				Game.heal(Game.max_hp() * 0.25)
				Game.toast.emit("You rest for a moment and recover health.")
			"table": Game.toast.emit("A well-used table, ready for a shared meal.")
			"chair": Game.toast.emit("A wooden chair stands in the room.")
			"couch": Game.toast.emit("A comfortable couch offers a place to rest.")
			"shelf": Game.toast.emit("The shelf holds books and keepsakes from the settlement.")
			"rug": Game.toast.emit("A woven rug makes the room feel welcoming.")
		return true
	var local := to_local(actor.global_position)
	# Do not close onto the player in the doorway.
	if _open and absf(local.z + 2.0) < 0.5 and absf(local.x + 1.0) < 0.8:
		Game.toast.emit("Step clear of the doorway to close it.")
		return true
	_open = not _open
	_hinge.rotation.y = PI / 2.0 if _open else 0.0
	_door_shape.set_deferred("disabled", _open)
	Game.toast.emit("Door opened" if _open else "Door closed")
	return true


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = 0.12
	if not is_instance_valid(_player) or _roof == null:
		return
	var local := to_local(_player.global_position)
	var inside := absf(local.x) < 1.95 and absf(local.z) < 1.95 and local.y > -0.7 and local.y < 3.2
	_roof.visible = not inside
