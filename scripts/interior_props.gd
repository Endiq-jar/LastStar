extends RefCounted
## Small, low-poly decorative props. Each instance shares cached primitive meshes
## and materials, is streamed with its house and casts no dynamic shadow.
## Sizes and offsets are in house-local metres; no runtime texture allocations.
const ITEMS := [
	["books", "a stack of well-loved books", [[0.44, 0.07, 0.30, 0.0, 0.12, 0.0, 0], [0.38, 0.07, 0.28, 0.02, 0.19, 0.0, 1], [0.34, 0.07, 0.24, -0.02, 0.26, 0.0, 2]]],
	["lantern", "a brass lantern", [[0.28, 0.06, 0.28, 0, 0.08, 0, 3], [0.18, 0.28, 0.18, 0, 0.25, 0, 4], [0.26, 0.06, 0.26, 0, 0.42, 0, 3]]],
	["vase", "a painted ceramic vase", [[0.22, 0.08, 0.22, 0, 0.09, 0, 2], [0.32, 0.25, 0.32, 0, 0.25, 0, 2], [0.16, 0.12, 0.16, 0, 0.43, 0, 1]]],
	["crate", "a wooden storage crate", [[0.48, 0.42, 0.42, 0, 0.26, 0, 0], [0.5, 0.05, 0.44, 0, 0.1, 0, 3], [0.5, 0.05, 0.44, 0, 0.43, 0, 3]]],
	["candle", "a small candle", [[0.28, 0.06, 0.28, 0, 0.08, 0, 3], [0.14, 0.25, 0.14, 0, 0.23, 0, 4], [0.06, 0.1, 0.06, 0, 0.4, 0, 5]]],
	["chest", "a closed keepsake chest", [[0.50, 0.30, 0.34, 0, 0.2, 0, 0], [0.52, 0.10, 0.36, 0, 0.4, 0, 1], [0.09, 0.12, 0.03, 0, 0.29, -0.19, 3]]],
	["stool", "a sturdy little stool", [[0.46, 0.10, 0.38, 0, 0.36, 0, 0], [0.10, 0.30, 0.10, -0.15, 0.17, 0, 1], [0.10, 0.30, 0.10, 0.15, 0.17, 0, 1]]],
	["basket", "a basket for the day's harvest", [[0.40, 0.26, 0.34, 0, 0.18, 0, 1], [0.44, 0.06, 0.38, 0, 0.34, 0, 0], [0.06, 0.17, 0.06, 0, 0.43, 0, 1]]],
	["teapot", "a teapot ready for guests", [[0.30, 0.22, 0.25, 0, 0.18, 0, 2], [0.17, 0.05, 0.17, 0, 0.32, 0, 4], [0.18, 0.06, 0.07, 0.22, 0.24, 0, 2]]],
	["cup", "a ceramic cup", [[0.19, 0.20, 0.19, 0, 0.15, 0, 4], [0.08, 0.10, 0.06, 0.13, 0.18, 0, 2], [0.21, 0.03, 0.21, 0, 0.26, 0, 2]]],
	["bottle", "a coloured glass bottle", [[0.18, 0.25, 0.18, 0, 0.17, 0, 6], [0.10, 0.12, 0.10, 0, 0.35, 0, 6], [0.11, 0.04, 0.11, 0, 0.43, 0, 1]]],
	["bowl", "a small serving bowl", [[0.32, 0.10, 0.32, 0, 0.10, 0, 2], [0.40, 0.05, 0.40, 0, 0.18, 0, 4]]],
	["plant_pot", "a potted house plant", [[0.28, 0.24, 0.28, 0, 0.17, 0, 1], [0.08, 0.26, 0.08, 0, 0.42, 0, 7], [0.30, 0.08, 0.18, 0, 0.52, 0, 7]]],
	["scroll", "a rolled parchment", [[0.38, 0.12, 0.16, 0, 0.12, 0, 4], [0.05, 0.14, 0.18, -0.17, 0.12, 0, 1], [0.05, 0.14, 0.18, 0.17, 0.12, 0, 1]]],
	["clock", "a little mantel clock", [[0.38, 0.07, 0.15, 0, 0.08, 0, 0], [0.30, 0.32, 0.12, 0, 0.28, 0, 1], [0.18, 0.18, 0.02, 0, 0.29, -0.07, 4]]],
	["frame", "a framed family portrait", [[0.40, 0.40, 0.07, 0, 0.27, 0, 0], [0.30, 0.30, 0.02, 0, 0.27, -0.05, 2], [0.10, 0.14, 0.02, 0, 0.27, -0.07, 4]]],
	["pillow", "a soft cushion", [[0.40, 0.12, 0.32, 0, 0.11, 0, 2], [0.30, 0.04, 0.23, 0, 0.19, 0, 4]]],
	["tray", "a serving tray", [[0.48, 0.04, 0.32, 0, 0.07, 0, 0], [0.05, 0.08, 0.32, -0.22, 0.11, 0, 1], [0.05, 0.08, 0.32, 0.22, 0.11, 0, 1]]],
	["spice_box", "a box of fragrant spices", [[0.32, 0.19, 0.24, 0, 0.15, 0, 0], [0.34, 0.05, 0.26, 0, 0.27, 0, 1], [0.08, 0.04, 0.04, 0, 0.31, 0, 3]]],
	["inkwell", "an inkwell and quill", [[0.20, 0.14, 0.20, 0, 0.12, 0, 6], [0.10, 0.05, 0.10, 0, 0.21, 0, 3], [0.04, 0.28, 0.04, 0, 0.34, 0, 4]]],
]
const COLORS := [Color(0.38, 0.23, 0.16), Color(0.57, 0.34, 0.22), Color(0.40, 0.52, 0.67), Color(0.70, 0.53, 0.25), Color(0.91, 0.84, 0.69), Color(1.0, 0.70, 0.26), Color(0.27, 0.47, 0.48), Color(0.29, 0.51, 0.30)]
static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}


static func make(index: int) -> Node3D:
	var number := posmod(index, ITEMS.size())
	var definition: Array = ITEMS[number]
	var root := Node3D.new()
	root.name = "Prop_" + str(definition[0])
	for piece in definition[2]:
		var size := Vector3(piece[0], piece[1], piece[2])
		if not _meshes.has(size):
			var box := BoxMesh.new()
			box.size = size
			_meshes[size] = box
		var color_index := int(piece[6])
		if not _materials.has(color_index):
			var material := StandardMaterial3D.new()
			material.albedo_color = COLORS[color_index]
			material.roughness = 0.9
			_materials[color_index] = material
		var visual := MeshInstance3D.new()
		visual.mesh = _meshes[size]
		visual.material_override = _materials[color_index]
		visual.position = Vector3(piece[3], piece[4], piece[5])
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		visual.visibility_range_end = 35.0
		visual.visibility_range_end_margin = 5.0
		root.add_child(visual)
	return root
