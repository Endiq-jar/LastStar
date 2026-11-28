extends Node3D
## The damaged Wander is streamed with Evergloom and can only be recovered
## during the investigation. Progress is held by Game, not this transient node.


func _ready() -> void:
	add_to_group("story_interaction")
	var cover := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.65, 0.12, 0.48)
	cover.mesh = mesh
	cover.position.y = 0.85
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.23, 0.18, 0.37)
	material.roughness = 0.8
	cover.material_override = material
	cover.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(cover)
	var label := Label3D.new()
	label.text = "F / Talk · Examine the lost Wander"
	label.position.y = 1.5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.pixel_size = 0.004
	label.outline_size = 6
	add_child(label)


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or int(Game.guard_story.get("wander_story_stage", 0)) != 2: return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Examine the lost Wander", "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	if Game.recover_lost_wander():
		Game.toast.emit("The Wander holds an unfinished message: Let them choose who hears us. Bring it to Veya in Lunareth.")
	return true
