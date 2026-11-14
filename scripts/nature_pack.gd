extends RefCounted
## The valley's environment, from one CC0 art pack.
##
## Every visible piece of nature in Last Star - the trees, the bushes, the
## plants, the meadow's grass, the flowers, the boulders and pebbles, the fallen
## logs and the stumps - comes from the Quaternius *Ultimate Stylized Nature
## Pack*, vendored under assets/nature/ (CC0-1.0, see assets/nature/README.md).
## Before this there was no model file in the project at all: the trees were
## primitive cylinders and spheres with painted pngs wrapped round them, the
## grass was an alpha-cutout sprite on a quad, and the rocks were spheres with a
## seamless rock tile. That whole pipeline is gone.
##
## The pack ships no textures. Its colour lives in eleven named materials per
## model, and its meshes carry no UVs at all, so there is exactly one way to use
## it: bake each surface's colour into vertex colours and draw it with a
## vertex-colour material. That is what `mesh_of()` does. The result is a single
## surface per model, which matters because every one of these is instanced
## through a MultiMesh, and a MultiMesh draws one material for the whole batch.
##
## The GLBs are preloaded, not loaded by path at runtime, so they are a real
## export dependency: an unimported model fails the build loudly instead of
## quietly leaving the valley bare.
##
## `clump()` is the one derived asset: the pack's grass tuft is ~100 separate
## blades (192 triangles) and a meadow needs tens of thousands of instances, so
## it is decimated to the tallest N blades. The blades are the pack's own
## geometry at the pack's own scale - nothing is redrawn - and the note on the
## function explains the budget it exists to meet.

const NATURE_SHADER := preload("res://shaders/vegetation/nature_foliage.gdshader")

## Model kind -> the vendored scene. Names are the upstream file names so the
## provenance table in assets/nature/README.md maps one to one.
const MODELS := {
	"tree_common_1": preload("res://assets/nature/CommonTree_1.glb"),
	"tree_common_3": preload("res://assets/nature/CommonTree_3.glb"),
	"tree_dead": preload("res://assets/nature/CommonTree_Dead_1.glb"),
	"tree_birch": preload("res://assets/nature/BirchTree_1.glb"),
	"tree_pine_1": preload("res://assets/nature/PineTree_1.glb"),
	"tree_pine_3": preload("res://assets/nature/PineTree_3.glb"),
	"tree_willow": preload("res://assets/nature/Willow_1.glb"),
	"bush_1": preload("res://assets/nature/Bush_1.glb"),
	"bush_2": preload("res://assets/nature/Bush_2.glb"),
	"plant_1": preload("res://assets/nature/Plant_1.glb"),
	"plant_3": preload("res://assets/nature/Plant_3.glb"),
	"flowers": preload("res://assets/nature/Flowers.glb"),
	"grass": preload("res://assets/nature/Grass.glb"),
	"grass_2": preload("res://assets/nature/Grass_2.glb"),
	"grass_short": preload("res://assets/nature/Grass_Short.glb"),
	"rock_1": preload("res://assets/nature/Rock_1.glb"),
	"rock_2": preload("res://assets/nature/Rock_2.glb"),
	"rock_4": preload("res://assets/nature/Rock_4.glb"),
	"rock_moss": preload("res://assets/nature/Rock_Moss_1.glb"),
	"log": preload("res://assets/nature/WoodLog.glb"),
	"stump": preload("res://assets/nature/TreeStump.glb"),
}

## The pack's material names, in sRGB.
##
## These are the pack's own baseColorFactors converted out of glTF's linear
## space, not invented: the valley is supposed to look like the pack, and every
## earlier attempt to "improve" a pack's palette by hand is how the stone
## monolith ended up as a white slab. Where a colour was tuned, the note says
## why.
const PALETTE := {
	"Green": Color(0.30, 0.39, 0.25),
	"DarkGreen": Color(0.24, 0.31, 0.20),
	"White": Color(0.75, 0.77, 0.73),        # birch bark
	"Black": Color(0.23, 0.23, 0.23),        # birch knots
	"Wood": Color(0.38, 0.27, 0.25),
	"LightWood": Color(0.48, 0.34, 0.31),
	"Rock": Color(0.48, 0.49, 0.53),
	"Cyan": Color(0.00, 0.48, 0.49),         # flower heads
	"Yellow": Color(0.63, 0.57, 0.33),
	"Mushroom_Top": Color(0.38, 0.33, 0.31),
	"Mushroom_Bottom": Color(0.58, 0.50, 0.47),
}

