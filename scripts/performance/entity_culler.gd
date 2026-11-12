extends Node
## Asynchronous path-traced entity occlusion culling.
##
## The renderer only rejects what is outside the *view*, so every slime, sigil
## and waypoint in the valley was submitted every frame even when the player was
## staring at a hillside - and each of them also kept running its AI, its bob
## animation and its sparkle timer. The valley has ridges, ruined gates, an
## altar ring and roofed shelters in it, so "inside the frustum" and "actually
## visible" are very different sets, and the difference was being paid every
## frame on the main thread and on the CPU rasteriser.
##
## This node answers the second question off the main thread:
##
##   1. On the main thread it keeps two plain-data snapshots of the world, both
##      readable by a worker without touching the scene tree:
##        * a height grid baked from the terrain generator, so hills, ridges and
##          the lake rim block sight lines exactly as the ground does;
##        * the AABBs of the structural props (gate pillars, lintels, the altar
##          monolith and pavilion roofs) - the walls and the ceilings.
##   2. Every PROBE_INTERVAL it hands the viewer position, the view direction,
##      the entity sample points and both snapshots to
##      WorkerThreadPool.add_task(). The task touches no Node at all, so the main
##      thread never waits on it: it only reads a completion flag.
##   3. Visibility is estimated with a small path-traced probe: a primary ray to
##      each sample point of the entity's volume, and - for blocked samples - a
##      pair of two-leg secondary paths around the midpoint of the segment. The
##      secondary paths are what keep an entity seen *through* the gap between
##      two pillars visible; they can only ever keep something drawn, never hide
##      something the primary rays can see.
##   4. The main thread applies the finished decisions with hysteresis so nothing
##      pops, and calls set_view_culled() on each entity, which skips its drawing
##      and its tick.
##
## Thread-safety argument, in full: a worker reads only Packed arrays, Vector3s
## and floats copied into the snapshot Dictionary, and writes only its own slot
## of the results Array under _lock. Nothing it touches is a Node, a resource or
## a reference the main thread mutates while the task is in flight. _exit_tree()
## waits for the task, so a free during a probe cannot leave a callable pointing
## at a dead object.

## How often the visibility pass is re-run. 5 Hz is far below the rate at which
## a player can walk around a wall, and updates are only applied when a decision
## flips, so a still camera costs one probe every fifth of a second.
const PROBE_INTERVAL := 0.2
## Slower cadence on the Performance quality tier: the probe is already cheap,
## but on a phone everything shares one of four cores.
const PROBE_INTERVAL_LOW := 0.4

## Never cull inside this radius. The camera sits 4.6 m behind the player, so
## anything this close is on screen and popping would be obvious.
const NEAR_HOLD := 12.0
## Beyond this the entity is not worth a draw call (and is a couple of pixels).
const FAR_CULL := 280.0
## Behind the view plane by more than this and it cannot be on screen at all.
const BEHIND_CULL := 3.0
## Consecutive "not visible" passes before an entity is hidden, so a single
## unlucky sample cannot flicker it off. Showing again is immediate.
const HIDE_STREAK := 2
## Seconds after becoming visible during which it is never hidden again.
const SHOW_GRACE := 0.75

## Terrain occlusion grid. 8 m is far coarser than the 3 m render mesh, which is
## deliberate: a ridge, a hill or a lake rim is tens of metres wide, the probe
## only needs to know whether the ground rises across the sight line, and a
## finer grid would cost a hundred thousand noise evaluations at boot.
const GRID_STEP := 8.0
const GRID_EXTENT := 520.0
## A sight line is sampled this often when checking it against the height grid.
const TERRAIN_STEP := 3.0
## How far above the interpolated height a point must be to count as clear.
const TERRAIN_MARGIN := 0.35
## Occluder boxes thinner than this in any axis are decoration, not geometry.
const MIN_BOX_EXTENT := 0.2
const MIN_BOX_VOLUME := 0.5
## Upper bound on boxes handed to the worker. The props only hold a few dozen
## real structures, so this is a guard against someone later stuffing thousands
## of meshes under _props, not a limit that is reached today.
const MAX_BOXES := 256
## A secondary path is aimed this far from the straight line to the sample, which
## is roughly the width of a gap between two ruined pillars.
const APERTURE_OFFSET := 1.4
## Two clear secondary paths are enough to call an entity visible through a gap.
const APERTURE_MIN := 2

