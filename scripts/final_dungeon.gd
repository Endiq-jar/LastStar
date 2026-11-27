extends Node3D
## The descent is built only while entered. Each guarded gate locks until its
## defenders are defeated; dying or leaving resets the current expedition.
const DOOR := preload("res://assets/dungeon/wall_doorway.glb")
const TORCH := preload("res://assets/dungeon/torch_lit.gltf.glb")
const SENTRY := preload("res://scripts/hollow_sentry.gd")
const BOSS := preload("res://scripts/hollow_warden.gd")
const SECTOR_LENGTH := 100.0
const SECTORS := 10
const DESCENT_PER_SECTOR := 8.0
const START_DEPTH := -100.0
var entrance := Vector3.ZERO
var player: CharacterBody3D
var return_point := Vector3.ZERO
var inside := false
var chamber: Node3D
var boss: Node3D
var sector := 0
var _remaining := 0
var _gates: Array[Node3D] = []
var _story_echoes: Array[Node3D] = []
var _exit: Vector3
var _arena_exit: Vector3
var _checkpoint: Vector3


func setup(world: Node3D, actor: CharacterBody3D, center: Vector2) -> void:
	player = actor
	var p := center + Vector2(0, -42)
	entrance = Vector3(p.x, float(world.call("_height", p.x, p.y)), p.y)
	position = entrance
	add_child(DOOR.instantiate())
	var label := Label3D.new()
	label.text = "THE LAST SEAL\nF / Talk · Original 100 Hollows required"
	label.position.y = 4.5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.006
	label.outline_size = 8
	add_child(label)
	Game.respawned.connect(_on_respawn)


func try_interact(actor: Node3D) -> bool:
	if inside:
		for echo in _story_echoes:
			if is_instance_valid(echo) and actor.global_position.distance_to(echo.global_position) < 3.5:
				Game.toast.emit(str(echo.get_meta("story")))
				return true
		if actor.global_position.distance_to(_exit) < 4.0 or actor.global_position.distance_to(_arena_exit) < 4.0:
			_leave()
			return true
	elif actor.global_position.distance_to(entrance) < 5.0:
		if not Game.can_enter_finale():
			Game.toast.emit("Resolve Ilyra's memory quest and clear the original 100 Hollows (%d / 100)." % Game.original_hollow_clear_count())
		else:
			_enter()
		return true
	return false


func _enter() -> void:
	if inside or not is_instance_valid(player): return
	return_point = player.global_position
	inside = true
	Game.in_final_dungeon = true
	sector = 0
	_remaining = 0
	_gates.clear()
	_story_echoes.clear()
	chamber = Node3D.new()
	chamber.name = "LastSealDepths"
	get_parent().add_child(chamber)
	chamber.global_position = Vector3(entrance.x, START_DEPTH, entrance.z)
	var angle := -atan2(DESCENT_PER_SECTOR, SECTOR_LENGTH)
	var length := sqrt(SECTOR_LENGTH * SECTOR_LENGTH + DESCENT_PER_SECTOR * DESCENT_PER_SECTOR)
	for i in range(SECTORS):
		var mid := Vector3(0, -DESCENT_PER_SECTOR * (float(i) + 0.5), -SECTOR_LENGTH * (float(i) + 0.5))
		_block(chamber, mid + Vector3(0, -0.5, 0), Vector3(12, 1, length + 0.1), Color(0.22, 0.20, 0.29), angle)
		_block(chamber, mid + Vector3(-6, 2.5, 0), Vector3(0.6, 6, length + 0.1), Color(0.18, 0.16, 0.23), angle)
		_block(chamber, mid + Vector3(6, 2.5, 0), Vector3(0.6, 6, length + 0.1), Color(0.18, 0.16, 0.23), angle)
		_block(chamber, mid + Vector3(0, 5.5, 0), Vector3(12, 0.6, length + 0.1), Color(0.16, 0.14, 0.21), angle)
		var gate_z := -SECTOR_LENGTH * (float(i) + 1.0) + 4.0
		var gate_y := -DESCENT_PER_SECTOR * (float(i) + 0.96)
		var gate := _block(chamber, Vector3(0, gate_y + 2.4, gate_z), Vector3(11.5, 5, 0.65), Color(0.45, 0.18, 0.30))
		gate.name = "GuardGate%d" % i
		_gates.append(gate)
		for z_offset in [25.0, 75.0]:
			var torch := TORCH.instantiate() as Node3D
			torch.position = Vector3(5.3, -DESCENT_PER_SECTOR * (float(i) + z_offset / SECTOR_LENGTH) + 1.2, -SECTOR_LENGTH * i - z_offset)
			torch.rotation.y = -PI / 2
			chamber.add_child(torch)
	# Optional echoes give the Keeper and the witnesses a voice on the descent.
	# They never lock progress, rewards or a returning player's route.
	for index in range(Game.STORY_CHRONICLE.FINAL_ECHOES.size()):
		var echo := Node3D.new()
		echo.name = "LastSealEcho%d" % (index + 1)
		var depth := 50.0 + float(index) * 300.0
		echo.position = Vector3(-4, -DESCENT_PER_SECTOR * depth / SECTOR_LENGTH, -depth)
		echo.set_meta("story", Game.STORY_CHRONICLE.FINAL_ECHOES[index])
		chamber.add_child(echo)
		var echo_label := Label3D.new()
		echo_label.text = "F / Talk · Listen to an echo"
		echo_label.position.y = 1.8
		echo_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		echo_label.font_size = 32
		echo_label.pixel_size = 0.004
		echo.add_child(echo_label)
		_story_echoes.append(echo)
	# Closed arena is a continuation of the descending kilometre corridor.
	_block(chamber, Vector3(0, -80.5, -1010), Vector3(20, 1, 20), Color(0.24, 0.20, 0.29))
	_block(chamber, Vector3(-10, -77, -1010), Vector3(0.5, 7, 20), Color(0.18, 0.16, 0.23))
	_block(chamber, Vector3(10, -77, -1010), Vector3(0.5, 7, 20), Color(0.18, 0.16, 0.23))
	_block(chamber, Vector3(0, -77, -1020), Vector3(20, 7, 0.5), Color(0.18, 0.16, 0.23))
	_block(chamber, Vector3(0, -73.5, -1010), Vector3(20, 0.5, 20), Color(0.16, 0.14, 0.21))
	_exit = chamber.to_global(Vector3(0, 0, -3))
	_arena_exit = chamber.to_global(Vector3(7, -80, -1015))
	_marker("F / Talk · Leave the depths", Vector3(0, 2, -3))
	_marker("F / Talk · Return to Aetheris", Vector3(7, -78, -1015))
	_checkpoint = chamber.to_global(Vector3(0, 1.6, -3))
	player.global_position = _checkpoint
	player.velocity = Vector3.ZERO
	if bool(Game.guard_story.get("keeper_defeated", false)):
		for gate in _gates: gate.queue_free()
		Game.toast.emit("The Keeper is defeated. The Last Seal remembers.")
	else:
		_spawn_guardians()
		Game.toast.emit("The Last Seal: defeat each pair of guardians to open the way down.")


