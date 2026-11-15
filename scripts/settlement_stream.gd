extends Node3D
## Stream compact settlement outposts around the player; only nearby structures
## and NPCs exist in the scene tree. Position resolution is deterministic.
const DATA := preload("res://scripts/settlement_data.gd")
const WALL := preload("res://assets/village/Wall_Plaster_Straight.gltf")
const DOOR_WALL := preload("res://assets/village/Wall_Plaster_Door_Round.gltf")
const WINDOW_WALL := preload("res://assets/village/Wall_Plaster_Window_Wide_Flat.gltf")
const ROOF := preload("res://assets/village/Roof_RoundTiles_4x4.gltf")
const GABLE := preload("res://assets/village/Roof_Front_Brick4.gltf")
const DOOR := preload("res://assets/village/Door_1_Round.gltf")
const WINDOW := preload("res://assets/village/Window_Wide_Flat1.gltf")
const NPC := preload("res://scripts/settler.gd")
const ITEM := preload("res://scripts/settlement_item.gd")
const LOAD_DISTANCE := 230.0
const UNLOAD_DISTANCE := 290.0

var _world: Node3D
var _player: Node3D
var _sites: Array[Dictionary] = []
var _loaded: Dictionary = {}
var _timer := 0.0


func setup(world: Node3D, player: Node3D) -> void:
	_world = world
	_player = player
	for site in DATA.SITES:
		var entry: Dictionary = site.duplicate(true)
		entry["resolved"] = _resolve(site["pos"])
		_sites.append(entry)
	_update_stream()


func _resolve(origin: Vector2) -> Vector2:
	# Avoid water and excessive gradients; deterministic offsets keep quest IDs
	# and settlement locations stable across saves.
	for radius in [0.0, 40.0, 80.0, 120.0, 180.0, 250.0]:
		for i in range(8):
			var p: Vector2 = origin + Vector2(cos(TAU * i / 8.0), sin(TAU * i / 8.0)) * radius
			if bool(_world.call("_is_wet", p.x, p.y)):
				continue
			var h := float(_world.call("_height", p.x, p.y))
			if h < 2.0:
				continue
			var good := true
			for offset in [Vector2(-12, -6), Vector2(12, -6), Vector2(0, 14), Vector2(0, 0), Vector2(0, -27), Vector2(27, 0)]:
				var q: Vector2 = p + offset
				if bool(_world.call("_is_wet", q.x, q.y)) or absf(float(_world.call("_height", q.x, q.y)) - h) > 8.0:
					good = false
					break
			if good:
				return p
	return origin


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = 1.0
		_update_stream()


func _update_stream() -> void:
	if not is_instance_valid(_player):
		return
	var p := Vector2(_player.global_position.x, _player.global_position.z)
	for site in _sites:
		var id: String = site["id"]
		var distance: float = p.distance_to(site["resolved"])
		if distance < LOAD_DISTANCE and not _loaded.has(id):
			_loaded[id] = _build_site(site)
		elif distance > UNLOAD_DISTANCE and _loaded.has(id):
			var old: Node = _loaded[id]
			_loaded.erase(id)
			old.queue_free()


func _build_site(site: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Settlement_" + str(site["id"])
	add_child(root)
	var center: Vector2 = site["resolved"]
	for offset in [Vector2(-12, -6), Vector2(12, -6), Vector2(0, 14)]:
		var p: Vector2 = center + offset
		var house := _house()
		house.position = Vector3(p.x, float(_world.call("_height", p.x, p.y)) - 0.1, p.y)
		root.add_child(house)
	var npc := NPC.new()
	npc.set("site_id", str(site["id"]))
	npc.position = Vector3(center.x, float(_world.call("_height", center.x, center.y)), center.y)
	root.add_child(npc)
	for kind in ["main", "side"]:
		var offset := Vector2(0, -27) if kind == "main" else Vector2(27, 0)
		var p: Vector2 = center + offset
		var item := ITEM.new()
		item.set("site_id", str(site["id"]))
		item.set("quest_kind", kind)
		item.position = Vector3(p.x, float(_world.call("_height", p.x, p.y)) + 1.0, p.y)
		root.add_child(item)
	return root


func _part(parent: Node3D, scene: PackedScene, position: Vector3, yaw: float = 0.0) -> void:
	var part := scene.instantiate() as Node3D
	part.position = position
	part.rotation.y = yaw
	parent.add_child(part)


func _house() -> Node3D:
	var house := Node3D.new()
	house.name = "VillageHouse"
	# Original 2m modular walls arranged into 4x4m exteriors. Interiors are not
	# yet playable; a single simple collision box keeps players out of the mesh.
	_part(house, DOOR_WALL, Vector3(-1, 0, -2), PI)
	_part(house, DOOR, Vector3(-0.45, 0, -2.02), PI)
	_part(house, WINDOW_WALL, Vector3(1, 0, -2), PI)
	_part(house, WINDOW, Vector3(1, 0, -2), PI)
	for x in [-1.0, 1.0]:
		_part(house, WALL, Vector3(x, 0, 2))
	for z in [-1.0, 1.0]:
		_part(house, WALL, Vector3(-2, 0, z), -PI / 2)
		_part(house, WALL, Vector3(2, 0, z), PI / 2)
	_part(house, ROOF, Vector3(0, 3.1, 0))
	_part(house, GABLE, Vector3(0, 3.05, 2))
	_part(house, GABLE, Vector3(0, 3.05, -2), PI)
	var collider := StaticBody3D.new()
	collider.collision_layer = 1
	collider.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.4, 4.0)
	shape.shape = box
	shape.position.y = 1.7
	collider.add_child(shape)
	house.add_child(collider)
	return house
