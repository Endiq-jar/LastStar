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
// Note the blue channel. A green albedo of (0.15, 0.27, 0.11) looks reasonable
// on paper, but a warm low sun plus a warm grade multiplies blue by ~0.4, and
// blue was already the weakest channel - so the lit result landed at rgb(82,163,9),
// a pure hue-92 lime with no blue left in it at all. Keeping blue at roughly half
// of green survives the warm light and reads as the soft green of lit grass.
//
// Hue is the thing being fixed, not just brightness. Measured off the rendered
// frame, the meadow's dominant 30-degree hue bin was bin 3 - yellow-green - with
// more than four times the pixels of any true green bin. The field was reading as
// straw, not as meadow, and no amount of saturation or luminance would have
// changed which colour it was.
//
// Green sits near 120 degrees. Grass albedo of (0.13, 0.26, 0.13) has hue ~120
// with blue held equal to red, which keeps the warm sun from dragging the lit
// result toward orange - the earlier lesson that a blue-poor green lands on a
// pure lime still applies, so blue is not reduced here.
uniform vec4 grass_color : source_color = vec4(0.125, 0.255, 0.125, 1.0);
uniform vec4 grass_tip : source_color = vec4(0.285, 0.430, 0.215, 1.0);
// The dry variant is what mixed the yellow in. Kept, because a meadow that is one
// flat green looks synthetic, but halved in weight further down.
uniform vec4 dry_color : source_color = vec4(0.335, 0.345, 0.180, 1.0);
uniform float wind_strength : hint_range(0.0, 1.0) = 0.22;
uniform float wind_speed : hint_range(0.0, 4.0) = 1.4;
uniform vec2 wind_dir = vec2(0.85, 0.35);
uniform float color_variance : hint_range(0.0, 1.0) = 0.20;
// Blades closer than this to the camera are shrunk out of existence, so the
// third-person camera can see the character it is following. Without it the
// meadow in front of the lens is a wall of grass taller than the player.
uniform float near_clear : hint_range(0.0, 12.0) = 1.9;
// Camera position, pushed in from grass_field.gd once per frame.
//
// This is a uniform rather than a built-in on purpose: the camera built-ins
// (CAMERA_POSITION_WORLD, MAIN_CAM_INV_VIEW_MATRIX) are fragment-stage only in
// the spatial shader, and referencing either one from vertex() is a compile error
// that Godot does not treat as fatal - it logs the error and draws every blade
// with a default white material. That produced a pale lavender meadow that read
// as an art bug. A uniform works in both stages and is one float3 per frame.
uniform vec3 cam_origin = vec3(0.0);
// Centre of the character the camera follows, pushed in from grass_field.gd.
// Blades inside this radius are culled so the player is never buried: with an
// upright, metre-wide tuft rendered from a third-person camera, the meadow in
// front of the lens covers the character entirely, and no amount of colour or
// density tuning fixes that - only not drawing it there does.
uniform vec3 player_origin = vec3(0.0);
uniform float player_clear : hint_range(0.0, 3.0) = 0.95;
// Direction the camera is looking, pushed in from grass_field.gd.
//
// The camera built-ins are fragment-stage only, so a vertex shader cannot ask
// which way the camera faces - but it can test a plane if the plane's normal is
// handed to it as a uniform. Everything on the far side of that plane is behind
// the lens and cannot contribute a pixel, yet the vertex stage was running the
// full wind sum, the sightline solve and three smoothsteps for all of it, and
// the rasteriser was feeding millions of degenerate quads to the fragment
// stage so they could be discarded. On a gameplay camera roughly half of the
// 182 m grass disc is behind the player.
uniform vec3 cam_forward = vec3(0.0, 0.0, -1.0);
// Centre and radius of the live field, so a chunk that has been streamed out
// but not yet freed stops drawing instead of hanging in the air.
uniform vec3 view_origin = vec3(0.0);
uniform sampler2D blade_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.42;

