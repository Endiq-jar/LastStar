extends RefCounted
## Builds the small set of meshes the vegetation layers instance.
##
## These are constructed in code rather than shipped as imported model files for
## three reasons: they are generated geometry with no art dependency, they must be
## regenerated if the wind or card layout changes, and hand-writing an ArrayMesh
## into a .tres is error-prone in a way that only shows up at load.
##
## Each mesh is cached per key, so asking twice costs nothing and the same Mesh
## resource is shared by every chunk that uses it - which is what lets the
## renderer batch them.

# static var, not const: a const Dictionary in GDScript is immutable, and
# assigning into it is a parse error ("Cannot assign a new value to a constant")
# that only surfaces at script load.
static var _cache: Dictionary = {}


## A single unit quad standing upright, centred on its origin.
## Used for grass, flowers and leaves, where a single card is enough.
static func quad() -> Mesh:
	if not _cache.has("quad"):
		var q := QuadMesh.new()
		q.size = Vector2(1.0, 1.0)
		# FACE_Z: standing upright, facing +Z. QuadMesh defaults to FACE_Z, but
		# this is stated explicitly because setting orientation to FACE_Y lays it
		# flat and turns every tuft into a ground decal - a mistake this project
		# has already made once and spent two rounds diagnosing.
		q.orientation = PlaneMesh.FACE_Z
		_cache["quad"] = q
	return _cache["quad"]


## Two unit quads crossed at 90 degrees.
##
## A single flat card vanishes when viewed exactly edge-on, so a meadow made of
## single quads develops visible swathes that blink out as the camera pans. Two
## crossed cards guarantee at least one presents area from any heading. The cost
## is 8 vertices instead of 4, and zero extra draw calls, because a MultiMesh
## draws every instance of one mesh in a single submission.
static func crossed() -> Mesh:
	if _cache.has("crossed"):
		return _cache["crossed"]

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	# Each quad: four corners, bottom edge at y=0 so the origin sits at the root.
	var corners := [
		Vector2(-0.5, 0.0), Vector2(0.5, 0.0),
		Vector2(0.5, 1.0), Vector2(-0.5, 1.0),
	]
	for rotation in [0.0, PI * 0.5]:
		var base := verts.size()
		var c := cos(rotation)
		var s := sin(rotation)
		for corner in corners:
			# Rotate the card about Y; the corner's x becomes (x,z).
			verts.append(Vector3(corner.x * c, corner.y, corner.x * s))
			norms.append(Vector3(-s, 0.0, c))
		# Two triangles per quad, wound counter-clockwise when seen from the
		# front face.
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
		uvs.append_array([
			Vector2(0.0, 1.0), Vector2(1.0, 1.0),
			Vector2(1.0, 0.0), Vector2(0.0, 0.0),
		])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_cache["crossed"] = mesh
	return mesh


## A low-poly faceted sphere, for rocks and pebbles.
static func rock(segments: int = 8, rings: int = 5) -> Mesh:
	var key := "rock_%d_%d" % [segments, rings]
	if not _cache.has(key):
		var sphere := SphereMesh.new()
		sphere.radius = 0.5
		sphere.height = 1.0
		sphere.radial_segments = segments
		sphere.rings = rings
		_cache[key] = sphere
	return _cache[key]


## A rounded foliage lobe, used to assemble bushes from a handful of blobs.
static func lobe() -> Mesh:
	if not _cache.has("lobe"):
		var sphere := SphereMesh.new()
		sphere.radius = 0.5
		sphere.height = 1.0
		sphere.radial_segments = 10
		sphere.rings = 6
		_cache["lobe"] = sphere
	return _cache["lobe"]


