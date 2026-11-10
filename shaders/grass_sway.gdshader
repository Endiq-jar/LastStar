shader_type spatial;
render_mode cull_disabled, diffuse_toon, specular_disabled, shadows_disabled;

// Alpha-scissor, not alpha-blend: a cut-out discard costs no sorting and no
// blending on mobile GLES3, which is why every open-world game does grass this
// way. Alpha blending here would also make blades sort against each other and
// flicker as the camera turns.

// Wind-swept stylized grass for MultiMeshInstance3D.
//
// Written for the Compatibility (OpenGL ES 3.0) renderer, which is what ships
// on the target phone. Two things matter there:
//   * no screen-space effects, so the colour must carry the look by itself;
//   * vertex work is cheap but fragment overdraw is not, so the shader avoids
//     extra texture fetches entirely and does all variation in the vertex stage.

// Albedo is deliberately dark and desaturated. Stylised grass gets its colour
// from the light and the sky gradient, not from the paint: bright green albedo
// plus a bright sun is what produced the neon lime carpet that made the valley
// look like a golf course. Real Genshin grass albedo sits around 0.12-0.22
// luminance and lets the key light take it up.
uniform vec4 grass_color : source_color = vec4(0.15, 0.27, 0.11, 1.0);
uniform vec4 grass_tip : source_color = vec4(0.40, 0.56, 0.21, 1.0);
uniform vec4 dry_color : source_color = vec4(0.38, 0.40, 0.19, 1.0);
uniform float wind_strength : hint_range(0.0, 1.0) = 0.22;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.4;
uniform vec2 wind_dir = vec2(0.85, 0.35);
uniform float color_variance : hint_range(0.0, 1.0) = 0.20;
uniform sampler2D blade_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.42;

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
	// Cut the blade shape out of the quad. Anything outside the drawn tuft is
	// discarded outright, so the quad never reads as a rectangle.
	vec4 tex = texture(blade_tex, UV);
	if (tex.a < alpha_cut) {
		discard;
	}

	// Root-to-tip gradient. Dark at the base anchors the tuft in the soil;
	// brighter at the tip catches the sky. The gradient is narrower than it
	// used to be - a wide one turned every chunk into a two-tone blob at
	// distance, which is what gave the hillsides that mown-lawn banding.
	float t = clamp(UV.y, 0.0, 1.0);
	vec3 base = grass_color.rgb;
	// Some tufts lean dry/yellow, the way a real meadow is not one flat green.
	base = mix(base, dry_color.rgb, v_tint * color_variance * 0.22);
	vec3 col = mix(base, grass_tip.rgb, pow(t, 1.35) * 0.72);

	// Break up the flat fill with a cheap per-tuft value variation. Without
	// this every tuft has identical colour and the field reads as one surface.
	col *= 0.86 + v_tint * 0.28;

	// --- distance fade ------------------------------------------------------
	// Far chunks cover many screen pixels each with a quad, so their flat colour
	// dominates the silhouette. Mute and cool them toward the hillside colour so
	// the field settles into the terrain instead of hovering over it.
	float dist = length(VERTEX);
	float far_t = smoothstep(55.0, 135.0, dist);
	col = mix(col, vec3(0.19, 0.26, 0.14), far_t * 0.55);

	ALBEDO = col;
	ROUGHNESS = 0.94;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	// Backlight fakes subsurface scatter: blades glow when lit from behind,
	// which is most of what makes wind-blown grass look alive. Small, because
	// it stacks over every blade in the field.
	BACKLIGHT = grass_tip.rgb * 0.14;
	// Keep the shadow-facing side from going black; ambient handles the rest.
	EMISSION = base * 0.02;
}