## Wind strength per kind. Trees move a little and slowly; grass moves a lot.
## Rocks, logs and stumps do not move at all - a swaying boulder was the first
## thing this got wrong.
const WIND := {
	"grass": 0.26,
	"grass_2": 0.26,
	"grass_short": 0.24,
	"flowers": 0.20,
	"plant_1": 0.16,
	"plant_3": 0.16,
	"bush_1": 0.10,
	"bush_2": 0.10,
	"tree_common_1": 0.09,
	"tree_common_3": 0.09,
	"tree_birch": 0.10,
	"tree_pine_1": 0.06,
	"tree_pine_3": 0.06,
	"tree_willow": 0.12,
	"tree_dead": 0.03,
}

## Shared caches. The whole valley's nature costs one mesh and one material per
## kind, not one per prop - the same reasoning as the slime and bone-cloth
## material caches.
static var _meshes := {}
static var _clumps := {}
static var _heights := {}
static var _materials := {}
static var _built := {}


static func has(kind: String) -> bool:
	return MODELS.has(kind)


## Every kind the pack can build, for the mesh check and the census.
static func kinds() -> Array:
	return MODELS.keys()


## The model, baked to ONE surface with vertex colours, ready for a MultiMesh.
##
## Baking is not an optimisation, it is a requirement: the pack's models are
## several surfaces with several materials each, and a MultiMesh instance draws
## every surface of its mesh with the instance's single material. Flattening the
## surfaces and carrying their colours per vertex is what lets a whole forest be
## one material and one batch.
static func mesh_of(kind: String) -> ArrayMesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var packed: PackedScene = MODELS.get(kind, null)
	if packed == null:
		return null
	var inst := packed.instantiate() as Node3D
	if inst == null:
		return null
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for child in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := _transform_to(inst, mi)
		var nxf := xf.basis.inverse().transposed()
		for surf in range(mi.mesh.get_surface_count()):
			var arrays := mi.mesh.surface_get_arrays(surf)
			if arrays == null or arrays.size() < Mesh.ARRAY_MAX:
				continue
			var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if sv.is_empty():
				continue
			var sn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var si: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var col := _surface_color(mi, surf)
			var base := verts.size()
			for i in range(sv.size()):
				verts.append(xf * sv[i])
				if i < sn.size():
					norms.append((nxf * sn[i]).normalized())
				else:
					norms.append(Vector3.UP)
				cols.append(col)
			if si.is_empty():
				for i in range(sv.size()):
					idx.append(base + i)
			else:
				for i in range(si.size()):
					idx.append(base + si[i])
	if verts.is_empty():
		inst.free()
		return null
	var out_arrays := []
	out_arrays.resize(Mesh.ARRAY_MAX)
	out_arrays[Mesh.ARRAY_VERTEX] = verts
	out_arrays[Mesh.ARRAY_NORMAL] = norms
	out_arrays[Mesh.ARRAY_COLOR] = cols
	out_arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arrays)
	mesh.resource_name = kind
	inst.free()
	_meshes[kind] = mesh
	_heights[kind] = mesh.get_aabb().size.y
	_built[kind] = idx.size() / 3
	return mesh


## The pack's grass, decimated to its tallest `keep` blades.
##
## This is the one place the pack's art is altered, and it is a budget decision,
## not a taste one. The tuft is ~100 separate blades in 192 triangles; the
## meadow draws tens of thousands of instances per frame through one MultiMesh,
## and at full density that is tens of millions of triangles for ground cover the
## player is standing on. Keeping the tallest third cuts the tuft to 64 triangles
## - the same order as the crossed cards this replaced (4) once the instance
## count is scaled to the tuft being ~1 m across instead of 0.7 m, and it keeps
## the silhouette, because the grass's read is its tallest blades.
##
## Blades are found as connected components of the index buffer, which is how
## the model is built: each blade is its own island of triangles sharing no
## vertices with its neighbours. If that ever stops being true the component
## count collapses to one and this returns the whole tuft rather than something
## broken.
static func clump(kind: String, keep: int = 36) -> ArrayMesh:
	var key := "%s|%d" % [kind, keep]
	if _clumps.has(key):
		return _clumps[key]
	var full := mesh_of(kind)
	if full == null or full.get_surface_count() == 0:
		return null
	var arrays := full.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var tris := idx.size() / 3
	if tris == 0:
		return full
	var parent := PackedInt32Array()
	parent.resize(verts.size())
	for i in range(verts.size()):
		parent[i] = i
	for t in range(tris):
		_union(parent, idx[t * 3], idx[t * 3 + 1])
		_union(parent, idx[t * 3], idx[t * 3 + 2])
	var groups := {}
	for t in range(tris):
		var root := _find(parent, idx[t * 3])
		if not groups.has(root):
			groups[root] = []
		(groups[root] as Array).append(t)
	if groups.size() <= keep:
		_clumps[key] = full
		return full
	var ranked: Array = []
	for root in groups:
		var tris_of_root: Array = groups[root]
		var tallest := -1e9
		for t in tris_of_root:
			for k in range(3):
				tallest = maxf(tallest, verts[idx[t * 3 + k]].y)
		ranked.append([tallest, tris_of_root])
	ranked.sort_custom(_taller_first)
	# Rebuild with only the kept triangles, renumbering the vertices so the
	# result is not a copy of the whole tuft with most of it unreferenced.
	var remap := {}
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_c := PackedColorArray()
	var out_i := PackedInt32Array()
	for r in range(keep):
		var kept_tris: Array = ranked[r][1]
		for t in kept_tris:
			for k in range(3):
				var old: int = idx[t * 3 + k]
				if not remap.has(old):
					remap[old] = out_v.size()
					out_v.append(verts[old])
					out_n.append(norms[old] if old < norms.size() else Vector3.UP)
					out_c.append(cols[old] if old < cols.size() else Color.WHITE)
				out_i.append(int(remap[old]))
	var arrays2 := []
	arrays2.resize(Mesh.ARRAY_MAX)
	arrays2[Mesh.ARRAY_VERTEX] = out_v
	arrays2[Mesh.ARRAY_NORMAL] = out_n
	arrays2[Mesh.ARRAY_COLOR] = out_c
	arrays2[Mesh.ARRAY_INDEX] = out_i
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays2)
	mesh.resource_name = key
	_clumps[key] = mesh
	_heights[key] = mesh.get_aabb().size.y
	_built[key] = out_i.size() / 3
	return mesh


