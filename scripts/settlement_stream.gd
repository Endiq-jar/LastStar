extends Node3D
## Stream compact settlement outposts around the player; only nearby structures
## and NPCs exist in the scene tree. Position resolution is deterministic.
const DATA := preload("res://scripts/settlement_data.gd")
const WALL := preload("res://assets/village/Wall_Plaster_Straight.gltf")
const DOOR_WALL := preload("res://assets/village/Wall_Plaster_Door_Round.gltf")
const WINDOW_WALL := preload("res://assets/village/Wall_Plaster_Window_Wide_Flat.gltf")
const ROOF := preload("res://assets/village/Roof_RoundTiles_4x4.gltf")
const ROOF_MID := preload("res://assets/village/Roof_RoundTiles_4x4_Mid.glb")
const ROOF_FAR := preload("res://assets/village/Roof_RoundTiles_4x4_Far.glb")
const GABLE := preload("res://assets/village/Roof_Front_Brick4.gltf")
const WINDOW := preload("res://assets/village/Window_Wide_Flat1.gltf")
const BED := preload("res://assets/furniture/bed_single_A.gltf")
const COUCH := preload("res://assets/furniture/couch.gltf")
const TABLE := preload("res://assets/furniture/table_small.gltf")
const CHAIR := preload("res://assets/furniture/chair_A_wood.gltf")
const SHELF := preload("res://assets/furniture/shelf_B_small_decorated.gltf")
const RUG := preload("res://assets/furniture/rug_rectangle_A.gltf")
const BED_MID := preload("res://assets/furniture/bed_single_A_Mid.glb")
const COUCH_MID := preload("res://assets/furniture/couch_Mid.glb")
const CHAIR_MID := preload("res://assets/furniture/chair_A_wood_Mid.glb")
const SHELF_MID := preload("res://assets/furniture/shelf_B_small_decorated_Mid.glb")
const NPC := preload("res://scripts/settler.gd")
const ITEM := preload("res://scripts/settlement_item.gd")
const HOUSE := preload("res://scripts/village_house.gd")
const PROPS := preload("res://scripts/interior_props.gd")
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
	Game.collection_changed.connect(_sync_items)
	_update_stream()


func _resolve(origin: Vector2) -> Vector2:
	# Avoid water and excessive gradients; deterministic offsets keep quest IDs
	# and settlement locations stable across saves.
	for radius in [0.0, 40.0, 80.0, 120.0, 180.0, 250.0, 350.0, 500.0]:
		for i in range(8):
			var p: Vector2 = origin + Vector2(cos(TAU * i / 8.0), sin(TAU * i / 8.0)) * radius
			if bool(_world.call("_is_wet", p.x, p.y)):
				continue
			var h := float(_world.call("_height", p.x, p.y))
			if h < 2.0:
				continue
			var good := true
			for offset in [Vector2(-12, -6), Vector2(12, -6), Vector2(0, 14)]:
				var q: Vector2 = p + offset
				var low := INF
				var high := -INF
				for corner in [Vector2(-3, -3), Vector2(-3, 3), Vector2(3, -3), Vector2(3, 3), Vector2.ZERO]:
					var sample: Vector2 = q + corner
					if bool(_world.call("_is_wet", sample.x, sample.y)):
						good = false
					var y := float(_world.call("_height", sample.x, sample.y))
					low = minf(low, y)
					high = maxf(high, y)
				if high - low > 2.0 or absf(high - h) > 12.0:
					good = false
			for offset in [Vector2(0, -27), Vector2(27, 0)]:
				var q: Vector2 = p + offset
				if bool(_world.call("_is_wet", q.x, q.y)) or absf(float(_world.call("_height", q.x, q.y)) - h) > 12.0:
					good = false
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
			_sync_items_for_site(site, _loaded[id])
		elif distance > UNLOAD_DISTANCE and _loaded.has(id):
			var old: Node = _loaded[id]
			_loaded.erase(id)
			old.queue_free()


