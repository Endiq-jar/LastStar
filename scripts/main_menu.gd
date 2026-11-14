extends Control
## Title menu, with a static illustration rather than an always-rendering 3D
## viewport so the menu stays inexpensive on mobile devices.

const UI := preload("res://scripts/ui_style.gd")
const TITLE_BACKGROUND := preload("res://assets/ui/celestial_title.webp")

@onready var start_btn: Button = %StartButton
@onready var quit_btn: Button = %QuitButton
@onready var party_row: HBoxContainer = %PartyRow
@onready var quality_btn: Button = %QualityButton


func _ready() -> void:
	Game.set_paused(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Game.reset_run()
	_build_background()
	_style_menu()
	start_btn.pressed.connect(_on_start)
	quit_btn.pressed.connect(func(): get_tree().quit())
	quality_btn.pressed.connect(_cycle_quality)
	start_btn.grab_focus()
	if Game.is_mobile() or OS.has_feature("web"):
		quit_btn.visible = false
	_update_quality_label()
	_fill_party()


func _build_background() -> void:
	var art := TextureRect.new()
	art.name = "CelestialBackground"
	art.texture = TITLE_BACKGROUND
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(art)
	move_child(art, 0)


func _style_menu() -> void:
	var panel := get_node("LeftPanel/Panel") as PanelContainer
	panel.add_theme_stylebox_override("panel", UI.panel(28.0, 0.84))
	UI.button(start_btn, true)
	UI.button(quality_btn)
	UI.button(quit_btn)


func _cycle_quality() -> void:
	Game.cycle_quality()
	_update_quality_label()


func _update_quality_label() -> void:
	quality_btn.text = "✦  Graphics: %s" % Game.quality_name()


func _fill_party() -> void:
	for i in range(Game.PARTY.size()):
		var data: Dictionary = Game.PARTY[i]
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 2)
		var element := Label.new()
		element.text = str(data["element"])
		element.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		element.add_theme_font_size_override("font_size", 12)
		element.add_theme_color_override("font_color", UI.ACCENT)
		v.add_child(element)
		var name_label := Label.new()
		name_label.text = str(data["name"])
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.add_theme_color_override("font_color", UI.TEXT)
		v.add_child(name_label)
		party_row.add_child(v)


func _on_start() -> void:
	Game.start_game()
