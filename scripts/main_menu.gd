extends Control
## Title menu, with a static illustration rather than an always-rendering 3D
## viewport so the menu stays inexpensive on mobile devices.

const UI := preload("res://scripts/ui_style.gd")
const AdventureMenu := preload("res://scripts/adventure_menu.gd")
var _home_menu: Control
const TITLE_BACKGROUND := preload("res://assets/ui/celestial_title.webp")

@onready var start_btn: Button = %StartButton
@onready var quit_btn: Button = %QuitButton
@onready var party_row: HBoxContainer = %PartyRow
@onready var quality_btn: Button = %QualityButton


func _ready() -> void:
	Game.set_paused(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Game.reset_run()
	Game.load_collection()
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
	_build_home_navigation()


func _build_home_navigation() -> void:
	start_btn.text = "✦     Play"
	quality_btn.visible = false
	var box := start_btn.get_parent() as VBoxContainer
	var grid := GridContainer.new()
	grid.name = "HomeNavigation"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	box.move_child(grid, start_btn.get_index() + 1)
	for page in ["Wardrobe", "Profile", "Settings", "Shop"]:
		var button := Button.new()
		button.name = page + "Button"
		button.text = page
		button.custom_minimum_size = Vector2(0, 42)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UI.button(button)
		button.pressed.connect(_open_home_page.bind(page))
		grid.add_child(button)
	_home_menu = AdventureMenu.new()
	_home_menu.set("home_mode", true)
	add_child(_home_menu)


func _open_home_page(page: String) -> void:
	_home_menu.call("open_menu", page)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and _home_menu != null and _home_menu.visible:
		_home_menu.call("close_menu")
		get_viewport().set_input_as_handled()


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
	get_node("LeftPanel/Panel/VBox/Blurb").visible = false
	get_node("LeftPanel/Panel/VBox/Footer").visible = false
	get_node("LeftPanel/Panel/VBox/Spacer").visible = false
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
