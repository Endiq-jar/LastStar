extends Control
## The Wander spell wheel: five spell buttons that fan out beside the joystick's
## top-left area, plus a book toggle on the right side of the screen.
##
## Interactions
##   tap            -> cast that slot
##   long press     -> open slot editor (pick any known spell, or clear)
##   drag across    -> nothing; each slot is its own button
##
## The wheel is hand-rolled rather than a Button grid because it needs a
## cooldown sweep, an empty-slot state and a press-and-hold gesture, none of
## which a plain Button gives us.

const ICON_DIR := "res://icons/actions/"
const SLOT_SIZE := 84.0
const BOOK_SIZE := 78.0
const HOLD_TIME := 0.45

var wander: Wander  ## the player's spellbook
var _root: Control
var _slots: Array[Control] = []
var _icons: Array[TextureRect] = []
var _sweeps: Array[Control] = []
var _glyphs: Array[Label] = []
var _book_button: Control
var _book_icon: TextureRect
var _editor: PanelContainer
var _editor_list: VBoxContainer
var _editor_title: Label
var _editor_slot := -1
var _open := false
var _slot_press: Dictionary = {}
var _slot_held: Dictionary = {}
var _slot_repeat: Dictionary = {}
var _visible_pos := Vector2.ZERO
var _hidden_pos := Vector2.ZERO


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_slots()
	_build_book_button()
	_build_editor()
	if wander != null:
		wander.slots_changed.connect(_refresh)
		_refresh()
	_set_open(false, true)


func setup(p_wander: Wander) -> void:
	## Hand the wheel its spellbook. Safe to call before or after _ready().
	wander = p_wander
	if _root == null:
		return
	if not wander.slots_changed.is_connected(_refresh):
		wander.slots_changed.connect(_refresh)
	_refresh()


func _build_slots() -> void:
	var vp := get_viewport_rect().size
	# Anchor near the joystick: the joystick sits at (150, height-190) with a
	# 92 px radius, so the wheel starts above and to the right of it.
	var origin := Vector2(64.0, vp.y - 470.0)
	for i in range(5):
		var slot := _make_slot(i)
		slot.position = origin + Vector2(0.0, i * (SLOT_SIZE + 12.0))
		_root.add_child(slot)
		_slots.append(slot)
	_visible_pos = origin
	_hidden_pos = origin + Vector2(-150.0, 0.0)


func _make_slot(i: int) -> Control:
	var holder := Control.new()
	holder.name = "SpellSlot%d" % i
	holder.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	holder.size = Vector2(SLOT_SIZE, SLOT_SIZE)
	holder.mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel", _slot_style(false))
	bg.name = "Bg"
	holder.add_child(bg)

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 8
	icon.offset_top = 8
	icon.offset_right = -8
	icon.offset_bottom = -8
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(icon)

	var sweep := Control.new()
	sweep.name = "Sweep"
	sweep.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sweep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sweep.draw.connect(func(): _draw_sweep(sweep, i))
	holder.add_child(sweep)

	var glyph := Label.new()
	glyph.name = "Glyph"
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 30)
	glyph.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(glyph)

	var num := Label.new()
	num.text = str(i + 1)
	num.position = Vector2(7, 4)
	num.add_theme_font_size_override("font_size", 14)
	num.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(num)

	# Press-and-hold gesture + tap. Named methods rather than inline lambdas:
	# a multi-line lambda needs its body on the same logical line and silently
	# becomes a parse error otherwise.
	var hold := Timer.new()
	hold.one_shot = true
	hold.wait_time = HOLD_TIME
	hold.name = "Hold"
	holder.add_child(hold)
	hold.timeout.connect(_on_slot_hold.bind(i))

	holder.gui_input.connect(_on_slot_input.bind(i, hold))

	_icons.append(icon)
	_sweeps.append(sweep)
	_glyphs.append(glyph)
	return holder


func _on_slot_input(ev: InputEvent, i: int, hold: Timer) -> void:
	var pressed := false
	var is_release := false
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		pressed = mb.pressed
		is_release = not mb.pressed
	elif ev is InputEventScreenTouch:
		var st := ev as InputEventScreenTouch
		pressed = st.pressed
		is_release = not st.pressed
	else:
		return

	if pressed:
		# Fire immediately on press rather than on release: waiting for the
		# finger to lift made every cast feel laggy. Holding opens the editor
		# instead, so the repeat is suppressed while the hold timer runs.
		_slot_press[i] = true
		_slot_held[i] = false
		_cast_slot(i)
		hold.start()
	elif is_release:
		hold.stop()
		_slot_press[i] = false


