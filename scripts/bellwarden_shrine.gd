extends Node3D
## Optional challenge in The Fortress Wall. The encounter belongs to the
## streamed Hollow: retreating, dying or unloading discards it and permits retry.
const WARDEN := preload("res://scripts/hollow_warden.gd")
var _guardian: CharacterBody3D
var _label: Label3D


func _ready() -> void:
	add_to_group("story_interaction")
	var stone := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.45
	mesh.bottom_radius = 0.65
	mesh.height = 0.8
	mesh.radial_segments = 8
	stone.mesh = mesh
	stone.position.y = 0.4
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.30, 0.31, 0.36)
	stone.material_override = material
	stone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(stone)
	var bell := MeshInstance3D.new()
	var bell_mesh := CylinderMesh.new()
	bell_mesh.top_radius = 0.25
	bell_mesh.bottom_radius = 0.4
	bell_mesh.height = 0.6
	bell_mesh.radial_segments = 8
	bell.mesh = bell_mesh
	bell.position.y = 1.15
	var bronze := StandardMaterial3D.new()
	bronze.albedo_color = Color(0.47, 0.32, 0.17)
	bell.material_override = bronze
	bell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bell)
	_label = Label3D.new()
	_label.position.y = 1.85
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 36
	_label.pixel_size = 0.004
	_label.outline_size = 6
	add_child(_label)
	_update_label()


func _update_label() -> void:
	_label.text = "The bell is quiet" if bool(Game.guard_story.get("bellwarden_done", false)) else "F / Talk · Examine the cracked bell"


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or not Game.story_memory_owned("memory_20"): return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Examine the cracked bell", "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	if bool(Game.guard_story.get("bellwarden_done", false)):
		Game.toast.emit("The bell no longer calls a defender. Its inscription reads: The last person through the gate is still one of us.")
		return true
	if is_instance_valid(_guardian) and not _guardian.is_queued_for_deletion():
		Game.toast.emit("The Bellwarden still guards the retreat. Watch its attacks.")
		return true
	_guardian = WARDEN.new()
	_guardian.name = "Bellwarden"
	_guardian.set("custom_name", "The Bellwarden")
	_guardian.set("is_vault", true)
	_guardian.set("attack_profile", "ring")
	_guardian.set("_power_multiplier", 3.0)
	_guardian.position = Vector3(0, 0.2, 5)
	add_child(_guardian)
	_guardian.connect("defeated", _guardian_defeated)
	Game.toast.emit("The cracked bell answers. A forgotten guardian rises; this optional foe is stronger than the Hollow's keeper.")
	return true


func _guardian_defeated() -> void:
	if Game.complete_bellwarden():
		_update_label()
		Game.toast.emit("The bell falls silent. A defender's words remain, and the Bellwarden pin is yours.")
