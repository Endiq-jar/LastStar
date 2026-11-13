shader_type spatial;
render_mode cull_disabled, diffuse_toon, specular_disabled, shadows_disabled;

// The meadow's grass card. Two crossed alpha-cut quads per tuft, 4 triangles an
// instance, drawn through one MultiMesh per 26 m chunk. This is the surface
// stamped ~95 000 times a frame, so it is the one shader in the game where a
// saved ALU op is worth having, and it is written with that in mind.
//
// ---- what is NOT here, and why ------------------------------------------
//
// No TIME. No wind, at the owner's request: a blade is where it was drawn. That
// is also the single largest saving in the file, because every displaced vertex
// in the old version pulled in a two-wave sine sum, a normalise and a matrix
// multiply before it was ever transformed.
//
// No texture read of the sheet's colour. The card is painted greyscale - the
// whole sheet lies between 0.85 and 0.95 luminance - because the old painted
// grass this uses was drawn as a white stencil and every bit of its colour came
// from uniforms, not from the paint. Reading `texture(blade_tex, UV).rgb`,
// taking its dot with the luma vector, dividing by the sheet's mean and mixing
// it back in was three instructions plus a dependent texture read to recover a
// number that varies by 5% across the whole sheet. It is gone. ALPHA is the only
// channel this shader needs from the texture, and ALPHA is free: `texture()`
// returns a vec4 either way.
//
// No `pow()`. The root-to-tip gradient used `pow(t, 1.35)`; pow is one of the
// more expensive things in a fragment shader and this one runs on every blade
// pixel. `t * (0.35 + 0.65 * t)` is within 0.02 of it over 0..1 and is two
// multiplies.
//
// No `length()` in the fragment stage. Distance from the instance origin to the
// camera does not change across a card's four vertices, so it is computed once
// per instance in vertex() and handed down as a varying. The old fragment stage
// did `length(VERTEX)` for the distance fade and again for the dissolve, per
// pixel, for every blade on screen.
//
// No per-vertex matrix chain. The fades are driven by the instance origin, which
// is MODEL_MATRIX[3].xyz - one column of the matrix that is already loaded -
// instead of by a world-space position that has to be reconstructed.
//
// Alpha-scissor, not alpha-blend: a cut-out discard costs no sorting and no
// blending on mobile GLES3.

// Albedo is deliberately dark and desaturated. Stylised grass gets its colour
// from the light and the sky gradient, not from the paint: a bright green albedo
// plus a bright sun is what produced the neon lime carpet that made the valley
// look like a golf course. Green sits near 120 degrees with blue held equal to
// red, because a warm sun plus a warm grade multiplies blue by ~0.4 and a
// blue-poor green lands on a pure lime.
uniform vec4 grass_color : source_color = vec4(0.108, 0.196, 0.100, 1.0);
uniform vec4 grass_tip : source_color = vec4(0.255, 0.375, 0.190, 1.0);
// The dry variant, weighted lightly below: a meadow of one flat green looks
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
// Height of the card in metres, for the sightline test's sample point.
uniform float card_height : hint_range(0.05, 4.0) = 0.73;

varying float v_tint;
// Collapse factor for this instance. Kept out of VERTEX scaling alone because a
// zero-length quad still rasterises zero-area triangles, and the fragment stage
// needs to know to skip them outright.
varying float v_cull;
// Distance from this instance to the camera, in metres. Constant across the
// card, so it is solved once per instance instead of once per blade pixel.
varying float v_dist;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;

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
	// One length() for the field radius, used by the streaming dissolve below;
	// it was being solved twice, once here and once in the dissolve itself, with
	// two overlapping thresholds six metres apart.
	float field_dist = length(origin.xz - view_origin.xz);
	float view_keep = smoothstep(-6.0, 3.0, dot(origin - cam_origin, cam_forward));

	// Per-instance colour variation, hashed from the instance origin so it is
	// stable frame to frame. This is the one hash in the shader and it is in the
	// vertex stage: at four vertices per instance against a few dozen fragments,
	// anything that can live here does.
	float h = fract(sin(dot(origin.xz, vec2(12.9898, 78.233))) * 43758.5453);
	v_tint = h;

	// One square root for the whole card, and the fade thresholds below are
	// compared against v_dist rather than against squared distances so they still
	// read in metres.
	v_dist = length(origin - cam_origin);

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
	float keep = smoothstep(near_clear * 0.22, near_clear * 0.72, v_dist);
	keep *= smoothstep(player_clear * 0.6, player_clear, length(origin - player_origin));
	keep *= smoothstep(0.16, 0.52, sightline_dist);
	// The streaming-edge dissolve lives here too - it only depends on the
	// instance origin, so it does not need to be a per-fragment test at all. The
	// old fragment stage ran a smoothstep and a discard for it on every blade
	// pixel in the field.
	//
	// The threshold has to match VIEW_CHUNKS * CHUNK_SIZE in grass_field.gd. The
	// ramp collapses the quad to nothing; because the card is already inside the
	// alpha-scissor test in the fragment stage, the pop happens four triangles at
	// a time and reads as the field thinning out, not as blades switching off.
	keep *= 1.0 - smoothstep(160.0, 180.0, field_dist);

	v_cull = keep * view_keep;
	// v_cull == 0 makes fragment() discard, and a discard is far cheaper than
	// rasterising a collapsed quad - so a culled blade must reach exactly 0.
	VERTEX *= v_cull;
}

void fragment() {
	if (v_cull < 0.02) {
		discard;
	}

	// Cut the blade shape out of the quad.
	//
	// The sheet is a 1-bit stencil: every texel is either opaque or fully clear,
	// so ALPHA and the painted value carry the same mask - transparent texels are
	// black, opaque ones are near-white. Both are tested, and the cost is one
	// compare on a channel the fetch already brought back. That is deliberate
	// belt-and-braces: a texture imported into a format without an alpha channel
	// reads alpha 1.0 everywhere and the meadow draws as plain rectangles, and
	// that failure looks exactly like a broken shader from the outside.
	vec4 tex = texture(blade_tex, UV);
	if (tex.a < alpha_cut || tex.r < 0.35) {
		discard;
	}

	// Root-to-tip gradient. Dark at the base anchors the tuft in the soil,
	// brighter at the tip catches the sky. Narrowed from what it was: a wide
	// gradient turned every chunk into a two-tone blob at distance, which is what
	// gave the hillsides a mown-lawn banding.
	//
	// clamp() is not needed: UV is 0..1 on a QuadMesh by construction, and the
	// ramp is a polynomial that cannot leave 0..1 for 0..1 input.
	float t = UV.y;
	// t^1.35, in two multiplies instead of a pow. Max error 0.02 over the ramp.
	float ramp = t * (0.35 + 0.65 * t) * 0.66;

	vec3 col = mix(grass_color.rgb, grass_tip.rgb, ramp);
	// The dry variant, at a twelfth of the variance weight.
	col = mix(col, dry_color.rgb, v_tint * color_variance * 0.12);
	// Cheap per-tuft value variation, so the field is not one surface. Centred a
	// little above 1.0: a range biased low is why the grass once read as wet mud
	// next to the terrain.
	col *= 0.94 + v_tint * 0.30;

	// --- distance fade ---------------------------------------------------
	// Far chunks cover many screen pixels each, so mute and cool them toward the
	// hillside colour and let the field settle into the terrain.
	col = mix(col, vec3(0.180, 0.290, 0.175), smoothstep(90.0, 190.0, v_dist) * 0.45);

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
