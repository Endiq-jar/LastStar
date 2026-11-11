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
