extends Node3D
## Two compact optional Hollows, each streamed only while inside.
const DESIGNS := preload("res://scripts/story_hollow_designs.gd")
const OPTIONAL := preload("res://scripts/optional_dungeons.gd")
const COLUMN := preload("res://assets/dungeon/column.gltf.glb")
const STORY_DUNGEONS := preload("res://scripts/story_dungeons.gd")
const FLOOR := preload("res://assets/dungeon/floor_tile_large.gltf.glb")
const WALL := preload("res://assets/dungeon/wall.gltf.glb")
const DOOR := preload("res://assets/dungeon/wall_doorway.glb")
const TORCH := preload("res://assets/dungeon/torch_lit.gltf.glb")
const CHEST := preload("res://assets/dungeon/chest.glb")
const WARDEN := preload("res://scripts/hollow_warden.gd")
const SENTRY := preload("res://scripts/hollow_sentry.gd")
const ALTITUDE := 500.0
var dungeon_id := "ashvale"
var _story_entry: Dictionary = {}
var _optional_entry: Dictionary = {}
var _sentries_left := 0
var _design: Dictionary = {}
var _runes_found := [false, false]
var _rune_nodes: Array[Node3D] = []
var player: CharacterBody3D
var entrance := Vector3.ZERO
var return_point := Vector3.ZERO
var inside := false
var chamber: Node3D
var boss: Node3D
var _exit_point := Vector3.ZERO


