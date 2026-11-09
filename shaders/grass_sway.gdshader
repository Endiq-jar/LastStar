shader_type spatial;
render_mode cull_disabled, diffuse_toon, specular_disabled, shadows_disabled;

// Wind-swept stylized grass blades for MultiMeshInstance3D. The world-space
// gust term is shared by every instance so the meadow ripples in waves.

uniform vec4 grass_color : source_color = vec4(0.38, 0.68, 0.32, 1.0);
uniform vec4 grass_tip : source_color = vec4(0.72, 0.92, 0.45, 1.0);
uniform float wind_strength : hint_range(0.0, 1.0) = 0.22;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.4;
uniform vec2 wind_dir = vec2(0.85, 0.35);

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float height = max(VERTEX.y, 0.0);
	float wave = sin(origin.x * 0.22 + origin.z * 0.17 - TIME * wind_speed * 1.6);
	float gust = sin(origin.x * 0.05 - TIME * 0.6 + origin.z * 0.03);
	float sway = (wave * 0.6 + gust * 0.4) * wind_strength * (height * 1.6);
	vec2 dir = normalize(wind_dir);
	VERTEX.x += dir.x * sway;
	VERTEX.z += dir.y * sway;
}

void fragment() {
	float t = clamp(UV.y, 0.0, 1.0);
	ALBEDO = mix(grass_color.rgb, grass_tip.rgb, t);
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	BACKLIGHT = grass_tip.rgb * 0.18;
}
