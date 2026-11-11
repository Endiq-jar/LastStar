shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled;

// Inverted-hull outline pass. Duplicate a mesh instance, put it slightly
// "behind" via vertex push along the normal, and keep this material on it.
// Cheap enough for mobile and gives the classic cel-shaded contour.

uniform vec4 outline_color : source_color = vec4(0.12, 0.10, 0.16, 1.0);
uniform float outline_width : hint_range(0.0, 0.2) = 0.012;
void vertex() {
	// Push the hull out along the vertex normal. NORMAL here is in model space,
	// which is what the inverted-hull technique wants: the hull stays the same
	// thickness in the model's own units however the character is placed.
	VERTEX += normalize(NORMAL) * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