varying float v_tint;
varying float v_height;
varying float v_cull;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float height = max(VERTEX.y, 0.0);

	// ---- view cull ------------------------------------------------------
	//
	// Two tests, both evaluated from the instance origin, so every vertex of a
	// quad reaches the same answer and the branch below is perfectly coherent
	// (no divergence, no wasted work on the far side of it).
	//
	//   1. Behind the camera. Signed distance along the view direction, with a
	//      6 m margin so a blade that straddles the near plane - part of it
	//      still on screen - is never dropped.
	//   2. Outside the streamed disc. Chunks are freed when the player walks
	//      away; this covers the frames between "out of range" and "queue_free
	//      actually ran".
	//
	// Collapsing the quad to a point rather than branching to a discard keeps
	// the instance buffer untouched - no reallocation, no popping of the
	// transform array, and the degenerate triangles cost the rasteriser
	// essentially nothing.
	float view_depth = dot(origin - cam_origin, cam_forward);
	float view_keep = smoothstep(-6.0, 3.0, view_depth);
	float field_dist = length(origin.xz - view_origin.xz);
	view_keep *= 1.0 - smoothstep(176.0, 182.0, field_dist);
	if (view_keep <= 0.0) {
		VERTEX = vec3(0.0);
		v_tint = 0.0;
		v_height = 0.0;
		v_cull = 0.0;
		return;
	}

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

	// Distance from this instance to the camera, in world space. VERTEX is in
	// model space here and MODEL_MATRIX is the instance transform, so the world
	// position of the tuft's base is MODEL_MATRIX[3].xyz, which is `origin`.
	float cam_dist = length(origin - cam_origin);
	// Also collapse blades standing on top of the character.
	float player_dist = length(origin - player_origin);

	// ...and blades standing BETWEEN the camera and the character. A radius around
	// the player alone is not enough: the camera is 3.9 m back, so a tuft at, say,
	// 2 m from her is nowhere near the clearing sphere and still sits directly in
	// the sightline, covering her torso. Distance to the camera-to-player segment
	// removes exactly the grass that would occlude her, in one smoothstep, and
	// nothing else.
	vec3 to_player = player_origin - cam_origin;
	// Measured from the middle of the blade, not from the root.
	//
	// Testing the root was clearing a huge bald apron across the foreground.
	// The camera sits 1.45 m up and the sightline drops toward her waist, so
	// the segment runs well above the ground it passes over; but a tuft whose
	// ROOT is under that segment still counted as occluding it and was
	// collapsed, even though the blade topped out half a metre below the line
	// and could not have hidden anything. Sampling the blade's mid-height means
	// only grass that actually crosses the sightline is cleared.
	vec3 blade_mid = origin + vec3(0.0, height * 0.55, 0.0);
	float seg_t = clamp(dot(blade_mid - cam_origin, to_player) / max(dot(to_player, to_player), 0.0001), 0.0, 1.0);
	float sightline_dist = length(blade_mid - (cam_origin + to_player * seg_t));
	// 0 right at the lens, 1 beyond near_clear. Collapsing the quad (rather than
	// discarding) keeps the vertex count identical, so there is no branch
	// divergence and no popping in the instance buffer.
	// The near clearing keeps blades out of the lens, but it was carved at up to
	// 2.6 m and, with the camera only 3.9 m back, that empty apron filled the
	// bottom third of the gameplay frame - bare shaded terrain under a bright
	// meadow, which is the dark shelf still visible under the character. Start
	// the carves closer to the lens so the grass reaches further toward her.
	v_cull = smoothstep(near_clear * 0.22, near_clear * 0.72, cam_dist);
	v_cull *= smoothstep(player_clear * 0.6, player_clear, player_dist);
	v_cull *= smoothstep(0.16, 0.52, sightline_dist);
	// The view cull from the top of this function, folded in rather than
	// applied as a separate multiply so the near-clear and the sightline clear
	// keep working exactly as before when the instance survives it.
	v_cull *= view_keep;
	VERTEX *= v_cull;
}

