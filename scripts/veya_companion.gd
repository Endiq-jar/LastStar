extends "res://scripts/settler.gd"
## Veya travels with her existing Lunareth identity after her personal quest.
## Her Gift slows one nearby scout; with Neri present it also interrupts it.
var _support_cooldown := 12.0


func _ready() -> void:
	set("site_id", "lunareth")
	set("resident_index", 0)
	super._ready()
	Game.collection_changed.connect(_sync_following)
	_sync_following()


func _sync_following() -> void:
	var following := bool(Game.guard_story.get("veya_following", false)) and int(Game.guard_story.get("wander_story_stage", 0)) == 4
	visible = following
	if following: add_to_group("story_npc")
	else: remove_from_group("story_npc")


func _process(delta: float) -> void:
	if Game.is_paused or not visible: return
	var player := get_tree().get_first_node_in_group("player") as CharacterBody3D
	if player == null: return
	var desired := player.global_position + Vector3(-1.7, 0, -1.7)
	var terrain := get_parent().get_node_or_null("Terrain")
	if terrain != null and player.global_position.y < 400.0 and not Game.in_final_dungeon:
		desired.y = float(terrain.call("get_height_at", desired.x, desired.z))
	else:
		desired.y = player.global_position.y
	var distance := global_position.distance_to(desired)
	if distance > 20.0: global_position = desired
	elif distance > 2.0: global_position = global_position.move_toward(desired, 4.5 * delta)
	_support_cooldown = maxf(0.0, _support_cooldown - delta)
	if _support_cooldown > 0.0: return
	for foe in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(foe) or foe.is_queued_for_deletion() or not foe is Node3D or not foe.has_method("apply_slow"): continue
		if foe.global_position.distance_to(player.global_position) >= 12.0: continue
		var ray := PhysicsRayQueryParameters3D.create(player.global_position + Vector3(0, 1, 0), foe.global_position + Vector3(0, 0.8, 0), 1)
		ray.exclude = [player.get_rid()]
		if not player.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(): continue
		_support_cooldown = 22.0
		foe.call("apply_slow", 4.0)
		if bool(Game.guard_story.get("neri_following", false)) and int(Game.guard_story.get("harbor_stage", 0)) == 3 and foe.has_method("interrupt_attack"):
			foe.call("interrupt_attack", 1.2)
			Game.toast.emit("Veya and Neri: a warning breaks the scout's attack")
		else:
			Game.toast.emit("Veya's Gift: a nearby scout is slowed")
		break
