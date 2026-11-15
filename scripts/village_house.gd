extends Node3D
## Hide the roof while the player is indoors so the room stays visible.
var _player: Node3D
var _roof: Node3D
var _clock := 0.0


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player") as Node3D
	_roof = get_node_or_null("RoofParts") as Node3D
	add_to_group("village_house")


func _process(delta: float) -> void:
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = 0.12
	if not is_instance_valid(_player) or _roof == null:
		return
	var local := to_local(_player.global_position)
	var inside := absf(local.x) < 1.95 and absf(local.z) < 1.95 and local.y > -0.7 and local.y < 3.2
	_roof.visible = not inside
