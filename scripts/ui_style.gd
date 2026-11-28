extends RefCounted
## Shared celestial UI palette and lightweight Godot controls.

const INK := Color(0.055, 0.055, 0.13, 0.94)
const EDGE := Color(0.77, 0.72, 0.85, 0.62)
const TEXT := Color(0.95, 0.95, 1.0, 1.0)
const ACCENT := Color(0.90, 0.82, 0.66, 1.0)
const ICONS := {
	"Wardrobe": preload("res://icons/ui/shirt_1.png"),
	"Profile": preload("res://icons/ui/singleplayer.png"),
	"Character": preload("res://icons/ui/singleplayer.png"),
	"Settings": preload("res://icons/ui/gear.png"),
	"Shop": preload("res://icons/ui/shoppingCart.png"),
	"Inventory": preload("res://icons/ui/menuGrid.png"),
	"Quests": preload("res://icons/ui/book_2.png"),
	"Story": preload("res://icons/ui/book_2.png"),
	"Wish": preload("res://icons/ui/star.png"),
	"Level Up": preload("res://icons/ui/plus.png"),
	"Dialogue": preload("res://icons/ui/menuList.png"),
	"Weapon": preload("res://icons/ui/sword_7.png"),
	"Clothing": preload("res://icons/ui/shirt_1.png"),
	"Backpack": preload("res://icons/ui/breastplate.png"),
	"Audio": preload("res://icons/ui/audioOn.png"),
	"Controls": preload("res://icons/ui/gamepad.png"),
	"Play": preload("res://icons/ui/open.png"),
	"Pause": preload("res://icons/ui/pause.png"),
	"Close": preload("res://icons/ui/cross.png"),
	"Return": preload("res://icons/ui/return.png"),
	"Potion": preload("res://icons/items/potion.svg"),
}


static func icon(button_node: Button, key: String) -> void:
	if ICONS.has(key):
		button_node.icon = ICONS[key]
		button_node.expand_icon = true
		button_node.add_theme_constant_override("icon_max_width", 23)
		button_node.add_theme_constant_override("h_separation", 10)
		button_node.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT


static func panel(padding: float = 24.0, opacity: float = 0.94) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK.r, INK.g, INK.b, opacity)
	style.border_color = EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	style.shadow_color = Color(0.02, 0.02, 0.08, 0.45)
	style.shadow_size = 10
	return style


static func button(button_node: Button, highlighted: bool = false) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.91, 0.82, 0.66, 0.98) if highlighted else Color(0.14, 0.13, 0.26, 0.85)
	normal.border_color = Color(0.73, 0.74, 0.97, 0.68)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(5)
	normal.content_margin_left = 16
	normal.content_margin_right = 16
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.98, 0.90, 0.74, 0.98) if highlighted else Color(0.29, 0.25, 0.42, 0.96)
	button_node.add_theme_stylebox_override("normal", normal)
	button_node.add_theme_stylebox_override("hover", hover)
	button_node.add_theme_stylebox_override("pressed", hover)
	button_node.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button_node.add_theme_color_override("icon_normal_color", Color(0.16, 0.12, 0.22) if highlighted else TEXT)
	button_node.add_theme_color_override("icon_hover_color", Color(0.16, 0.12, 0.22) if highlighted else TEXT)
	button_node.add_theme_color_override("icon_pressed_color", Color(0.16, 0.12, 0.22) if highlighted else TEXT)
	button_node.add_theme_color_override("font_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
	button_node.add_theme_color_override("font_hover_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
	button_node.add_theme_color_override("font_pressed_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
	button_node.add_theme_color_override("font_focus_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