func _spawn_guardians() -> void:
	if not inside or sector >= SECTORS: return
	_remaining = 2
	for x in [-2.5, 2.5]:
		var scout := SENTRY.new()
		scout.set("_power_multiplier", 15000.0)
		scout.is_orc = sector % 2 == 1
		scout.position = Vector3(x, -DESCENT_PER_SECTOR * (float(sector) + 0.65) + 0.2, -SECTOR_LENGTH * (float(sector) + 0.65))
		chamber.add_child(scout)
		scout.defeated.connect(_guardian_defeated)


func _guardian_defeated() -> void:
	if not inside or _remaining <= 0: return
	_remaining -= 1
	if _remaining != 0: return
	if is_instance_valid(_gates[sector]): _gates[sector].queue_free()
	sector += 1
	# A checkpoint after each gate makes the long descent fair without changing
	# the player's overworld waypoint or persisting a half-finished expedition.
	_checkpoint = chamber.to_global(Vector3(0, -DESCENT_PER_SECTOR * sector + 1.6, -SECTOR_LENGTH * sector + 1.0))
	if sector == SECTORS:
		_spawn_keeper()
	else:
		_spawn_guardians()
		Game.toast.emit("Gate opened · depth %d / %d" % [sector * 100, SECTORS * 100])


func _spawn_keeper() -> void:
	boss = BOSS.new()
	boss.set("_power_multiplier", 15000.0)
	boss.set("is_keeper", true)
	boss.position = Vector3(0, -79.8, -1013)
	chamber.add_child(boss)
	boss.connect("defeated", _keeper_defeated)
	Game.toast.emit("The Keeper: I will not let the world lose anyone again. Watch for the star slash!")


func _keeper_defeated() -> void:
	if not bool(Game.guard_story.get("keeper_defeated", false)):
		Game.guard_story["keeper_defeated"] = true
		Game.coins += 1000
		Game.starlight += 200
		Game.save_collection()
		Game.collection_changed.emit()
	Game.toast.emit("The Keeper falls. The Seals hold, and Elaris remembers. +1000 Ane, +200 starlight.")


func _marker(text: String, at: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = at
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 32
	label.pixel_size = 0.004
	label.outline_size = 6
	chamber.add_child(label)


func _block(parent: Node3D, at: Vector3, size: Vector3, color: Color, angle: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	body.rotation.x = angle
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	visual.material_override = material
	body.add_child(visual)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	return body


func _leave() -> void:
	if not inside: return
	inside = false
	Game.in_final_dungeon = false
	player.global_position = return_point + Vector3(0, 0.3, 0)
	player.velocity = Vector3.ZERO
	if is_instance_valid(chamber): chamber.queue_free()
	chamber = null
	boss = null
	_gates.clear()
	_story_echoes.clear()
	Game.toast.emit("You returned from the Last Seal.")


func _on_respawn() -> void:
	if not inside or not is_instance_valid(chamber) or not is_instance_valid(player): return
	# Player's normal respawn runs first; return to the last opened gate after it.
	Game.in_final_dungeon = true
	player.global_position = _checkpoint
	player.velocity = Vector3.ZERO
	if is_instance_valid(boss) and not boss.is_queued_for_deletion():
		boss.call("reset_encounter")
	Game.toast.emit("Returned to the last open gate. The Keeper recovers between attempts.")
