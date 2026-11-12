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
		# The signature is a hash of the actual vertex cloud, not the bounding
		# box.
		#
		# Two attempts at this were wrong in the same direction. A bounding box
		# cannot see the difference between a 5-petal star and an 18-floret umbel
		# unless they happen to differ in size, so it reported them identical at
		# 0.13_0.26_0.13 while they had 174 and 870 vertices respectively. Adding
		# the triangle count did not help either: SurfaceTool produced 80
		# triangles for all twenty, so the extra field was a constant and the
		# collision survived. Both versions measured a property of the mesh's
		# envelope and called it the shape.
		var sig := _shape_signature(verts)
		# Printed for every flower, not just on failure. The check reported a
		# duplicate on code that should not produce one, and the message named the
		# two flowers without saying what was equal - so the next run could not
		# distinguish a bad table from a bad signature from a stale script.
		print("MESH_CHECK sig %-10s %s verts=%d tris=%d" % [
			n, sig, verts.size(), idx.size() / 3])
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

	# The cluster builders are what the vegetation layers actually instance, and
	# they were the part that crashed: a bush composed from SphereMesh lobes hit
	# "Trying to assign value of type 'SphereMesh' to a variable of type
	# 'ArrayMesh'" at load time, and this check still said OK because it only
	# ever exercised flower() and leaf(). Test the thing that ships.
	print("MESH_CHECK clusters")
	for v in range(8):
		var m: Mesh = V.flower_cluster(v, 5, 0.42)
		if m == null or m.get_surface_count() == 0:
			failures.append("flower_cluster(%d) produced no surface" % v)
			continue
		var cv: PackedVector3Array = (m as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		if cv.size() < 60:
			failures.append("flower_cluster(%d) has only %d vertices - are the heads attached?" % [v, cv.size()])
		for x in cv:
			if not (is_finite(x.x) and is_finite(x.y) and is_finite(x.z)):
				failures.append("flower_cluster(%d) contains a non-finite vertex" % v)
				break
	# Every cluster must be built from a different mix, or the eight variants that
	# exist to vary the meadow are the same meadow eight times.
	var csigs: Dictionary = {}
	for v in range(8):
		var m: Mesh = V.flower_cluster(v, 5, 0.42)
		if m == null or m.get_surface_count() == 0:
			continue
		var cv: PackedVector3Array = (m as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		csigs[_shape_signature(cv)] = v
	if csigs.size() < 8:
		failures.append("only %d of 8 flower clusters are distinct" % csigs.size())

	for sv in [1, 2, 3]:
		var bm: Mesh = V.bush_cluster(sv, 7)
		if bm == null or bm.get_surface_count() == 0:
			failures.append("bush_cluster(%d) produced no surface" % sv)
			continue
		var bv: PackedVector3Array = (bm as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		if bv.size() < 100:
			failures.append("bush_cluster(%d) has only %d vertices" % [sv, bv.size()])

	for k in leaf_kinds:
		var lm2: Mesh = V.leaf_cluster(k, 5)
		if lm2 == null or lm2.get_surface_count() == 0:
			failures.append("leaf_cluster('%s') produced no surface" % k)
			continue
		var lv2: PackedVector3Array = (lm2 as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		if lv2.size() < 45:
			failures.append("leaf_cluster('%s') has only %d vertices" % [k, lv2.size()])
	print("MESH_CHECK clusters distinct=%d/8" % csigs.size())

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


## A stable hash of a vertex cloud, quantised to a millimetre.
##
## Two flowers are "the same flower" if their vertices land in the same places -
## that is what a player sees, and it is what the twenty-silhouettes requirement
## actually asks for. A bounding box or a triangle count cannot answer that.
func _shape_signature(verts: PackedVector3Array) -> String:
	var acc := 2166136261
	for v in verts:
		# Quantise before hashing. Exact float equality is meaningless here -
		# two petals built from slightly different parameters are visually
		# identical at 1 mm, and flagging them would be noise.
		var a := int(round(v.x * 1000.0))
		var b := int(round(v.y * 1000.0))
		var c := int(round(v.z * 1000.0))
		acc = (acc ^ a) * 16777619
		acc = (acc ^ b) * 16777619
		acc = (acc ^ c) * 16777619
		acc = acc & 0x7fffffff
	return "%04x_%08x" % [verts.size(), acc]