static func _taller_first(a: Array, b: Array) -> bool:
	return float(a[0]) > float(b[0])


static func _find(parent: PackedInt32Array, a: int) -> int:
	var node := a
	while parent[node] != node:
		parent[node] = parent[parent[node]]
		node = parent[node]
	return node


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb


## Height of a kind in metres at scale 1.0, measured from the baked mesh rather
## than assumed: the pack is authored in centimetres behind a 100x node scale,
## so "how tall is this tree" is exactly the thing a caller must not guess.
static func height_of(kind: String) -> float:
	if _heights.has(kind):
		return float(_heights[kind])
	if mesh_of(kind) == null:
		return 0.0
	return float(_heights.get(kind, 0.0))


## The one material every instance of a kind shares.
##
## `wind` overrides the kind's own default; the grass field drives its own sway
## and the spawner wants dead trees to stand still. `tint` multiplies the baked
## vertex colours, which is how a single mesh gives a whole forest per-tree
## variation.
static func material(kind: String, wind: float = -1.0, tint: Color = Color.WHITE) -> ShaderMaterial:
	var sway: float = float(WIND.get(kind, 0.0)) if wind < 0.0 else wind
	var key := "%s|%.2f|%s" % [kind, sway, tint.to_html(false)]
	if _materials.has(key):
		return _materials[key]
	var m := ShaderMaterial.new()
	m.shader = NATURE_SHADER
	m.set_shader_parameter("base_tint", Vector3(tint.r, tint.g, tint.b))
	m.set_shader_parameter("wind_strength", sway)
	m.set_shader_parameter("sway_height", maxf(height_of(kind), 0.05))
	m.set_shader_parameter("tint_variation", 0.10)
	# Rocks and wood do not transmit light; leaves and blades do. The same split
	# applies to the root-to-tip darkening - it exists to anchor a blade in the
	# soil, and on a boulder it just makes the bottom third look dirty - and to
	# the rim, which is a leaf edge catching the sky and on stone reads as a glow.
	var soft := sway > 0.015
	m.set_shader_parameter("backlight_scale", 0.35 if soft else 0.0)
	m.set_shader_parameter("roughness_value", 0.90 if soft else 0.96)
	m.set_shader_parameter("base_darken", 0.30 if soft else 0.0)
	m.set_shader_parameter("rim_strength", 0.35 if soft else 0.08)
	_materials[key] = m
	return m


## One placed prop, for the handful of pieces that are not instanced in bulk.
static func make(kind: String, size: float = 1.0, tint: Color = Color.WHITE) -> MeshInstance3D:
	var mesh := mesh_of(kind)
	if mesh == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = "Nature_" + kind
	mi.mesh = mesh
	mi.material_override = material(kind, -1.0, tint)
	mi.scale = Vector3.ONE * size
	mi.add_to_group("nature_pack")
	return mi


## Colour of one source surface: the pack's named palette where the material has
## a name, the material's own albedo otherwise.
static func _surface_color(mi: MeshInstance3D, surf: int) -> Color:
	var mat := mi.get_active_material(surf)
	var col := Color(0.34, 0.42, 0.28)
	if mat == null:
		return col
	var key := str(mat.resource_name)
	if PALETTE.has(key):
		return PALETTE[key]
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_color
	return col


static func _transform_to(root: Node, node: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## What the pack is actually contributing, for the probe and the perf census.
static func census() -> String:
	var tris := 0
	for kind in _built:
		tris += int(_built[kind])
	return "NATURE_PACK kinds=%d meshes=%d triangles=%d" % [MODELS.size(), _built.size(), tris]
