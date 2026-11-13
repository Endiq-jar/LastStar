extends CanvasLayer
## LastStar HUD: party portraits with HP + element colour, burst energy,
## stamina, quest tracker, compass, touch controls (Android/iOS), pause menu
## and the victory banner.

const TOUCH := preload("res://scripts/touch_controls.gd")
## Loaded at runtime rather than preloaded: a preload that fails to resolve
## reports only "could not resolve script" against *this* file, which hides the
## real error inside the wheel. load() keeps the failure local and survivable -
## the HUD still works if the spell wheel is broken.
const SPELL_WHEEL_PATH := "res://scripts/spell_wheel.gd"

var _spell_wheel: Control
var _quest_label: Label
var _compass: Label
var _stamina: ProgressBar
var _energy: ProgressBar
var _sigil_label: Label
var _toast: Label
var _win_panel: PanelContainer
var _win_label: Label
var _skill_button: Button
var _burst_button: Button
var _pause_panel: PanelContainer
var _quality_btn: Button
var _toast_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Game.sigils_changed.connect(_on_sigils_changed)
	Game.stats_changed.connect(_refresh_stats)
	Game.character_changed.connect(_on_character_changed)
	Game.quest_changed.connect(_on_quest_changed)
	Game.toast.connect(_on_toast)
	Game.game_won.connect(_on_game_won)
	_refresh_stats()
	_on_sigils_changed(Game.sigils_collected, Game.TOTAL_SIGILS)
	_on_quest_changed(Game.quest_text)
	_update_quality_label()
	_attach_wander.call_deferred()
	if Game.is_mobile():
		var touch = TOUCH.new()
		touch.name = "TouchControls"
		add_child(touch)


func _attach_wander() -> void:
	## The HUD is built before the player, so the spellbook does not exist yet.
	## Poll a few frames for it rather than depending on scene-tree ordering.
	for i in range(180):
		if Game.wander != null:
			if _spell_wheel != null:
				_spell_wheel.call("setup", Game.wander)
			return
		await get_tree().process_frame
	push_warning("LastStar: no Wander spellbook appeared - the spell wheel is inert")


