extends Node3D
## Ilyra remains the same talkable character when recruited. Her Gift provides
## a small defensive healing pulse during combat; the story choice strengthens it.
var _home := Vector3.ZERO
var _support_cooldown := 8.0
var _label: Label3D
const RESIDENT := preload("res://scripts/settler.gd")
static var _lod_meshes: Array[ArrayMesh] = []


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
	# Share one prebuilt silhouette per distance band between Ilyra instances.
	# Follow, dialogue and support logic stay on this node, independent of LOD.
	if _lod_meshes.is_empty():
		for level in range(4): _lod_meshes.append(RESIDENT._make_lod(level))
	for level in range(4):
		var visual := MeshInstance3D.new()
		visual.name = "GuardLOD%d" % level
		visual.mesh = _lod_meshes[level]
		visual.set_surface_override_material(0, coat)
		visual.set_surface_override_material(1, skin)
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		visual.visibility_range_begin = RESIDENT.LOD_START[level]
		visual.visibility_range_end = RESIDENT.LOD_END[level]
		add_child(visual)
	var badge := SphereMesh.new()
	badge.radius = 0.065
	badge.height = 0.13
	badge.radial_segments = 8
	badge.rings = 4
	var badge_visual := _piece(badge, gold, Vector3(0, 1.27, -0.24))
	badge_visual.visibility_range_end = 25.0

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
	if terrain != null and player.global_position.y < 400.0 and not Game.in_final_dungeon:
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


func _piece(mesh: Mesh, material: Material, at: Vector3) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = at
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(part)
	return part
