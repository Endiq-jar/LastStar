extends "res://scripts/settler.gd"
## Neri keeps her settlement dialogue identity while travelling. Her defensive
## support and position are independent of the streamed Tidefall settlement.
var _support_cooldown := 10.0


func _ready() -> void:
	set("site_id", "tidefall")
	set("resident_index", 0)
	super._ready()
	Game.collection_changed.connect(_sync_following)
	_sync_following()


func _sync_following() -> void:
	var following := bool(Game.guard_story.get("neri_following", false)) and int(Game.guard_story.get("harbor_stage", 0)) == 3
	visible = following
	if following:
		add_to_group("story_npc")
	else:
		remove_from_group("story_npc")


func _process(delta: float) -> void:
	if Game.is_paused or not visible: return
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null: return
	var desired := player.global_position + Vector3(-1.7, 0, 1.7)
	var terrain := get_parent().get_node_or_null("Terrain")
	if terrain != null and player.global_position.y < 400.0 and not Game.in_final_dungeon:
		desired.y = float(terrain.call("get_height_at", desired.x, desired.z))
	else:
		desired.y = player.global_position.y
	var distance := global_position.distance_to(desired)
	if distance > 20.0:
		global_position = desired
	elif distance > 2.0:
		global_position = global_position.move_toward(desired, 4.5 * delta)
	_support_cooldown = maxf(0.0, _support_cooldown - delta)
	if _support_cooldown > 0.0: return
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if enemy is Node3D and is_instance_valid(enemy) and not enemy.is_queued_for_deletion() and enemy.global_position.distance_to(player.global_position) < 16.0:
			if Game.energy < Game.MAX_ENERGY * 0.8:
				_support_cooldown = 20.0
				Game.add_energy(14.0)
				if bool(Game.guard_story.get("ilyra_following", false)):
					Game.shield_points = maxf(Game.shield_points, 35.0)
					Game.stats_changed.emit()
					Game.toast.emit("Neri and Ilyra: +14 Light and a shared ward")
				else:
					Game.toast.emit("Neri's Gift: +14 Light")
				break
