extends Node3D
## A visible, inspectable result of the player's Orchard decision.
var shared := false


func _ready() -> void:
	add_to_group("story_interaction")
	var pot := MeshInstance3D.new()
	var pot_mesh := CylinderMesh.new()
	pot_mesh.top_radius = 0.48
	pot_mesh.bottom_radius = 0.32
	pot_mesh.height = 0.5
	pot_mesh.radial_segments = 8
	pot.mesh = pot_mesh
	pot.position.y = 0.25
	var clay := StandardMaterial3D.new()
	clay.albedo_color = Color(0.42, 0.29, 0.20)
	pot.material_override = clay
	pot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pot)
	var sapling := MeshInstance3D.new()
	var crown := SphereMesh.new()
	crown.radius = 0.38
	crown.height = 0.7
	crown.radial_segments = 8
	crown.rings = 4
	sapling.mesh = crown
	sapling.position.y = 0.85
	var leaves := StandardMaterial3D.new()
	leaves.albedo_color = Color(0.34, 0.58, 0.31)
	sapling.material_override = leaves
	sapling.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sapling)
	var label := Label3D.new()
	label.text = "F / Talk · Shared cutting" if shared else "F / Talk · Protected cutting"
	label.position.y = 1.6
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.pixel_size = 0.004
	label.outline_size = 6
	add_child(label)


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or int(Game.guard_story.get("orchard_story_stage", 0)) != 4: return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Inspect shared cutting" if shared else "Inspect protected cutting", "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	Game.toast.emit("A cutting from the Orchard grows in Glassheaven. A note explains how to tend it and share future seeds." if shared else "The Orchard's sheltered cutting has a care roster. Visitors can learn its history without disturbing the older roots.")
	return true