## A single curved petal as a triangle strip, built from a parametric outline.
##
## The spec calls for flowers that are distinct in silhouette, not one shape
## recoloured twenty times. A petal is described by three numbers: how wide it is
## at its widest, how far along that widest point sits, and how far the tip curls
## back toward the stem. Those three are enough to produce a round petal, a
## narrow strap, a spoon, a heart or a five-pointed star when several are fanned
## around the same centre.
##
## Built as an ArrayMesh rather than a PrimitiveMesh because Godot has no petal
## primitive and hand-writing a .tres is fragile - the previous attempt at that
## failed and the note is still in the file.
static func petal(width: float, belly: float, curl: float, segs: int = 5) -> Mesh:
	var key := "petal_%.3f_%.3f_%.3f_%d" % [width, belly, curl, segs]
	if _cache.has(key):
		return _cache[key]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	# The petal runs along +Y from the flower centre, opening outward in X and
	# curling in Z. Two rows of vertices per step, mirrored across the midline,
	# which is enough for a smooth silhouette at the distances these are seen.
	var rows := segs + 1
	for i in range(rows):
		var t := float(i) / float(segs)
		# Half-width: zero at the base, widest at `belly`, tapering to a point.
		var w := width * sin(PI * clampf(t / maxf(belly, 0.001), 0.0, 1.0) * 0.5)
		if t > belly:
			w *= 1.0 - pow((t - belly) / maxf(1.0 - belly, 0.001), 2.0)
		var y := t
		var z := curl * t * t
		verts.append(Vector3(-w, y, z))
		verts.append(Vector3(w, y, z))
		# Normals face back toward the stem. Cheap, and these are lit by a toon
		# ramp that barely uses them.
		var n := Vector3(0.0, -curl * 0.6, 1.0).normalized()
		norms.append(n)
		norms.append(n)
		uvs.append(Vector2(0.0, t))
		uvs.append(Vector2(1.0, t))
	for i in range(segs):
		var a := i * 2
		idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_cache[key] = mesh
	return mesh


## A whole flower head: `count` petals fanned around the origin.
##
## `pitch` tips each petal out of the plane - 0 is a flat daisy face, close to 1
## is a bell or a trumpet. `layer2` adds a second, smaller and more upright ring,
## which is what makes a rose read differently from a daisy rather than just
## larger.
static func flower_head(count: int, petal_w: float, belly: float, curl: float,
		pitch: float, radius: float, layer2: bool = false) -> Mesh:
	var key := "flower_%d_%.3f_%.3f_%.3f_%.3f_%.3f_%s" % [
		count, petal_w, belly, curl, pitch, radius, str(layer2)]
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_ring(st, count, petal_w, belly, curl, pitch, radius, 0.0)
	if layer2:
		_append_ring(st, maxi(3, count - 2), petal_w * 0.62, belly, curl,
			pitch * 0.45, radius * 0.52, 0.16)
	# A small domed centre so the head is not a hole when seen from above.
	st.append_from(_dome(radius * 0.26, radius * 0.16), 0,
		Transform3D(Basis(), Vector3(0.0, 0.02, 0.0)))
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


static func _append_ring(st: SurfaceTool, count: int, petal_w: float, belly: float,
		curl: float, pitch: float, radius: float, y_off: float) -> void:
	# Build one petal, then instance its triangles around the ring by hand so the
	# result is a single surface (one draw call per flower type, not per petal).
	var verts: PackedVector3Array = _petal_verts(petal_w, belly, curl, 4)
	for i in range(count):
		var ang := TAU * float(i) / float(count)
		var basis := Basis(Vector3.UP, ang) * Basis(Vector3.RIGHT, pitch)
		for v in verts:
			var p: Vector3 = basis * (v * radius)
			st.add_vertex(p + Vector3(0.0, y_off, 0.0))


static func _petal_verts(width: float, belly: float, curl: float, segs: int) -> PackedVector3Array:
	# A flat fan of triangles is enough for a petal at these screen sizes, and it
	# keeps the vertex count low - these are instanced tens of thousands of times.
	var out := PackedVector3Array()
	for i in range(segs):
		var t0 := float(i) / float(segs)
		var t1 := float(i + 1) / float(segs)
		var w0 := width * sin(PI * clampf(t0 / maxf(belly, 0.001), 0.0, 1.0) * 0.5)
		var w1 := width * sin(PI * clampf(t1 / maxf(belly, 0.001), 0.0, 1.0) * 0.5)
		var z0 := curl * t0 * t0
		var z1 := curl * t1 * t1
		out.append_array([
			Vector3(-w0, t0, z0), Vector3(w0, t0, z0), Vector3(-w1, t1, z1),
			Vector3(w1, t0, z0), Vector3(w1, t1, z1), Vector3(-w1, t1, z1),
		])
	return out


