extends Node

## Validates the procedural vegetation meshes that the spec requires to exist as
## real geometry rather than as texture cards.
##
## This exists because the brief asks for twenty distinct flower silhouettes and
## five leaf varieties, and "twenty" is trivially satisfiable by writing twenty
## names into a table that all resolve to the same petal. The check therefore
## asserts on the geometry, not on the table: each flower must produce a non-empty
## surface, and its bounding extent must differ from every other flower's.
##
## Exit code is 0 only if every assertion holds, so the workflow can fail on it.


func _ready() -> void:
	var failures: PackedStringArray = []
	var V = load("res://scripts/performance/vegetation_meshes.gd")
	if V == null:
		print("MESH_CHECK FAIL: could not load vegetation_meshes.gd")
		get_tree().quit(1)
		return

	var names: Array = V.flower_names()
	print("MESH_CHECK flowers declared=%d" % names.size())
	if names.size() < 20:
		failures.append("expected at least 20 flowers, table has %d" % names.size())

	var seen: Dictionary = {}
	var total_tris := 0
	for n in names:
		var m: ArrayMesh = V.flower(n)
		if m == null or m.get_surface_count() == 0:
			failures.append("flower '%s' produced no surface" % n)
			continue
		var arrays: Array = m.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if verts.size() < 12:
			failures.append("flower '%s' has only %d vertices" % [n, verts.size()])
			continue
		if idx.size() % 3 != 0:
			failures.append("flower '%s' index count %d is not a triangle list" % [n, idx.size()])
		total_tris += idx.size() / 3
		var bb := _bounds(verts)
		# Round to a centimetre: two silhouettes that agree to 1 cm at these
		# sizes are the same silhouette, whatever the table calls them.
		var sig := "%.2f_%.2f_%.2f" % [bb.size.x, bb.size.y, bb.size.z]
		if seen.has(sig):
			failures.append("flower '%s' is geometrically identical to '%s'" % [n, seen[sig]])
		seen[sig] = n
		# A flat disc of petals has essentially no depth; bells and trumpets do.
		# Nothing should be a zero-thickness sheet in every axis pairing.
		if bb.size.y > 0.0 and maxf(bb.size.x, bb.size.z) < 0.02:
			failures.append("flower '%s' has degenerate horizontal extent" % n)

	print("MESH_CHECK distinct flower extents=%d/%d tris=%d" % [seen.size(), names.size(), total_tris])

	# Every vertex of every flower must be finite. A NaN in an ArrayMesh does not
	# raise - it silently drops the whole instance from the multimesh, which shows
	# up as "the flowers are missing" with no error anywhere.
	for n in names:
		var m: ArrayMesh = V.flower(n)
		if m == null or m.get_surface_count() == 0:
			continue
		var verts: PackedVector3Array = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in verts:
			if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
				failures.append("flower '%s' contains a non-finite vertex" % n)
				break

	var leaf_kinds := ["lance", "oval", "round", "needle", "lobed"]
	var leaf_sigs: Dictionary = {}
	for k in leaf_kinds:
		var lm: ArrayMesh = V.leaf_variety(k)
		if lm == null or lm.get_surface_count() == 0:
			failures.append("leaf '%s' produced no surface" % k)
			continue
		var la: Array = lm.surface_get_arrays(0)
		var lv: PackedVector3Array = la[Mesh.ARRAY_VERTEX]
		if lv.size() < 9:
			failures.append("leaf '%s' has only %d vertices" % [k, lv.size()])
			continue
		var lb := _bounds(lv)
		var lsig := "%.2f_%.2f_%.2f" % [lb.size.x, lb.size.y, lb.size.z]
		if leaf_sigs.has(lsig):
			failures.append("leaf '%s' is identical to '%s'" % [k, leaf_sigs[lsig]])
		leaf_sigs[lsig] = k
		# The midrib fold is the reason a leaf is not a paper cut-out. If every
		# vertex sits on one plane the fold was lost, which is the exact failure
		# mode the five-varieties requirement is meant to prevent.
		var zmin := lv[0].z
		var zmax := lv[0].z
		for v in lv:
			zmin = minf(zmin, v.z)
			zmax = maxf(zmax, v.z)
		if zmax - zmin < 0.004:
			failures.append("leaf '%s' is flat - the midrib fold is missing" % k)
	print("MESH_CHECK distinct leaf extents=%d/%d" % [leaf_sigs.size(), leaf_kinds.size()])

	var trunk_mesh: ArrayMesh = V.trunk(6.0, 0.3, 0.35)
	if trunk_mesh == null or trunk_mesh.get_surface_count() == 0:
		failures.append("trunk produced no surface")
	else:
		var tv: PackedVector3Array = trunk_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		if tv.size() < 24:
			failures.append("trunk has only %d vertices" % tv.size())
		var tb := _bounds(tv)
		# A tapered trunk must be narrower at the top than at the bottom.
		var bottom_max := 0.0
		var top_max := 0.0
		for v in tv:
			if v.y < 0.5:
				bottom_max = maxf(bottom_max, Vector2(v.x, v.z).length())
			elif v.y > tb.size.y - 0.5:
				top_max = maxf(top_max, Vector2(v.x, v.z).length())
		if top_max >= bottom_max:
			failures.append("trunk is not tapered: top r=%.3f bottom r=%.3f" % [top_max, bottom_max])
		print("MESH_CHECK trunk verts=%d r_top=%.3f r_bottom=%.3f" % [tv.size(), top_max, bottom_max])

	if failures.is_empty():
		print("MESH_CHECK OK")
		get_tree().quit(0)
	else:
		for f in failures:
			print("MESH_CHECK FAIL: %s" % f)
		get_tree().quit(1)


func _bounds(verts: PackedVector3Array) -> AABB:
	var bb := AABB(verts[0], Vector3.ZERO)
	for v in verts:
		bb = bb.expand(v)
	return bb