func _build() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# ---- top-left: sigils + quest ---------------------------------------
	var top_left := VBoxContainer.new()
	top_left.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	top_left.offset_left = 22
	top_left.offset_top = 16
	top_left.offset_right = 700
	top_left.offset_bottom = 110
	top_left.add_theme_constant_override("separation", 6)
	root.add_child(top_left)

	var sigil_row := HBoxContainer.new()
	sigil_row.add_theme_constant_override("separation", 8)
	top_left.add_child(sigil_row)
	var sigil_icon := Label.new()
	sigil_icon.text = "✦"
	sigil_icon.add_theme_font_size_override("font_size", 26)
	sigil_icon.add_theme_color_override("font_color", Color(1.0, 0.86, 0.45))
	sigil_row.add_child(sigil_icon)
	_sigil_label = Label.new()
	_sigil_label.text = "0 / 12 star sigils"
	_sigil_label.add_theme_font_size_override("font_size", 21)
	_sigil_label.add_theme_color_override("font_color", Color(1.0, 0.97, 0.9))
	_sigil_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_sigil_label.add_theme_constant_override("shadow_offset_x", 2)
	_sigil_label.add_theme_constant_override("shadow_offset_y", 2)
	sigil_row.add_child(_sigil_label)

	_quest_label = Label.new()
	_quest_label.text = ""
	_quest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quest_label.add_theme_font_size_override("font_size", 15)
	_quest_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0, 0.92))
	_quest_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	_quest_label.add_theme_constant_override("shadow_offset_x", 1)
	_quest_label.add_theme_constant_override("shadow_offset_y", 1)
	top_left.add_child(_quest_label)

	# ---- top-right: compass + pause --------------------------------------
	var top_right := HBoxContainer.new()
	top_right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	top_right.offset_left = -420
	top_right.offset_top = 16
	top_right.offset_right = -22
	top_right.offset_bottom = 70
	top_right.alignment = BoxContainer.ALIGNMENT_END
	top_right.add_theme_constant_override("separation", 14)
	root.add_child(top_right)

	_compass = Label.new()
	_compass.text = "✦ —"
	_compass.add_theme_font_size_override("font_size", 18)
	_compass.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	_compass.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	_compass.add_theme_constant_override("shadow_offset_x", 2)
	_compass.add_theme_constant_override("shadow_offset_y", 2)
	top_right.add_child(_compass)

	var pause_btn := _round_button("II", Vector2(46, 46))
	pause_btn.pressed.connect(_pause)
	top_right.add_child(pause_btn)

	# ---- bottom-left: the Wander spell wheel ---------------------------
	# (The old party-swap strip used to live here. Party switching is on the
	# keyboard/T key and the pause menu; the thumb corner belongs to spells.)
	var wheel_script := load(SPELL_WHEEL_PATH)
	if wheel_script != null:
		_spell_wheel = wheel_script.new()
	else:
		push_error("LastStar: could not load " + SPELL_WHEEL_PATH)
	if _spell_wheel != null:
		_spell_wheel.name = "SpellWheel"
		root.add_child(_spell_wheel)

	# ---- bottom-center: stamina + burst energy -------------------------
	var bottom_center := VBoxContainer.new()
	bottom_center.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	bottom_center.offset_left = -230
	bottom_center.offset_right = 230
	bottom_center.offset_top = -92
	bottom_center.offset_bottom = -18
	bottom_center.add_theme_constant_override("separation", 7)
	root.add_child(bottom_center)

	var energy_row := HBoxContainer.new()
	energy_row.add_theme_constant_override("separation", 8)
	energy_row.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom_center.add_child(energy_row)
	var e_label := Label.new()
	e_label.text = "Burst"
	e_label.add_theme_font_size_override("font_size", 13)
	e_label.add_theme_color_override("font_color", Color(1, 0.92, 0.65))
	energy_row.add_child(e_label)
	_energy = ProgressBar.new()
	_energy.max_value = Game.MAX_ENERGY
	_energy.custom_minimum_size = Vector2(320, 13)
	_energy.show_percentage = false
	_energy.add_theme_stylebox_override("background", _bar_bg())
	_energy.add_theme_stylebox_override("fill", _bar_fill(Color(1.0, 0.82, 0.35)))
	energy_row.add_child(_energy)

	_stamina = ProgressBar.new()
	_stamina.max_value = Game.MAX_STAMINA
	_stamina.custom_minimum_size = Vector2(460, 11)
	_stamina.show_percentage = false
	_stamina.add_theme_stylebox_override("background", _bar_bg())
	_stamina.add_theme_stylebox_override("fill", _bar_fill(Color(0.55, 0.95, 0.85)))
	bottom_center.add_child(_stamina)

	# ---- bottom-right: actions ------------------------------------------
	var actions := HBoxContainer.new()
	actions.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	actions.offset_left = -470
	actions.offset_top = -156
	actions.offset_right = -24
	actions.offset_bottom = -24
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 12)
	root.add_child(actions)

	# Fires on press, repeats while held (see scripts/hold_button.gd). Godot's
	# `pressed` signal only fires on release, which felt like input lag on a
	# phone.
	var jump_btn := _action_button("Jump", Color(0.55, 0.9, 1.0), Vector2(84, 84), "jump")
	actions.add_child(jump_btn)
	HoldButton.bind(jump_btn, _press_jump)

	_skill_button = _action_button("Skill", Color(0.5, 0.95, 0.75), Vector2(100, 100), "skill")
	actions.add_child(_skill_button)
	HoldButton.bind(_skill_button, func(): _emit_action("skill"))

	var attack_btn := _action_button("Slash", Color(1.0, 0.8, 0.45), Vector2(118, 118), "attack")
	actions.add_child(attack_btn)
	HoldButton.bind(attack_btn, func(): _emit_action("attack"))

	_burst_button = _action_button("Burst", Color(1.0, 0.72, 0.4), Vector2(100, 100), "burst")
	actions.add_child(_burst_button)
	HoldButton.bind(_burst_button, func(): _emit_action("burst"))

	# ---- toast ----------------------------------------------------------
	_toast = Label.new()
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_left = -340
	_toast.offset_right = 340
	_toast.offset_top = 92
	_toast.offset_bottom = 132
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", 19)
	_toast.add_theme_color_override("font_color", Color(1.0, 0.95, 0.82))
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_toast.add_theme_constant_override("shadow_offset_x", 2)
	_toast.add_theme_constant_override("shadow_offset_y", 2)
	_toast.modulate.a = 0.0
	root.add_child(_toast)

	# ---- pause menu -----------------------------------------------------
	_pause_panel = PanelContainer.new()
	_pause_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_pause_panel.offset_left = -230
	_pause_panel.offset_right = 230
	_pause_panel.offset_top = -190
	_pause_panel.offset_bottom = 190
	_pause_panel.add_theme_stylebox_override("panel", _panel_style())
	_pause_panel.visible = false
	root.add_child(_pause_panel)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 12)
	_pause_panel.add_child(pv)
	var ptitle := Label.new()
	ptitle.text = "Paused"
	ptitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ptitle.add_theme_font_size_override("font_size", 32)
	ptitle.add_theme_color_override("font_color", Color(1.0, 0.92, 0.7))
	pv.add_child(ptitle)
	var resume := _round_button("Resume", Vector2(300, 48))
	resume.pressed.connect(_resume)
	pv.add_child(resume)
	_quality_btn = _round_button("Quality: Balanced", Vector2(300, 44))
	_quality_btn.pressed.connect(_cycle_quality)
	pv.add_child(_quality_btn)
	var repair := _round_button("Repair view (if the world is black)", Vector2(300, 44))
	repair.pressed.connect(_repair_view)
	pv.add_child(repair)
	var to_menu := _round_button("Return to the menu", Vector2(300, 44))
	to_menu.pressed.connect(func(): Game.quit_to_menu())
	pv.add_child(to_menu)
	var hint := Label.new()
	hint.text = "WASD · Shift sprint · Space jump/glide\nLMB attack · E skill · Q burst · T switch"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9, 0.85))
	pv.add_child(hint)

	# ---- win banner -----------------------------------------------------
	_win_panel = PanelContainer.new()
	_win_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_win_panel.offset_left = -280
	_win_panel.offset_right = 280
	_win_panel.offset_top = -170
	_win_panel.offset_bottom = 170
	_win_panel.add_theme_stylebox_override("panel", _panel_style())
	_win_panel.visible = false
	root.add_child(_win_panel)

	var wv := VBoxContainer.new()
	wv.add_theme_constant_override("separation", 12)
	_win_panel.add_child(wv)
	var wtitle := Label.new()
	wtitle.text = "Starlight Restored"
	wtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wtitle.add_theme_font_size_override("font_size", 34)
	wtitle.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	wv.add_child(wtitle)
	_win_label = Label.new()
	_win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_win_label.add_theme_font_size_override("font_size", 16)
	wv.add_child(_win_label)
	var back := _round_button("Return to the menu", Vector2(280, 46))
	back.pressed.connect(func(): Game.quit_to_menu())
	wv.add_child(back)


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.09, 0.14, 0.94)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(1.0, 0.88, 0.58, 0.85)
	sb.corner_radius_top_left = 18
	sb.corner_radius_top_right = 18
	sb.corner_radius_bottom_left = 18
	sb.corner_radius_bottom_right = 18
	sb.content_margin_left = 28
	sb.content_margin_top = 24
	sb.content_margin_right = 28
	sb.content_margin_bottom = 24
	return sb


