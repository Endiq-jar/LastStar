shader_type spatial;
render_mode cull_disabled, diffuse_toon, specular_disabled, shadows_disabled;

// The meadow's grass card, with no animation in it at all.
//
// Two crossed alpha-cut quads per tuft, painted by tools/gen_textures.py and
// drawn through one MultiMesh per 26 m chunk. That is 4 triangles an instance
// where the Quaternius tuft it replaces was 64, and the meadow is the one
// surface in this game that is stamped tens of thousands of times - which is
// where most of the frame's geometry came from.
//
// The wind was removed at the owner's request, and the removal is the whole of
// what this file does differently from the swaying version it grew out of. No
// TIME, no wind solve, no per-vertex displacement: a blade is where it was
// drawn. What is kept is everything that is about *not drawing* - the
// behind-camera collapse, the clearing around the character, the distance fade
// and the dissolve at the streaming edge - because each of those is a saving
// rather than a cost.
//
// Alpha-scissor, not alpha-blend: a cut-out discard costs no sorting and no
// blending on mobile GLES3.

// Albedo is deliberately dark and desaturated. Stylised grass gets its colour
// from the light and the sky gradient, not from the paint: a bright green albedo
// plus a bright sun is what produced the neon lime carpet that made the valley
// look like a golf course. Green sits near 120 degrees with blue held equal to
// red, because a warm sun plus a warm grade multiplies blue by ~0.4 and a
// blue-poor green lands on a pure lime.
uniform vec4 grass_color : source_color = vec4(0.125, 0.255, 0.125, 1.0);
uniform vec4 grass_tip : source_color = vec4(0.285, 0.430, 0.215, 1.0);
// How much of the painted sheet's own luminance survives into the lit colour.
//
// The sheet is drawn near-white on purpose: it carries the *shape* of the tuft -
// which blade is in front, where its rim is, how dark it is at the root - and
// the shader owns the hue. Multiplying a green shader colour by the green sheet
// that used to be here gave one flat lime for every blade; multiplying it by a
// pale sheet gives the same green with the tuft's own light and shade in it,
// which is what makes a field of four-triangle cards read as grass.
uniform float sheet_shading : hint_range(0.0, 1.0) = 0.78;
// The dry variant, halved in weight below: a meadow of one flat green looks
// synthetic, but too much of this is what gave the field its straw cast.
uniform vec4 dry_color : source_color = vec4(0.335, 0.345, 0.180, 1.0);
uniform float color_variance : hint_range(0.0, 1.0) = 0.20;
// Blades closer than this to the camera are collapsed so the third-person camera
// can see the character it is following.
uniform float near_clear : hint_range(0.0, 12.0) = 1.9;
// Camera position, pushed in from grass_field.gd once per frame. A uniform
// rather than a built-in on purpose: the camera built-ins are fragment-stage
// only in the spatial shader, and referencing one from vertex() is a compile
// error that Godot does not treat as fatal - it draws every blade with a default
// material instead, which once produced a pale lavender meadow.
uniform vec3 cam_origin = vec3(0.0);
uniform vec3 player_origin = vec3(0.0);
uniform float player_clear : hint_range(0.0, 3.0) = 0.95;
uniform vec3 cam_forward = vec3(0.0, 0.0, -1.0);
// Centre of the live field, so a chunk streamed out but not yet freed stops
// drawing instead of hanging in the air.
uniform vec3 view_origin = vec3(0.0);
uniform sampler2D blade_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.42;
// Height of the card in metres. The mesh is 0.694 m tall with its origin at the
// root; the value is here so the sightline test can name a real height instead of
// a magic number.
uniform float card_height : hint_range(0.05, 4.0) = 0.694;

varying float v_tint;
varying float v_cull;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float height = max(VERTEX.y, 0.0);

	// ---- view cull ------------------------------------------------------
	//
	//   1. Behind the camera, with a 6 m margin so a blade straddling the near
	//      plane is never dropped.
	//   2. Outside the streamed disc, which covers the frames between "out of
	//      range" and "queue_free actually ran".
	//
	// Collapsing the quad to a point keeps the instance buffer untouched: no
	// reallocation, no popping, and the degenerate triangles cost the rasteriser
	// essentially nothing. This cannot be an early `return` - Godot's shader
	// language rejects `return` in the vertex processor, and it is a hard
	// compile failure that takes the whole material to white.
	float view_depth = dot(origin - cam_origin, cam_forward);
	float view_keep = smoothstep(-6.0, 3.0, view_depth);
	float field_dist = length(origin.xz - view_origin.xz);
	view_keep *= 1.0 - smoothstep(176.0, 182.0, field_dist);

	// Per-instance colour variation, hashed from the instance origin so it is
	// stable frame to frame (no shimmer as the camera moves).
	float h = fract(sin(dot(origin.xz, vec2(12.9898, 78.233))) * 43758.5453);
	v_tint = h;

	float cam_dist = length(origin - cam_origin);
	float player_dist = length(origin - player_origin);

	// Blades standing BETWEEN the camera and the character. A radius around the
	// player alone is not enough: the camera is 3.9 m back, so a tuft 2 m from her
	// is nowhere near the clearing sphere and still covers her torso. Distance to
	// the camera-to-player segment removes exactly the grass that would occlude
	// her, and nothing else. Sampled at the blade's mid-height, because a tuft
	// whose ROOT is under the segment but which tops out below it occludes
	// nothing - testing the root carved a bald apron across the foreground.
	vec3 to_player = player_origin - cam_origin;
	vec3 blade_mid = origin + vec3(0.0, max(card_height, 0.1) * 0.55, 0.0);
	float seg_t = clamp(dot(blade_mid - cam_origin, to_player) / max(dot(to_player, to_player), 0.0001), 0.0, 1.0);
	float sightline_dist = length(blade_mid - (cam_origin + to_player * seg_t));

	// 0 right at the lens, 1 beyond near_clear. Collapsing rather than
	// discarding keeps the vertex count identical: no divergence, no popping.
	v_cull = smoothstep(near_clear * 0.22, near_clear * 0.72, cam_dist);
	v_cull *= smoothstep(player_clear * 0.6, player_clear, player_dist);
	v_cull *= smoothstep(0.16, 0.52, sightline_dist);
	v_cull *= view_keep;
	// v_cull == 0 makes fragment() discard, and a discard is far cheaper than
	// rasterising a collapsed quad - so a culled blade must reach exactly 0.
	VERTEX *= v_cull;
}

