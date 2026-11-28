extends Node3D
## Transient encounter; only a successful rescue is persisted. Leaving the
## streamed settlement or respawning discards the wave and permits a retry.
const SCOUT := preload("res://scripts/hollow_sentry.gd")
var _active := false
var _remaining := 0
var _label: Label3D


func _ready() -> void:
	add_to_group("story_interaction")
	Game.respawned.connect(_reset_wave)
	var pack := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.9, 0.65, 0.65)
	pack.mesh = mesh
	pack.position.y = 0.33
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.48, 0.29, 0.17)
	pack.material_override = mat
	pack.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pack)
	_label = Label3D.new()
	_label.text = "F / Talk · Search the stranded caravan"
	_label.position.y = 1.5
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 36
	_label.pixel_size = 0.004
	_label.outline_size = 6
	add_child(_label)


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or int(Game.guard_story.get("caravan_stage", 0)) != 2: return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Search the stranded caravan", "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	if _active:
		Game.toast.emit("The caravan is sheltering. %d attackers remain." % _remaining)
		return true
	_active = true
	_remaining = 2
	_label.text = "Protect the caravan · 2 attackers"
	for index in range(2):
		var scout := SCOUT.new()
		scout.name = "CaravanAttacker%d" % index
		scout.is_orc = index == 1
		scout.position = Vector3(-5.0 if index == 0 else 5.0, 0.2, -6.0)
		add_child(scout)
		scout.defeated.connect(_attacker_defeated)
	Game.toast.emit("The caravan sheltered behind its packs. Defeat both attackers.")
	return true


func _attacker_defeated() -> void:
	if not _active: return
	_remaining -= 1
	if _remaining > 0:
		_label.text = "Protect the caravan · %d attacker" % _remaining
		return
	_active = false
	if Game.rescue_caravan():
		Game.toast.emit("The caravan can reach Frostmere. Tell Zara in Suncrest what happened.")


func _reset_wave() -> void:
	if not _active: return
	_active = false
	_remaining = 0
	for child in get_children():
		if child is CharacterBody3D:
			child.remove_from_group("enemy")
			child.queue_free()
	_label.text = "F / Talk · Search the stranded caravan"
	Game.toast.emit("The caravan remains sheltered. Return to try again.")
