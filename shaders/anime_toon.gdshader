shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;

// LastStar anime/toon character shading.
// Genshin-style: hard 2-band shadow ramp in world space (so it stays stable
// while the character turns), cool tinted shadows, warm rim light, and a
// specular "anime" band for hair/cloth highlights.

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 shadow_tint : source_color = vec4(0.55, 0.60, 0.86, 1.0);
uniform vec4 rim_color : source_color = vec4(1.0, 0.93, 0.80, 1.0);
uniform float ramp_softness : hint_range(0.01, 0.6) = 0.09;
uniform float diffuse_energy : hint_range(0.0, 2.0) = 1.0;
uniform float spec_energy : hint_range(0.0, 2.0) = 0.55;
uniform float spec_size : hint_range(0.0, 1.0) = 0.22;
// Hard ceiling on how much the anime specular band may add. Without it a
// sphere facing the sun sums the band over its whole visible area.
uniform float spec_ceiling : hint_range(0.0, 1.0) = 0.32;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.35;
uniform float rim_power : hint_range(1.0, 8.0) = 3.4;
uniform float emission_boost : hint_range(0.0, 4.0) = 0.0;
uniform vec4 emission_color : source_color = vec4(0.4, 0.8, 1.0, 1.0);

varying vec3 v_world_normal;

void vertex() {
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	// A slight horizontal gradient across the model's local X gives big smooth
	// forms (hair, hair cap, torso) a readable orientation. Without it a hemisphere
	// lit by a single key is a featureless disc, which is what made the hair look
	// like a white dome rather than hair.
	float form = clamp((UV.x - 0.5) * 2.0, -1.0, 1.0);
	vec3 base = albedo_color.rgb * tex.rgb;
	base *= 1.0 + form * 0.10;
	ALBEDO = base;
	ROUGHNESS = 0.62;
	METALLIC = 0.0;
	SPECULAR = 0.28;
	// A floor proportional to the part's own colour.
	//
	// The character is sunlit from behind in play (the sun sits behind her right
	// shoulder, which is why the gameplay camera sees her lit and the front
	// portrait sees her in shadow). With only ambient behind it, her face came out
	// near black and the whole reviewing problem moved from "too white" to "no
	// face". 0.02 of the albedo is three thousandths of a stop on an 8-bit buffer
	// and did nothing. This is the same treatment the terrain and grass get, so
	// every surface in the frame has a shadow of a colour rather than a hole.
	EMISSION = emission_color.rgb * emission_boost + base * 0.12;
}

void light() {
	float ndl = dot(normalize(NORMAL), normalize(LIGHT));
	// Two-tone ramp with a soft transition — the core of the anime look.
	float lit = smoothstep(-ramp_softness, ramp_softness, ndl);
	float warm = smoothstep(0.45, 0.95, ndl);
	// Use ALBEDO, not the raw albedo_color uniform: ALBEDO is what fragment() wrote,
	// including the texture multiply. Reading the uniform meant every part ignored
	// its own texture and the model shaded from flat colours.
	//
	// LIGHT_COLOR in Godot's light() already has the light's energy folded in, so a
	// 1.6-energy key arrives with a magnitude well above 1. Multiplying that by a
	// pale albedo without a scale factor is what clipped the whole character to
	// white regardless of how the diffuse factor was tuned.
	vec3 key = min(LIGHT_COLOR * ATTENUATION, vec3(1.55));
	vec3 shadowed = key * ALBEDO * shadow_tint.rgb;
	vec3 lit_col = key * ALBEDO;
	// The key light is clamped to 1.55 above, so this factor is now the only gain
	// control: a 0.8 albedo times a 1.55 key times 0.62 lands just under 0.8 in
	// linear space, which the filmic curve maps to a lit surface with its shading
	// intact instead of a clipped white one.
	DIFFUSE_LIGHT += mix(shadowed, lit_col, lit) * (0.68 + warm * 0.30) * diffuse_energy * 0.62;

	// Anime specular band: a thin ring around the key direction.
	float spec_ndl = smoothstep(1.0 - spec_size, 1.0 - spec_size * 0.35, ndl);
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float spec_amount = spec_ndl * spec_energy * (0.4 + ndv * 0.6);
	// Fade the band out as the surface turns fully toward the light, so it reads
	// as a highlight on the edge of the lit side rather than a disc on the front.
	spec_amount *= 1.0 - smoothstep(0.90, 1.0, ndl);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * min(spec_amount, spec_ceiling);

	// Rim: bright edge facing away from the light, gives that "painted" pop.
	//
	// Both terms are clamped. On a head-sized sphere facing the key light, ndl
	// is ~1 across most of the visible surface, so the specular band covered the
	// whole head, and the rim term multiplied by a 2.2-energy sun put the total
	// radiance far over the tonemapper's knee. The result was a featureless white
	// ball where the player's face should be - the single worst artefact in the
	// render, and it made every character read as a blank mannequin.
	float rim = pow(1.0 - max(ndv, 0.0), rim_power);
	rim *= smoothstep(0.05, 0.45, 1.0 - ndl);
	DIFFUSE_LIGHT += rim_color.rgb * LIGHT_COLOR * ATTENUATION * rim * rim_strength * 0.22;
}