func _on_slot_hold(i: int) -> void:
	if _slot_held.get(i, false):
		return
	_slot_held[i] = true
	_open_editor(i)


func _process(_delta: float) -> void:
	# Hold-to-repeat casting: while a slot is held (and the editor has not opened
	# instead) cast again once a second. Cooldowns still gate the actual cast,
	# so a held button simply re-casts at whatever rate the spell allows.
	for i in range(_slots.size()):
		if not _slot_press.get(i, false) or _slot_held.get(i, false):
			continue
		_slot_repeat[i] = float(_slot_repeat.get(i, 0.0)) + _delta
		if float(_slot_repeat[i]) >= 1.0:
			_slot_repeat[i] = 0.0
			_cast_slot(i)


func _on_book_input(ev: InputEvent) -> void:
	var pressed := false
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		pressed = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	elif ev is InputEventScreenTouch:
		pressed = (ev as InputEventScreenTouch).pressed
	else:
		return
	if pressed:
		_set_open(not _open)


func _on_editor_close() -> void:
	_editor.visible = false


func _on_editor_pick(id: String) -> void:
	wander.set_slot(_editor_slot, id)
	_editor.visible = false


func _build_book_button() -> void:
	var vp := get_viewport_rect().size
	_book_button = Control.new()
	_book_button.name = "SpellBook"
	_book_button.size = Vector2(BOOK_SIZE, BOOK_SIZE)
	_book_button.position = Vector2(vp.x - BOOK_SIZE - 26.0, vp.y - 372.0)
	_book_button.mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.14, 0.26, 0.80)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(1.0, 0.88, 0.55, 0.85)
	sb.corner_radius_top_left = int(BOOK_SIZE * 0.5)
	sb.corner_radius_top_right = int(BOOK_SIZE * 0.5)
	sb.corner_radius_bottom_left = int(BOOK_SIZE * 0.5)
	sb.corner_radius_bottom_right = int(BOOK_SIZE * 0.5)
	bg.add_theme_stylebox_override("panel", sb)
	_book_button.add_child(bg)

	_book_icon = TextureRect.new()
	_book_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_book_icon.offset_left = 9
	_book_icon.offset_top = 9
	_book_icon.offset_right = -9
	_book_icon.offset_bottom = -9
	_book_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_book_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_book_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_book_icon.texture = _tex("spellbook")
	_book_button.add_child(_book_icon)

	_book_button.gui_input.connect(_on_book_input)
	_root.add_child(_book_button)


func _build_editor() -> void:
	_editor = PanelContainer.new()
	_editor.name = "SpellEditor"
	_editor.visible = false
	_editor.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_editor.offset_left = -230
	_editor.offset_right = 230
	_editor.offset_top = -220
	_editor.offset_bottom = 220
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.09, 0.16, 0.97)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.55, 0.85, 1.0, 0.8)
	sb.corner_radius_top_left = 16
	sb.corner_radius_top_right = 16
	sb.corner_radius_bottom_left = 16
	sb.corner_radius_bottom_right = 16
	sb.content_margin_left = 18
	sb.content_margin_top = 14
	sb.content_margin_right = 18
	sb.content_margin_bottom = 14
	_editor.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_editor.add_child(v)

	_editor_title = Label.new()
	_editor_title.text = "Spell slot"
	_editor_title.add_theme_font_size_override("font_size", 21)
	_editor_title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.7))
	v.add_child(_editor_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)

	_editor_list = VBoxContainer.new()
	_editor_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_editor_list)

	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(0, 46)
	close.add_theme_font_size_override("font_size", 18)
	close.pressed.connect(_on_editor_close)
	v.add_child(close)

	_root.add_child(_editor)


func _open_editor(slot_index: int) -> void:
	if wander == null:
		return
	_editor_slot = slot_index
	_editor_title.text = "Slot %d" % (slot_index + 1)
	for c in _editor_list.get_children():
		c.queue_free()

	# Clear-slot option
	_editor_list.add_child(_editor_row("", "Empty slot", null))

	for id in wander.CATALOGUE.keys():
		if not wander.known(id):
			continue
		var data: Dictionary = wander.spell(id)
		_editor_list.add_child(_editor_row(id, str(data["name"]), data))
	_editor.visible = true