func _bar_bg() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.09, 0.14, 0.8)
	sb.corner_radius_top_left = 5
	sb.corner_radius_top_right = 5
	sb.corner_radius_bottom_left = 5
	sb.corner_radius_bottom_right = 5
	return sb


func _bar_fill(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = 5
	sb.corner_radius_top_right = 5
	sb.corner_radius_bottom_left = 5
	sb.corner_radius_bottom_right = 5
	return sb


func _round_button(text: String, size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.add_theme_font_size_override("font_size", 16)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.14, 0.20, 0.85)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.7, 0.85, 0.95, 0.55)
	var r := int(min(size.x, size.y) * 0.5)
	sb.corner_radius_top_left = r
	sb.corner_radius_top_right = r
	sb.corner_radius_bottom_left = r
	sb.corner_radius_bottom_right = r
	b.add_theme_stylebox_override("normal", sb)
	var hov := sb.duplicate() as StyleBoxFlat
	hov.bg_color = Color(0.14, 0.24, 0.34, 0.95)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", hov)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
	return b


func _icon_texture(icon_name: String) -> Texture2D:
	if icon_name == "":
		return null
	var path := "res://icons/actions/%s.webp" % icon_name
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


## A round action button with a drawn icon plus a small caption underneath.
## Text-only buttons read poorly on a phone: an icon is recognisable at a glance
## while a word has to be read every time.
func _action_button(text: String, color: Color, size: Vector2, icon_name: String = "") -> Button:
	var b := _round_button("", size)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r * 0.18, color.g * 0.2, color.b * 0.24, 0.82)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(color.r, color.g, color.b, 0.9)
	var r := int(min(size.x, size.y) * 0.5)
	sb.corner_radius_top_left = r
	sb.corner_radius_top_right = r
	sb.corner_radius_bottom_left = r
	sb.corner_radius_bottom_right = r
	b.add_theme_stylebox_override("normal", sb)
	var hov := sb.duplicate() as StyleBoxFlat
	hov.bg_color = Color(color.r * 0.3, color.g * 0.32, color.b * 0.36, 0.95)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", hov)
	b.add_theme_font_size_override("font_size", 17)

	var tex := _icon_texture(icon_name)
	if tex != null:
		var pic := TextureRect.new()
		pic.texture = tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Icon fills the disc; the caption sits in the lower third.
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var pad := size.x * 0.16
		pic.offset_left = pad
		pic.offset_top = pad * 0.7
		pic.offset_right = -pad
		pic.offset_bottom = -pad
		b.add_child(pic)

		if text != "":
			var cap := Label.new()
			cap.text = text
			cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cap.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			cap.add_theme_font_size_override("font_size", maxi(11, int(size.x * 0.15)))
			cap.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
			cap.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
			cap.add_theme_constant_override("shadow_offset_x", 1)
			cap.add_theme_constant_override("shadow_offset_y", 1)
			cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cap.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
			cap.offset_top = -maxi(16, int(size.y * 0.26))
			b.add_child(cap)
	else:
		b.text = text
	return b