func setup(world: Node3D, actor: CharacterBody3D, center: Vector2, which: String = "ashvale") -> void:
	dungeon_id = which
	_story_entry = STORY_DUNGEONS.by_id(which)
	_design = DESIGNS.get_design(which)
	_optional_entry = OPTIONAL.by_id(which)
	player = actor
	var p := center + Vector2(0, -22)
	entrance = Vector3(p.x, float(world.call("_height", p.x, p.y)), p.y)
	position = entrance
	var door := DOOR.instantiate() as Node3D
	add_child(door)
	var label := Label3D.new()
	var title := str(_optional_entry["name"]) if not _optional_entry.is_empty() else (str(_story_entry.get("name", "")) if not _story_entry.is_empty() else ("SUNCREST ROOST" if dungeon_id == "roost" else ("MEMORY VAULT" if dungeon_id == "vault" else "ASHVALE HOLLOW")))
	label.text = "%s\nF / Talk to enter · Challenging" % title.to_upper()
	label.position = Vector3(0, 4.5, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.006
	label.outline_size = 8
	add_child(label)
	Game.respawned.connect(_on_respawn)


func try_interact(actor: Node3D) -> bool:
	if inside:
		if not _is_cleared() and _try_rune(actor): return true
		if _is_cleared() and is_instance_valid(chamber):
			var chest := chamber.get_node_or_null("VictoryChest") as Node3D
			if chest != null and actor.global_position.distance_to(chest.global_position) < 3.5:
				if dungeon_id == "ashvale":
					if not Game.collect_hollow_memory():
						Game.toast.emit("The memory fragment has already been recovered.")
				else:
					Game.toast.emit("This dungeon's reward has already been claimed.")
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
	_runes_found = [false, false]
	_rune_nodes.clear()
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
			if not (_design.size() > 0 and int(_design["side"]) == side and i == 0):
				var side_wall := WALL.instantiate() as Node3D
				side_wall.position = Vector3(side * 10, 0, i * 4)
				side_wall.rotation.y = PI / 2.0
				chamber.add_child(side_wall)
	_box(chamber, Vector3(0, -0.20, 0), Vector3(20, 0.4, 20))
	_box(chamber, Vector3(0, 2, -10), Vector3(20, 4, 0.5))
	_box(chamber, Vector3(0, 2, 10), Vector3(20, 4, 0.5))
	for side in [-1, 1]:
		if not _design.is_empty() and int(_design["side"]) == side:
			_box(chamber, Vector3(side * 10, 2, -6), Vector3(0.5, 4, 8))
			_box(chamber, Vector3(side * 10, 2, 6), Vector3(0.5, 4, 8))
		else:
			_box(chamber, Vector3(side * 10, 2, 0), Vector3(0.5, 4, 20))
	if not _design.is_empty(): _build_story_annex()
	for x in [-8.0, 8.0]:
		for z in [-8.0, 8.0]:
			var torch := TORCH.instantiate() as Node3D
			torch.position = Vector3(x, 1.2, z)
			chamber.add_child(torch)
	if not _optional_entry.is_empty():
		var decoration_count := 2 + int(_optional_entry["slot"]) % 3
		var column_points := [Vector3(-7, 0, -5), Vector3(7, 0, -5), Vector3(-7, 0, 4), Vector3(7, 0, 4)]
		for index in range(decoration_count):
			var column := COLUMN.instantiate() as Node3D
			column.position = column_points[index]
			chamber.add_child(column)
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
	if not _is_cleared():
		var encounter_rank := int(_optional_entry.get("rank", 0)) if not _optional_entry.is_empty() else int(dungeon_id.trim_prefix("memory_"))
		_sentries_left = 2 + encounter_rank % 3 if not _story_entry.is_empty() or not _optional_entry.is_empty() else 2
		var positions := [Vector3(-4, 0.15, -2), Vector3(4, 0.15, -2), Vector3(-5, 0.15, 2), Vector3(5, 0.15, 2)]
		for index in range(_sentries_left):
			var scout := SENTRY.new()
			scout.is_orc = dungeon_id == "vault" or ((not _story_entry.is_empty() or not _optional_entry.is_empty()) and (index + encounter_rank) % 2 == 0)
			scout.position = positions[index]
			chamber.add_child(scout)
			scout.defeated.connect(_on_sentry_defeated)
		if _design.is_empty():
			Game.toast.emit("Defeat the guardians. Dodge the red circles! Exit is at the rear right.")
		else:
			Game.toast.emit("%s: defeat guardians and recover both echoes to awaken the guardian." % _design["theme"])
	else:
		_add_chest()
		Game.toast.emit("This Hollow is cleared. Leave when ready.")


func _build_story_annex() -> void:
	var side: int = int(_design["side"])
	# Open a doorway into a small separately furnished side chamber.
	for x in [12, 16]:
		for z in [-4, 0, 4]:
			var tile := FLOOR.instantiate() as Node3D
			tile.position = Vector3(side * x, 0, z)
			chamber.add_child(tile)
			var ceiling := FLOOR.instantiate() as Node3D
			ceiling.position = Vector3(side * x, 5, z)
			ceiling.rotation.x = PI
			chamber.add_child(ceiling)
	_box(chamber, Vector3(side * 14, -0.2, 0), Vector3(8, 0.4, 12))
	_box(chamber, Vector3(side * 18, 2, 0), Vector3(0.5, 4, 12))
	for z in [-6, 6]:
		_box(chamber, Vector3(side * 14, 2, z), Vector3(8, 4, 0.5))
		for x in [12, 16]:
			var wall := WALL.instantiate() as Node3D
			wall.position = Vector3(side * x, 0, z)
			chamber.add_child(wall)
	for z in [-4, 0, 4]:
		var end_wall := WALL.instantiate() as Node3D
		end_wall.position = Vector3(side * 18, 0, z)
		end_wall.rotation.y = PI / 2.0
		chamber.add_child(end_wall)
	for point in _design["columns"]:
		var column := COLUMN.instantiate() as Node3D
		column.position = point
		chamber.add_child(column)
	for index in range(2):
		var rune := Node3D.new()
		rune.name = "StoryEcho%d" % index
		rune.position = _design["runes"][index]
		chamber.add_child(rune)
		var marker := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.36
		sphere.height = 0.72
		marker.mesh = sphere
		marker.position.y = 1.1
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = _design["color"]
		marker.material_override = material
		rune.add_child(marker)
		var label := Label3D.new()
		label.text = "F / Talk · Recall echo %d / 2" % (index + 1)
		label.position.y = 2.0
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 36
		label.pixel_size = 0.003
		label.outline_size = 6
		rune.add_child(label)
		_rune_nodes.append(rune)


func _try_rune(actor: Node3D) -> bool:
	if _design.is_empty(): return false
	for index in range(_rune_nodes.size()):
		var rune := _rune_nodes[index]
		if is_instance_valid(rune) and actor.global_position.distance_to(rune.global_position) < 3.0:
			if _runes_found[index]:
				Game.toast.emit("This echo has already been recalled.")
				return true
			_runes_found[index] = true
			var label := rune.get_child(1) as Label3D
			label.text = "Echo recalled"
			Game.toast.emit(str(_design["first" if index == 0 else "second"]))
			if _runes_found[0] and _runes_found[1] and _sentries_left == 0: _spawn_warden()
			return true
	return false


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


func _is_cleared() -> bool:
	if dungeon_id == "ashvale": return Game.ashvale_hollow_cleared
	if not _story_entry.is_empty() or not _optional_entry.is_empty(): return bool(Game.dungeon_clears.get(dungeon_id, false))
	return bool(Game.dungeon_clears.get("memory_vault" if dungeon_id == "vault" else "suncrest_roost", false))


func _on_sentry_defeated() -> void:
	if not inside or _sentries_left <= 0: return
	_sentries_left -= 1
	if _sentries_left == 0:
		if _design.is_empty() or (_runes_found[0] and _runes_found[1]):
			_spawn_warden()
		else:
			Game.toast.emit("Guardians defeated. Recover both glowing echoes, including the one in the side chamber.")
	else:
		Game.toast.emit("%d guardian(s) remain." % _sentries_left)


func _spawn_warden() -> void:
	if not inside or not is_instance_valid(chamber) or is_instance_valid(boss): return
	boss = WARDEN.new()
	boss.set("is_vault", dungeon_id == "vault")
	boss.set("is_dragon", dungeon_id == "roost")
	if not _story_entry.is_empty() or not _optional_entry.is_empty():
		var rank := int(_optional_entry.get("rank", 0)) if not _optional_entry.is_empty() else int(dungeon_id.trim_prefix("memory_"))
		var encounter_name := str(_optional_entry.get("name", "")) if not _optional_entry.is_empty() else str(_story_entry["name"])
		boss.set("is_dragon", rank % 3 == 0)
		boss.set("is_vault", rank % 3 == 1)
		boss.set("custom_name", str(_design.get("boss", "Guardian of " + encounter_name)))
		boss.set("difficulty_scale", 1.0 + float(rank % 26) * 0.02)
	boss.position = Vector3(0, 0.15, -4)
	chamber.add_child(boss)
	boss.connect("defeated", _on_defeated)
	Game.toast.emit("A guardian awakened! Watch its attacks.")


func _on_defeated() -> void:
	if not _is_cleared():
		if not _optional_entry.is_empty():
			var rank := int(_optional_entry["rank"])
			Game.dungeon_clears[dungeon_id] = true
			var coin_reward := 60 + (rank % 10) * 5
			var light_reward := 15 + (rank % 6) * 3
			Game.coins += coin_reward
			Game.starlight += light_reward
			Game.toast.emit("%s cleared: +%d Ane, +%d starlight." % [_optional_entry["name"], coin_reward, light_reward])
		elif not _story_entry.is_empty():
			var rank := int(dungeon_id.trim_prefix("memory_"))
			Game.dungeon_clears[dungeon_id] = true
			Game.coins += 100 + rank * 2
			Game.starlight += 25 + rank
			var reward_spell: String = Game.grant_memory_spell(dungeon_id)
			var spell_message := " · new spell: " + str(Game.wander.spell(reward_spell).get("name", reward_spell)) if not reward_spell.is_empty() and Game.wander != null else ""
			Game.toast.emit("Memory recovered: %s (%d / 25)%s." % [_story_entry["name"], Game.story_memory_count(), spell_message])
		elif dungeon_id == "roost":
			Game.dungeon_clears["suncrest_roost"] = true
			Game.starlight += 60
			Game.coins += 200
			Game.toast.emit("Suncrest Roost cleared: a memory, 60 starlight, 200 Ane!")
		elif dungeon_id == "vault":
			Game.dungeon_clears["memory_vault"] = true
			Game.starlight += 50
			Game.coins += 150
			# Mark complete before learn() can emit the autosave signal.
			Game.wander_levels["verdant_bloom"] = 1
			if Game.wander != null:
				Game.wander.learn("verdant_bloom")
				Game.save_wander()
			Game.toast.emit("Memory Vault cleared: Verdant Bloom, 50 starlight, 150 Ane!")
		else:
			Game.ashvale_hollow_cleared = true
			Game.starlight += 30
			Game.coins += 100
			Game.toast.emit("Hollow cleared! +30 starlight, +100 Ane. Search the chest.")
		Game.save_collection()
		Game.collection_changed.emit()
	_add_chest()


func _add_chest() -> void:
	if chamber == null or chamber.has_node("VictoryChest"): return
	var chest := CHEST.instantiate() as Node3D
	chest.name = "VictoryChest"
	chest.position = Vector3(0, 0.05, -6)
	chamber.add_child(chest)
	var label := Label3D.new()
	label.text = "F / Talk · Memory fragment" if dungeon_id == "ashvale" else "Dungeon cleared · reward claimed"
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
	Game.toast.emit("Left the dungeon. You can return and try again.")


func _on_respawn() -> void:
	if inside:
		inside = false
		if is_instance_valid(chamber): chamber.queue_free()
		chamber = null
		boss = null
		Game.toast.emit("You escaped the Hollow. Prepare and try again.")
