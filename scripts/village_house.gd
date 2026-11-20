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


func try_interact(actor: Node3D) -> bool:
	var local := to_local(actor.global_position)
	if absf(local.x + 1.0) > 1.3 or absf(local.z + 2.0) > 1.5 or absf(local.y) > 2.0:
		return false
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
