extends Node3D
## Stream the reusable story Hollows only near their entrances.
const DATA := preload("res://scripts/story_dungeons.gd")
const OPTIONAL := preload("res://scripts/optional_dungeons.gd")
const HOLLOW := preload("res://scripts/ashvale_hollow.gd")
const LOAD_DISTANCE := 150.0
const UNLOAD_DISTANCE := 200.0
var _world: Node3D
var _player: CharacterBody3D
var _locations: Array[Dictionary] = []
var _loaded: Dictionary = {}
var _extra_locations: Array[Dictionary] = []
var _clock := 0.0


func setup(world: Node3D, player: CharacterBody3D, sites: Array) -> void:
	_world = world
	_player = player
	for entry in DATA.ENTRIES:
		var site: Dictionary = sites[int(entry["site"])]
		var center: Vector2 = site["resolved"]
		var direction := -1.0 if int(entry["slot"]) == 0 else 1.0
		var ideal := center + Vector2(40.0 * direction, 32.0)
		var pos := _dry_location(ideal, center)
		_locations.append({"id": entry["id"], "pos": pos})
	for index in range(OPTIONAL.COUNT):
		var option: Dictionary = OPTIONAL.entry(index)
		var site: Dictionary = sites[int(option["site"])]
		var center: Vector2 = site["resolved"]
		var angle: float = TAU * float(option["slot"]) / 6.0 + float(option["site"]) * 0.13
		var ideal: Vector2 = center + Vector2(cos(angle), sin(angle)) * 115.0
		var pos := _optional_location(ideal, center)
		_extra_locations.append({"id": option["id"], "pos": pos})
	_update_stream()


func _dry_location(ideal: Vector2, settlement: Vector2) -> Vector2:
	for radius in [0.0, 12.0, 24.0, 36.0, 48.0]:
		for n in range(8):
			var point: Vector2 = ideal + Vector2(cos(TAU * n / 8.0), sin(TAU * n / 8.0)) * radius
			if point.distance_to(settlement) < 30.0 or bool(_world.call("_is_wet", point.x, point.y)): continue
			var y := float(_world.call("_height", point.x, point.y))
			var suitable := true
			for offset in [Vector2(3, 0), Vector2(-3, 0), Vector2(0, 3), Vector2(0, -3)]:
				var sample: Vector2 = point + offset
				if bool(_world.call("_is_wet", sample.x, sample.y)) or absf(float(_world.call("_height", sample.x, sample.y)) - y) > 2.0:
					suitable = false
			if suitable: return point
	return ideal


func _optional_location(ideal: Vector2, settlement: Vector2) -> Vector2:
	for radius in [0.0, 12.0, 24.0, 36.0, 48.0, 60.0, 84.0]:
		for n in range(8):
			var point: Vector2 = ideal + Vector2(cos(TAU * n / 8.0), sin(TAU * n / 8.0)) * radius
			if point.distance_to(settlement) < 65.0 or bool(_world.call("_is_wet", point.x, point.y)): continue
			var near := false
			for existing in _locations + _extra_locations:
				if point.distance_to(existing["pos"]) < 18.0:
					near = true
					break
			if near: continue
			var height := float(_world.call("_height", point.x, point.y))
			var good := true
			for offset in [Vector2(3, 0), Vector2(-3, 0), Vector2(0, 3), Vector2(0, -3)]:
				var sample: Vector2 = point + offset
				if bool(_world.call("_is_wet", sample.x, sample.y)) or absf(float(_world.call("_height", sample.x, sample.y)) - height) > 2.0: good = false
			if good: return point
	# Deterministic fallback; callers can identify it in the site census.
	return ideal


func _process(delta: float) -> void:
	_clock -= delta
	if _clock <= 0.0:
		_clock = 1.0
		_update_stream()


func _update_stream() -> void:
	if not is_instance_valid(_player): return
	var player_pos := Vector2(_player.global_position.x, _player.global_position.z)
	for entry in _locations + _extra_locations:
		var id: String = entry["id"]
		var point: Vector2 = entry["pos"]
		var distance := player_pos.distance_to(point)
		if distance < LOAD_DISTANCE and not _loaded.has(id):
			var hollow := HOLLOW.new()
			hollow.name = "StoryHollow_" + id
			add_child(hollow)
			hollow.add_to_group("hollow_entrance")
			hollow.setup(_world, _player, point + Vector2(0, 22), id)
			_loaded[id] = hollow
		elif distance > UNLOAD_DISTANCE and _loaded.has(id):
			var hollow: Node = _loaded[id]
			# Keep the active dungeon alive even if its coordinates lie far away.
			if bool(hollow.get("inside")): continue
			_loaded.erase(id)
			hollow.remove_from_group("hollow_entrance")
			hollow.queue_free()