func _build_site(site: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Settlement_" + str(site["id"])
	add_child(root)
	var center: Vector2 = site["resolved"]
	var house_slot := 0
	var site_index := 0
	for index in range(DATA.SITES.size()):
		if str(DATA.SITES[index]["id"]) == str(site["id"]): site_index = index
	for offset in [Vector2(-12, -6), Vector2(12, -6), Vector2(0, 14)]:
		var p: Vector2 = center + offset
		var low := INF
		var high := -INF
		for corner in [Vector2(-3, -3), Vector2(-3, 3), Vector2(3, -3), Vector2(3, 3), Vector2.ZERO]:
			var sample: Vector2 = p + corner
			var y := float(_world.call("_height", sample.x, sample.y))
			low = minf(low, y)
			high = maxf(high, y)
		var house := _house(site_index, house_slot)
		house_slot += 1
		house.position = Vector3(p.x, high + 0.08, p.y)
		house.scale = Vector3(1.5, 1.0, 1.5)
		root.add_child(house)
		_add_foundation(house, high - low + 0.4)
		_add_entrance_ramp(house, p, high + 0.08)
	for index in range(DATA.RESIDENT_COUNT):
		var pos := _resident_position(center, index)
		var npc := NPC.new()
		npc.name = "Resident_%02d" % index
		npc.site_id = str(site["id"])
		npc.resident_index = index
		npc.position = Vector3(pos.x, float(_world.call("_height", pos.x, pos.y)), pos.y)
		root.add_child(npc)
	return root


func _resident_position(center: Vector2, index: int) -> Vector2:
	if index == 0:
		return center
	var slot := index - 1
	var radius := 17.0 if slot < 10 else 25.0
	var angle := TAU * float(slot % 10) / 10.0 + (0.18 if slot >= 10 else 0.0)
	for attempt in range(12):
		var a := angle + float(attempt) * 0.18
		var pos := center + Vector2(cos(a), sin(a)) * radius
		var near_house := false
		for h in [Vector2(-12, -6), Vector2(12, -6), Vector2(0, 14)]:
			if pos.distance_to(center + h) < 6.5:
				near_house = true
			if pos.distance_to(center + h + Vector2(-1.5, -7.5)) < 2.5:
				near_house = true
		if not near_house and not bool(_world.call("_is_wet", pos.x, pos.y)):
			return pos
	return center + Vector2(cos(angle), sin(angle)) * radius


func _sync_items() -> void:
	for site in _sites:
		var id: String = site["id"]
		if _loaded.has(id):
			_sync_items_for_site(site, _loaded[id])


func _sync_items_for_site(site: Dictionary, root: Node3D) -> void:
	var id: String = site["id"]
	var center: Vector2 = site["resolved"]
	for index in range(DATA.RESIDENT_COUNT):
		for kind in ["main", "side"]:
			var node_name := "QuestItem_%02d_%s" % [index, kind]
			var node := root.get_node_or_null(node_name)
			var active: bool = Game.settlement_quest_status(id, kind, index) == "active"
			if active and node == null:
				var p: Vector2 = center + DATA.quest_offset(index, kind)
				# Choose nearby dry ground if the ideal placement falls in water.
				for turn in range(8):
					if not bool(_world.call("_is_wet", p.x, p.y)):
						break
					p = center + DATA.quest_offset(index, kind).rotated(float(turn + 1) * 0.15)
				var item := ITEM.new()
				item.name = node_name
				item.site_id = id
				item.resident_index = index
				item.quest_kind = kind
				item.position = Vector3(p.x, float(_world.call("_height", p.x, p.y)) + 1.0, p.y)
				root.add_child(item)
			elif not active and node != null:
				root.remove_child(node)
				node.queue_free()


func _add_foundation(house: Node3D, depth: float) -> void:
	var foundation := MeshInstance3D.new()
	var block := BoxMesh.new()
	block.size = Vector3(4.1, depth, 4.1)
	foundation.mesh = block
	foundation.position.y = -depth * 0.5
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.43, 0.40, 0.39)
	stone.roughness = 1.0
	foundation.material_override = stone
	foundation.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	house.add_child(foundation)


