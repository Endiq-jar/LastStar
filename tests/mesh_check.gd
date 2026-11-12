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

	# Rocks. The previous rock was a SphereMesh, which is the one shape a boulder
	# must not be - and it passed every check here because nothing tested it.
	print("MESH_CHECK rocks")
	var rock_mesh: Mesh = V.rock(9, 4)
	if rock_mesh == null or rock_mesh.get_surface_count() == 0:
		failures.append("rock produced no surface")
	else:
		var rv: PackedVector3Array = (rock_mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var rn: PackedVector3Array = (rock_mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
		var rb := _bounds(rv)
		print("MESH_CHECK rock verts=%d extent=(%.2f,%.2f,%.2f)" % [rv.size(), rb.size.x, rb.size.y, rb.size.z])
		if rv.size() < 60:
			failures.append("rock has only %d vertices - not faceted" % rv.size())
		# Squashed, not spherical: boulders sit in the ground.
		if rb.size.y > rb.size.x * 0.95:
			failures.append("rock is as tall as it is wide (%.2f vs %.2f) - looks like a sphere" % [rb.size.y, rb.size.x])
		# Faceted shading: a rock built with flat normals has one normal per face,
		# so adjacent vertices share a normal rather than averaging. Count distinct
		# normals - a smooth sphere has far fewer than a hard-edged one.
		var distinct := {}
		for i in range(0, rn.size(), 3):
			distinct["%.2f_%.2f_%.2f" % [rn[i].x, rn[i].y, rn[i].z]] = true
		print("MESH_CHECK rock faces=%d distinct_normals=%d" % [rv.size() / 3, distinct.size()])
		if distinct.size() < 20:
			failures.append("rock has only %d distinct normals - it is smooth-shaded, not faceted" % distinct.size())
		# Every triangle must have a real area, or the rock has invisible holes.
		for i in range(0, rv.size() - 2, 3):
			if (rv[i + 1] - rv[i]).cross(rv[i + 2] - rv[i]).length_squared() < 1e-10:
				failures.append("rock contains a degenerate triangle at %d" % i)
				break

	var boulder_mesh: Mesh = V.boulder()
	if boulder_mesh == null or boulder_mesh.get_surface_count() == 0:
		failures.append("boulder produced no surface")
	else:
		var bv2: PackedVector3Array = (boulder_mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		print("MESH_CHECK boulder verts=%d" % bv2.size())
		if bv2.size() < 150:
			failures.append("boulder has only %d vertices - the pieces did not compose" % bv2.size())
		for x in bv2:
			if not (is_finite(x.x) and is_finite(x.y) and is_finite(x.z)):
				failures.append("boulder contains a non-finite vertex")
				break
		# Must carry UVs, or it samples one texel of the rock texture and is a flat
		# grey shape - the exact bug the flowers had.
		var bu: PackedVector2Array = (boulder_mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
		if bu.size() != bv2.size():
			failures.append("boulder has no UVs (%d uvs vs %d verts) - it cannot be textured" % [bu.size(), bv2.size()])
		else:
			var uvmin := bu[0]
			var uvmax := bu[0]
			for u in bu:
				uvmin = Vector2(minf(uvmin.x, u.x), minf(uvmin.y, u.y))
				uvmax = Vector2(maxf(uvmax.x, u.x), maxf(uvmax.y, u.y))
			print("MESH_CHECK boulder uv_span=(%.2f,%.2f)" % [(uvmax - uvmin).x, (uvmax - uvmin).y])
			if (uvmax - uvmin).length() < 0.1:
				failures.append("boulder UVs are collapsed - the texture would be one flat colour")

	# Cluster composition with a NON-INDEXED source.
	#
	# The boulder is built by composing three rock meshes through _append_mesh, and
	# the rock is emitted as a flat triangle soup with no index array. Reading a
	# missing ARRAY_INDEX as a typed PackedInt32Array is a hard error ("assigning
	# Nil to PackedInt32Array") and it crashed the boot - while this check was
	# green, because it only ever looked at V.boulder()'s output, never at the
	# composition path that produces it. Same mistake as the SphereMesh lobes: test
	# the route, not the destination.
	var soup: ArrayMesh = V.rock(8, 3)
	if soup != null and soup.get_surface_count() > 0:
		var sa: Array = soup.surface_get_arrays(0)
		print("MESH_CHECK rock surface indexed=%s" % str(sa[Mesh.ARRAY_INDEX] != null))
		var composed: Mesh = V.boulder()
		if composed == null or composed.get_surface_count() == 0:
			failures.append("boulder composition failed from a non-indexed source")
		else:
			var cav: PackedVector3Array = (composed as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			if cav.size() < 150:
				failures.append("composed boulder has only %d vertices" % cav.size())

	# Nature pack. The valley's environment is these models now, and they are
	# used in a way no other check can see: baked to a single surface with vertex
	# colours, because the pack ships neither textures nor UVs and a MultiMesh
	# draws one material for a whole batch. A model that bakes empty, or without
	# colours, is an invisible prop - the world would still build its batches and
	# every node would exist.
	print("MESH_CHECK nature pack")
	var NP = load("res://scripts/nature_pack.gd")
	if NP == null:
		failures.append("could not load nature_pack.gd")
	else:
		var kinds: Array = NP.kinds()
		print("MESH_CHECK nature kinds=%d" % kinds.size())
		if kinds.size() < 12:
			failures.append("nature pack has only %d kinds" % kinds.size())
		var total_tris := 0
		for kind in kinds:
			var m: ArrayMesh = NP.mesh_of(kind)
			if m == null or m.get_surface_count() == 0:
				failures.append("nature model '%s' baked no surface" % kind)
				continue
			# One surface is the requirement, not an accident: an instance draws
			# every surface with the same material.
			if m.get_surface_count() != 1:
				failures.append("nature model '%s' baked %d surfaces" % [kind, m.get_surface_count()])
			var arrays: Array = m.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if verts.is_empty() or idx.is_empty():
				failures.append("nature model '%s' has no geometry" % kind)
				continue
			if cols.size() != verts.size():
				failures.append("nature model '%s' lost its vertex colours (%d cols vs %d verts) - every surface would draw one flat colour or none at all" % [kind, cols.size(), verts.size()])
			# The pack is authored in centimetres behind a 100x node scale. If that
			# scale is dropped the model is a 3 cm prop, and nothing but a
			# measurement would notice.
			var h: float = NP.height_of(kind)
			if h < 0.2 or h > 8.0:
				failures.append("nature model '%s' is %.2f m tall - the 100x glTF node scale did not survive" % [kind, h])
			total_tris += idx.size() / 3
			print("MESH_CHECK nature %-14s verts=%5d tris=%5d height=%.2fm" % [kind, verts.size(), idx.size() / 3, h])
		print("MESH_CHECK nature total tris=%d" % total_tris)
		if total_tris < 4000:
			failures.append("nature pack baked only %d triangles" % total_tris)
		# The grass clump is the one derived asset, and the meadow's budget
		# depends on it actually being smaller than the tuft it comes from.
		var full: ArrayMesh = NP.mesh_of("grass")
		var clump: ArrayMesh = NP.clump("grass", 36)
		if clump == null or clump.get_surface_count() == 0:
			failures.append("grass clump baked no surface")
		else:
			var fa: Array = full.surface_get_arrays(0)
			var ca: Array = clump.surface_get_arrays(0)
			var ftris := (fa[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			var ctris := (ca[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			print("MESH_CHECK grass tuft tris=%d clump(36) tris=%d" % [ftris, ctris])
			if ctris >= ftris:
				failures.append("grass clump kept %d of %d triangles - the decimation did nothing" % [ctris, ftris])
			if ctris < 24:
				failures.append("grass clump has only %d triangles - too coarse to read as grass" % ctris)

	# Surface textures must be opaque.
	#
	# Twice now a sprite atlas has been wired in as a surface texture: rocks.png
	# (33% transparent black) and leaf.png (84% transparent, stored as rgb(0,1,0)).
	# Both produced black geometry that no amount of tinting could fix, because the
	# tint was multiplying zero. A texture used as a material surface has to be a
	# texture, not a sheet of cut-outs.
	print("MESH_CHECK surface textures")
	# The environment's own pngs are gone with the texture pipeline; what is
	# left is the terrain's painted ground.
	for path in ["res://textures/terrain/rock.png",
			"res://textures/terrain/meadow.png",
			"res://textures/terrain/sand.png"]:
		if not ResourceLoader.exists(path):
			failures.append("missing surface texture %s" % path)
			continue
		var tex: Texture2D = load(path)
		if tex == null:
			failures.append("could not load %s" % path)
			continue
		var im: Image = tex.get_image()
		if im == null:
			failures.append("no image data for %s" % path)
			continue
		if im.is_compressed():
			im.decompress()
		var w := im.get_width()
		var h := im.get_height()
		var step := maxi(1, w / 64)
		var near_black := 0
		var transparent := 0
		var total := 0
		for yy in range(0, h, step):
			for xx in range(0, w, step):
				var c := im.get_pixel(xx, yy)
				total += 1
				if c.a < 0.9:
					transparent += 1
				if c.r + c.g + c.b < 0.18:
					near_black += 1
		var tr := float(transparent) / maxf(1.0, float(total))
		var nk := float(near_black) / maxf(1.0, float(total))
		print("MESH_CHECK tex %-46s %dx%d transparent=%.1f%% near-black=%.1f%%" % [
			path.get_file(), w, h, tr * 100.0, nk * 100.0])
		if tr > 0.05:
			failures.append("%s is %.0f%% transparent - it is a sprite sheet, not a surface texture" % [path.get_file(), tr * 100.0])
		if nk > 0.10:
			failures.append("%s is %.0f%% near-black" % [path.get_file(), nk * 100.0])

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
