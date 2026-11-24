extends Node3D
## Every resident keeps the same quest identity regardless of visual LOD.
## Shared meshes reduce draw calls; each resident draws just one two-surface LOD.
const DATA := preload("res://scripts/settlement_data.gd")
const LOD_START := [0.0, 10.0, 25.0, 50.0]
const LOD_END := [10.0, 25.0, 50.0, 100.0]
var site_id := ""
var resident_index := 0
static var _lod_meshes: Array[ArrayMesh] = []
static var _skin: StandardMaterial3D
static var _clothes: Dictionary = {}


static func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


static func _round_body(segments: int, rings: int) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.26
	mesh.height = 0.95
	mesh.radial_segments = segments
	mesh.rings = rings
	return mesh


static func _round_head(segments: int, rings: int) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.19
	mesh.height = 0.38
	mesh.radial_segments = segments
	mesh.rings = rings
	return mesh


static func _append(tool: SurfaceTool, mesh: Mesh, at: Vector3) -> void:
	tool.append_from(mesh, 0, Transform3D(Basis.IDENTITY, at))


static func _make_lod(level: int) -> ArrayMesh:
	var cloth := SurfaceTool.new()
	cloth.begin(Mesh.PRIMITIVE_TRIANGLES)
	var skin := SurfaceTool.new()
	skin.begin(Mesh.PRIMITIVE_TRIANGLES)
	if level == 3:
		_append(cloth, _box(Vector3(0.48, 1.45, 0.32)), Vector3(0, 0.73, 0))
		_append(skin, _box(Vector3(0.36, 0.38, 0.36)), Vector3(0, 1.75, 0))
	else:
		var segments: int = [12, 8, 6][level]
		var rings: int = [6, 4, 3][level]
		_append(cloth, _round_body(segments, rings), Vector3(0, 1.04, 0))
		_append(skin, _round_head(segments, rings), Vector3(0, 1.75, 0))
		var limb := _box(Vector3(0.18, 0.55, 0.21))
		for side in [-1.0, 1.0]:
			_append(cloth, limb, Vector3(side * 0.13, 0.27, 0))
			if level < 2: _append(cloth, limb, Vector3(side * 0.35, 1.05, 0))
	var result := ArrayMesh.new()
	cloth.commit(result)
	skin.commit(result)
	return result


func _ready() -> void:
	add_to_group("story_npc")
	var site := DATA.by_id(site_id)
	var person := DATA.resident(site_id, resident_index)
	if _skin == null:
		_skin = StandardMaterial3D.new()
		_skin.albedo_color = Color(0.76, 0.59, 0.49)
		for level in range(4): _lod_meshes.append(_make_lod(level))
	var color_index: int = abs((site_id + str(resident_index)).hash()) % 12
	if not _clothes.has(color_index):
		var cloth := StandardMaterial3D.new()
		cloth.albedo_color = Color.from_hsv(float(color_index) / 12.0, 0.38, 0.62)
		_clothes[color_index] = cloth
	for level in range(4):
		var visual := MeshInstance3D.new()
		visual.name = "ResidentLOD%d" % level
		visual.mesh = _lod_meshes[level]
		visual.set_surface_override_material(0, _clothes[color_index])
		visual.set_surface_override_material(1, _skin)
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		visual.visibility_range_begin = LOD_START[level]
		visual.visibility_range_end = LOD_END[level]
		add_child(visual)
	var label := Label3D.new()
	label.text = "%s · %s\n%s  |  F / Talk" % [person.get("name", "Resident"), person.get("role", ""), site.get("name", "")]
	label.position.y = 2.3
	label.visibility_range_end = 24.0
	label.visibility_range_end_margin = 3.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.004
	label.outline_size = 8
	add_child(label)