void fragment() {
	// Cut the blade shape out of the quad: anything outside the drawn tuft is
	// discarded outright, so a card never reads as a rectangle.
	vec4 tex = texture(blade_tex, UV);
	if (tex.a < alpha_cut) {
		discard;
	}
	if (v_cull < 0.02) {
		discard;
	}

	// Root-to-tip gradient. Dark at the base anchors the tuft in the soil,
	// brighter at the tip catches the sky. Narrowed from what it was: a wide
	// gradient turned every chunk into a two-tone blob at distance, which is what
	// gave the hillsides a mown-lawn banding.
	float t = clamp(UV.y, 0.0, 1.0);
	vec3 base = grass_color.rgb;
	base = mix(base, dry_color.rgb, v_tint * color_variance * 0.12);
	vec3 col = mix(base, grass_tip.rgb, pow(t, 1.35) * 0.66);

	// Cheap per-tuft value variation, so the field is not one surface. Centred a
	// little above 1.0: a range biased low is why the grass once read as wet mud
	// next to the terrain.
	col *= 0.94 + v_tint * 0.30;
	// The painted sheet's own light and shade, as a *factor* on the calibrated
	// albedo rather than as a colour mixed into it.
	//
	// This is the difference between a meadow and a starburst. Blending a fixed
	// 35% of the sheet's colour in (what this did) averages every blade toward
	// the same value: the rim, the blade behind, the dark root all land within a
	// few percent of each other, so 27 000 cards draw as one flat green sheet
	// with a spiky silhouette. Scaling by the sheet's luminance keeps the range
	// the illustrator drew - near-white blade faces, mid rims, dark roots - and
	// folds it into the calibrated hue.
	float sheet = dot(tex.rgb, vec3(0.2126, 0.7152, 0.0722));
	// Clamped: the brightest blade faces come back at 0.8-0.9 and a 1.55x gain
	// would push them past 1.0, where the albedo clips and the highlight is a
	// flat white blob instead of a lit blade.
	sheet = clampf(mix(1.0, sheet * 1.55, sheet_shading), 0.55, 1.28);
	col *= sheet;

	// --- distance fade ---------------------------------------------------
	// Far chunks cover many screen pixels each, so mute and cool them toward the
	// hillside colour and let the field settle into the terrain.
	float dist = length(VERTEX);
	float far_t = smoothstep(90.0, 190.0, dist);
	col = mix(col, vec3(0.180, 0.290, 0.175), far_t * 0.45);

	// Dissolve before the streaming edge, so the field does not end in a hard arc
	// of blades against bare terrain. Must match VIEW_CHUNKS * CHUNK_SIZE in
	// grass_field.gd.
	float edge = smoothstep(160.0, 180.0, dist);
	if (edge > 0.96) {
		discard;
	}

	// Same hue discipline as the terrain: a little luminance mixed back in keeps
	// the meadow from reading as a separate, greener surface.
	col = mix(col, vec3(dot(col, vec3(0.2126, 0.7152, 0.0722))), 0.08);

	ALBEDO = col;
	ROUGHNESS = 0.94;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	// Backlight fakes subsurface scatter: a blade glows when the light is behind
	// it, which is most of what makes grass read as grass. Small, because it
	// stacks over every blade in the field.
	BACKLIGHT = grass_tip.rgb * 0.14;
	// Shadow fill, on the same scale as the terrain's.
	//
	// This is a floor plus a shallow slope rather than a scale factor, and the
	// difference matters: matching the terrain's *scale* copies the other
	// surface's problem as well as its cure, because the two surfaces have very
	// different albedo ranges - terrain paint sits near 0.1, a grass blade near
	// 0.35, so the same k puts three times the light on the blade. What shadow
	// should look like is an absolute level, roughly 0.10-0.20 linear, and a
	// floor gets there whatever the albedo. tools/fill_check.py asserts this
	// agreement without a GPU, on every push.
	EMISSION = col * 0.55 + vec3(0.112, 0.124, 0.100);
}