func _part(parent: Node3D, scene: PackedScene, position: Vector3, yaw: float = 0.0) -> void:
	var part := scene.instantiate() as Node3D
	part.position = position
	part.rotation.y = yaw
	parent.add_child(part)


func _roof_lod(parent: Node3D, model: PackedScene, start: float, end: float, node_name: String) -> void:
	var variant := model.instantiate() as Node3D
	variant.name = node_name
	variant.position = Vector3(0, 3.1, 0)
	parent.add_child(variant)
	_set_mesh_range(variant, start, end)


func _set_mesh_range(root: Node, start: float, end: float) -> void:
	if root is GeometryInstance3D:
		var visual := root as GeometryInstance3D
		visual.visibility_range_begin = start
		visual.visibility_range_end = end
	for child in root.get_children(): _set_mesh_range(child, start, end)


func _house(site_index: int, house_slot: int) -> Node3D:
	var house := HOUSE.new()
	house.set_meta("interior_variant", site_index * 3 + house_slot)
	house.name = "VillageHouse"
	# The door fills the opening and swings around its left-hand hinge.
	_part(house, DOOR_WALL, Vector3(-1, 0, -2), PI)
	_part(house, WINDOW_WALL, Vector3(1, 0, -2), PI)
	_part(house, WINDOW, Vector3(1, 0, -2), PI)
	for x in [-1.0, 1.0]:
		_part(house, WALL, Vector3(x, 0, 2))
	for z in [-1.0, 1.0]:
		_part(house, WALL, Vector3(-2, 0, z), -PI / 2)
		_part(house, WALL, Vector3(2, 0, z), PI / 2)
	var roof := Node3D.new()
	roof.name = "RoofParts"
	house.add_child(roof)
	# Roof is the heaviest house component. Preserve the source close-up and
	# switch to independently simplified versions as its screen coverage falls.
	_roof_lod(roof, ROOF, 0.0, 25.0, "RoofNear")
	_roof_lod(roof, ROOF_MID, 25.0, 50.0, "RoofMid")
	_roof_lod(roof, ROOF_FAR, 50.0, 100.0, "RoofFar")
	_part(roof, GABLE, Vector3(0, 3.05, 2))
	_part(roof, GABLE, Vector3(0, 3.05, -2), PI)
	var collider := StaticBody3D.new()
	collider.name = "HouseCollision"
	collider.collision_layer = 1
	collider.collision_mask = 0
	house.add_child(collider)
	_box_collision(collider, Vector3(4, 3, 0.25), Vector3(0, 1.5, 2))
	_box_collision(collider, Vector3(0.25, 3, 4), Vector3(-2, 1.5, 0))
	_box_collision(collider, Vector3(0.25, 3, 4), Vector3(2, 1.5, 0))
	_box_collision(collider, Vector3(0.5, 3, 0.25), Vector3(-1.75, 1.5, -2))
	_box_collision(collider, Vector3(2.5, 3, 0.25), Vector3(0.75, 1.5, -2))
	_box_collision(collider, Vector3(1, 0.6, 0.25), Vector3(-1, 2.7, -2))
	_box_collision(collider, Vector3(4, 0.2, 4), Vector3(0, -0.1, 0))
	var floor_mesh := MeshInstance3D.new()
	var floor := BoxMesh.new()
	floor.size = Vector3(3.9, 0.08, 3.9)
	floor_mesh.mesh = floor
	floor_mesh.position.y = 0.02
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color.from_hsv(0.055 + float(site_index) * 0.003, 0.48 + float(house_slot) * 0.05, 0.36 + float(site_index) * 0.008)
	floor_mesh.material_override = floor_mat
	house.add_child(floor_mesh)
	# A few combinations keep the footprint clear. The original bedroom is the
	# first house; living rooms swap in a couch rather than placing every prop.
	var variation := (site_index + house_slot) % 3
	if variation == 1:
		_furnish(house, COUCH, "couch", "Inspect couch", Vector3(1.0, 0.08, 0.35), 0.0, COUCH_MID)
	else:
		_furnish(house, BED, "bed", "Rest at bed", Vector3(1.0, 0.08, 0.35), 0.0, BED_MID)
	if variation != 2:
		_furnish(house, TABLE, "table", "Inspect table", Vector3(-1.0, 0.08, 0.65))
	if variation != 0:
		_furnish(house, CHAIR, "chair", "Inspect chair", Vector3(-1.0, 0.08, 1.5), PI, CHAIR_MID)
	if (site_index + house_slot) % 2 == 0:
		_furnish(house, SHELF, "shelf", "Read shelf", Vector3(0.0, 0.18, 1.85), PI, SHELF_MID)
	if (site_index + house_slot) % 4 != 3:
		_furnish(house, RUG, "rug", "Inspect rug", Vector3(0.05, 0.08, 0.0))
	# Two small props per house, selected deterministically, never all 20 at once.
	for prop_slot in range(2):
		var prop_index := (site_index * 6 + house_slot * 2 + prop_slot) % PROPS.ITEMS.size()
		var definition: Array = PROPS.ITEMS[prop_index]
		var prop := PROPS.make(prop_index)
		var id := "prop_" + str(definition[0])
		prop.name = "Furniture_" + id
		prop.position = Vector3(1.55 if prop_slot == 0 else -1.55, 0.08, -0.55 if prop_slot == 0 else -0.35)
		house.add_child(prop)
		house.register_furniture(id, "Inspect " + str(definition[0]).replace("_", " "), prop.position, "You examine " + str(definition[1]) + ".")
	return house