## A leaf, as a lanceolate blade with a visible midrib fold.
##
## The fold is the whole point: a flat leaf card reads as a paper cut-out from
## any angle off the axis, and five "varieties" that differ only in aspect ratio
## look like one leaf at five scales. Folding it along the midrib catches light
## on one half and shades the other, which is what makes leaf cardinality
## readable in motion.
static func leaf(length: float, width: float, belly: float, fold: float,
		tip_curl: float = 0.0) -> Mesh:
	var key := "leaf_%.3f_%.3f_%.3f_%.3f_%.3f" % [length, width, belly, fold, tip_curl]
	if _cache.has(key):
		return _cache[key]
	var segs := 6
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in range(segs + 1):
		var t := float(i) / float(segs)
		var w := width * sin(PI * clampf(t / maxf(belly, 0.001), 0.0, 1.0) * 0.5)
		if t > belly:
			w *= 1.0 - pow((t - belly) / maxf(1.0 - belly, 0.001), 2.2)
		var y := t * length
		var z := tip_curl * t * t
		# Midrib sits proud of the edges by `fold`, so the blade is a shallow V.
		verts.append(Vector3(-w, y, z + fold * w))
		verts.append(Vector3(0.0, y, z))
		verts.append(Vector3(w, y, z + fold * w))
		var n := Vector3(0.0, -0.25, 1.0).normalized()
		norms.append_array([n, n, n])
		uvs.append_array([Vector2(0.0, t), Vector2(0.5, t), Vector2(1.0, t)])
	for i in range(segs):
		var a := i * 3
		idx.append_array([
			a, a + 1, a + 3, a + 1, a + 4, a + 3,
			a + 1, a + 2, a + 4, a + 2, a + 5, a + 4,
		])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_cache[key] = mesh
	return mesh


## A tapered trunk: a cylinder whose radius falls away along its length, with a
## slight lean. Straight cylinders of constant radius are the single most
## recognisable "programmer tree" tell.
static func trunk(height: float, radius: float, taper: float = 0.35,
		lean: float = 0.0, sides: int = 7) -> Mesh:
	var key := "trunk_%.2f_%.2f_%.2f_%.2f_%d" % [height, radius, taper, lean, sides]
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 4
	var prev: Array[Vector3] = []
	for r in range(rings + 1):
		var t := float(r) / float(rings)
		var rad := radius * lerpf(1.0, 1.0 - taper, t)
		var y := t * height
		var x := lean * t * t
		var cur: Array[Vector3] = []
		for i in range(sides + 1):
			var a := TAU * float(i) / float(sides)
			cur.append(Vector3(x + cos(a) * rad, y, sin(a) * rad))
		if r > 0:
			for i in range(sides):
				var a0 := prev[i]
				var a1 := prev[i + 1]
				var b0 := cur[i]
				var b1 := cur[i + 1]
				st.add_vertex(a0); st.add_vertex(b0); st.add_vertex(a1)
				st.add_vertex(a1); st.add_vertex(b0); st.add_vertex(b1)
		prev = cur
	st.generate_normals()
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## A low dome, used for flower centres and for pebbles that are not spheres.
static func _dome(radius: float, height: float) -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius + height
	sphere.radial_segments = 8
	sphere.rings = 4
	sphere.is_hemisphere = true
	return sphere


## The twenty authored flower silhouettes.
##
## Each entry is (name, petal count, petal width, belly, curl, pitch, radius,
## second ring). They are deliberately spread across the real families a meadow
## has - daisy, cosmos, buttercup, poppy, bell, trumpet, umbel, star, rose, thistle
## - because twenty variations on one shape is what the spec explicitly rejects.
static func flower(kind: String) -> Mesh:
	var t := _flower_table()
	if not t.has(kind):
		return flower_head(5, 0.22, 0.45, 0.0, 0.15, 0.30)
	var e: Array = t[kind]
	return flower_head(e[1], e[2], e[3], e[4], e[5], e[6], e[7])


static func flower_names() -> Array:
	return _flower_table().keys()


