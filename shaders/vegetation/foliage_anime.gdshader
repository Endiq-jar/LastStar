shader_type spatial;
// Anime foliage: grass, border grass, flowers, bushes and leaves.
//
// Written for the Compatibility (OpenGL ES 3.0) renderer, which is what this
// project ships: no compute, no screen-space effects, no texture arrays. One
// albedo sample, and the wind is vertex-only.
//
// Mobile decisions, each verified against the Godot 4.3 spatial shader docs:
//
//   * alpha_scissor, NOT transparency. ALPHA is deliberately never written -
//     the docs are explicit that reading or writing ALPHA moves the material to
//     the transparent pipeline, which loses depth writes, forces back-to-front
//     sorting and multiplies overdraw. Scissored foliage writes depth and
//     blends nothing.
//   * cull_disabled plus a two-sided lighting term, because a grass card is a
//     single quad and must be lit from behind as well as in front.
//   * RIM_TINT is a float in Godot 4, running 0 (white) to 1 (albedo), NOT a
//     colour. Assigning a vec3 there fails to compile and the surface falls
//     back to default white.
//   * wind_offset() is a vertex operation, so the runtime cost is zero.

#include "res://shaders/vegetation/foliage_wind.gdshaderinc"

render_mode cull_disabled, diffuse_lambert;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.42;

uniform vec3 base_tint : source_color = vec3(1.0);
// Per-instance brightness variation, driven from INSTANCE_CUSTOM.
uniform float tint_variation : hint_range(0.0, 0.4) = 0.12;
uniform vec3 shadow_fill : source_color = vec3(0.22, 0.30, 0.22);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.45;
uniform float backface_lift : hint_range(0.0, 1.0) = 0.30;

varying float v_tint;

void vertex() {
	// World-space origin of this instance: MODEL_MATRIX maps local to world and
	// already carries the instance transform for a MultiMesh.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// 0 at the root, 1 at the tip. The quad is centred, so local y runs -0.5..0.5
	// for the unit card the spawner uses.
	float h_norm = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	float local_h = max(VERTEX.y + 0.5, 0.0);

	world_pos.xyz += wind_offset(world_pos, local_h, h_norm, TIME);

	// Back to local space for the built-in pipeline.
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world_pos, 1.0)).xyz;

	// Stable per-instance value packed by the spawner into INSTANCE_CUSTOM.r.
	v_tint = 1.0 + (INSTANCE_CUSTOM.r - 0.5) * 2.0 * tint_variation;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	// Scissor. On tile-based mobile GPUs the fragment is killed before any
	// shading work, which is why this is far cheaper than blending.
	if (tex.a < alpha_cut) {
		discard;
	}

	ALBEDO = tex.rgb * base_tint * v_tint;
	// NOTE: ALPHA is intentionally not written - see the header.

	// Two-sided: a card facing away gets a flat fill rather than going black.
	// FRONT_FACING is a fragment built-in in Godot 4.
	if (!FRONT_FACING) {
		EMISSION = ALBEDO * shadow_fill * backface_lift;
	}

	// Fake translucency: light bleeding through a thin blade. BACKLIGHT is
	// inout vec3 and is applied by the built-in lighting model.
	BACKLIGHT = vec3(0.42, 0.55, 0.30);

	ROUGHNESS = 0.88;
	SPECULAR = 0.08;
	// Rim is cheap view-dependent edge light. RIM_TINT must be a float.
	RIM = rim_strength;
	RIM_TINT = 0.35;
}
