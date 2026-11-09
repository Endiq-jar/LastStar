extends Control
## On-screen joystick for Android/iOS. Writes Game.touch_move, which the player
## prefers over keyboard input when it is non-zero. The right half of the
## screen is used for camera orbit drags (handled in player.gd).

var _base_center := Vector2(150, 0)
var _knob: Panel
var _knob_center := Vector2.ZERO
var _active_index := -1
const RADIUS := 92.0
const KNOB_RADIUS := 38.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vp := get_viewport_rect().size
	_base_center = Vector2(150, vp.y - 190)
	_knob_center = _base_center

	var base := Panel.new()
	base.name = "Base"
	base.position = _base_center - Vector2(RADIUS, RADIUS)
	base.size = Vector2(RADIUS * 2.0, RADIUS * 2.0)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.10, 0.16, 0.35)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.85, 0.95, 1.0, 0.35)
	sb.corner_radius_top_left = int(RADIUS)
	sb.corner_radius_top_right = int(RADIUS)
	sb.corner_radius_bottom_left = int(RADIUS)
	sb.corner_radius_bottom_right = int(RADIUS)
	base.add_theme_stylebox_override("panel", sb)
	add_child(base)

	_knob = Panel.new()
	_knob.name = "Knob"
	_knob.position = _knob_center - Vector2(KNOB_RADIUS, KNOB_RADIUS)
	_knob.size = Vector2(KNOB_RADIUS * 2.0, KNOB_RADIUS * 2.0)
	_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ks := StyleBoxFlat.new()
	ks.bg_color = Color(0.55, 0.9, 1.0, 0.45)
	ks.border_width_left = 2
	ks.border_width_top = 2
	ks.border_width_right = 2
	ks.border_width_bottom = 2
	ks.border_color = Color(0.9, 0.98, 1.0, 0.9)
	ks.corner_radius_top_left = int(KNOB_RADIUS)
	ks.corner_radius_top_right = int(KNOB_RADIUS)
	ks.corner_radius_bottom_left = int(KNOB_RADIUS)
	ks.corner_radius_bottom_right = int(KNOB_RADIUS)
	_knob.add_theme_stylebox_override("panel", ks)
	add_child(_knob)

	Game.touch_active = true


func _exit_tree() -> void:
	Game.touch_move = Vector2.ZERO


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.index == _active_index or (t.pressed and _active_index == -1 and t.position.x < get_viewport_rect().size.x * 0.45 and t.position.distance_to(_base_center) < RADIUS * 1.9):
			_active_index = t.index if t.pressed else -1
			if not t.pressed:
				Game.touch_move = Vector2.ZERO
				_knob_center = _base_center
				_knob.position = _knob_center - Vector2(KNOB_RADIUS, KNOB_RADIUS)
			else:
				_update_knob(t.position)
			get_viewport().set_input_as_handled()

	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _active_index:
			_update_knob(d.position)
			get_viewport().set_input_as_handled()


func _update_knob(pos: Vector2) -> void:
	var offset := (pos - _base_center).limit_length(RADIUS)
	_knob_center = _base_center + offset
	_knob.position = _knob_center - Vector2(KNOB_RADIUS, KNOB_RADIUS)
	var v := offset / RADIUS
	# Screen up is -y, which must map to move_forward (-y in Input.get_vector).
	Game.touch_move = Vector2(v.x, v.y)
