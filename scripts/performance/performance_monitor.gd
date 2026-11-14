extends PanelContainer
## Developer overlay. Engine monitors are estimates, not Android system RAM or
## GPU timestamps. Frame samples are collected only while this panel is open.

const UI := preload("res://scripts/ui_style.gd")

var _label: Label
var _frames: Array[float] = []
var _refresh_timer := 0.0


func _ready() -> void:
	name = "PerformanceMonitor"
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	self.offset_left = -420
	self.offset_top = 115
	self.offset_right = -15
	self.offset_bottom = 345
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := UI.panel(12.0, 0.92)
	add_theme_stylebox_override("panel", style)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 15)
	add_child(_label)
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	if not Game.is_paused and delta > 0.0:
		_frames.append(delta)
		if _frames.size() > 300:
			_frames.pop_front()
	_refresh_timer += delta
	if _refresh_timer < 0.5:
		return
	_refresh_timer = 0.0
	_refresh_text(delta)


func _refresh_text(delta: float) -> void:
	var low := "warming up"
	if _frames.size() >= 100:
		var sorted := _frames.duplicate()
		sorted.sort()
		var count := maxi(1, int(ceil(float(sorted.size()) * 0.01)))
		var sum := 0.0
		for i in range(sorted.size() - count, sorted.size()):
			sum += sorted[i]
		low = "%.1f FPS" % (float(count) / sum)
	var world := get_parent().get_parent()
	var terrain := world.get_node_or_null("Terrain")
	var chunk := "n/a"
	if terrain != null:
		chunk = "%.2f ms" % float(terrain.get("last_chunk_ms"))
	var active := 0
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if enemy is Node3D and (enemy as Node3D).is_visible_in_tree():
			active += 1
	var viewport := get_viewport()
	_label.text = ("LAST STAR — PERFORMANCE\n" +
		"FPS %.0f | frame %.1f ms | 1%% low %s\n" +
		"CPU process %.1f ms | physics %.1f ms | GPU n/a\n" +
		"Draws %d | triangles %d | visible enemies %d\n" +
		"Active physics %d | engine RAM %.1f MB\n" +
		"Video %.1f MB | textures %.1f MB | 3D scale %.2f\n" +
		"Last terrain chunk %s | temperature n/a\n" +
		"Shader compile timing n/a") % [
		Performance.get_monitor(Performance.TIME_FPS), delta * 1000.0, low,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)), active,
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		viewport.scaling_3d_scale, chunk]