void fragment() {
	// Cut the blade shape out of the quad. Anything outside the drawn tuft is
	// discarded outright, so the quad never reads as a rectangle.
	vec4 tex = texture(blade_tex, UV);
	if (tex.a < alpha_cut || v_cull < 0.02) {
		discard;
	}

	// Root-to-tip gradient. Dark at the base anchors the tuft in the soil;
	// brighter at the tip catches the sky. The gradient is narrower than it
	// used to be - a wide one turned every chunk into a two-tone blob at
	// distance, which is what gave the hillsides that mown-lawn banding.
	float t = clamp(UV.y, 0.0, 1.0);
	vec3 base = grass_color.rgb;
	// Some tufts lean dry/yellow, the way a real meadow is not one flat green.
	// 0.22 -> 0.12. The dry mix is the direct source of the yellow cast, and at
	// 0.22 blended with the tint noise a fifth of every tuft leaned straw.
	base = mix(base, dry_color.rgb, v_tint * color_variance * 0.12);
	vec3 col = mix(base, grass_tip.rgb, pow(t, 1.35) * 0.66);

	// Break up the flat fill with a cheap per-tuft value variation. Without
	// this every tuft has identical colour and the field reads as one surface.
	// Centred a little above 1.0: the previous 0.86-1.14 range biased the whole
	// field darker, which is why the grass read as wet mud next to the terrain.
	col *= 0.94 + v_tint * 0.30;

	// --- distance fade ------------------------------------------------------
	// Far chunks cover many screen pixels each with a quad, so their flat colour
	// dominates the silhouette. Mute and cool them toward the hillside colour so
	// the field settles into the terrain instead of hovering over it.
	float dist = length(VERTEX);
	// Fade to the meadow's own mid tone, not to a dark forest green - the field
	// has to sit in the hillside, and the hillside is not dark.
	// Stretched with the reach. At 60-140 m the whole field past 140 m sat at the
	// far colour, which is a flat wash of muted green across half the newly
	// extended meadow.
	float far_t = smoothstep(90.0, 190.0, dist);
	col = mix(col, vec3(0.180, 0.290, 0.175), far_t * 0.45);

	// Dissolve before the streaming edge. Grass only exists in a 130 m radius
	// around the player, and the shader was drawing right up to that boundary -
	// a hard arc of blades against bare terrain, plainly visible in the gameplay
	// frame. This must match VIEW_CHUNKS * CHUNK_SIZE in grass_field.gd, which is
	// now 7 * 26 = 182 m. Leaving these at 112/128 after raising the field's reach
	// would have kept the old hard arc and thrown away the new grass.
	float edge = smoothstep(160.0, 180.0, dist);
	if (edge > 0.96) {
		discard;
	}

	// Same hue discipline as the terrain: the field has to sit in the hillside, and
	// the hillside is no longer a saturated hue. A little luminance mixed back in
	// keeps the meadow from reading as a separate, greener surface.
	// Was 0.14. Pulling a quarter of the way to grey is a large part of why the
	// field read as dusty rather than green; 0.08 still settles the field into the
	// hillside without washing the hue out.
	col = mix(col, vec3(dot(col, vec3(0.2126, 0.7152, 0.0722))), 0.08);

	ALBEDO = col;
	ROUGHNESS = 0.94;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	// Backlight fakes subsurface scatter: blades glow when lit from behind,
	// which is most of what makes wind-blown grass look alive. Small, because
	// it stacks over every blade in the field.
	BACKLIGHT = grass_tip.rgb * 0.14;
	// Shadow fill, matched to the terrain.
	//
	// This was `base * 0.10 + 0.014` - a tenth of the albedo - while the terrain
	// shader's own fill is around twice the albedo. The two surfaces were
	// therefore lit on scales roughly twenty times apart, and that mismatch, not
	// the terrain, is what the render probe has been reporting as
	// "shadowed ground is reading as a hole" at a lit/dark ratio of 7.8x against
	// its 1.8-3.0 target.
	//
	// The mistake in the original reasoning is visible in the old comment: it
	// worried that a proportional term would be too small because "base is around
	// 0.15, so 0.02 of it is three thousandths of a stop". That is true of
	// 1.0/255 steps in the dark, but the fill is not competing with 8-bit
	// quantisation - it is competing with the terrain next to it, which is being
	// lifted by ~2x. A tenth of the albedo cannot meet a 2x lift from below.
	//
	// Matching the terrain's scale lets a blade and the ground under it land in
	// one value range, which is what stops the meadow reading as a bright lawn
	// floating over a void. It is `col`, the same variable this shader hands to
	// ALBEDO, and not `base`: `col` carries the distance fade and the hue
	// neutralisation, so a far blade dims in fill exactly as it dims in albedo.
	// Filling from `base` would light distant blades more than near ones and
	// reopen the seam at the streaming edge.
	//
	// tools/fill_check.py asserts this agreement without a GPU, which is how it
	// is now checked on every push instead of only when a framebuffer exists.
	// A *floor plus a shallow slope*, not a scale factor.
	//
	// 1.95x matched the terrain's fill scale in the dark and blew the meadow
	// white in the light: the probe's brightest ground pixel became
	// rgb(235,255,197) with green clipped at 255, so the lit/dark ratio only
	// fell from 7.8x to 4.9x while the foreground turned into a glowing mass.
	// Matching a scale factor copies the other surface's problem as well as its
	// cure, because the two surfaces have very different albedo ranges -
	// terrain paint sits near 0.1, a grass blade near 0.35, so the same k puts
	// three times the light on the blade.
	//
	// What shadow should look like is an absolute level: the ambient-only
	// irradiance, roughly 0.10-0.20 linear. A floor gets there regardless of
	// albedo; a shallow slope on top keeps painted variation visible inside the
	// shade instead of flattening it to one value.
	//
	//   shade blade (col 0.15) -> 0.17      sunlit blade (col 0.5) -> 0.36
	//
	// versus 0.02 and 0.98 before, which was both a black hole and a highlight
	// clip in the same shader.
	// Floor raised alongside terrain_anime.gdshader for the same reason - see the
	// note there. These two must move together or the meadow separates from the
	// hillside it is standing on.
	EMISSION = col * 0.55 + vec3(0.112, 0.124, 0.100);
}
