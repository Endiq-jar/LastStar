shader_type spatial;
render_mode cull_back, diffuse_toon, specular_toon, depth_draw_opaque;

// Stylized Genshin-like terrain: three painted layers (meadow / rock / sand)
// triplanar-blended by height + slope, with soft painterly macro variation and
// wet, reflective bands near the waterline. Tuned for mobile (3 samples).

uniform sampler2D meadow_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec4 meadow_tint : source_color = vec4(0.28, 0.45, 0.20, 1.0);
uniform vec4 meadow_deep : source_color = vec4(0.13, 0.27, 0.13, 1.0);
uniform vec4 rock_tint : source_color = vec4(0.42, 0.41, 0.44, 1.0);
uniform vec4 sand_tint : source_color = vec4(0.74, 0.68, 0.52, 1.0);
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
// Distance (metres) over which albedo starts to mute toward atmospheric haze.
uniform float haze_begin : hint_range(0.0, 600.0) = 130.0;
uniform float haze_end : hint_range(0.0, 900.0) = 620.0;

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

	// Large-scale variation for the meadow colour. This used to be hard
	// quantized into bands for a "hand-painted planes" look; at the scale it
	// was running at, those bands were 20-40 m blocks, which read as giant
	// green camouflage patches rather than brushwork. A gently curved smooth
	// value gives the same painterly breakup without the blocky edges.
	float macro = texture(macro_tex, v_world.xz * macro_scale).r;
	float macro2 = texture(macro_tex, v_world.xz * macro_scale * 3.1 + vec2(0.37, 0.11)).r;
	float patch = smoothstep(0.12, 0.88, macro * 0.65 + macro2 * 0.35);

	// Anime terrain is painted in flat planes, not textured noise. The old
	// version multiplied triplanar noise at uv_scale 0.055 over everything,
	// which at distance turned every mountain into a wall of fine-grained
	// static. Now the large-scale `patch` value picks the colour and the
	// texture only adds a faint brush grain on top.
	float dry = smoothstep(0.55, 1.0, patch);

	// Detail from the painted textures, scaled to a painterly size rather than
	// a photographic one. tri() picks the best projection per surface so cliffs
	// do not stretch the meadow.
	//
	// Only the *luminance* of these is used, never their colour, and it is
	// centred on 1.0 so it modulates rather than tints. Multiplying the albedo
	// by the raw texture was the main source of the neon: the painted greens are
	// blue-poor (blue channel around 0.16), so squaring them into an already
	// blue-poor meadow albedo drove blue near zero and left a pure, saturated
	// green with nothing to hold it back. Luminance detail keeps the texture's
	// brushwork - the variation in value that reads as painted - without
	// touching the hue the lighting depends on.
	vec3 meadow_detail = tri(meadow_tex, v_world, wn, uv_scale);
	vec3 rock_detail = tri(rock_tex, v_world, wn, uv_scale * 0.62);
	vec3 sand_detail = tri(sand_tex, v_world, wn, uv_scale * 1.25);
	float meadow_l = dot(meadow_detail, vec3(0.2126, 0.7152, 0.0722));
	float rock_l = dot(rock_detail, vec3(0.2126, 0.7152, 0.0722));
	float sand_l = dot(sand_detail, vec3(0.2126, 0.7152, 0.0722));

	// Meadow: two greens, broken up by the soft macro patches, modulated by the
	// painted detail (kept subtle so the flat anime bands still dominate).
	vec3 grass = mix(meadow_deep.rgb, meadow_tint.rgb, 0.35 + patch * 0.65);
	grass *= mix(1.0, meadow_l * 1.9, 0.45);
	// A little golden meadow mixed in, the way open-world grass reads. Kept
	// low: push this and the hillsides turn acid yellow-green.
	// The dry blend is nearly as weak as it can be while still breaking up the
	// field. At 0.10 with a lighter yellow it painted large acid-yellow blotches
	// across the meadow that read as camo, not as sun-bleached grass.
	grass = mix(grass, vec3(0.34, 0.36, 0.19), dry * 0.06);

	// Rock: warm grey, cooler in shadowed bands.
	vec3 rock_col = rock_tint.rgb * mix(0.66, 1.0, patch);
	rock_col *= mix(1.0, rock_l * 1.9, 0.42);

	// Height bands: sand at the shoreline, meadow in the valley, rock up high.
	float shore = 1.0 - smoothstep(water_level + 0.4, water_level + 2.6, h);
	float highland = smoothstep(rock_height * 0.78, rock_height * 1.35, h);
	vec3 sand_col = sand_tint.rgb * mix(1.0, sand_l * 1.9, 0.38);
	vec3 col = mix(grass, sand_col, shore);
	col = mix(col, rock_col, highland * 0.9);

	// Slope: grass gives way to rock then bare cliff faces, banded so hillsides
	// read as flat planes instead of gradients.
	float rock_slope = smoothstep(slope_rock, slope_rock + 0.14, slope);
	rock_slope = floor(rock_slope * 3.0 + 0.5) / 3.0;
	float cliff_slope = smoothstep(slope_cliff, slope_cliff + 0.12, slope);
	col = mix(col, rock_col * mix(1.0, 0.80, cliff_slope), rock_slope * 0.92);

	// Snow caps only on genuinely high ground: a clean white with a cool tint,
	// not a noise texture.
	float snow = smoothstep(snow_height - 14.0, snow_height + 20.0, h);
	snow *= 1.0 - smoothstep(0.42, 0.62, slope);
	col = mix(col, vec3(0.72, 0.77, 0.87), snow * 0.85);

	// Wet band near the shore: darker + glossier.
	float wet = 1.0 - smoothstep(water_level, water_level + wet_band, h);
	col = mix(col, col * vec3(0.62, 0.68, 0.78), wet * 0.55);

	// --- aerial perspective -------------------------------------------------
	// The problem with doing this with fog only is that fog multiplies the
	// *lighting*, so a saturated albedo still arrives as a saturated colour and
	// the far ranges turned into neon green cut-outs against the sky. Muting the
	// albedo with distance (toward its own luminance, nudged cool) is what a
	// painter does, and it is what makes the depth read.
	// In the fragment stage VERTEX is the view-space position, so its length is
	// the distance to the camera on every renderer without extra uniforms.
	float cam_dist = length(VERTEX);
	float haze = smoothstep(haze_begin, haze_end, cam_dist);
	// Mute toward luminance AND darken. Muting alone kept the far ridge as bright
	// as the near hill, so it read as a flat green wall behind the valley instead
	// of receding into atmosphere; the depth cue is mostly the value drop.
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	vec3 hazed = mix(vec3(luma), col, 0.58) * vec3(0.86, 0.92, 1.10);
	col = mix(col, hazed, haze * 0.95);

	ALBEDO = col;
	ROUGHNESS = mix(0.92, 0.24, wet);
	METALLIC = 0.0;
	SPECULAR = mix(0.18, 0.55, wet);
	// Fake ambient occlusion in the creases the noise made.
	AO = mix(0.82, 1.0, patch);
	AO_LIGHT_AFFECT = 0.25;
}
