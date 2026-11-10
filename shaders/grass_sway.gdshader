shader_type spatial;
render_mode cull_disabled, diffuse_toon, specular_disabled, shadows_disabled;

// Wind-swept stylized grass for MultiMeshInstance3D.
//
// Written for the Compatibility (OpenGL ES 3.0) renderer, which is what ships
// on the target phone. Two things matter there:
//   * no screen-space effects, so the colour must carry the look by itself;
//   * vertex work is cheap but fragment overdraw is not, so the shader avoids
//     extra texture fetches entirely and does all variation in the vertex stage.

uniform vec4 grass_color : source_color = vec4(0.34, 0.60, 0.26, 1.0);
uniform vec4 grass_tip : source_color = vec4(0.78, 0.94, 0.46, 1.0);
uniform vec4 dry_color : source_color = vec4(0.72, 0.74, 0.34, 1.0);
uniform float wind_strength : hint_range(0.0, 1.0) = 0.22;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.4;
uniform vec2 wind_dir = vec2(0.85, 0.35);
uniform float color_variance : hint_range(0.0, 1.0) = 0.35;

varying float v_tint;
varying float v_height;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float height = max(VERTEX.y, 0.0);

	// Two overlapping waves: a slow gust field plus a faster ripple, both
	// driven by world position so neighbouring chunks move as one meadow.
	float wave = sin(origin.x * 0.19 + origin.z * 0.15 - TIME * wind_speed * 1.7);
	float gust = sin(origin.x * 0.043 - TIME * 0.55 + origin.z * 0.031);
	float sway = (wave * 0.62 + gust * 0.38) * wind_strength * height * 1.7;
	vec2 dir = normalize(wind_dir);
	VERTEX.x += dir.x * sway;
	VERTEX.z += dir.y * sway;
	// Bending shortens the blade slightly, which reads as real motion.
	VERTEX.y -= abs(sway) * 0.22;

	// Per-instance colour variation, hashed from the instance origin so it is
	// stable frame to frame (no shimmer as the camera moves).
	float h = fract(sin(dot(origin.xz, vec2(12.9898, 78.233))) * 43758.5453);
	v_tint = h;
	v_height = height;
}

void fragment() {
	// Root-to-tip gradient. Dark at the base anchors the tuft in the soil;
	// bright at the tip catches the sky, which is what makes stylised grass glow.
	float t = clamp(UV.y, 0.0, 1.0);
	vec3 base = grass_color.rgb;
	// Some tufts lean dry/yellow, the way a real meadow is not one flat green.
	base = mix(base, dry_color.rgb, v_tint * color_variance * 0.55);
	vec3 col = mix(base, grass_tip.rgb, t * 0.85);
	// A touch of extra brightness at the very tip.
	col += grass_tip.rgb * smoothstep(0.75, 1.0, t) * 0.18;

	ALBEDO = col;
	ROUGHNESS = 0.92;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	// Backlight fakes subsurface scatter: blades glow when lit from behind,
	// which is most of what makes wind-blown grass look alive.
	BACKLIGHT = grass_tip.rgb * 0.55;
	// Keep the shadow-facing side from going black; ambient handles the rest.
	EMISSION = base * 0.06;
}
