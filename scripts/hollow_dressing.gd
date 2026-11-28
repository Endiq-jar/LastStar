extends RefCounted
## Shared, non-colliding dungeon dressing. Three instanced draw batches provide
## bone fragments, old stains and floor scratches without adding physics or lights.


static func add_to(parent: Node3D, locations: Array[Vector3]) -> void:
	var bones := BoxMesh.new()
	bones.size = Vector3(0.07, 0.07, 0.62)
	var bone_mat := StandardMaterial3D.new()
	bone_mat.albedo_color = Color(0.52, 0.49, 0.42)
	bone_mat.roughness = 1.0
	bones.material = bone_mat
	var stains := CylinderMesh.new()
	stains.top_radius = 0.55
	stains.bottom_radius = 0.55
	stains.height = 0.015
	stains.radial_segments = 8
	var stain_mat := StandardMaterial3D.new()
	stain_mat.albedo_color = Color(0.18, 0.055, 0.065)
	stain_mat.roughness = 1.0
	stains.material = stain_mat
	var marks := BoxMesh.new()
	marks.size = Vector3(0.035, 0.75, 0.025)
	var mark_mat := StandardMaterial3D.new()
	mark_mat.albedo_color = Color(0.15, 0.07, 0.09)
	mark_mat.roughness = 1.0
	marks.material = mark_mat
	var bone_transforms: Array[Transform3D] = []
	var stain_transforms: Array[Transform3D] = []
	var mark_transforms: Array[Transform3D] = []
	for point in locations:
		stain_transforms.append(Transform3D(Basis.IDENTITY, point + Vector3(0, 0.025, 0)))
		for i in range(3):
			var angle := (float(i) - 1.0) * 0.75
			bone_transforms.append(Transform3D(Basis(Vector3.UP, angle), point + Vector3(float(i - 1) * 0.24, 0.08, float(i % 2) * 0.2)))
			mark_transforms.append(Transform3D(Basis(Vector3.RIGHT, PI / 2.0), point + Vector3(float(i - 1) * 0.16, 0.045, 0.8)))
	_batch(parent, "HollowBones", bones, bone_transforms)
	_batch(parent, "HollowStains", stains, stain_transforms)
	_batch(parent, "HollowClawMarks", marks, mark_transforms)


static func _batch(parent: Node3D, label: String, mesh: Mesh, transforms: Array[Transform3D]) -> void:
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = mesh
	instances.instance_count = transforms.size()
	for i in range(transforms.size()): instances.set_instance_transform(i, transforms[i])
	var visual := MultiMeshInstance3D.new()
	visual.name = label
	visual.multimesh = instances
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual.visibility_range_end = 100.0
	parent.add_child(visual)