func _furnish(house: Node3D, model: PackedScene, id: String, label: String, at: Vector3, yaw: float = 0.0, middle_model: PackedScene = null) -> void:
	var furnishing := Node3D.new()
	furnishing.name = "Furniture_" + id
	furnishing.position = at
	furnishing.rotation.y = yaw
	var near := model.instantiate() as Node3D
	near.name = "Near"
	furnishing.add_child(near)
	_set_mesh_range(near, 0.0, 15.0 if middle_model != null else 50.0)
	if middle_model != null:
		var middle := middle_model.instantiate() as Node3D
		middle.name = "Middle"
		furnishing.add_child(middle)
		_set_mesh_range(middle, 15.0, 50.0)
	house.add_child(furnishing)
	house.call("register_furniture", id, label, at)


func _box_collision(body: StaticBody3D, size: Vector3, position: Vector3) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = position
	body.add_child(shape)
	return shape


func _add_entrance_ramp(house: Node3D, at: Vector2, floor_height: float) -> void:
	var far_height := float(_world.call("_height", at.x - 1.5, at.y - 9.0))
	var rise := floor_height - far_height
	var length := sqrt(16.0 + rise * rise)
	var angle := -atan2(rise, 4.0)
	var body := StaticBody3D.new()
	body.name = "EntranceRamp"
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector3(-1, (far_height - floor_height) * 0.5, -4)
	body.rotation.x = angle
	house.add_child(body)
	_box_collision(body, Vector3(1.2, 0.18, length), Vector3(0, -0.08, 0))
	var visual := MeshInstance3D.new()
	var ramp := BoxMesh.new()
	ramp.size = Vector3(1.2, 0.14, length)
	visual.mesh = ramp
	visual.position.y = -0.07
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.32, 0.23)
	visual.material_override = mat
	body.add_child(visual)
