shader_type spatial;
render_mode cull_back, diffuse_toon, specular_toon, depth_draw_opaque;

// Stylized Genshin-like terrain: three painted layers (meadow / rock / sand)
// triplanar-blended by height + slope, with soft painterly macro variation and
// wet, reflective bands near the waterline. Tuned for mobile (3 samples).

uniform sampler2D meadow_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec4 meadow_tint : source_color = vec4(0.55, 0.78, 0.38, 1.0);
uniform vec4 meadow_deep : source_color = vec4(0.34, 0.58, 0.30, 1.0);
uniform vec4 rock_tint : source_color = vec4(0.68, 0.66, 0.62, 1.0);
uniform vec4 sand_tint : source_color = vec4(0.90, 0.83, 0.66, 1.0);
uniform vec4 shadow_tint : source_color = vec4(0.68, 0.72, 0.95, 1.0);

uniform float uv_scale : hint_range(0.002, 0.2) = 0.045;
uniform float macro_scale : hint_range(0.001, 0.05) = 0.006;
uniform float rock_height : hint_range(0.0, 200.0) = 64.0;
uniform float snow_height : hint_range(0.0, 200.0) = 980.0;
uniform float slope_rock : hint_range(0.0, 1.0) = 0.30;
uniform float slope_cliff : hint_range(0.0, 1.0) = 0.52;
uniform float water_level : hint_range(-20.0, 40.0) = 1.0;
uniform float wet_band : hint_range(0.5, 24.0) = 5.0;
uniform float band_softness : hint_range(0.0, 0.3) = 0.055;

varying vec3 v_world;
varying vec3 v_world_normal;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 tri(sampler2D tex, vec3 p, vec3 n, float s) {
	vec3 b = pow(abs(n), vec3(4.0));
	b /= (b.x + b.y + b.z + 1e-5);
	return texture(tex, p.zy * s).rgb * b.x + texture(tex, p.xz * s).rgb * b.y + texture(tex, p.xy * s).rgb * b.z;
}

void fragment() {
	vec3 wn = normalize(v_world_normal);
	float slope = 1.0 - clamp(wn.y, 0.0, 1.0);
	float h = v_world.y;

	// Painterly posterization: quantize large-scale variation into soft bands
	// so distant hillsides read as hand-painted planes instead of noise.
	float macro = texture(macro_tex, v_world.xz * macro_scale).r;
	float macro2 = texture(macro_tex, v_world.xz * macro_scale * 3.1 + vec2(0.37, 0.11)).r;
	float patch = macro * 0.65 + macro2 * 0.35;
	patch = floor(patch / max(band_softness, 0.001)) * band_softness;
	patch = clamp(patch, 0.0, 1.0);

	vec3 meadow = tri(meadow_tex, v_world, wn, uv_scale);
	vec3 rock = tri(rock_tex, v_world, wn, uv_scale * 0.55);
	vec3 sand = tri(sand_tex, v_world, wn, uv_scale * 1.4);
	meadow *= meadow_tint.rgb * mix(meadow_deep.rgb, vec3(1.0), patch * 0.45);
	rock *= rock_tint.rgb * (0.86 + patch * 0.28);
	sand *= sand_tint.rgb;

	// Height bands: sand at shoreline, meadow in the valley, rock up high.
	float shore = 1.0 - smoothstep(water_level + 0.4, water_level + 2.4, h);
	float highland = smoothstep(rock_height * 0.55, rock_height * 1.15, h);
	vec3 col = mix(meadow, sand, shore);
	col = mix(col, rock, highland * 0.85);

	// Slope: grass gives way to rock then bare cliff faces.
	float rock_slope = smoothstep(slope_rock, slope_rock + 0.16, slope);
	float cliff_slope = smoothstep(slope_cliff, slope_cliff + 0.14, slope);
	col = mix(col, rock * mix(1.0, 0.82, cliff_slope), rock_slope * 0.9);

	// Snow caps on very high, flatter ground (warm keeps it stylized, not grey).
	float snow = smoothstep(snow_height - 18.0, snow_height + 12.0, h) * (1.0 - slope * 0.8);
	col = mix(col, vec3(0.96, 0.97, 1.0), clamp(snow, 0.0, 1.0) * 0.85);

	// Wet band near the shore: darker + glossier.
	float wet = 1.0 - smoothstep(water_level, water_level + wet_band, h);
	col = mix(col, col * vec3(0.62, 0.68, 0.78), wet * 0.55);

	ALBEDO = col;
	ROUGHNESS = mix(0.92, 0.24, wet);
	METALLIC = 0.0;
	SPECULAR = mix(0.18, 0.55, wet);
	// Fake ambient occlusion in the creases the noise made.
	AO = mix(0.82, 1.0, patch);
	AO_LIGHT_AFFECT = 0.25;
}
