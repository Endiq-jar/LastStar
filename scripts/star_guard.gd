extends Node3D
## Ilyra remains the same talkable character when recruited. Her Gift provides
## a small defensive healing pulse during combat; the story choice strengthens it.
var _home := Vector3.ZERO
var _support_cooldown := 8.0
var _label: Label3D


func _ready() -> void:
	add_to_group("story_npc")
	_home = global_position
	Game.collection_changed.connect(_sync_following)
	var coat := StandardMaterial3D.new()
	coat.albedo_color = Color(0.19, 0.29, 0.45)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.76, 0.59, 0.49)
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.80, 0.62, 0.28)
	var body := CapsuleMesh.new()
	body.radius = 0.26
	body.height = 0.95
	_piece(body, coat, Vector3(0, 1.04, 0))
	var head := SphereMesh.new()
	head.radius = 0.19
	head.height = 0.38
	_piece(head, skin, Vector3(0, 1.75, 0))
	var leg := BoxMesh.new()
	leg.size = Vector3(0.18, 0.55, 0.21)
	for side in [-1.0, 1.0]:
		_piece(leg, coat, Vector3(side * 0.13, 0.27, 0))
		var arm := BoxMesh.new()
		arm.size = Vector3(0.16, 0.70, 0.16)
		_piece(arm, coat, Vector3(side * 0.35, 1.05, 0))
	var badge := SphereMesh.new()
	badge.radius = 0.065
	badge.height = 0.13
	_piece(badge, gold, Vector3(0, 1.27, -0.24))
	var label := Label3D.new()
	_label = label
	label.text = "Star Guard Ilyra\nTalk: F or Talk button"
	label.position.y = 2.25
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.005
	label.outline_size = 8
	add_child(label)
	_sync_following()


func _sync_following() -> void:
	if _label == null: return
	var following := bool(Game.guard_story.get("ilyra_following", false))
	_label.text = "Ilyra · travelling companion\nF / Talk" if following else "Star Guard Ilyra\nTalk: F or Talk button"
	if not following:
		global_position = _home


func _process(delta: float) -> void:
	if Game.is_paused or not bool(Game.guard_story.get("ilyra_following", false)):
		return
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null: return
	var desired := player.global_position + Vector3(1.7, 0, 1.7)
	var terrain := get_parent().get_node_or_null("Terrain")
	if terrain != null and player.global_position.y < 400.0:
		desired.y = float(terrain.call("get_height_at", desired.x, desired.z))
	else:
		desired.y = player.global_position.y
	var distance := global_position.distance_to(desired)
	if distance > 20.0:
		global_position = desired
	elif distance > 2.0:
		global_position = global_position.move_toward(desired, 4.5 * delta)
	_support_cooldown = maxf(0.0, _support_cooldown - delta)
	if _support_cooldown <= 0.0 and Game.current_hp() < Game.max_hp() * 0.8:
		for enemy in get_tree().get_nodes_in_group("enemy"):
			if enemy is Node3D and is_instance_valid(enemy) and enemy.global_position.distance_to(player.global_position) < 16.0:
				_support_cooldown = 18.0
				var amount := 105.0 if int(Game.guard_story.get("ilyra_bond", 0)) >= 2 else 75.0
				Game.heal(amount)
				Game.toast.emit("Ilyra's Gift: +%d health" % int(amount))
				break


func _piece(mesh: Mesh, material: Material, at: Vector3) -> void:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = at
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(part)
