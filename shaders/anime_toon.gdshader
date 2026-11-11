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
uniform float spec_size : hint_range(0.0, 1.0) = 0.055;
// Hard ceiling on how much the anime specular band may add. Without it a
// sphere facing the sun sums the band over its whole visible area.
// A single anime specular band was blowing out to a white blob on every rounded
// form - a bright ring the size of her head on the hair cap, and another on her
// chest. The band is smaller and capped lower now; the hair highlights that carry
// the look come from the band's edge, not its centre.
uniform float spec_ceiling : hint_range(0.0, 1.0) = 0.10;
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

	// No specular term at all.
	//
	// It had three goes at this and every one was an artefact: keyed off ndl it
	// drew a donut around the light direction (the grey ring on her hair and
	// chest); keyed off the half-vector it became a grey smudge across everything
	// facing the camera; tightened, it became hard-edged grey ellipses, one per
	// light, because the top of the smoothstep saturates and flattens to a solid
	// patch. A near-black albedo has nothing to modulate a highlight with, so any
	// visible spec on it is grey paint.
	//
	// A cel character does not need one: the two-tone ramp, the rim and the
	// outline carry the form, and the reference art gets its hair shine from
	// painted texture, not from a specular lobe. Removing the term is the honest
	// fix, and it is what the reference material actually does.

	// NdotV is still needed by the rim below.
	vec3 view_dir = normalize(VIEW);
	float ndv = clamp(dot(normalize(NORMAL), view_dir), 0.0, 1.0);

	// Rim: bright edge facing away from the light, gives that "painted" pop.
	//
	// Kept small and clamped on purpose. On a head-sized sphere facing the key
	// light ndl is ~1 across most of the visible surface, so a strong rim
	// multiplied by a 2.2-energy sun put the total radiance far over the
	// tonemapper's knee - the featureless white ball that used to be her face.
	float rim = pow(1.0 - max(ndv, 0.0), rim_power);
	rim *= smoothstep(0.05, 0.45, 1.0 - ndl);
	DIFFUSE_LIGHT += rim_color.rgb * LIGHT_COLOR * ATTENUATION * rim * rim_strength * 0.22;
}