func _editor_row(id: String, label: String, data) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 56)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 18)
	var equipped_here: bool = id != "" and wander.equipped_at(_editor_slot) == id
	b.text = "   %s%s" % [label, "  ✓" if equipped_here else ""]
	if data is Dictionary:
		if wander.equipped_at(_editor_slot) != id and _find_slot(id) >= 0:
			b.text += "   (slot %d)" % (_find_slot(id) + 1)
		b.tooltip_text = "%s\n%s\nLight %d · cooldown %.1fs · Lv.%d" % [
			data["name"], data.get("desc", ""), int(data["cost"]),
			float(data["cooldown"]), wander.level_of(id)]
	if id == "":
		b.pressed.connect(_on_editor_pick.bind(""))
	else:
		var icon := TextureRect.new()
		icon.texture = _tex(str(data.get("icon", "")))
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
		icon.offset_left = 6
		icon.offset_right = 50
		icon.offset_top = 4
		icon.offset_bottom = -4
		b.add_child(icon)
		b.pressed.connect(_on_editor_pick.bind(id))
	return b


func _find_slot(id: String) -> int:
	for i in range(5):
		if wander.equipped_at(i) == id:
			return i
	return -1


func _cast_slot(i: int) -> void:
	if wander == null:
		return
	var id: String = wander.equipped_at(i)
	if id == "":
		Game.toast.emit("Empty spell slot — long press to assign")
		return
	if not Game.spend_energy(float(wander.spell(id)["cost"])):
		Game.toast.emit("Not enough Light")
		return
	if wander.cooldown_left(id) > 0.0:
		Game.toast.emit("%s is recharging" % wander.spell(id)["name"])
		return
	var data: Dictionary = wander.begin_cast(id)
	Game.spell_cast.emit(id, data)


func _set_open(open: bool, instant: bool = false) -> void:
	_open = open
	_book_icon.texture = _tex("library" if open else "spellbook")
	for i in range(_slots.size()):
		var base := _visible_pos if open else _hidden_pos
		var target := base + Vector2(0.0, i * (SLOT_SIZE + 12.0))
		var slot := _slots[i]
		if instant:
			slot.position = target
			slot.modulate.a = 1.0 if open else 0.0
		else:
			var tw := create_tween().set_parallel(true)
			tw.tween_property(slot, "position", target, 0.22).set_trans(Tween.TRANS_CUBIC)
			tw.tween_property(slot, "modulate:a", 1.0 if open else 0.0, 0.18)
	for i in range(_slots.size()):
		_slots[i].mouse_filter = Control.MOUSE_FILTER_STOP if open else Control.MOUSE_FILTER_IGNORE


func _refresh() -> void:
	if wander == null:
		return
	for i in range(_slots.size()):
		var id: String = wander.equipped_at(i)
		var known: bool = wander.known(id)
		var icon := _icons[i]
		if known:
			icon.texture = _tex(str(wander.spell(id).get("icon", "")))
			icon.modulate = Color(1, 1, 1, 1)
		else:
			icon.texture = null
			_glyphs[i].text = "+"
		var bg := _slots[i].get_node_or_null("Bg") as Panel
		if bg:
			var ready_now: bool = known and wander.cooldown_left(id) <= 0.0
			bg.add_theme_stylebox_override("panel", _slot_style(known, ready_now))
		_sweeps[i].queue_redraw()
	_book_icon.modulate = Color(1, 1, 1, 1)


func _draw_sweep(canvas: Control, i: int) -> void:
	if wander == null:
		return
	var id: String = wander.equipped_at(i)
	if not wander.known(id):
		return
	var ratio: float = wander.cooldown_ratio(id)
	if ratio >= 1.0:
		return
	# Draw the remaining cooldown as a dark radial wedge over the icon.
	var c := canvas.size * 0.5
	var r := minf(canvas.size.x, canvas.size.y) * 0.5 - 2.0
	var steps := 26
	var start := -PI * 0.5
	var span := TAU * (1.0 - ratio)
	var pts := PackedVector2Array()
	pts.append(c)
	for s in range(steps + 1):
		var a := start + span * (float(s) / float(steps))
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	canvas.draw_colored_polygon(pts, Color(0.02, 0.04, 0.09, 0.66))


func _slot_style(has_spell: bool, ready_now: bool = true) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.12, 0.22, 0.82) if has_spell else Color(0.08, 0.10, 0.16, 0.45)
	var border := Color(0.75, 0.9, 1.0, 0.75)
	if has_spell and ready_now:
		border = Color(1.0, 0.9, 0.6, 0.95)
	elif has_spell:
		border = Color(0.45, 0.6, 0.8, 0.7)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = border
	var rad := int(SLOT_SIZE * 0.5)
	sb.corner_radius_top_left = rad
	sb.corner_radius_top_right = rad
	sb.corner_radius_bottom_left = rad
	sb.corner_radius_bottom_right = rad
	return sb


func _tex(name: String) -> Texture2D:
	if name == "":
		return null
	var path := ICON_DIR + name + ".png"
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null
