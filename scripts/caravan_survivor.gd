extends Node3D
## Two people sheltering at Frostmere after the caravan encounter. The scene is
## streamed; conversation progress lives in guard_story and is optional.
var survivor_index := 0
var _label: Label3D


func _ready() -> void:
	add_to_group("story_interaction")
	var body := MeshInstance3D.new()
	var coat := CapsuleMesh.new()
	coat.radius = 0.24
	coat.height = 0.9
	coat.radial_segments = 8
	coat.rings = 4
	body.mesh = coat
	body.position.y = 0.85
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.61, 0.34, 0.19) if survivor_index == 0 else Color(0.29, 0.42, 0.54)
	body.material_override = cloth
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(body)
	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.18
	head_mesh.height = 0.36
	head_mesh.radial_segments = 8
	head_mesh.rings = 4
	head.mesh = head_mesh
	head.position.y = 1.55
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.76, 0.59, 0.49)
	head.material_override = skin
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(head)
	_label = Label3D.new()
	_label.text = "F / Talk · " + _survivor_name()
	_label.position.y = 2.0
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 36
	_label.pixel_size = 0.004
	_label.outline_size = 6
	add_child(_label)


func _survivor_name() -> String:
	return "Tala, caravan guide" if survivor_index == 0 else "Esen, traveller"


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or int(Game.guard_story.get("caravan_stage", 0)) != 3: return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Talk to " + _survivor_name(), "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	Game.hear_caravan_survivor(survivor_index)
	if survivor_index == 0:
		Game.toast.emit("Tala: We stopped because Esen's family needed shelter. I would make that choice again, but a stocked shelter would have kept us moving sooner.")
	else:
		Game.toast.emit("Esen: Tala gave us a place without asking for payment. Please tell Zara we were not cargo. We can help guide the next family too.")
	return true