static func _flower_table() -> Dictionary:
	return {
		"daisy":      [1, 14, 0.085, 0.55, 0.05, 0.05, 0.30, false],
		"oxeye":      [1, 10, 0.130, 0.50, 0.06, 0.10, 0.32, false],
		"cosmos":     [1,  8, 0.150, 0.55, 0.10, 0.22, 0.34, false],
		"buttercup":  [1,  5, 0.200, 0.48, 0.18, 0.30, 0.22, false],
		"poppy":      [1,  4, 0.290, 0.50, 0.26, 0.12, 0.30, false],
		"anemone":    [1,  7, 0.170, 0.52, 0.16, 0.18, 0.28, false],
		"cornflower": [1,  9, 0.100, 0.60, 0.34, 0.34, 0.26, true],
		"bell":       [1,  6, 0.115, 0.30, 0.62, 0.95, 0.24, false],
		"bluebell":   [1,  5, 0.100, 0.25, 0.70, 1.05, 0.20, false],
		"trumpet":    [1,  6, 0.105, 0.20, 0.55, 0.80, 0.22, false],
		"star":       [1,  5, 0.075, 0.30, 0.02, 0.10, 0.26, false],
		"open_star":  [1,  6, 0.060, 0.25, 0.01, 0.05, 0.28, false],
		"rose":       [1,  6, 0.140, 0.42, 0.30, 0.55, 0.26, true],
		"camellia":   [1,  6, 0.150, 0.46, 0.26, 0.48, 0.28, true],
		"thistle":    [1,  8, 0.040, 0.35, 0.05, 0.62, 0.22, true],
		"clover":     [1, 12, 0.045, 0.60, 0.02, 0.12, 0.24, false],
		"yarrow":     [1, 18, 0.030, 0.45, 0.02, 0.30, 0.20, true],
		"verbena":    [1, 10, 0.050, 0.50, 0.06, 0.30, 0.24, true],
		"marigold":   [1, 12, 0.065, 0.55, 0.14, 0.30, 0.26, true],
		"sunflower":  [1, 16, 0.075, 0.58, 0.10, 0.14, 0.42, true],
	}


## The five authored leaf silhouettes: lance, oval, round, needle, and lobed.
static func leaf_variety(kind: String) -> Mesh:
	match kind:
		"lance":
			return leaf(1.0, 0.13, 0.30, 0.16, 0.18)
		"oval":
			return leaf(0.8, 0.28, 0.48, 0.20, 0.05)
		"round":
			return leaf(0.6, 0.30, 0.55, 0.14, 0.02)
		"needle":
			return leaf(1.3, 0.05, 0.22, 0.10, 0.30)
		_:
			return leaf(0.9, 0.24, 0.42, 0.30, 0.10)