var _terrain: Node3D
var _props_root: Node3D
var _entities: Array[Node3D] = []
## Per entity: the node, the applied decision, the hysteresis counters and the
## measured visual extent used to pick sample points. Keyed by instance id.
var _states := {}

var _heights := PackedFloat32Array()
var _grid_n := 0
var _grid_ready := false
var _bake_started := false

var _boxes := PackedFloat32Array()
var _box_count := 0
var _box_timer := 0.0

var _task_id := -1
var _probe_timer := 0.0
var _results: Array = []
var _lock := Mutex.new()

var _probe_count := 0
var _task_count := 0
var _visible_count := 0
var _hidden_count := 0


func setup(terrain_node: Node3D, props_root: Node3D) -> void:
	_terrain = terrain_node
	_props_root = props_root
	if not _bake_started:
		_bake_started = true
		# Deferred: baking the grid walks the noise field ~17k times, and doing
		# that inside the world's _ready() would push the first frame out by a
		# hitch the player would feel at spawn.
		_bake_terrain.call_deferred()
	_refresh_boxes()


func register_entity(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	if _entities.has(node):
		return
	_entities.append(node)
	var id := node.get_instance_id()
	if not _states.has(id):
		var extent := _measure(node)
		_states[id] = {
			"node": node,
			"hidden": false,
			"streak": 0,
			"grace_until": 0,
			"half": extent.x,
			"top": extent.y,
		}


## Register every Node3D in a group - "enemy", "sigil", "waypoint" - so the
## caller does not have to know what was spawned where.
func register_group(group_name: String) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group(group_name):
		if node is Node3D:
			register_entity(node as Node3D)


func _process(delta: float) -> void:
	if Game.is_paused:
		return
	if not _grid_ready:
		return
	_poll_task()
	# Props are static, but the box snapshot is cheap enough to rebuild
	# occasionally and this keeps the culler correct if anything ever spawns a
	# structure at runtime.
	_box_timer -= delta
	if _box_timer <= 0.0:
		_box_timer = 5.0
		_refresh_boxes()
	_probe_timer -= delta
	if _probe_timer <= 0.0 and _task_id < 0:
		_probe_timer = _interval()
		_launch()


func _exit_tree() -> void:
	# A worker writing into this object's results Array while the object is being
	# freed is the one way this design could crash. Wait for it: the task is a
	# few hundred microseconds of AABB maths, so this is not a stall.
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1


func _interval() -> float:
	if Game.quality_tier >= 1:
		return PROBE_INTERVAL_LOW
	return PROBE_INTERVAL


## Bake the collision height field into a coarse grid the worker can read.
func _bake_terrain() -> void:
	if _terrain == null or not is_instance_valid(_terrain):
		return
	if not _terrain.has_method("get_height_at"):
		push_warning("LastStar: entity culler has no terrain to sample")
		return
	var n := int((GRID_EXTENT * 2.0) / GRID_STEP) + 1
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var origin := -GRID_EXTENT
	for gz in range(n):
		for gx in range(n):
			var x := origin + float(gx) * GRID_STEP
			var z := origin + float(gz) * GRID_STEP
			heights[gz * n + gx] = float(_terrain.call("get_height_at", x, z))
	_heights = heights
	_grid_n = n
	_grid_ready = true


## Snapshot the structural props as world-space AABBs.
func _refresh_boxes() -> void:
	if _props_root == null or not is_instance_valid(_props_root):
		_boxes = PackedFloat32Array()
		_box_count = 0
		return
	var found: Array[AABB] = []
	var stack: Array[Node] = [_props_root]
	# Capped: the worker's cost is linear in the number of boxes, and the props
	# only ever hold a few dozen real structures. The walk is depth-first, so the
	# cap keeps whole landmark clusters rather than a random subset.
	while not stack.is_empty() and found.size() < MAX_BOXES:
		var n: Node = stack.pop_back()
		for child in n.get_children():
			stack.append(child)
		if not (n is MeshInstance3D):
			continue
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		if box.size.x < MIN_BOX_EXTENT or box.size.y < MIN_BOX_EXTENT or box.size.z < MIN_BOX_EXTENT:
			continue
		if box.size.x * box.size.y * box.size.z < MIN_BOX_VOLUME:
			continue
		found.append(box)
	var keep := found.size()
	var packed := PackedFloat32Array()
	packed.resize(keep * 6)
	for i in range(keep):
		var b := found[i]
		var o := i * 6
		packed[o] = b.position.x
		packed[o + 1] = b.position.y
		packed[o + 2] = b.position.z
		packed[o + 3] = b.position.x + b.size.x
		packed[o + 4] = b.position.y + b.size.y
		packed[o + 5] = b.position.z + b.size.z
	_boxes = packed
	_box_count = keep


## Hand the current question to a worker thread.
func _launch() -> void:
	var cam: Camera3D = null
	var vp := get_viewport()
	if vp != null:
		cam = vp.get_camera_3d()
	var viewer := Vector3.ZERO
	var forward := Vector3.FORWARD
	if cam != null:
		viewer = cam.global_position
		forward = -cam.global_transform.basis.z
	else:
		var players := get_tree().get_nodes_in_group("player")
		if players.is_empty():
			return
		var p := players[0] as Node3D
		if p == null:
			return
		viewer = p.global_position + Vector3(0.0, 1.65, 0.0)
		forward = -p.global_transform.basis.z

	var side := forward.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()

	var live: Array[Node3D] = []
	var samples := PackedVector3Array()
	var ranges := PackedInt32Array()
	for node in _entities:
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			continue
		if not node.is_inside_tree():
			continue
		var st: Dictionary = _states.get(node.get_instance_id(), {})
		var half := float(st.get("half", 0.6))
		var top := float(st.get("top", 1.3))
		var pts := _sample_points(node.global_position, side, half, top)
		ranges.append(samples.size())
		samples.append_array(pts)
		live.append(node)
	if live.is_empty() or samples.is_empty():
		return
	ranges.append(samples.size())

	var results: Array = []
	results.resize(live.size())
	results.fill(1.0)

	var snap := {
		"viewer": viewer,
		"forward": forward,
		"heights": _heights,
		"grid_n": _grid_n,
		"grid_step": GRID_STEP,
		"grid_origin": -GRID_EXTENT,
		"boxes": _boxes,
		"box_count": _box_count,
		"near_hold": NEAR_HOLD,
		"far_cull": FAR_CULL,
		"behind_cull": BEHIND_CULL,
	}
	_entities = live
	_results = results
	_task_count += 1
	_task_id = WorkerThreadPool.add_task(
		_run_probe.bind(snap, samples, ranges, results), false, "entity visibility probe")


## The worker. Touches no Node: everything it needs is in the arguments.
func _run_probe(snap: Dictionary, samples: PackedVector3Array,
		ranges: PackedInt32Array, results: Array) -> void:
	var count := ranges.size() - 1
	for i in range(count):
		var first := ranges[i]
		var last := ranges[i + 1]
		if last <= first:
			continue
		var pts: PackedVector3Array = samples.slice(first, last)
		var centre := Vector3.ZERO
		for p in pts:
			centre += p
		centre /= float(pts.size())
		var seen := _visibility_of(snap, centre, pts)
		_lock.lock()
		results[i] = 1.0 if seen else 0.0
		_lock.unlock()


func _poll_task() -> void:
	if _task_id < 0:
		return
	if not WorkerThreadPool.is_task_completed(_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_probe_count += 1
	_apply()


## Apply the finished decisions on the main thread, with hysteresis.
func _apply() -> void:
	_lock.lock()
	var results := _results.duplicate()
	_lock.unlock()
	var now := Time.get_ticks_msec()
	var grace_ms := int(SHOW_GRACE * 1000.0)
	for id in _states.keys():
		var st: Dictionary = _states[id]
		var node = st.get("node")
		if node == null or not is_instance_valid(node):
			_states.erase(id)
	_visible_count = 0
	_hidden_count = 0
	for i in range(_entities.size()):
		var node := _entities[i]
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			continue
		var seen := false
		if i < results.size():
			seen = float(results[i]) >= 0.5
		var id := node.get_instance_id()
		var st: Dictionary = _states.get(id, {})
		if st.is_empty():
			var extent := _measure(node)
			st = {"node": node, "hidden": false, "streak": 0, "grace_until": 0,
				"half": extent.x, "top": extent.y}
			_states[id] = st
		if seen:
			st["streak"] = 0
			st["grace_until"] = now + grace_ms
			if bool(st["hidden"]):
				st["hidden"] = false
				_apply_cull(node, false)
		else:
			st["streak"] = int(st["streak"]) + 1
			if not bool(st["hidden"]) and int(st["streak"]) >= HIDE_STREAK \
					and now >= int(st["grace_until"]):
				st["hidden"] = true
				_apply_cull(node, true)
		if bool(st["hidden"]):
			_hidden_count += 1
		else:
			_visible_count += 1


func _apply_cull(node: Node3D, hidden: bool) -> void:
	if node.has_method("set_view_culled"):
		node.call("set_view_culled", hidden)
		return
	# Fallback for an entity that only has the generic Node3D visual: skip it in
	# the renderer, and stop its per-frame script as well.
	node.visible = not hidden
	node.set_process(not hidden)


## Five points on the entity's own volume: low, middle and high on its vertical
## axis, plus the two silhouettes across the view. Sizing these from the measured
## AABB matters - a fixed "2 m above the origin" sample is clear air over a
## knee-high slime, which would have made every slime permanently visible.
func _sample_points(centre: Vector3, side: Vector3,
		half: float, top: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(centre + Vector3(0.0, top * 0.15, 0.0))
	out.append(centre + Vector3(0.0, top * 0.5, 0.0))
	out.append(centre + Vector3(0.0, top * 0.92, 0.0))
	out.append(centre + side * half + Vector3(0.0, top * 0.5, 0.0))
	out.append(centre - side * half + Vector3(0.0, top * 0.5, 0.0))
	return out


## The actual visibility estimate. Pure function of the snapshot: no members, no
## scene tree, safe from any thread.
static func _visibility_of(snap: Dictionary, centre: Vector3,
		samples: PackedVector3Array) -> bool:
	var viewer: Vector3 = snap["viewer"]
	var forward: Vector3 = snap["forward"]
	var to := centre - viewer
	var dist := to.length()
	if dist <= float(snap["near_hold"]):
		return true
	if dist > float(snap["far_cull"]):
		return false
	if dist > float(snap["behind_cull"]) and to.dot(forward) <= 0.0:
		return false
	var direct := 0
	var bounced := 0
	for s in samples:
		if _segment_clear(snap, viewer, s):
			direct += 1
			continue
		for p in _aperture_points(viewer, s, forward):
			if _segment_clear(snap, viewer, p) and _segment_clear(snap, p, s):
				bounced += 1
	if direct >= 1:
		return true
	return bounced >= APERTURE_MIN


## Two-leg secondary paths through the segment midpoint: the path-traced part.
## Offset perpendicular to the sight line, which is where a gap between pillars
## or the open side of a shelter actually is.
static func _aperture_points(viewer: Vector3, target: Vector3,
		forward: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var mid := viewer.lerp(target, 0.5)
	var side := forward.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()
	out.append(mid + side * APERTURE_OFFSET)
	out.append(mid - side * APERTURE_OFFSET)
	return out


static func _segment_clear(snap: Dictionary, a: Vector3, b: Vector3) -> bool:
	if _terrain_blocks(snap, a, b):
		return false
	var boxes: PackedFloat32Array = snap["boxes"]
	var n: int = snap["box_count"]
	for i in range(n):
		var o := i * 6
		var lo := Vector3(boxes[o], boxes[o + 1], boxes[o + 2])
		var hi := Vector3(boxes[o + 3], boxes[o + 4], boxes[o + 5])
		if not _segment_hits_box(a, b, lo, hi):
			continue
		# A box that contains the *target* is the entity's own surroundings, not
		# an occluder between the viewer and it - a sigil that landed inside a
		# crystal cluster's AABB would otherwise be hidden by the cluster it is
		# standing in. The viewer's end is deliberately not exempt: a camera that
		# clipped inside a pillar is looking at the inside of the pillar, and
		# exempting it would let that pillar stop occluding anything at all.
		if _point_in_box(b, lo, hi):
			continue
		return false
	return true


static func _point_in_box(p: Vector3, lo: Vector3, hi: Vector3) -> bool:
	return p.x >= lo.x and p.y >= lo.y and p.z >= lo.z \
		and p.x <= hi.x and p.y <= hi.y and p.z <= hi.z


static func _terrain_blocks(snap: Dictionary, a: Vector3, b: Vector3) -> bool:
	var n: int = snap["grid_n"]
	if n < 2:
		return false
	var heights: PackedFloat32Array = snap["heights"]
	if heights.size() < n * n:
		return false
	var step: float = snap["grid_step"]
	var origin: float = snap["grid_origin"]
	var seg := b - a
	var dist := seg.length()
	if dist < 0.5:
		return false
	var steps := clampi(int(dist / TERRAIN_STEP) + 2, 3, 96)
	for i in range(1, steps):
		var t := float(i) / float(steps)
		var p := a + seg * t
		var ground := _grid_height(heights, n, step, origin, p.x, p.z)
		if ground > p.y + TERRAIN_MARGIN:
			return true
	return false


## Bilinear height at a world position, or a very low value outside the grid
## (nothing is known there, and inventing a hill would cull the whole horizon).
static func _grid_height(heights: PackedFloat32Array, n: int, step: float,
		origin: float, x: float, z: float) -> float:
	var fx := (x - origin) / step
	var fz := (z - origin) / step
	if fx < 0.0 or fz < 0.0 or fx >= float(n - 1) or fz >= float(n - 1):
		return -100000.0
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - float(ix)
	var tz := fz - float(iz)
	var i00 := iz * n + ix
	var h00 := heights[i00]
	var h10 := heights[i00 + 1]
	var h01 := heights[i00 + n]
	var h11 := heights[i00 + n + 1]
	var top := h00 + (h10 - h00) * tx
	var bottom := h01 + (h11 - h01) * tx
	return top + (bottom - top) * tz


## Segment/AABB intersection by the slab method, in the segment's own parameter
## space. Deliberately branchy instead of dividing by zero: a ray exactly
## parallel to a face is a real case here (sight lines along a row of pillars).
static func _segment_hits_box(a: Vector3, b: Vector3,
		lo: Vector3, hi: Vector3) -> bool:
	var d := b - a
	var t0 := 0.02
	var t1 := 0.98
	for axis in range(3):
		var p := _axis(a, axis)
		var dd := _axis(d, axis)
		var l := _axis(lo, axis)
		var h := _axis(hi, axis)
		if absf(dd) < 0.0001:
			if p < l or p > h:
				return false
			continue
		var ta := (l - p) / dd
		var tb := (h - p) / dd
		if ta > tb:
			var swap := ta
			ta = tb
			tb = swap
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return false
	return true


static func _axis(v: Vector3, i: int) -> float:
	if i == 0:
		return v.x
	if i == 1:
		return v.y
	return v.z


## Local visual extent of an entity: (half width across the view, height). Taken
## once at registration from the mesh children, because a slime and a waypoint
## statue need very different sample points.
static func _measure(node: Node3D) -> Vector2:
	var box := AABB()
	var first := true
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for child in n.get_children():
			stack.append(child)
		if not (n is MeshInstance3D):
			continue
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var world_box: AABB = mi.global_transform * mi.get_aabb()
		box = world_box if first else box.merge(world_box)
		first = false
	if first:
		return Vector2(0.6, 1.3)
	var half := clampf(maxf(box.size.x, box.size.z) * 0.5, 0.25, 2.4)
	var top := clampf(box.size.y, 0.5, 6.5)
	return Vector2(half, top)


## True when the entity's visual is not being submitted to the renderer.
static func _visual_suppressed(node: Node3D) -> bool:
	if not node.is_visible_in_tree():
		return true
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and not (n as Node3D).visible:
			return true
		for child in n.get_children():
			stack.append(child)
	return false


func stats() -> Dictionary:
	var consistent := true
	var checked := 0
	var render_skipped := 0
	var tick_reduced := 0
	for id in _states.keys():
		var st: Dictionary = _states[id]
		var node = st.get("node")
		if node == null or not is_instance_valid(node):
			continue
		if node.is_queued_for_deletion():
			continue
		if not node.has_method("is_view_culled"):
			if bool(st["hidden"]):
				render_skipped += 1
			continue
		checked += 1
		if bool(node.call("is_view_culled")) != bool(st["hidden"]):
			consistent = false
		if bool(st["hidden"]):
			tick_reduced += 1
			if _visual_suppressed(node):
				render_skipped += 1
	return {
		"registered": _entities.size(),
		"visible": _visible_count,
		"hidden": _hidden_count,
		"probes": _probe_count,
		"tasks": _task_count,
		"threads": OS.get_processor_count(),
		"grid": _grid_n * _grid_n,
		"occluders": _box_count,
		"interval": _interval(),
		"checked": checked,
		"consistent": consistent,
		"render_skipped": render_skipped,
		"tick_reduced": tick_reduced,
	}


func census() -> String:
	return "ENTITY_CULL registered=%d visible=%d hidden=%d probes=%d tasks=%d threads=%d grid=%d occluders=%d render_skipped=%d tick_reduced=%d" % [
		_entities.size(), _visible_count, _hidden_count, _probe_count, _task_count,
		OS.get_processor_count(), _grid_n * _grid_n, _box_count,
		int(stats()["render_skipped"]), int(stats()["tick_reduced"])]


## Deterministic checks of the geometry predicates, on synthetic geometry where
## the answer is known: one wall, one roof, one ridge.
##
## The render probe cannot see a wrong cull decision - both a culled entity and a
## correctly hidden one simply are not in the frame - so the predicates have to
## be asserted directly. This is what CI gates on.
func self_test() -> Dictionary:
	var failures: Array[String] = []
	var n := 33
	var step := 8.0
	var origin := -128.0
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	for gz in range(n):
		for gx in range(n):
			var x := origin + float(gx) * step
			var z := origin + float(gz) * step
			var h := 0.0
			if absf(x) < 40.0 and absf(z) < 10.0:
				h = 9.0
			heights[gz * n + gx] = h
	var boxes := PackedFloat32Array()
	# Wall: 2 m thick, 10 m tall, at x = 0 around z = 40.
	# Roof: a 12 x 12 m ceiling over z = 65, 4 m up.
	boxes.append_array(PackedFloat32Array([
		-1.0, -2.0, 36.0, 1.0, 8.0, 44.0,
		-6.0, 4.0, 59.0, 6.0, 5.0, 71.0,
	]))
	var snap := {
		"heights": heights,
		"grid_n": n,
		"grid_step": step,
		"grid_origin": origin,
		"boxes": boxes,
		"box_count": 2,
		"viewer": Vector3(-40.0, 2.0, 40.0),
		"forward": Vector3(1.0, 0.0, 0.0),
		"near_hold": NEAR_HOLD,
		"far_cull": FAR_CULL,
		"behind_cull": BEHIND_CULL,
	}
	var wall_lo := Vector3(-1.0, -2.0, 36.0)
	var wall_hi := Vector3(1.0, 8.0, 44.0)
	if not _segment_hits_box(Vector3(-40.0, 2.0, 40.0), Vector3(40.0, 1.0, 40.0), wall_lo, wall_hi):
		failures.append("a segment straight through the wall reported no hit")
	if _segment_hits_box(Vector3(-40.0, 2.0, 40.0), Vector3(40.0, 1.0, 60.0), wall_lo, wall_hi):
		failures.append("a segment beside the wall reported a hit")
	if _segment_hits_box(Vector3(-40.0, 2.0, 40.0), Vector3(-20.0, 2.0, 40.0), wall_lo, wall_hi):
		failures.append("a segment that stops short of the wall reported a hit")

	# Terrain: the ridge sits across z = 0 between x = -40 and 40.
	var low_a := Vector3(0.0, 2.0, -60.0)
	var low_b := Vector3(0.0, 1.0, 60.0)
	if not _terrain_blocks(snap, low_a, low_b):
		failures.append("a sight line through a 9 m ridge reported clear")
	var high_a := Vector3(0.0, 40.0, -60.0)
	if _terrain_blocks(snap, high_a, low_b):
		failures.append("a sight line over the ridge reported blocked")

	# Ceiling: from above, the roof hides what is under it; from the side, the
	# open shelter is see-through.
	var above := Vector3(0.0, 30.0, 65.0)
	var under := Vector3(0.0, 1.0, 65.0)
	var beside := Vector3(-40.0, 1.5, 65.0)
	if not _segment_hits_box(above, under, Vector3(-6.0, 4.0, 59.0), Vector3(6.0, 5.0, 71.0)):
		failures.append("a downward sight line through the roof reported no hit")
	if not _segment_clear(snap, beside, under):
		failures.append("a sight line under the open shelter reported blocked")

	# Whole-estimate cases, with sample points standing in for an entity.
	if not _visibility_of(snap, Vector3(-20.0, 1.0, 40.0), _sample_points(Vector3(-20.0, 1.0, 40.0), Vector3(0, 0, 1), 0.6, 1.3)):
		failures.append("an entity in the open was reported hidden")
	if _visibility_of(snap, Vector3(40.0, 1.0, 40.0), _sample_points(Vector3(40.0, 1.0, 40.0), Vector3(0, 0, 1), 0.6, 1.3)):
		failures.append("an entity behind the wall was reported visible")
	var behind_snap := snap.duplicate()
	behind_snap["forward"] = Vector3(-1.0, 0.0, 0.0)
	if _visibility_of(behind_snap, Vector3(40.0, 1.0, 40.0), _sample_points(Vector3(40.0, 1.0, 40.0), Vector3(0, 0, 1), 0.6, 1.3)):
		failures.append("an entity behind the camera was reported visible")
	if _visibility_of(snap, Vector3(400.0, 1.0, 40.0), _sample_points(Vector3(400.0, 1.0, 40.0), Vector3(0, 0, 1), 0.6, 1.3)):
		failures.append("an entity beyond the far cull was reported visible")
	if not _visibility_of(snap, Vector3(-34.0, 1.0, 40.0), _sample_points(Vector3(-34.0, 1.0, 40.0), Vector3(0, 0, 1), 0.6, 1.3)):
		failures.append("an entity inside the near hold was reported hidden")

	var checks := 12
	return {
		"ok": failures.is_empty(),
		"summary": "%d/%d predicate checks passed (wall, ridge, roof, near/far/behind)" % [
			checks - failures.size(), checks],
		"failures": failures,
	}
