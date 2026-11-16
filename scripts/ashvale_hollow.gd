extends Node3D
## A compact optional Hollow. Geometry exists only while inside to limit cost.
const FLOOR := preload("res://assets/dungeon/floor_tile_large.gltf.glb")
const WALL := preload("res://assets/dungeon/wall.gltf.glb")
const DOOR := preload("res://assets/dungeon/wall_doorway.glb")
const TORCH := preload("res://assets/dungeon/torch_lit.gltf.glb")
const CHEST := preload("res://assets/dungeon/chest.glb")
const WARDEN := preload("res://scripts/hollow_warden.gd")
const ALTITUDE := 500.0
var player: CharacterBody3D
var entrance := Vector3.ZERO
var return_point := Vector3.ZERO
var inside := false
var chamber: Node3D
var boss: Node3D
var _exit_point := Vector3.ZERO


func setup(world: Node3D, actor: CharacterBody3D, center: Vector2) -> void:
	player = actor
	var p := center + Vector2(0, -22)
	entrance = Vector3(p.x, float(world.call("_height", p.x, p.y)), p.y)
	position = entrance
	var door := DOOR.instantiate() as Node3D
	add_child(door)
	var label := Label3D.new()
	label.text = "ASHVALE HOLLOW\nF / Talk to enter · Challenging"
	label.position = Vector3(0, 4.5, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.006
	label.outline_size = 8
	add_child(label)
	Game.respawned.connect(_on_respawn)


func try_interact(actor: Node3D) -> bool:
	if inside:
		if Game.ashvale_hollow_cleared and is_instance_valid(chamber):
			var chest := chamber.get_node_or_null("VictoryChest") as Node3D
			if chest != null and actor.global_position.distance_to(chest.global_position) < 3.5:
				if not Game.collect_hollow_memory():
					Game.toast.emit("The memory fragment has already been recovered.")
				return true
		if actor.global_position.distance_to(_exit_point) < 4.0:
			_leave()
			return true
	elif actor.global_position.distance_to(entrance) < 5.0:
		_enter()
		return true
	return false


func _enter() -> void:
	if inside or not is_instance_valid(player): return
	return_point = player.global_position
	inside = true
	chamber = Node3D.new()
	chamber.name = "HollowChamber"
	get_parent().add_child(chamber)
	chamber.global_position = Vector3(entrance.x, ALTITUDE, entrance.z)
	for x in range(-2, 3):
		for z in range(-2, 3):
			var tile := FLOOR.instantiate() as Node3D
			tile.position = Vector3(x * 4, 0, z * 4)
			chamber.add_child(tile)
			var ceiling := FLOOR.instantiate() as Node3D
			ceiling.position = Vector3(x * 4, 5.0, z * 4)
			ceiling.rotation.x = PI
			chamber.add_child(ceiling)
	for i in range(-2, 3):
		for side in [-1, 1]:
			var wall := WALL.instantiate() as Node3D
			wall.position = Vector3(i * 4, 0, side * 10)
			chamber.add_child(wall)
			var side_wall := WALL.instantiate() as Node3D
			side_wall.position = Vector3(side * 10, 0, i * 4)
			side_wall.rotation.y = PI / 2.0
			chamber.add_child(side_wall)
	_box(chamber, Vector3(0, -0.20, 0), Vector3(20, 0.4, 20))
	_box(chamber, Vector3(0, 2, -10), Vector3(20, 4, 0.5))
	_box(chamber, Vector3(0, 2, 10), Vector3(20, 4, 0.5))
	_box(chamber, Vector3(-10, 2, 0), Vector3(0.5, 4, 20))
	_box(chamber, Vector3(10, 2, 0), Vector3(0.5, 4, 20))
	for x in [-8.0, 8.0]:
		for z in [-8.0, 8.0]:
			var torch := TORCH.instantiate() as Node3D
			torch.position = Vector3(x, 1.2, z)
			chamber.add_child(torch)
	var exit_label := Label3D.new()
	exit_label.text = "F / Talk · Leave Hollow"
	exit_label.position = Vector3(7, 2.2, 8)
	exit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	exit_label.font_size = 48
	exit_label.pixel_size = 0.0025
	chamber.add_child(exit_label)
	var exit_marker := TORCH.instantiate() as Node3D
	exit_marker.position = Vector3(7, 1.2, 8)
	chamber.add_child(exit_marker)
	_exit_point = chamber.global_position + Vector3(7, 0, 8)
	player.global_position = chamber.global_position + Vector3(0, 0.2, 7.0)
	player.velocity = Vector3.ZERO
	if not Game.ashvale_hollow_cleared:
		boss = WARDEN.new()
		boss.position = Vector3(0, 0.15, -4)
		chamber.add_child(boss)
		boss.connect("defeated", _on_defeated)
		Game.toast.emit("Warden ahead. Dodge red circles! Exit is marked at the rear right.")
	else:
		_add_chest()
		Game.toast.emit("Ashvale Hollow is cleared. Leave when ready.")


func _box(parent: Node3D, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = at
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)


func _on_defeated() -> void:
	if not Game.ashvale_hollow_cleared:
		Game.ashvale_hollow_cleared = true
		Game.starlight += 30
		Game.coins += 100
		Game.save_collection()
		Game.collection_changed.emit()
		Game.toast.emit("Hollow cleared! +30 starlight, +100 Ane. Return to the entrance.")
	_add_chest()


func _add_chest() -> void:
	if chamber == null or chamber.has_node("VictoryChest"): return
	var chest := CHEST.instantiate() as Node3D
	chest.name = "VictoryChest"
	chest.position = Vector3(0, 0.05, -6)
	chamber.add_child(chest)
	var label := Label3D.new()
	label.text = "F / Talk · Memory fragment"
	label.position = Vector3(0, 1.6, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.pixel_size = 0.003
	label.outline_size = 6
	chest.add_child(label)


func _leave() -> void:
	if not inside: return
	inside = false
	player.global_position = return_point + Vector3(0, 0.3, 0)
	player.velocity = Vector3.ZERO
	if is_instance_valid(chamber): chamber.queue_free()
	chamber = null
	boss = null
	Game.toast.emit("Left Ashvale Hollow. You can return and try again.")


func _on_respawn() -> void:
	if inside:
		inside = false
		if is_instance_valid(chamber): chamber.queue_free()
		chamber = null
		boss = null
		Game.toast.emit("You escaped the Hollow. Prepare and try again.")
