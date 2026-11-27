extends Node3D
## An optional, streamed companion-story interaction in Ashvale.
var _label: Label3D


func _ready() -> void:
	add_to_group("story_interaction")
	var stone := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.8, 1.15, 0.35)
	stone.mesh = mesh
	stone.position.y = 0.575
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.36, 0.39, 0.43)
	material.roughness = 0.9
	stone.material_override = material
	stone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(stone)
	_label = Label3D.new()
	_label.text = "F / Talk · Read the patrol memorial"
	_label.position.y = 1.65
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 36
	_label.pixel_size = 0.004
	_label.outline_size = 6
	add_child(_label)


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or int(Game.guard_story.get("ilyra_arc_stage", 0)) != 1:
		return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Read patrol memorial", "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	if Game.read_ilyra_memorial():
		Game.toast.emit("The memorial bears no names. Ask Captain Ren in Elaris Capital why the patrol record was sealed.")
	return true
