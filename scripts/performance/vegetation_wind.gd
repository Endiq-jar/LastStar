extends Node
## Pushes the character position into every foliage material once per frame.
##
## The wind itself is computed on the GPU (see foliage_wind.gdshaderinc), so
## this is the only CPU cost of the whole vegetation system: one uniform write
## per material, per frame. That is what "interaction with player movement"
## costs when it is done properly - the alternative, a physics body per tuft or
## a per-blade script, is what makes vegetation expensive.
##
## It also serves as the registry the vegetation layers use to find the shared
## materials, so a single instance of this node drives every layer.

var _materials: Array[ShaderMaterial] = []
var _player: Node3D


func _ready() -> void:
	# Run after the player has moved for the frame, so the push is never a frame
	# behind - a lagging push reads as the grass being dragged.
	process_priority = 1000


func register_material(mat: ShaderMaterial) -> void:
	if mat != null and not _materials.has(mat):
		_materials.append(mat)


func set_player(player: Node3D) -> void:
	_player = player


func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var pos := _player.global_position
	for mat in _materials:
		mat.set_shader_parameter("player_world_pos", pos)
