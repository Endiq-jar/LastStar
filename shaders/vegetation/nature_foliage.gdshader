shader_type spatial;
// Vertex-colour foliage for the Quaternius nature models.
//
// The pack ships no textures: every surface's colour is a named material, and
// the meshes carry no UVs at all (POSITION and NORMAL are the only attributes).
// NaturePack bakes those colours into vertex colours, so this shader reads COLOR
// and never samples a texture. That is the whole difference from
// foliage_anime.gdshader, which exists to cut a shape out of a painted card.
//
// Written for the Compatibility (OpenGL ES 3.0) renderer, same as the rest of
// the valley:
//
//   * cull_disabled, because a grass tuft's blades are single triangles and the
//     pack marks every material single-sided. Godot flips the normal for a
//     backface when culling is off, so the inside of a blade is lit as the
//     inside of a blade rather than as a hole.
//   * No alpha scissor and no ALPHA write: this geometry is solid, so there is
//     nothing to cut out and nothing to blend.
//   * Wind is a vertex operation through the shared wind include, weighted by
//     height up the model so roots stay planted. The include's uniforms
//     (wind_strength, player_world_pos) are the same ones vegetation_wind.gd
//     pushes every frame, so the character parts this foliage exactly as she
//     parts the meadow.
//   * The shadow fill is the same expression the grass and the terrain use
//     (col * 0.55 + a low floor). tools/fill_check.py exists because these
//     surfaces disagreed once and the meadow read as a lawn hovering over a
//     hole; a new surface has to land in the same value range.

#include "res://shaders/vegetation/foliage_wind.gdshaderinc"

render_mode cull_disabled, diffuse_lambert;

uniform vec3 base_tint : source_color = vec3(1.0);
// Height of the model in metres. The wind weight is normalised by it, so a 3 m
// tree and a 0.5 m bush move by the same fraction of their own height instead
// of the tree swaying three times as far.
uniform float sway_height : hint_range(0.0, 24.0) = 1.0;
uniform float tint_variation : hint_range(0.0, 0.4) = 0.10;
uniform vec3 shadow_fill : source_color = vec3(0.22, 0.30, 0.22);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.35;
uniform float backlight_scale : hint_range(0.0, 1.0) = 0.35;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.92;
// Root-to-tip darkening. Grass and flowers use it; a rock passes 0.
uniform float base_darken : hint_range(0.0, 1.0) = 0.30;

varying float v_tint;
varying float v_height;

void vertex() {
	// MODEL_MATRIX already carries the MultiMesh instance transform, so this is
	// the vertex's world position.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// The models are authored with their origin on the ground, so local Y is the
	// height above the root - no half-height offset like the centred cards.
	float h_norm = clamp(VERTEX.y / max(sway_height, 0.0001), 0.0, 1.0);
	world_pos += wind_offset(world_pos, h_norm, h_norm, TIME);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world_pos, 1.0)).xyz;

	// Stable per-instance brightness from INSTANCE_CUSTOM.r, so a whole batch of
	// one mesh is not one flat colour.
	v_tint = 1.0 + (INSTANCE_CUSTOM.r - 0.5) * 2.0 * tint_variation;
	v_height = h_norm;
}

void fragment() {
	vec3 col = COLOR.rgb * base_tint * v_tint;
	col *= mix(1.0 - base_darken, 1.0, v_height);

	ALBEDO = col;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
	SPECULAR = 0.04;
	// Thin growth transmits light; wood and stone do not, and pass 0.
	BACKLIGHT = vec3(0.32, 0.45, 0.24) * backlight_scale;
	RIM = rim_strength;
	RIM_TINT = 0.35;
	// Same fill scale as the grass and the terrain - see the header.
	EMISSION = col * 0.55 + vec3(0.112, 0.124, 0.100);
}
