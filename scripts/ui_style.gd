extends RefCounted
## Shared celestial UI palette and lightweight Godot controls.

const INK := Color(0.055, 0.055, 0.13, 0.94)
const EDGE := Color(0.67, 0.67, 0.94, 0.65)
const TEXT := Color(0.95, 0.95, 1.0, 1.0)
const ACCENT := Color(0.77, 0.76, 1.0, 1.0)


static func panel(padding: float = 24.0, opacity: float = 0.94) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK.r, INK.g, INK.b, opacity)
	style.border_color = EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	style.shadow_color = Color(0.02, 0.02, 0.08, 0.45)
	style.shadow_size = 10
	return style


static func button(button_node: Button, highlighted: bool = false) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.78, 0.78, 0.96, 0.92) if highlighted else Color(0.18, 0.18, 0.34, 0.80)
	normal.border_color = Color(0.73, 0.74, 0.97, 0.68)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(9)
	normal.content_margin_left = 16
	normal.content_margin_right = 16
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.90, 0.89, 1.0, 0.98) if highlighted else Color(0.30, 0.28, 0.51, 0.96)
	button_node.add_theme_stylebox_override("normal", normal)
	button_node.add_theme_stylebox_override("hover", hover)
	button_node.add_theme_stylebox_override("pressed", hover)
	button_node.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button_node.add_theme_color_override("font_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
	button_node.add_theme_color_override("font_hover_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
	button_node.add_theme_color_override("font_pressed_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
	button_node.add_theme_color_override("font_focus_color", Color(0.12, 0.10, 0.25) if highlighted else TEXT)
