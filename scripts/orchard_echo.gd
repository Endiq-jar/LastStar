extends Node3D
## Three separate witnesses beneath the Orchard; the mask is stored in Game,
## so unloading the settlement or returning on an old save is safe.
const ACCOUNTS := [
	"A child's mark: We sheltered under the roots. Someone stayed outside until every child was inside.",
	"A gardener's mark: We took cuttings, not the whole root. The old tree survived to grow again.",
	"A traveller's mark: We carried seeds away, but only after the orchard keeper showed us how to plant them."
]
var echo_index := 0


func _ready() -> void:
	add_to_group("story_interaction")
	var visual := MeshInstance3D.new()
	var stone := CylinderMesh.new()
	stone.top_radius = 0.28
	stone.bottom_radius = 0.38
	stone.height = 0.65
	stone.radial_segments = 8
	visual.mesh = stone
	visual.position.y = 0.325
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.51, 0.29)
	visual.material_override = mat
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)
	var label := Label3D.new()
	label.text = "F / Talk · Listen to root mark %d" % (echo_index + 1)
	label.position.y = 1.35
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.pixel_size = 0.004
	label.outline_size = 6
	add_child(label)


func interaction_for(actor: Node3D) -> Dictionary:
	if not is_instance_valid(actor) or int(Game.guard_story.get("orchard_story_stage", 0)) != 1: return {}
	if echo_index < 0 or echo_index >= ACCOUNTS.size() or (int(Game.guard_story.get("orchard_echoes", 0)) & (1 << echo_index)) != 0: return {}
	var distance := actor.global_position.distance_to(global_position)
	if distance > 3.5: return {}
	return {"name": "Listen to root mark %d" % (echo_index + 1), "distance": distance}


func try_interact(actor: Node3D) -> bool:
	if interaction_for(actor).is_empty(): return false
	# Copy the account first: the saved transition can remove this streamed node.
	var account: String = ACCOUNTS[echo_index]
	if Game.hear_orchard_echo(echo_index): Game.toast.emit(account)
	return true