func _press_jump() -> void:
	# A one-frame pulse. The player reads Input.is_action_just_pressed("jump"),
	# so a longer hold would be consumed on the next frame anyway; holding the
	# button repeats this through HoldButton.
	Input.action_press("jump")
	Input.action_release.call_deferred("jump")


func _emit_action(action: String) -> void:
	Input.action_press(action)
	Input.action_release(action)


func _pause() -> void:
	if Game.has_won:
		return
	_pause_panel.visible = true
	Game.set_paused(true)
	_update_quality_label()


func _resume() -> void:
	_pause_panel.visible = false
	Game.set_paused(false)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and not Game.has_won:
		if _pause_panel.visible:
			_resume()
		else:
			_pause()
		get_viewport().set_input_as_handled()


func _repair_view() -> void:
	## Escape hatch for a blank 3D view: rebuild the camera, environment and
	## lights. Cheap, instant and safe to press at any time.
	var world := get_tree().current_scene
	if world and world.has_method("repair_render"):
		world.call("repair_render")
		Game.toast.emit("View rebuilt")
	else:
		Game.toast.emit("Nothing to repair here")


func _cycle_quality() -> void:
	Game.cycle_quality()
	_update_quality_label()
	var world := get_tree().current_scene
	if world and world.has_method("apply_quality"):
		world.call("apply_quality")


func _update_quality_label() -> void:
	if _quality_btn:
		_quality_btn.text = "Quality: %s" % Game.quality_name()


func _process(_delta: float) -> void:
	_update_compass()
	# Guard the bars: if _build() ever bails early these are null, and assigning
	# to a null property spams a script error every frame.
	if _energy == null or _stamina == null:
		return
	if not Game.is_paused:
		_energy.value = Game.energy
		_stamina.value = Game.stamina
		var player := get_tree().get_first_node_in_group("player")
		if player and is_instance_valid(player) and player.has_method("skill_ready_ratio"):
			var r: float = player.skill_ready_ratio()
			_skill_button.modulate = Color(1, 1, 1, 0.45 + r * 0.55)
			_burst_button.modulate = Color(1, 1, 1, 0.45 if Game.energy < float(Game.character()["burst_cost"]) else 1.0)


func _update_compass() -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null or _compass == null:
		return
	var best := INF
	var target: Node3D = null
	for sigil in get_tree().get_nodes_in_group("sigil"):
		if sigil is Node3D:
			var d: float = player.global_position.distance_to((sigil as Node3D).global_position)
			if d < best:
				best = d
				target = sigil as Node3D
	if target == null:
		_compass.text = "✦ all recovered"
		return
	var to: Vector3 = target.global_position - player.global_position
	to.y = 0.0
	var bearing := atan2(-to.x, -to.z)
	var cam_yaw := 0.0
	if player.has_method("get_camera_yaw"):
		cam_yaw = player.get_camera_yaw()
	var rel := wrapf(bearing - cam_yaw, -PI, PI)
	var arrow := "↑"
	if rel > PI * 0.75 or rel < -PI * 0.75:
		arrow = "↓"
	elif rel > PI * 0.25:
		arrow = "←"
	elif rel < -PI * 0.25:
		arrow = "→"
	elif rel > PI * 0.08:
		arrow = "↖"
	elif rel < -PI * 0.08:
		arrow = "↗"
	_compass.text = "✦ %s  %.0fm" % [arrow, best]


func _refresh_stats() -> void:
	# Party HP lives in the pause menu and the character sheet now that the
	# bottom-left strip is the spell wheel. Keep the quality label in sync here
	# since stats_changed fires on every energy/stamina change.
	_update_quality_label()


func _on_character_changed(_i: int) -> void:
	_refresh_stats()


func _on_sigils_changed(collected: int, total: int) -> void:
	_sigil_label.text = "%d / %d star sigils" % [collected, total]


func _on_quest_changed(text: String) -> void:
	_quest_label.text = text


func _on_toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.8)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.9)


func _on_game_won() -> void:
	_win_panel.visible = true
	_win_label.text = "You gathered all %d star sigils, cleared the slimes and woke the valley's waypoints.\n\nSigils %d/%d · Slimes %d · Waypoints %d" % [
		Game.TOTAL_SIGILS,
		Game.sigils_collected, Game.TOTAL_SIGILS,
		Game.slimes_defeated, Game.waypoints_activated,
	]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