## A clump of flower heads on their own stems, as ONE mesh.
##
## The layers instance one mesh across a whole chunk, so a species either draws
## in one call or in twenty. A cluster keeps it at one. `variety` selects which
## heads make up the mix, so different chunks can carry different flowers while
## each still costs a single draw call.
##
## Stems matter as much as heads: a head floating at its own centre with nothing
## under it reads as confetti the moment the camera is below it, which on a
## hillside it always is.
static func flower_cluster(variety: int, heads: int = 5, height: float = 0.42) -> Mesh:
	var key := "cluster_%d_%d_%.2f" % [variety, heads, height]
	if _cache.has(key):
		return _cache[key]
	var table := _flower_table()
	var names: Array = table.keys()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * (variety + 1)
	for i in range(heads):
		var kind: String = names[(variety * 3 + i) % names.size()]
		var head := flower(kind)
		var spread := rng.randf_range(0.06, 0.20)
		var ang := rng.randf() * TAU
		var h := height * rng.randf_range(0.75, 1.15)
		var pos := Vector3(cos(ang) * spread, h, sin(ang) * spread)
		var b := Basis(Vector3.UP, rng.randf() * TAU)
		b = b.scaled(Vector3.ONE * rng.randf_range(0.7, 1.05))
		# Tip the head toward the light a little so the fan does not read as a
		# flat disc lying in the grass.
		b = b * Basis(Vector3.RIGHT, rng.randf_range(-0.25, 0.25))
		_append_mesh(st, head, Transform3D(b, pos))
		# Stem: a thin three-sided prism from the ground to the head.
		_append_stem(st, Vector3(0.0, 0.0, 0.0), pos, 0.008)
	st.generate_normals()
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## A bush built from several lobes at different offsets and scales, so the
## silhouette is irregular rather than a single sphere.
static func bush_cluster(seed_value: int = 1, lobes: int = 7) -> Mesh:
	var key := "bush_%d_%d" % [seed_value, lobes]
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 104729
	var lobe := _dome(0.5, 0.35)
	for i in range(lobes):
		var ang := TAU * float(i) / float(lobes) + rng.randf_range(-0.3, 0.3)
		var r := rng.randf_range(0.05, 0.34)
		var pos := Vector3(cos(ang) * r, rng.randf_range(0.10, 0.42), sin(ang) * r)
		var b := Basis(Vector3.UP, rng.randf() * TAU)
		b = b.scaled(Vector3(rng.randf_range(0.5, 0.95), rng.randf_range(0.35, 0.7), rng.randf_range(0.5, 0.95)))
		_append_mesh(st, lobe, Transform3D(b, pos))
	st.generate_normals()
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## A small group of leaves sprouting from a shared point, folded along the midrib.
static func leaf_cluster(variety: String, count: int = 5) -> Mesh:
	var key := "leafcl_%s_%d" % [variety, count]
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337 + count
	var blade := leaf_variety(variety)
	for i in range(count):
		var ang := TAU * float(i) / float(count) + rng.randf_range(-0.25, 0.25)
		var tilt := rng.randf_range(0.35, 1.05)
		var b := Basis(Vector3.UP, ang) * Basis(Vector3.RIGHT, tilt)
		b = b.scaled(Vector3.ONE * rng.randf_range(0.7, 1.2))
		_append_mesh(st, blade, Transform3D(b, Vector3(0.0, rng.randf_range(0.05, 0.18), 0.0)))
	st.generate_normals()
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## Appends every triangle of `src`, transformed. Used to compose clusters.
static func _append_mesh(st: SurfaceTool, src: Mesh, xform: Transform3D) -> void:
	if src == null:
		return
	# `src` is a Mesh, not an ArrayMesh. Assuming ArrayMesh and writing
	# `var arr: ArrayMesh = src` compiled fine and failed at runtime the moment a
	# bush was built from SphereMesh lobes:
	#   SCRIPT ERROR: Trying to assign value of type 'SphereMesh' to a variable of
	#   type 'ArrayMesh'
	# PrimitiveMesh subclasses (SphereMesh, CylinderMesh...) cannot be read with
	# surface_get_arrays at all - they expose get_mesh_arrays() instead, which is
	# the flattened form. So branch on the concrete type.
	var arrays_list: Array = []
	if src is ArrayMesh:
		var am := src as ArrayMesh
		for si in range(am.get_surface_count()):
			arrays_list.append(am.surface_get_arrays(si))
	elif src is PrimitiveMesh:
		arrays_list.append((src as PrimitiveMesh).get_mesh_arrays())
	else:
		push_warning("vegetation_meshes: cannot read mesh type %s" % src.get_class())
		return
	for a in arrays_list:
		var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			for i in range(0, verts.size() - 2, 3):
				_tri(st, xform, verts[i], verts[i + 1], verts[i + 2])
		else:
			for i in range(0, idx.size() - 2, 3):
				_tri(st, xform, verts[idx[i]], verts[idx[i + 1]], verts[idx[i + 2]])


static func _tri(st: SurfaceTool, xf: Transform3D, a: Vector3, b: Vector3, c: Vector3) -> void:
	# Reject degenerate triangles. A zero-area triangle produces a zero normal,
	# which the toon shader turns into a black speck - visible as flecks of dirt
	# over the whole meadow.
	if (b - a).cross(c - a).length_squared() < 1e-12:
		return
	st.add_vertex(xf * a)
	st.add_vertex(xf * b)
	st.add_vertex(xf * c)


static func _append_stem(st: SurfaceTool, from: Vector3, to: Vector3, radius: float) -> void:
	var axis := to - from
	if axis.length_squared() < 1e-8:
		return
	var up := axis.normalized()
	var side := up.cross(Vector3.FORWARD)
	if side.length_squared() < 1e-6:
		side = up.cross(Vector3.RIGHT)
	side = side.normalized()
	var other := up.cross(side).normalized()
	var sides := 3
	var ring: Array[Vector3] = []
	for i in range(sides):
		var a := TAU * float(i) / float(sides)
		ring.append(side * cos(a) * radius + other * sin(a) * radius)
	for i in range(sides):
		var a0 := ring[i]
		var a1 := ring[(i + 1) % sides]
		_tri(st, Transform3D(), from + a0, to + a0, to + a1)
		_tri(st, Transform3D(), from + a0, to + a1, from + a1)
