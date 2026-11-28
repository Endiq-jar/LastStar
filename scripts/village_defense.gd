extends Node3D
## Optional Frostmere defense. An interrupted wave is transient and can be
## retried; only a completed defense is written to the story save.
const SCOUT := preload("res://scripts/hollow_sentry.gd")
var _active := false
var _remaining := 0
var _label: Label3D


func _ready() -> void:
	add_to_group("story_interaction")
	Game.respawned.connect(_reset_wave)
	var pedestal := MeshInstance3D.new()
	var stone := CylinderMesh.new()
	stone.top_radius = 0.35
	stone.bottom_radius = 0.5
	stone.height = 0.8
	stone.radial_segments = 8
	pedestal.mesh = stone
	pedestal.position.y = 0.4
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.36, 0.46, 0.52)
	pedestal.material_override = material
	pedestal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pedestal)
	_label = Label3D.new()
	_label.text = "F / Talk · Signal Frostmere's watch"
	_label.position.y = 1.5
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 36
	_label.pixel_size = 0.004
	_label.outline_size = 6
	add_child(_label)


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or int(Game.guard_story.get("watch_stage", 0)) != 1: return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Signal Frostmere's watch", "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	if _active:
		Game.toast.emit("Frostmere's watch: %d attackers remain." % _remaining)
		return true
	_active = true
	_remaining = 2
	_label.text = "Defend the watch · 2 attackers"
	for index in range(2):
		var scout := SCOUT.new()
		scout.name = "WatchAttacker%d" % index
		scout.is_orc = index == 1
		scout.position = Vector3(-5.0 if index == 0 else 5.0, 0.2, -6.0)
		add_child(scout)
		scout.defeated.connect(_attacker_defeated)
	Game.toast.emit("The watch is lit. Defeat both attackers; dodge their marked strikes.")
	return true


func _attacker_defeated() -> void:
	if not _active: return
	_remaining -= 1
	if _remaining > 0:
		_label.text = "Defend the watch · %d attacker" % _remaining
		return
	_active = false
	if Game.complete_watch_defense():
		Game.toast.emit("The watch held. Return to Bryn in Frostmere.")


func _reset_wave() -> void:
	if not _active: return
	_active = false
	_remaining = 0
	for child in get_children():
		if child is CharacterBody3D:
			child.remove_from_group("enemy")
			child.queue_free()
	_label.text = "F / Talk · Signal Frostmere's watch"
	Game.toast.emit("The attack withdrew. Return to the watch to try again.")
